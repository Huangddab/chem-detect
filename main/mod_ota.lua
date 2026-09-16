--[[
@module  mod_ota
@brief   OTA 固件升级模块 (HTTP 服务器 + FOTA)
注: 网络模式管理已拆分到 mod_net.lua

OTA 流程:
  1. mod_net 启动 WiFi (AP/STA) 并启动 HTTP 服务器
  2. 手机/电脑连接后访问 192.168.4.1 (AP) 或 STA IP
  3. 网页上传固件 → FOTA 写入 → 校验 → 重启

对外接口:
  mod_ota.get_state()             — 获取 OTA 升级状态
  mod_ota.is_running()            — 是否有传输正在进行

🤖 整体或部分由 opencode 生成
]]

local app_data = require "app_data"
-- 星型架构：不直接 require mod_screen，通过 app_data 回调中介调用

local mod_ota = {}

-- ========== 模块状态 ==========
-- idle → initializing → ready → uploading → verifying → success / fail
local ota_state = "idle"
local ota_progress = 0
local ota_error = ""
local fw_received = 0
local fota_inited = false

-- 异步任务状态（HTTP回调不能调用sys.wait，通过sys.taskInit+轮询模式处理）
-- 屏幕/文件操作通过 app_data 回调中介调用 mod_screen
local screen_api = nil            -- 运行时赋值为 app_data.get_callback("screen_ota")
local screen_task_pending = false
local screen_task_result = nil

-- ========== 传输互斥锁 ==========
-- 确保 固件OTA / 屏幕OTA / 文件传输 三者同时只能进行一个
-- "none" / "fw_ota" / "screen_ota" / "file_transfer"
local transfer_lock = "none"

-- 尝试获取传输锁
local function acquire_transfer(name)
    if transfer_lock ~= "none" then
        return false, transfer_lock
    end
    transfer_lock = name
    log.info("OTA", "传输锁已获取:", name)
    return true
end

-- 释放传输锁
local function release_transfer()
    if transfer_lock ~= "none" then
        log.info("OTA", "传输锁已释放:", transfer_lock)
    end
    transfer_lock = "none"
end

-- ========== 内部工具 ==========

-- 更新 OTA 状态到 app_data
local function update_ota_data()
    app_data.update_ota(ota_state, ota_progress, nil, ota_error, VERSION or "001.000.000")
end

-- 获取 HTTP 服务器 IP（根据配置模式不同）
local function get_server_ip()
    local net_mode = app_data.get_config("net_mode") or "off"
    if net_mode == "ap" then
        local ip = socket.localIP(socket.LWIP_AP)
        if ip and ip ~= "0.0.0.0" then return ip end
        return "192.168.4.1"
    elseif net_mode == "sta" then
        local ip = socket.localIP(socket.LWIP_STA)
        if ip and ip ~= "0.0.0.0" then return ip end
        return "未知"
    end
    return "未知"
end

-- 获取屏幕 OTA 回调 API（延迟获取，确保 mod_screen 已注册）
local function get_screen_api()
    if not screen_api then
        screen_api = app_data.get_callback("screen_ota")
    end
    return screen_api
end

-- ========== 读取网页文件 ==========
local html_cache = nil        -- 内存缓存（避免每次请求读 flash）
local html_cache_gz = false

local OTA_HTML_GZ_PATHS = {
    "/luadb/ota.html.gz",
    "/ota.html.gz",
}
local OTA_HTML_PATHS = {
    "/ota.html",
    "/luadb/ota.html",
    "ota.html",
    "/luadb/web/ota.html",
}

