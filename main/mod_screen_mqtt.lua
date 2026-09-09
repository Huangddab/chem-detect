--[[
@module  mod_screen_mqtt
@brief   TJC 串口屏 MQTT 设置界面处理模块
@version 2.0
@date    2026.09.08
功能:
  1. MQTT 配置界面数据推送: 服务器地址、端口、设备ID、连接状态日志
  2. 按钮事件处理: b1=连接(拉取t3/t4), b2=断开
  3. SET 指令处理: 设置服务器地址/端口/开关
  4. 配置变更后自动刷新屏幕显示

屏幕控件 (MQTT 设置页):
  t3  — MQTT 服务器地址（用户输入 + MCU 显示）
  t4  — MQTT 端口号（用户输入 + MCU 显示）
  t5  — 设备 ID（MCU 只写显示）
  t6  — 日志/状态信息（MCU 写）

按钮:
  b1  — 连接按钮（触发 0x23: MCU 从 t3/t4 拉取地址端口后连接）
  b2  — 断开按钮（触发 0x24: 关闭 MQTT）

命令码 (屏幕端统一用 printh 70 XX FF FF FF):
  查询配置:  printh 70 0D FF FF FF   (GET_MQTT)
  连接:      printh 70 23 FF FF FF   (MQTT_CONNECT, b1)
  断开:      printh 70 24 FF FF FF   (MQTT_DISCONNECT, b2)
  SET 指令:  prints "SET_MQTT_SERVER <addr>" + printh 70 + printh FF FF FF

🤖 整体或部分由 opencode 生成
]]

local mod_screen_mqtt = {}

-- ========== 依赖 ==========
local app_data = require "app_data"

-- ========== MQTT 屏幕控件名 ==========
local WIDGET = {
    server = "t3",    -- MQTT 服务器地址（用户输入 + MCU 显示）
    port   = "t4",    -- MQTT 端口号（用户输入 + MCU 显示）
    dev_id = "t5",    -- 设备 ID（MCU 只写显示）
    log    = "t6",    -- 日志/状态信息（MCU 写）
}

-- ========== 模块状态 ==========
local initialized = false
local screen_api = nil    -- 屏幕指令发送接口 (来自 callback)

-- MQTT 拉取状态（MCU 主动从屏幕 t3/t4 读取服务器地址和端口）
local mqtt_pull_step   = 0         -- 0=空闲 1=等待服务器地址 2=等待端口
local mqtt_pull_server = nil       -- 临时存储拉取到的服务器地址
local mqtt_pull_timer  = nil       -- 拉取超时定时器

-- ========== 辅助函数 ==========

-- 设置文本控件内容（通过 screen_api 回调）
local function set_text(widget, text)
    if screen_api and screen_api.set_text then
        screen_api.set_text(widget, tostring(text))
    end
end

-- 读取文本控件（通过 screen_api 回调）
local function get_text(widget)
    if screen_api and screen_api.get_text then
        screen_api.get_text(widget)
    end
end

-- ========== Handler 函数 ==========

-- GET_MQTT (0x0D): 推送当前 MQTT 配置和连接状态到屏幕
-- t3=服务器地址  t4=端口  t5=设备ID  t6=日志/状态
local function handle_get_mqtt()
    local server   = app_data.get_config("mqtt_server") or ""
    local port     = app_data.get_config("mqtt_port") or 1883
    local mqtt_en  = app_data.get_config("mqtt_en") or false
    local connected = app_data.get().mqtt.connected
    local device_id = app_data.get().sys.device_id or ""

    set_text(WIDGET.server, server)
    set_text(WIDGET.port, tostring(port))
    set_text(WIDGET.dev_id, device_id)

    local status_text = "MQTT OFF"
    if mqtt_en then
        status_text = connected and "MQTT ONLINE" or "MQTT CONNECTING"
    end
    set_text(WIDGET.log, status_text)

    log.debug("SCR_MQTT", "MQTT 配置已推送: server=", server, "port=", port,
        "en=", mqtt_en, "connected=", connected)
