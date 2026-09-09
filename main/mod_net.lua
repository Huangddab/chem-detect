--[[
@module  mod_net
@brief   WiFi 网络模式管理 (AP / STA / OFF)

网络模式 (net_mode):
  "ap"  — WiFi AP 热点（手机连热点访问 OTA 网页）
  "sta" — WiFi STA（连接路由器联网）
  "off" — WiFi 关闭

本模块从 mod_ota.lua 拆分而来，负责 WiFi 硬件管理 + 网络模式切换。
HTTP 服务器由 mod_ota 通过 app_data 回调 "ota_http_handler" 提供 handler。

对外接口:
  mod_net.set_mode("ap")     — 切换网络模式（热切换，无需重启）
  mod_net.get_mode()         — 获取当前运行模式
  mod_net.get_modes()        — 获取所有可选模式列表

🤖 整体或部分由 opencode 生成
]]

local app_data = require "app_data"
-- 安全加载 DHCP 服务器模块（固件可能未内置）
local dhcpsrv_ok, dhcpsrv = pcall(require, "dhcpsrv")

local mod_net = {}

-- ========== 模块状态 ==========
local current_net_mode = nil
local http_started = false

-- ========== 可选网络模式 ==========
local NET_MODES = {
    { id = "off", name = "关闭",     desc = "关闭WiFi" },
    { id = "ap",  name = "WiFi热点", desc = "手机连热点访问OTA" },
    { id = "sta", name = "WiFi联网", desc = "连接路由器联网" },
}

-- ========== 获取 HTTP handler（通过 app_data 回调中介） ==========
local function get_http_handler()
    local api = app_data.get_callback("ota_http_handler")
    if api and api.get then
        return api.get()
    end
    return nil
end

-- ========== 网络模式: WiFi AP 热点 ==========
local function start_wifi_ap()
    local config = app_data.get().config
    local ssid = config.ap_ssid or "Enboso"
    local password = config.ap_password or "enboso334968"

    -- 1. 初始化 WiFi 芯片
    wlan.init()
    sys.wait(300)

    -- 2. 设置为 AP 模式（从 STA 切回时必须！否则芯片还在 STA 模式）
    wlan.setMode(wlan.AP)
    sys.wait(100)

    -- 3. 创建 AP 热点
    log.info("NET", "创建 WiFi 热点:", ssid)
    wlan.createAP(ssid, password)
    sys.wait(500)

    -- 3. 设置 AP 网卡 IP
    netdrv.ipv4(socket.LWIP_AP, "192.168.4.1", "255.255.255.0", "0.0.0.0")

    -- 4. 等待 AP 网卡就绪
    local wait_count = 0
    while netdrv.ready(socket.LWIP_AP) ~= true do
        sys.wait(100)
        wait_count = wait_count + 1
        if wait_count > 60 then
            log.error("NET", "AP 创建超时")
            return false
        end
    end
    log.info("NET", "AP 网卡已就绪")

    -- 5. DHCP 服务器
    if dhcpsrv_ok and dhcpsrv then
        dhcpsrv.create({adapter = socket.LWIP_AP})
        log.info("NET", "DHCP 服务器已启动")
    else
        log.warn("NET", "dhcpsrv 不可用, 需手动设置静态 IP")
    end

    -- 6. HTTP 服务器（handler 由 mod_ota 通过回调提供）
    local handler = get_http_handler()
    if handler then
        local ok = httpsrv.start(80, handler, socket.LWIP_AP)
        log.info("NET", "httpsrv.start AP 返回:", tostring(ok))
        if ok then
            http_started = true
        else
            log.error("NET", "httpsrv.start AP 失败")
            return false
        end
    else
        log.error("NET", "HTTP handler 未注册, 无法启动 HTTP 服务器")
        return false
    end

    local ip = socket.localIP(socket.LWIP_AP)
    if not ip or ip == "0.0.0.0" then ip = "192.168.4.1" end
    log.info("NET", "WiFi AP 已启动:", ssid)
    log.info("NET", "访问 http://" .. ip .. " 进行 OTA 升级")
    return true