local function read_html_file()
    -- 内存缓存（避免每次请求都读 flash）
    if html_cache then
        return html_cache, html_cache_gz
    end
    -- 优先读取 gzip 压缩版（8KB vs 49KB，避免 tcp_write 缓冲区溢出）
    for _, path in ipairs(OTA_HTML_GZ_PATHS) do
        local f = io.open(path, "rb")
        if f then
            local content = f:read("*a")
            f:close()
            if content and #content > 50 then
                log.info("OTA", "找到网页文件(gzip):", path, "大小:", #content)
                html_cache = content
                html_cache_gz = true
                return content, true
            end
        end
    end
    -- 回退到未压缩版本
    for _, path in ipairs(OTA_HTML_PATHS) do
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and #content > 100 then
                log.info("OTA", "找到网页文件:", path, "大小:", #content)
                html_cache = content
                html_cache_gz = false
                return content, false
            end
        end
    end
    log.error("OTA", "未找到 ota.html")
    return '<html><body style="font-family:sans-serif;padding:40px;">'
        .. '<h2>OTA 页面未找到</h2>'
        .. '<p>请在 Luatools 中添加 ota.html 或 ota.html.gz 文件重新烧录</p>'
        .. '</body></html>', false
end

-- ========== HTTP 路由分发 ==========

-- 路由表：{ uri_pattern = { handler = function, methods = "GET|POST" or nil } }
-- uri_pattern 支持精确匹配，handler 接收 (method, uri, headers, body) 返回 code, headers, body

-- 首页 / OTA 页面
local function route_index_ota(method, uri, headers, body)
    local html, is_gz = read_html_file()
    local hdrs = {["Content-Type"] = "text/html; charset=utf-8"}
    if is_gz then hdrs["Content-Encoding"] = "gzip" end
    return 200, hdrs, html
end

-- OTA 状态查询
local function route_ota_status(method, uri, headers, body)
    -- 固件OTA已结束则释放传输锁
    if (ota_state == "fail" or ota_state == "idle" or ota_state == "success") and transfer_lock == "fw_ota" then
        release_transfer()
    end
    local resp = json.encode({
        state = ota_state,
        progress = ota_progress,
        version = VERSION or "001.000.000",
        device_id = app_data.get().sys.device_id or "",
        error_msg = ota_error,
        received = fw_received,
        net_mode = app_data.get_config("net_mode") or "off",
        transfer_lock = transfer_lock,
    })
    return 200, {["Content-Type"] = "application/json"}, resp
end

-- OTA 开始
local function route_ota_begin(method, uri, headers, body)
    -- 互斥检查：确保同时只有一个传输操作
    local locked, holder = acquire_transfer("fw_ota")
    if not locked then
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "正在进行其他传输: " .. holder})
    end
    if ota_state ~= "idle" and ota_state ~= "fail" and ota_state ~= "success" then
        release_transfer()
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "正在升级中: " .. ota_state})
    end
    ota_state = "initializing"
    ota_progress = 0
    ota_error = ""
    fw_received = 0
    fota_inited = false
    update_ota_data()
    log.info("OTA", "开始初始化 FOTA...")
    sys.taskInit(function()
        if not fota.init() then
            log.error("OTA", "FOTA 初始化失败")
            ota_state = "fail"
            ota_error = "FOTA初始化失败"
            update_ota_data()
            release_transfer()
            return
        end
        fota_inited = true
        log.info("OTA", "等待底层准备...")
        local wait_count = 0
        while not fota.wait() do
            sys.wait(100)
            wait_count = wait_count + 1
            if wait_count > 50 then
                ota_state = "fail"
                ota_error = "等待底层超时"
                update_ota_data()
                fota.finish(false)
                release_transfer()
                return
            end
        end
        ota_state = "ready"
        update_ota_data()
        log.info("OTA", "底层就绪, 等待固件数据")
    end)
    return 200, {["Content-Type"] = "application/json"},
        json.encode({ok = true, msg = "正在初始化"})
end