end

-- MQTT 连接拉取响应处理（由 mod_screen 的 handle_recv 调用）
-- @param str get 响应的文本内容（已去掉 0x70 前缀和 0xFF 结束符）
function mod_screen_mqtt.handle_pull_response(str)
    if mqtt_pull_step == 1 then
        -- 收到服务器地址，继续拉取端口
        mqtt_pull_server = str
        log.info("SCR_MQTT", "拉取服务器地址:", str)
        mqtt_pull_step = 2
        if mqtt_pull_timer then sys.timerStop(mqtt_pull_timer) end
        sys.timerStart(function()
            get_text(WIDGET.port)
        end, 50)
        mqtt_pull_timer = sys.timerStart(function()
            if mqtt_pull_step ~= 0 then
                log.error("SCR_MQTT", "拉取端口超时")
                mqtt_pull_step = 0
                mqtt_pull_server = nil
                set_text(WIDGET.log, "Pull port timeout")
            end
            mqtt_pull_timer = nil
        end, 2000)
    elseif mqtt_pull_step == 2 then
        -- 收到端口，执行 MQTT 连接
        local port_str = str
        local server = mqtt_pull_server
        log.info("SCR_MQTT", "拉取端口:", port_str)
        mqtt_pull_step = 0
        mqtt_pull_server = nil
        if mqtt_pull_timer then sys.timerStop(mqtt_pull_timer); mqtt_pull_timer = nil end

        local port = tonumber(port_str) or 1883
        if server == "" or server == nil then
            log.warn("SCR_MQTT", "服务器地址为空, 连接失败")
            set_text(WIDGET.log, "Server empty!")
            return
        end
        -- 保存配置并开启 MQTT
        app_data.set_config("mqtt_server", server)
        app_data.set_config("mqtt_port", port)
        app_data.set_config("mqtt_en", true)
        set_text(WIDGET.log, "Connecting...")
        sys.publish("CONFIG_CHANGED")
        log.info("SCR_MQTT", "MQTT 连接:", server, port)
    end
end

-- MQTT 连接按钮 (0x23): MCU 主动从屏幕 t3/t4 拉取服务器地址和端口
function mod_screen_mqtt.handle_connect()
    if mqtt_pull_step ~= 0 then
        log.warn("SCR_MQTT", "MQTT 拉取正在进行中, 忽略重复触发")
        return
    end
    log.info("SCR_MQTT", "拉取凭据: 请求 t3.txt (服务器地址)")
    mqtt_pull_step = 1
    mqtt_pull_server = nil
    set_text(WIDGET.log, "Connecting...")
    sys.timerStart(function()
        get_text(WIDGET.server)
    end, 50)
    mqtt_pull_timer = sys.timerStart(function()
        if mqtt_pull_step ~= 0 then
            log.error("SCR_MQTT", "拉取服务器地址超时")
            mqtt_pull_step = 0
            mqtt_pull_server = nil
            set_text(WIDGET.log, "Pull server timeout")
        end
        mqtt_pull_timer = nil
    end, 2000)
end

-- MQTT 断开按钮 (0x24): 关闭 MQTT
function mod_screen_mqtt.handle_disconnect()
    app_data.set_config("mqtt_en", false)
    log.info("SCR_MQTT", "MQTT 已断开")
    set_text(WIDGET.log, "MQTT OFF")
    sys.publish("CONFIG_CHANGED")
end

-- SET_MQTT_SERVER: 设置 MQTT 服务器地址
local function handle_set_mqtt_server(param)
    param = param or ""
    if param == "" then
        log.warn("SCR_MQTT", "MQTT 服务器地址为空, 忽略")
        return
    end
    app_data.set_config("mqtt_server", param)
    log.info("SCR_MQTT", "MQTT 服务器地址已设置:", param)
    set_text(WIDGET.server, param)
    sys.publish("CONFIG_CHANGED")
