--[[
@module  mod_screen_ims
@brief   TJC 串口屏 IMS 离子迁移谱界面处理模块
@version 1.0
@date    2026.08.12
功能:
  1. IMS 界面数据推送: 仪器状态、故障、报警状态、灵敏度、波形
  2. 按钮事件处理: 刷新、读取报警库、切换报警库、跳过预热、切换灵敏度
  3. 通过 app_data 回调中介与 mod_ims 交互 (星型架构)

屏幕控件 (IMS 界面):
  t0 — 仪器状态: "仪器状态：检测中"
  t1 — 故障信息: "无故障" / "故障:0xXX"
  t2 — 报警状态: "未报警" / "报警:2"
  t3 — 报警物质名称: "无" / "沙林,芥子气"
  t4 — 仪器灵敏度: "高" / "低"
  t5 — 日志显示区
  s0 — 波形控件 (通道0=正峰, 通道1=负峰)

按钮命令码 (屏幕端统一用 printh 70 XX FF FF FF):
  b1 刷新:       printh 70 0C FF FF FF   (GET_IMS)
  b2 读报警库:   printh 70 1E FF FF FF   (IMS_READ_LIB)
  b3 切换报警库: printh 70 1F FF FF FF   (IMS_SWITCH_LIB)
  b4 跳过预热:   printh 70 20 FF FF FF   (IMS_SKIP_WARM)
  b5 切换灵敏度: printh 70 21 FF FF FF   (IMS_TOGGLE_SENS)

🤖 整体或部分由 opencode 生成
]]

local mod_screen_ims = {}

-- ========== 依赖 ==========
local app_data = require "app_data"

-- ========== TJC 协议常量 ==========
local CMD_END = string.char(0xFF, 0xFF, 0xFF)

-- ========== IMS 屏幕控件名 ==========
local WIDGET = {
    status      = "t0",   -- 仪器状态
    fault       = "t1",   -- 故障信息
    alarm       = "t2",   -- 报警状态
    alarm_name  = "t3",   -- 报警物质名称
    sensitivity = "t4",   -- 仪器灵敏度
    log         = "t5",   -- 日志显示
    waveform    = "s0",   -- 波形控件
}

-- ========== 模块状态 ==========
local initialized = false
local screen_api  = nil    -- 屏幕指令发送接口 (来自 callback)
local ims_api     = nil    -- IMS 功能接口 (来自 callback)
local source_mode_active = false  -- 寻源模式是否激活 (0x0C 进入, 0x0E 退出)

-- ========== 编码转换: UTF-8 → GB2312 ==========
-- TJC 屏幕串口通信层只支持 GBK 编码, Lua 源码是 UTF-8, 需要转换
-- iconv 无直接 utf8→gb2312 映射, 需两步链式: utf8→ucs2→gb2312
local ic_utf8_ucs2 = nil
local ic_ucs2_gb   = nil

local function utf8_to_gb(text)
    if not text or text == "" then return text end
    text = tostring(text)
    -- 纯 ASCII 无需转换
    if not text:find("[\128-\255]") then return text end
    -- 延迟初始化两个转换句柄
    if not ic_utf8_ucs2 then
        ic_utf8_ucs2 = iconv.open("ucs2", "utf8")
        ic_ucs2_gb   = iconv.open("gb2312", "ucs2")
        if not ic_utf8_ucs2 or not ic_ucs2_gb then
            log.warn("IMS_SCR", "iconv 初始化失败")
            return text
        end
    end
    -- 第一步: UTF-8 → UCS2
    local ucs2 = ic_utf8_ucs2:iconv(text)
    if not ucs2 or ucs2 == "" then return text end
    -- 第二步: UCS2 → GB2312
    local gb = ic_ucs2_gb:iconv(ucs2)
    if gb and gb ~= "" then
        return gb
    end
    return text
end

-- ========== 屏幕指令发送 ==========

-- 发送 TJC 指令 (自动追加 0xFF 0xFF 0xFF 结束符)
local function send_cmd(cmd)
    if screen_api and screen_api.send_raw then
        screen_api.send_raw(cmd)
    else
        log.warn("IMS_SCR", "屏幕 API 不可用")
    end
end