-- OTA 分块上传
local function route_ota_chunk(method, uri, headers, body)
    -- 互斥检查
    if transfer_lock ~= "fw_ota" then
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = transfer_lock == "none" and "未开始固件OTA" or "正在进行其他传输: " .. transfer_lock})
    end
    if ota_state ~= "ready" and ota_state ~= "uploading" then
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "状态错误: " .. ota_state})
    end
    if not body or #body == 0 then
        return 400, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "无数据"})
    end
    if not fota_inited then
        return 500, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "FOTA未初始化"})
    end
    ota_state = "uploading"
    fw_received = fw_received + #body
    local buf = zbuff.create(#body)
    buf:write(body)
    local result, is_done = fota.run(buf)
    buf:del()
    log.info("OTA", "写入:", #body, "累计:", fw_received)
    if not result then
        ota_state = "fail"
        ota_error = "固件写入失败"
        update_ota_data()
        fota.finish(false)
        release_transfer()
        return 500, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "写入失败"})
    end
    ota_progress = 80
    update_ota_data()
    if is_done then
        ota_state = "verifying"
        ota_progress = 90
        update_ota_data()
        log.info("OTA", "写入完成, 启动校验...")
        sys.taskInit(function()
            local check_count = 0
            while check_count < 30 do
                sys.wait(100)
                local succ, done = fota.isDone()
                if not succ then
                    ota_state = "fail"
                    ota_error = "校验失败"
                    update_ota_data()
                    fota.finish(false)
                    release_transfer()
                    return
                end
                if done then
                    ota_progress = 100
                    ota_state = "success"
                    update_ota_data()
                    fota.finish(true)
                    release_transfer()
                    log.info("OTA", "校验通过, 2秒后重启...")
                    sys.wait(2000)
                    rtos.reboot()
                    return
                end
                check_count = check_count + 1
                ota_progress = 90 + check_count // 3
                update_ota_data()
            end
            ota_state = "fail"
            ota_error = "校验超时"
            update_ota_data()
            fota.finish(false)
            release_transfer()
        end)
        return 200, {["Content-Type"] = "application/json"},
            json.encode({ok = true, done = true, msg = "校验中"})
    end
    return 200, {["Content-Type"] = "application/json"},
        json.encode({ok = true, done = false, received = fw_received})
end

-- OTA 取消
local function route_ota_cancel(method, uri, headers, body)
    if ota_state == "uploading" or ota_state == "ready" or ota_state == "initializing" then
        if fota_inited then fota.finish(false) end
        ota_state = "idle"
        ota_progress = 0
        ota_error = ""
        fw_received = 0
        fota_inited = false
        update_ota_data()
        release_transfer()
        log.info("OTA", "升级已取消")
        return 200, {["Content-Type"] = "application/json"},
            json.encode({ok = true, msg = "已取消"})
    end
    return 409, {["Content-Type"] = "application/json"},
        json.encode({ok = false, error = "无法取消: " .. ota_state})
end

-- 系统信息
local function route_sysinfo(method, uri, headers, body)
    local data = app_data.get()
    local lua_total, lua_used = rtos.meminfo()
    local resp = json.encode({
        device_id = data.sys.device_id or "",
        version = VERSION or "001.000.000",
        uptime = data.sys.uptime or 0,
        ip = get_server_ip(),
        net_mode = app_data.get_config("net_mode") or "off",
        mqtt_connected = data.mqtt.connected,
        mem_usage = string.format("%.1f%%", lua_used / lua_total * 100),
        lua_free_kb = math.floor((lua_total - lua_used) / 1024),
        transfer_lock = transfer_lock,
    })
    return 200, {["Content-Type"] = "application/json"}, resp
end

-- ========== 屏幕 OTA / 文件透传异步调用辅助 ==========

-- 启动异步屏幕操作，返回 200 + "处理中"
-- @param task_fn function(callback_api) 异步协程函数，返回结果表
-- @param busy_msg 忙碌时的错误信息（409）
-- @return code, headers, body
local function async_screen_task(task_fn, busy_msg, lock_name)
    local api = get_screen_api()
    if not api then
        return 503, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "屏幕模块未加载"})
    end
    -- 检查上一次异步任务是否失败，失败则释放锁
    if screen_task_result and screen_task_result.ok == false then
        release_transfer()
    end
    if screen_task_pending then
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = busy_msg or "上一个操作未完成"})
    end
    -- 获取传输锁（仅 begin 路由传 lock_name）
    if lock_name then
        local ok, holder = acquire_transfer(lock_name)
        if not ok then
            return 409, {["Content-Type"] = "application/json"},
                json.encode({ok = false, error = "正在进行其他传输: " .. holder})
        end
    end
    screen_task_pending = true
    screen_task_result = nil
    sys.taskInit(function()
        screen_task_result = task_fn(api)
        screen_task_pending = false
        -- 失败时自动释放锁
        if lock_name and screen_task_result and screen_task_result.ok == false then
            release_transfer()
        end
    end)
    return 200, {["Content-Type"] = "application/json"},
        json.encode({ok = true, msg = "处理中..."})