end

-- ========== 网络模式: WiFi STA ==========
-- 参考官方 demo: LuatOS/module/Air8000/demo/wlan/wifi_sta.lua
-- 使用 IP_READY 事件驱动, 而非轮询 socket.localIP()
local function start_wifi_sta()
    local config = app_data.get().config
    local ssid = config.sta_ssid or ""
    local password = config.sta_password or ""

    if ssid == "" then
        log.error("NET", "sta_ssid 为空, 请通过屏幕设置页配置")
        return false
    end

    -- 1. 初始化 WiFi 芯片
    wlan.init()
    sys.wait(300)

    -- 2. 设置为 STA 模式（从 AP 切回时必须！）
    wlan.setMode(wlan.STA)
    sys.wait(100)

    -- 3. 连接路由器
    log.info("NET", "WiFi STA 连接路由器:", ssid, "密码:", password)
    wlan.connect(ssid, password)

    -- 4. 事件驱动等待 IP_READY（超时 30 秒，官方 demo 为无限等待）
    local got_ip = false
    local function on_ip_ready(ip, adapter)
        if adapter == socket.LWIP_STA then
            log.info("NET", "收到 IP_READY, IP:", ip)
            got_ip = true
        end
    end
    sys.subscribe("IP_READY", on_ip_ready)

    local wait_count = 0
    while not got_ip do
        -- 同时检查 socket.adapter 是否就绪（双保险）
        if socket.adapter(socket.LWIP_STA) then
            local ip = socket.localIP(socket.LWIP_STA)
            if ip and ip ~= "0.0.0.0" then
                got_ip = true
                log.info("NET", "WiFi STA 已连接, IP:", ip)
                break
            end
        end
        sys.waitUntil("IP_READY", 1000)
        wait_count = wait_count + 1
        if wait_count > 30 then
            sys.unsubscribe("IP_READY", on_ip_ready)
            log.error("NET", "WiFi STA 连接超时(30秒), 请检查 SSID/密码")
            return false
        end
    end
    sys.unsubscribe("IP_READY", on_ip_ready)

    -- 5. 设置 DNS
    socket.setDNS(socket.LWIP_STA, 1, "223.5.5.5")
    socket.setDNS(socket.LWIP_STA, 2, "114.114.114.114")

    -- 6. 获取 IP 并启动 HTTP 服务器
    local ip = socket.localIP(socket.LWIP_STA)
    log.info("NET", "WiFi STA 已就绪, IP:", ip)

    local handler = get_http_handler()
    if handler then
        sys.wait(200)  -- 确保网络适配器完全就绪
        local ok = httpsrv.start(80, handler, socket.LWIP_STA)
        log.info("NET", "httpsrv.start STA 返回:", tostring(ok), "IP:", ip)
        if ok then
            http_started = true
            log.info("NET", "同一 WiFi 下的设备访问 http://" .. ip .. " 进行 OTA 升级")
        else
            log.error("NET", "httpsrv.start STA 失败, HTTP 服务器未启动")
            return false
        end
    else
        log.error("NET", "HTTP handler 未注册, 无法启动 HTTP 服务器")
        return false
    end

    return true
end

-- ========== 停止当前网络模式 ==========
local function stop_wifi_ap()
    log.info("NET", "停止 WiFi AP 热点")
    if http_started then
        local ok = pcall(httpsrv.stop, 80, nil, socket.LWIP_AP)
        log.info("NET", "httpsrv.stop AP:", tostring(ok))
        http_started = false
    end
    if wlan.stopAP then wlan.stopAP() end
end

local function stop_wifi_sta()
    log.info("NET", "停止 WiFi STA")
    if http_started then
        local ok = pcall(httpsrv.stop, 80, nil, socket.LWIP_STA)
        log.info("NET", "httpsrv.stop STA:", tostring(ok))
        http_started = false
    end
    if wlan.disconnect then wlan.disconnect() end
end