end

-- SET_MQTT_PORT: 设置 MQTT 端口号
local function handle_set_mqtt_port(param)
    param = param or "1883"
    local port = tonumber(param) or 1883
    if port < 1 or port > 65535 then
        log.warn("SCR_MQTT", "MQTT 端口号超出范围:", port)
        set_text(WIDGET.log, "Port range: 1-65535")
        return
    end
    app_data.set_config("mqtt_port", port)
    log.info("SCR_MQTT", "MQTT 端口已设置:", port)
    set_text(WIDGET.port, tostring(port))
    sys.publish("CONFIG_CHANGED")
end

-- SET_MQTT_EN: 设置 MQTT 开关
local function handle_set_mqtt_en(param)
    param = param or ""
    local en
    if param == "1" or param:lower() == "true" or param:lower() == "on" then
        en = true
    elseif param == "0" or param:lower() == "false" or param:lower() == "off" then
        en = false
    else
        en = not app_data.get_config("mqtt_en")
    end
    app_data.set_config("mqtt_en", en)
    log.info("SCR_MQTT", "MQTT 开关:", en and "ON" or "OFF")
    handle_get_mqtt()
end

-- ========== 初始化 ==========
function mod_screen_mqtt.init()
    -- 获取屏幕指令发送接口
    screen_api = app_data.get_callback("screen_api")
    if not screen_api then
        log.warn("SCR_MQTT", "screen_api 回调未注册, MQTT 屏幕功能不可用")
        return
    end
    initialized = true
    log.info("SCR_MQTT", "MQTT 屏幕界面模块初始化完成")
end

-- ========== 启动 ==========
function mod_screen_mqtt.start()
    if not initialized then
        log.warn("SCR_MQTT", "模块未初始化, 跳过启动")
        return
    end

    if not app_data.get_config("screen_en") then
        log.info("SCR_MQTT", "屏幕功能未启用, 跳过启动")
        return
    end

    -- 订阅 MQTT 配置查询事件
    sys.subscribe("MQTT_REFRESH", function()
        sys.taskInit(function()
            handle_get_mqtt()
        end)
    end)

    -- 订阅 MQTT 连接事件 (由 mod_screen 0x23 命令码发布)
    sys.subscribe("MQTT_CONNECT", function()
        sys.taskInit(function()
            mod_screen_mqtt.handle_connect()
        end)
    end)

    -- 订阅 MQTT 断开事件 (由 mod_screen 0x24 命令码发布)
    sys.subscribe("MQTT_DISCONNECT", function()
        sys.taskInit(function()
            mod_screen_mqtt.handle_disconnect()
        end)
    end)

    -- 订阅配置变更事件 (SET 指令修改配置时自动刷新屏幕)
    sys.subscribe("CONFIG_CHANGED", function()
        sys.taskInit(function()
            handle_get_mqtt()
        end)
    end)

    -- 注册 SET 指令 handler 到 mod_screen 路由表
    local mod_screen = require "mod_screen"
    mod_screen.on_request("SET_MQTT_SERVER", handle_set_mqtt_server)
    mod_screen.on_request("SET_MQTT_PORT", handle_set_mqtt_port)
    mod_screen.on_request("SET_MQTT_EN", handle_set_mqtt_en)

    log.info("SCR_MQTT", "MQTT 屏幕界面已启动")
end

-- ========== 对外接口 ==========

-- 主动推送 MQTT 配置到屏幕（供外部模块调用）
function mod_screen_mqtt.refresh()
    handle_get_mqtt()
end

-- 获取当前 MQTT 拉取状态（供 mod_screen 判断 get 响应分发）
function mod_screen_mqtt.get_pull_step()
    return mqtt_pull_step
end

return mod_screen_mqtt