end

-- 屏幕 OTA：开始升级
local function route_screen_ota_begin(method, uri, headers, body)
    local file_size = tonumber(body) or 0
    if file_size <= 0 then
        return 400, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "无效的文件大小"})
    end
    return async_screen_task(function(api)
        local ok, err = api.begin(file_size)
        return {ok = ok, err = err}
    end, "上一个操作未完成", "screen_ota")
end

-- 屏幕 OTA：上传固件数据块
local function route_screen_ota_chunk(method, uri, headers, body)
    local api = get_screen_api()
    if not api then
        return 503, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "屏幕模块未加载"})
    end
    -- 检查上一次异步任务是否失败
    if screen_task_result and screen_task_result.ok == false then
        release_transfer()
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "上一次操作失败: " .. (screen_task_result.err or "")})
    end
    -- 互斥检查
    if transfer_lock ~= "screen_ota" then
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = transfer_lock == "none" and "未开始屏幕OTA" or "正在进行其他传输: " .. transfer_lock})
    end
    if screen_task_pending then
        return 202, {["Content-Type"] = "application/json"},
            json.encode({ok = true, pending = true, msg = "处理中..."})
    end
    if not body or #body == 0 then
        return 400, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "无数据"})
    end
    local chunk_data = body
    screen_task_pending = true
    screen_task_result = nil
    sys.taskInit(function()
        local ok, done, err = api.write_chunk(chunk_data)
        screen_task_result = {ok = ok, err = err, done = done}
        screen_task_pending = false
        -- 失败时释放锁
        if not ok then
            release_transfer()
        end
    end)
    return 200, {["Content-Type"] = "application/json"},
        json.encode({ok = true, msg = "传输中..."})
end

-- 屏幕 OTA：完成升级
local function route_screen_ota_finish(method, uri, headers, body)
    return async_screen_task(function(api)
        local ok = api.finish()
        release_transfer()
        return {ok = ok}
    end, "上一个操作未完成")
end

-- 屏幕 OTA：状态查询
local function route_screen_ota_status(method, uri, headers, body)
    local api = get_screen_api()
    if not api then
        return 503, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "屏幕模块未加载"})
    end
    -- 检查异步任务是否失败
    if screen_task_result and screen_task_result.ok == false then
        release_transfer()
    end
    local s = api.get_status()
    -- 操作已结束则释放锁
    if (s.state == "success" or s.state == "fail" or s.state == "idle") and transfer_lock == "screen_ota" then
        release_transfer()
    end
    local r = screen_task_result or {}
    return 200, {["Content-Type"] = "application/json"},
        json.encode({state = s.state, progress = s.progress, received = s.received,
                     pending = screen_task_pending, ok = r.ok, err = r.err, done = r.done,
                     transfer_lock = transfer_lock})
end

-- 屏幕 OTA：取消升级
local function route_screen_ota_cancel(method, uri, headers, body)
    local api = get_screen_api()
    if not api then
        return 503, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "屏幕模块未加载"})
    end
    screen_task_pending = false
    screen_task_result = nil
    release_transfer()
    sys.taskInit(function()
        api.cancel()
    end)
    return 200, {["Content-Type"] = "application/json"},
        json.encode({ok = true, msg = "已取消"})
end

-- 文件透传：开始
local function route_screen_file_begin(method, uri, headers, body)
    local api = get_screen_api()
    if not api then
        return 503, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "屏幕模块未加载"})
    end
    if not body or #body == 0 then
        return 400, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "参数为空"})
    end
    local dest_path, file_size = body:match("^([^,]+),(%d+)$")
    if not dest_path or not file_size then
        return 400, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "格式: 路径,大小"})
    end
    local dp, fs = dest_path, tonumber(file_size)
    return async_screen_task(function(api_fn)
        local ok, err = api_fn.file_begin(dp, fs)
        return {ok = ok, err = err}
    end, "上一个操作未完成", "file_transfer")
end