local function stop_current_mode()
    if not current_net_mode then return end
    if current_net_mode == "ap" then
        stop_wifi_ap()
    elseif current_net_mode == "sta" then
        stop_wifi_sta()
    end
    current_net_mode = nil
    sys.wait(500)
end

-- ========== 启动指定网络模式 ==========
-- @param mode "ap" / "sta" / "off"
-- @return boolean 是否成功
local function start_net_mode(mode)
    log.info("NET", "启动网络模式:", mode)

    -- 如果有运行中的模式，先清理
    if current_net_mode then
        stop_current_mode()
    end

    -- off 模式：仅停止 WiFi，不启动新网络
    if mode == "off" then
        log.info("NET", "WiFi 已关闭")
        current_net_mode = "off"
        return true
    end

    local ok = false
    if mode == "ap" then
        ok = start_wifi_ap()
    elseif mode == "sta" then
        ok = start_wifi_sta()
    else
        log.error("NET", "未知网络模式:", mode)
        return false
    end

    if ok then
        current_net_mode = mode
        app_data.update_ota("idle", 0, nil, nil)
    end
    return ok
end

-- ========== 对外接口 ==========

-- 切换网络模式（热切换，无需重启）
-- @param mode "ap" / "sta" / "off"
-- @return boolean 是否成功
function mod_net.set_mode(mode)
    -- 验证模式有效性
    local valid = false
    for _, m in ipairs(NET_MODES) do
        if m.id == mode then valid = true break end
    end
    if not valid then
        log.error("NET", "无效的网络模式:", mode)
        return false
    end

    -- 相同模式不切换
    if mode == current_net_mode then
        log.info("NET", "当前已是该模式:", mode)
        return true
    end

    -- 保存到配置（持久化）
    app_data.set_config("net_mode", mode)

    -- 热切换（在协程中执行，因为 stop/start 需要 sys.wait）
    sys.taskInit(function()
        log.info("NET", "热切换: " .. (current_net_mode or "无") .. " -> " .. mode)
        local ok = start_net_mode(mode)
        if ok then
            log.info("NET", "热切换成功, 当前模式:", mode)
            -- 通知屏幕显示最终状态
            sys.publish("NET_STATUS", "connected")
        else
            log.error("NET", "热切换失败")
            -- 不回退 AP 模式，仅通知屏幕显示失败
            current_net_mode = "off"
            sys.publish("NET_STATUS", "failed")
        end
    end)

    return true
end

-- 获取当前运行中的网络模式
-- @return string 当前模式 ID
function mod_net.get_mode()
    return current_net_mode
end

-- 获取所有可选网络模式列表（供屏幕显示）
-- @return table {{id=, name=, desc=}, ...}
function mod_net.get_modes()
    return NET_MODES
end

-- ========== 初始化 ==========
function mod_net.init()
    log.info("NET", "网络管理模块初始化")

    -- 订阅网络模式切换事件（由 UART1 CFG 指令或屏幕设置页触发）
    sys.subscribe("NET_MODE_CHANGE", function(mode)
        log.info("NET", "收到网络模式切换事件:", mode)
        mod_net.set_mode(mode)
    end)
end

-- ========== 启动 ==========
function mod_net.start()
    sys.taskInit(function()
        -- 检查功能开关
        if not app_data.get_config("ota_en") then
            log.info("NET", "OTA 功能未启用 (ota_en=false), 跳过网络启动")
            return
        end

        -- 读取配置中的网络模式
        local mode = app_data.get_config("net_mode") or "ap"
        log.info("NET", "配置的网络模式:", mode)

        -- off 模式：不启动 WiFi
        if mode == "off" then
            log.info("NET", "网络模式为 off, 跳过 WiFi 启动")
            current_net_mode = "off"
            return
        end

        -- 启动对应网络模式
        local ok = start_net_mode(mode)

        -- STA 启动失败时不回退 AP，仅记录日志
        if not ok and mode == "sta" then
            log.error("NET", "STA 启动失败, WiFi 保持关闭")
            current_net_mode = "off"
        end
    end)
end

return mod_net