-- 设置文本控件 (自动 UTF-8 → GB2312 转换)
local function set_text(widget, text)
    send_cmd(string.format('%s.txt="%s"', widget, utf8_to_gb(text)))
end

-- 直接写入 UART 原始数据 (波形批量发送)
local function write_raw(data)
    if screen_api and screen_api.write_raw then
        screen_api.write_raw(data)
    else
        log.warn("IMS_SCR", "屏幕 write_raw 不可用")
    end
end

-- ========== 数据推送函数 ==========

-- 推送仪器状态到 t0
local function push_status(ims)
    local desc = ims.status_desc or "未连接"
    set_text(WIDGET.status, "仪器状态：" .. desc)
end

-- 推送故障信息到 t1
local function push_fault(ims)
    if ims.fault and ims.fault ~= 0 then
        set_text(WIDGET.fault, string.format("故障:0x%02X", ims.fault))
    else
        set_text(WIDGET.fault, "无故障")
    end
end

-- 推送报警状态到 t2
local function push_alarm(ims)
    local count = ims.alarm_count or 0
    if count > 0 then
        set_text(WIDGET.alarm, "报警:" .. tostring(count))
    else
        set_text(WIDGET.alarm, "未报警")
    end
end

-- 推送报警物质名称到 t3
local function push_alarm_name(ims)
    local names = ims.alarm_names or {}
    if #names > 0 then
        set_text(WIDGET.alarm_name, table.concat(names, ","))
    else
        set_text(WIDGET.alarm_name, "无")
    end
end

-- 推送灵敏度到 t4
local function push_sensitivity(ims)
    local sens_text = "未知"
    if ims.sensitivity == 0 then
        sens_text = "高"
    elseif ims.sensitivity == 1 then
        sens_text = "低"
    end
    set_text(WIDGET.sensitivity, sens_text)
end

-- 推送日志到 t5
local function push_log(msg)
    set_text(WIDGET.log, msg)
end

-- 推送波形到 s0 (正峰→通道0, 负峰→通道1)
-- 使用 addt 透传指令, 数据值范围 0-255
-- 每个数据点重复 4 次填满屏幕, 不清屏 (波形自动滚动)
local WAVE_REPEAT = 4