-- 文件透传：上传数据块
local function route_screen_file_chunk(method, uri, headers, body)
    local api = get_screen_api()
    if not api then
        return 503, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "屏幕模块未加载"})
    end
    -- 检查上一次异步任务是否失败
    if screen_task_result and screen_task_result.ok == false then
        release_transfer()
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "上一次操作失败: " .. (screen_task_result.err or "")})
    end
    -- 互斥检查
    if transfer_lock ~= "file_transfer" then
        return 409, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = transfer_lock == "none" and "未开始文件传输" or "正在进行其他传输: " .. transfer_lock})
    end
    if screen_task_pending then
        return 202, {["Content-Type"] = "application/json"},
            json.encode({ok = true, pending = true, msg = "处理中..."})
    end
    if not body or #body == 0 then
        return 400, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "无数据"})
    end
    local chunk_data = body
    screen_task_pending = true
    screen_task_result = nil
    sys.taskInit(function()
        local ok, done, err = api.file_chunk(chunk_data)
        screen_task_result = {ok = ok, err = err, done = done}
        screen_task_pending = false
        -- 失败时释放锁
        if not ok then
            release_transfer()
        end
    end)
    return 200, {["Content-Type"] = "application/json"},
        json.encode({ok = true, msg = "传输中..."})
end

-- 文件透传：完成
local function route_screen_file_finish(method, uri, headers, body)
    return async_screen_task(function(api)
        local ok = api.file_finish()
        release_transfer()
        return {ok = ok}
    end, "上一个操作未完成")
end

-- 文件透传：状态查询
local function route_screen_file_status(method, uri, headers, body)
    local api = get_screen_api()
    if not api then
        return 503, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "屏幕模块未加载"})
    end
    -- 检查异步任务是否失败
    if screen_task_result and screen_task_result.ok == false then
        release_transfer()
    end
    local s = api.file_get_status()
    -- 操作已结束则释放锁
    if (s.state == "success" or s.state == "fail" or s.state == "idle") and transfer_lock == "file_transfer" then
        release_transfer()
    end
    local r = screen_task_result or {}
    return 200, {["Content-Type"] = "application/json"},
        json.encode({state = s.state, progress = s.progress, received = s.received,
                     pending = screen_task_pending, ok = r.ok, err = r.err, done = r.done,
                     transfer_lock = transfer_lock})
end

-- 文件透传：取消
local function route_screen_file_cancel(method, uri, headers, body)
    local api = get_screen_api()
    if not api then
        return 503, {["Content-Type"] = "application/json"},
            json.encode({ok = false, error = "屏幕模块未加载"})
    end
    screen_task_pending = false
    screen_task_result = nil
    release_transfer()
    sys.taskInit(function()
        api.file_cancel()
    end)
    return 200, {["Content-Type"] = "application/json"},
        json.encode({ok = true, msg = "已取消"})
end

-- ========== 蓝牙污染源路由管理 ==========

-- 查询全部污染源路由
local function route_ble_sources_list(method, uri, headers, body)
    local sources = app_data.get_ble_sources()
    return 200, { ["Content-Type"] = "application/json" },
        json.encode({ ok = true, total = #sources, sources = sources })
end

-- 添加污染源路由
local function route_ble_sources_add(method, uri, headers, body)
    if not body or #body == 0 then
        return 400, { ["Content-Type"] = "application/json" },
            json.encode({ ok = false, error = "请求体为空" })
    end
    local entry = json.decode(body)
    if not entry or not entry.major then
        return 400, { ["Content-Type"] = "application/json" },
            json.encode({ ok = false, error = "JSON 解析失败或缺少 major 字段" })
    end
    local ok, result = app_data.add_ble_source(entry)
    if ok then
        return 200, { ["Content-Type"] = "application/json" },
            json.encode({ ok = true, source = result })
    else
        return 409, { ["Content-Type"] = "application/json" },
            json.encode({ ok = false, error = result })
    end
end

-- 删除污染源路由
local function route_ble_sources_delete(method, uri, headers, body)
    if not body or #body == 0 then
        return 400, { ["Content-Type"] = "application/json" },
            json.encode({ ok = false, error = "请求体为空" })
    end
    local req = json.decode(body)
    if not req or not req.major then
        return 400, { ["Content-Type"] = "application/json" },
            json.encode({ ok = false, error = "JSON 解析失败或缺少 major 字段" })
    end
    local ok, result = app_data.remove_ble_source(req.major)
    if ok then
        return 200, { ["Content-Type"] = "application/json" },
            json.encode({ ok = true, removed = result })
    else
        return 404, { ["Content-Type"] = "application/json" },
            json.encode({ ok = false, error = result })
    end
end

-- ========== HTTP 路由表 ==========

local ROUTES = {
    -- 静态页面
    { pattern = "/",             handler = route_index_ota },
    { pattern = "/index.html",   handler = route_index_ota },
    { pattern = "/ota",          handler = route_index_ota },
    { pattern = "/ota.html",     handler = route_index_ota },
    -- OTA 升级
    { pattern = "/ota/status",   handler = route_ota_status, method = "GET" },
    { pattern = "/ota/begin",    handler = route_ota_begin,  method = "POST" },
    { pattern = "/ota/chunk",    handler = route_ota_chunk,  method = "POST" },
    { pattern = "/ota/cancel",   handler = route_ota_cancel, method = "POST" },
    -- 系统信息
    { pattern = "/sysinfo",      handler = route_sysinfo,    method = "GET" },
    -- 屏幕 OTA
    { pattern = "/screen_ota/begin",  handler = route_screen_ota_begin,  method = "POST" },
    { pattern = "/screen_ota/chunk",  handler = route_screen_ota_chunk,  method = "POST" },
    { pattern = "/screen_ota/finish", handler = route_screen_ota_finish, method = "POST" },
    { pattern = "/screen_ota/status", handler = route_screen_ota_status, method = "GET" },
    { pattern = "/screen_ota/cancel", handler = route_screen_ota_cancel, method = "POST" },
    -- 文件透传
    { pattern = "/screen_file/begin",  handler = route_screen_file_begin,  method = "POST" },
    { pattern = "/screen_file/chunk",  handler = route_screen_file_chunk,  method = "POST" },
    { pattern = "/screen_file/finish", handler = route_screen_file_finish, method = "POST" },
    { pattern = "/screen_file/status", handler = route_screen_file_status, method = "GET" },
    { pattern = "/screen_file/cancel", handler = route_screen_file_cancel, method = "POST" },
    -- 蓝牙污染源路由管理
    { pattern = "/ble/sources",         handler = route_ble_sources_list,   method = "GET"  },
    { pattern = "/ble/sources/add",    handler = route_ble_sources_add,   method = "POST" },
    { pattern = "/ble/sources/delete",  handler = route_ble_sources_delete, method = "POST" },
}

-- ========== HTTP 请求处理（路由分发版） ==========
local function handle_http(fd, method, uri, headers, body)
    log.debug("OTA", "HTTP:", method, uri)

    for _, route in ipairs(ROUTES) do
        if route.pattern == uri then
            if route.method and route.method ~= method then
                return 405, {["Content-Type"] = "text/plain"}, "Method Not Allowed"
            end
            return route.handler(method, uri, headers, body)
        end
    end

    -- 未匹配到任何路由
    return 404, {["Content-Type"] = "text/plain"}, "Not Found: " .. uri
end

-- ========== 注册 HTTP handler 回调（供 mod_net 获取） ==========
app_data.register_callback("ota_http_handler", {
    get = function() return handle_http end,
})

-- ========== 对外接口 ==========

-- 获取 OTA 升级状态
function mod_ota.get_state()
    return ota_state, ota_progress, ota_error
end

function mod_ota.is_running()
    return transfer_lock ~= "none"
end

-- ========== 初始化 ==========
function mod_ota.init()
    log.info("OTA", "OTA 模块初始化")
    update_ota_data()

    -- 预读网页到内存缓存（避免首次访问时读 flash 的延迟）
    read_html_file()

    -- 网络模式切换订阅已移至 mod_net.init()
end

-- ========== 启动 ==========
function mod_ota.start()
    -- OTA 模块启动（网络启动已移至 mod_net.start）
    log.info("OTA", "OTA 模块已启动 (HTTP 服务器由 mod_net 启动)")
end

return mod_ota