local function push_waveform(pos_peak, neg_peak)
    if not pos_peak or #pos_peak == 0 then
        log.debug("IMS_SCR", "无波形数据")
        return
    end

    -- 分别计算正峰和负峰的最大值用于缩放
    local pos_max = 1
    for _, v in ipairs(pos_peak) do
        if v > pos_max then pos_max = v end
    end
    local neg_max = 1
    if neg_peak and #neg_peak > 0 then
        for _, v in ipairs(neg_peak) do
            if v > neg_max then neg_max = v end
        end
    end

    -- 通道 0: 正峰, 每个点重复 WAVE_REPEAT 次
    local pos_raw = {}
    for i = 1, #pos_peak do
        local byte = string.char(math.floor(pos_peak[i] * 255 / pos_max))
        for _ = 1, WAVE_REPEAT do
            pos_raw[#pos_raw + 1] = byte
        end
    end
    local pos_data = table.concat(pos_raw)
    local pos_count = #pos_data

    send_cmd(string.format("addt %s.id,0,%d", WIDGET.waveform, pos_count))
    sys.waitUntil("ADDT_READY", 100)  -- 等待屏幕就绪 (0xFE)
    write_raw(pos_data)
    sys.waitUntil("ADDT_DONE", 100)   -- 等待屏幕完成 (0xFD)

    -- 通道 1: 负峰, 每个点重复 WAVE_REPEAT 次
    if neg_peak and #neg_peak > 0 then
        local neg_raw = {}
        for i = 1, #neg_peak do
            local byte = string.char(math.floor(neg_peak[i] * 255 / neg_max))
            for _ = 1, WAVE_REPEAT do
                neg_raw[#neg_raw + 1] = byte
            end
        end
        local neg_data = table.concat(neg_raw)
        local neg_count = #neg_data

        send_cmd(string.format("addt %s.id,1,%d", WIDGET.waveform, neg_count))
        sys.waitUntil("ADDT_READY", 100)
        write_raw(neg_data)
        sys.waitUntil("ADDT_DONE", 100)
    end

    log.debug("IMS_SCR", "波形已推送: 正峰", #pos_peak * WAVE_REPEAT, "点, 负峰", #(neg_peak or {}) * WAVE_REPEAT, "点")
end

-- 刷新所有 IMS 数据到屏幕 (b1)
local function refresh_all()
    local d = app_data.get()
    local ims = d.sensor.ims
    if not ims then
        push_log("IMS 数据不可用")
        return
    end
    push_status(ims)
    push_fault(ims)
    push_alarm(ims)
    push_alarm_name(ims)
    push_sensitivity(ims)
    push_waveform(ims.pos_peak, ims.neg_peak)
    log.info("IMS_SCR", "IMS 界面数据已刷新")
end

-- ========== 按钮事件处理 ==========

-- b2: 读取报警库
-- 协议 V0.3: 返回 102 字节, mod_ims 自动解析后写入 app_data
local function handle_read_lib()
    if not ims_api or not ims_api.get_lib then
        push_log("IMS API 不可用")
        return
    end
    local ok = ims_api.get_lib()
    if not ok then
        push_log("读取失败: IMS 未连接")
        return
    end
    push_log("正在读取报警库...")

    sys.taskInit(function()
        -- 等待 mod_ims 解析完成 (IMS_LIB_LOADED 事件)
        local result = {sys.waitUntil("IMS_LIB_LOADED", 3000)}
        if not result[1] then
            push_log("读取报警库超时")
            return
        end

        -- 直接从 app_data 读取已解析的报警库信息
        local d = app_data.get()
        local ims = d.sensor.ims
        if not ims.lib_loaded or ims.lib_total == 0 then
            push_log("报警库数据异常")
            return
        end

        -- 构造显示文本
        local lib_lines = {}
        for i = 1, ims.lib_total do
            local name = ims.lib_names[i] or "未命名"
            local mark = (i == ims.lib_current) and "*" or " "
            lib_lines[#lib_lines + 1] = string.format("%d:%s%s", i, mark, name)
        end
        local text = table.concat(lib_lines, "|")
        push_log(text)

        log.info("IMS_SCR", string.format("报警库: 总数=%d 当前=%d",
            ims.lib_total, ims.lib_current))
    end)
end

-- b3: 切换报警库 (1→2, 2→1)
local function handle_switch_lib()
    if not ims_api or not ims_api.select_lib then
        push_log("IMS API 不可用")
        return
    end
    local cur = ims_api.get_current_lib and ims_api.get_current_lib() or 1
    local new_lib = (cur == 1) and 2 or 1
    local ok = ims_api.select_lib(new_lib)
    if not ok then
        push_log("切换失败: IMS 未连接")
        return
    end
    if ims_api.set_current_lib then
        ims_api.set_current_lib(new_lib)
    end
    push_log(string.format("报警库已切换: %d→%d", cur, new_lib))
    -- 更新 t3 报警状态
    local d = app_data.get()
    push_alarm(d.sensor.ims)
    log.info("IMS_SCR", "报警库切换:", cur, "→", new_lib)
end

-- b4: 跳过预热 (仅在预热状态可执行)
local function handle_skip_warm()
    if not ims_api or not ims_api.skip_warmup then
        push_log("IMS API 不可用")
        return
    end
    local d = app_data.get()
    local ims = d.sensor.ims
    -- status: 0=预热, 1=检测, 2=清洁
    if ims.status ~= 0 then
        push_log("非预热状态, 无法跳过")
        log.info("IMS_SCR", "跳过预热失败: 当前状态=", ims.status_desc)
        return
    end
    local ok = ims_api.skip_warmup()
    if ok then
        push_log("已发送跳过预热命令")
        log.info("IMS_SCR", "跳过预热命令已发送")
    else
        push_log("跳过预热失败: IMS 未连接")
    end
end

-- b5: 切换灵敏度 (高↔低)
local function handle_toggle_sens()
    if not ims_api or not ims_api.set_sens then
        push_log("IMS API 不可用")
        return
    end
    local d = app_data.get()
    local ims = d.sensor.ims
    -- sensitivity: 0=高, 1=低
    local cur_sens = ims.sensitivity or 0
    local new_sens = (cur_sens == 0) and 1 or 0
    local ok = ims_api.set_sens(new_sens)
    if not ok then
        push_log("切换失败: IMS 未连接")
        return
    end
    -- 更新 t4 灵敏度显示
    local sens_text = (new_sens == 0) and "高" or "低"
    push_log(string.format("灵敏度已切换: %s", sens_text))
    set_text(WIDGET.sensitivity, "仪器灵敏度：" .. sens_text)
    log.info("IMS_SCR", "灵敏度切换:", cur_sens, "→", new_sens)
end

-- ========== 初始化 ==========
function mod_screen_ims.init()
    -- 获取屏幕指令发送接口
    screen_api = app_data.get_callback("screen_api")
    if not screen_api then
        log.warn("IMS_SCR", "screen_api 回调未注册, IMS 屏幕功能不可用")
        return
    end
    -- 获取 IMS 功能接口
    ims_api = app_data.get_callback("ims_api")
    if not ims_api then
        log.warn("IMS_SCR", "ims_api 回调未注册, IMS 屏幕功能受限")
    end
    initialized = true
    log.info("IMS_SCR", "IMS 屏幕界面模块初始化完成")
end

-- ========== 启动 ==========
function mod_screen_ims.start()
    if not initialized then
        log.warn("IMS_SCR", "模块未初始化, 跳过启动")
        return
    end

    -- 检查功能开关
    if not app_data.get_config("screen_en") then
        log.info("IMS_SCR", "屏幕功能未启用, 跳过启动")
        return
    end

    -- 订阅 IMS 屏幕事件 (由 mod_screen REQUEST_HANDLERS 发布)
    sys.subscribe("IMS_REFRESH", function()
        sys.taskInit(function()
            refresh_all()
        end)
    end)

    -- 寻源模式: 0x0C 进入 (持续刷新 s0 双波峰图), 0x0E 退出
    sys.subscribe("IMS_SOURCE_MODE", function(enable)
        source_mode_active = enable
        if enable then
            log.info("IMS_SCR", "进入寻源模式, 每次 IMS 数据更新自动刷新 s0")
            -- 立即刷新一次 s0 波形 (不推送其他数据)
            sys.taskInit(function()
                local d = app_data.get()
                local ims = d.sensor.ims
                push_waveform(ims.pos_peak, ims.neg_peak)
            end)
        else
            log.info("IMS_SCR", "退出寻源模式, 停止自动刷新 s0")
        end
    end)

    -- IMS 数据更新 (mod_ims 每次轮询后发布): 寻源模式激活时自动刷新 s0 波峰图
    sys.subscribe("IMS_DATA_UPDATE", function()
        if source_mode_active then
            sys.taskInit(function()
                local d = app_data.get()
                local ims = d.sensor.ims
                push_waveform(ims.pos_peak, ims.neg_peak)
            end)
        end
    end)

    sys.subscribe("IMS_READ_LIB", function()
        sys.taskInit(function()
            handle_read_lib()
        end)
    end)

    sys.subscribe("IMS_SWITCH_LIB", function()
        sys.taskInit(function()
            handle_switch_lib()
        end)
    end)

    sys.subscribe("IMS_SKIP_WARM", function()
        sys.taskInit(function()
            handle_skip_warm()
        end)
    end)

    sys.subscribe("IMS_TOGGLE_SENS", function()
        sys.taskInit(function()
            handle_toggle_sens()
        end)
    end)

    -- 监听开机自动读取报警库完成事件, 仅记录日志不推送屏幕
    -- 用户进入 IMS 页面按刷新按钮时由 refresh_all() 显示
    sys.subscribe("IMS_LIB_LOADED", function()
        sys.taskInit(function()
            local d = app_data.get()
            local ims = d.sensor.ims
            if not ims.lib_loaded or ims.lib_total == 0 then
                return
            end
            -- 构造显示文本（仅日志记录，不推送屏幕）
            local lib_lines = {}
            for i = 1, ims.lib_total do
                local name = ims.lib_names[i] or "未命名"
                local mark = (i == ims.lib_current) and "*" or " "
                lib_lines[#lib_lines + 1] = string.format("%d:%s%s", i, mark, name)
            end
            local text = table.concat(lib_lines, "|")
            log.info("IMS_SCR", "报警库已加载:", text)
        end)
    end)

    log.info("IMS_SCR", "IMS 屏幕界面模块已启动")
end

return mod_screen_ims
