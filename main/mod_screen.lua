--[[
@module  mod_screen
@brief   X5 陶晶池串口屏 UART 通信模块 (UART11)
@version 3.5
@date    2026.07.22
功能:
  1. 屏幕通信: TJC 指令收发、页面切换、请求-响应数据推送
  2. 设置页: WiFi 模式切换 (AP/STA/OFF) + 蓝牙开关
  3. 命令码半字节编码: 高位=命令类型 低位=目标对象
注: 屏幕 OTA 固件升级 + 文件透传已拆分到 mod_screen_ota.lua
@usage
本模块通过 UART11 (WGPIO pin 48/49) 与 X5 系列陶晶池串口屏通信。

请求-响应模式:
  屏幕通过 prints 指令发送字符串请求 (0x70 + 字符串 + 0xFF 0xFF 0xFF)
  MCU 解析指令名并调用对应 handler 返回数据
  内置指令: GET_ALL / GET_SYS / GET_SENSOR / GET_GNSS
  可通过 mod_screen.on_request(cmd, fn) 注册自定义指令

TJC 陶晶池协议说明:
  指令为 ASCII 文本，每条指令以 3 个 0xFF 字节结尾
  发送示例:
    t0.txt="Hello"\xFF\xFF\xFF       -- 设置文本控件
    n0.val=123\xFF\xFF\xFF          -- 设置数值控件
    page 1\xFF\xFF\xFF              -- 切换页面
    ref t0\xFF\xFF\xFF              -- 刷新控件
    get t0.txt\xFF\xFF\xFF          -- 读取控件值

  接收示例（屏幕触控事件）:
    0x65 0x00 0x02 0x01 0xFF 0xFF 0xFF  -- 触控事件: 页面0 控件2 按下
    0x65 0x00 0x02 0x00 0xFF 0xFF 0xFF  -- 触控事件: 页面0 控件2 松开
    0x70 + 字符串数据 + 0xFF 0xFF 0xFF   -- 字符串返回
    0x71 + 4字节int32 + 0xFF 0xFF 0xFF  -- 数值返回

控件名约定:
  t0, t1, t2 ...  — 文本控件 (txt 属性)
  n0, n1, n2 ...  — 数值控件 (val 属性)
  j0, j1 ...      — 波形控件 (val 属性)
  具体控件名需与屏幕工程一致，在 WIDGET_MAP 中配置映射

硬件连接:
  Air8000 UART11_TX (pin 49) -> 屏幕 RX
  Air8000 UART11_RX (pin 48) -> 屏幕 TX
  共地, 5V 供电

在 main.lua 中调用:
  local mod_screen = require "mod_screen"
  mod_screen.init()
  mod_screen.start()

🤖 整体或部分由 opencode 生成
]]

local mod_screen = {}

-- ========== TJC 协议常量 ==========
-- 指令结束符: 3 个 0xFF
local CMD_END = string.char(0xFF, 0xFF, 0xFF)

-- OTA/文件透传忙碌标志（由 mod_screen_ota 通过回调设置）
local ota_active = false

-- ========== 加载依赖 ==========
local app_data = require "app_data"
-- libgnss 是核心库，exgnss 初始化后自动可用，不需要 require

-- ========== 硬件参数 ==========
local UART_ID       = 11          -- UART11 (WGPIO pin 48 RX / pin 49 TX)
local UART_BAUD     = 115200      -- 陶晶池屏默认波特率
local UART_DATABITS = 8
local UART_PARITY   = 0           -- 无校验
local UART_STOPBITS = 1
local UART_BUF_SIZE = 10240       -- UART缓冲区大小（大数据传输需要增大）

-- 接收数据类型
local RECV_TOUCH     = 0x65   -- 触控事件
local RECV_STRING    = 0x70   -- 字符串数据返回
local RECV_NUMBER    = 0x71   -- 数值数据返回
local RECV_PAGE_ID   = 0x66   -- 当前页面ID返回
local RECV_WAVE_ACK  = 0x1A   -- 波形 add 命令应答 (可忽略)
local RECV_WAVE_READY = 0xFE   -- addt 透传就绪 (可忽略)
local RECV_WAVE_DONE  = 0xFD   -- addt 透传完成 (可忽略)

-- ========== 控件名映射表 ==========
-- 根据你的屏幕工程修改控件名
-- 左边是数据含义，右边是屏幕工程中的控件名
local WIDGET_MAP = {
    -- 系统信息
    device_id     = "t0",       -- 设备 ID
    uptime        = "t1",       -- 运行时间 (秒)
    alarm_level   = "t2",       -- 报警等级
    -- PID 传感器
    pid_conc      = "t3",       -- PID 浓度
    pid_voltage   = "t4",       -- PID 电压
    -- IMS 毒剂检测
    ims_count     = "t5",       -- IMS 报警数
    ims_names     = "t6",       -- IMS 毒剂名称
    -- 电池
    bat_voltage   = "t7",       -- 电池电压
    bat_pct       = "t8",       -- 电池百分比
    -- GNSS（基础）
    gps_lat       = "t9",       -- 纬度
    gps_lng       = "t10",      -- 经度
    gps_fixed     = "t11",      -- 定位状态 (0/1)
    -- G-sensor
    fall_detected = "t12",      -- 跌倒检测 (0/1)
    -- MQTT
    mqtt_status   = "t13",      -- MQTT 连接状态 (0/1)
    -- GNSS 详细数据（libgnss 直接读取）
    -- 以下控件用于 GNSS 详情页（独立页面，控件名从 t0 开始）
    -- t0: RMC 纬度       GET_RMC
    -- t1: RMC 经度       GET_RMC
    -- t2: RMC 速度       GET_RMC
    -- t3: RMC 时间       GET_RMC
    -- t4: GSA PDOP       GET_GSA
    -- t5: GSA 定位模式   GET_GSA
    -- t6: GSV 可见卫星数 GET_GSV
    -- t7: isFix 定位状态 GET_FIX
    -- t8: LOC 纬度       GET_LOC
    -- t9: LOC 经度       GET_LOC
}

-- ========== 设置页控件配置（根据屏幕工程修改）==========
-- 设置页是一个独立的屏幕页面，控件名可与主页重复（不同页面）
-- 屏幕端按钮通过 prints/printh 发送指令，MCU 不再依赖控件 ID 分发
local CFG_WIDGET_MODE   = "t0"     -- WiFi 模式显示文本控件
local CFG_WIDGET_BLE    = "t1"     -- 蓝牙开关显示文本控件
local CFG_WIDGET_SSID   = "t2"     -- WiFi 名称（用户输入 + MCU 显示）
local CFG_WIDGET_PWD    = "t3"     -- WiFi 密码（用户输入 + MCU 显示）
local CFG_WIDGET_BUZZER = "t5"     -- 蜂鸣器开关显示文本控件
local CFG_WIDGET_INFO   = "t4"     -- 网络信息提示文本控件

-- ========== 缓冲参数 ==========
-- airlink 底层 C 缓冲区硬编码 4096 字节，Lua 侧缓冲区需 >= 4096
local RX_BUF_MAX    = 8192        -- 接收缓冲区上限 (字节)
local FRAME_TIMEOUT = 200         -- 半包超时 (ms)
local RX_READ_CHUNK = 1024        -- 单次 uart.read 读取量 (字节)

-- 接收数据处理任务的事件名
local SCREEN_RX_EVENT = "SCREEN_RX_DATA"

-- ========== 请求-响应模式 ==========
-- 屏幕通过字符串指令请求数据，MCU 收到后返回对应数据
-- 不再定时推送，完全由屏幕端主动请求

-- ========== 模块状态 ==========
local initialized     = false
local hw_initialized  = false
local rx_buffer       = ""        -- 接收缓冲区
local rx_timer_id     = nil       -- 半包超时定时器
local current_page    = 0         -- 当前页面编号
local buzzer_test_on = false      -- 蜂鸣器测试开关状态

-- STA 凭据拉取状态（MCU 主动从屏幕 t4/t5 读取）
local sta_pull_step   = 0         -- 0=空闲 1=等待SSID 2=等待密码
local sta_pull_ssid   = nil       -- 临时存储拉取到的 SSID
local sta_pull_timer  = nil       -- 拉取超时定时器

-- ========== TJC 指令构造 ==========

-- 构造结束符 (3 个 0xFF)
-- local CMD_END 已在常量区定义

-- 发送原始指令（自动追加 0xFF 0xFF 0xFF 结束符）
-- @param cmd ASCII 指令文本
local function send_cmd(cmd)
    if not hw_initialized then
        log.warn("SCREEN", "UART 未初始化, 跳过发送")
        return
    end
    log.debug("SCREEN", "TX:", cmd)
    uart.write(UART_ID, cmd .. CMD_END)
end

-- ========== 发送接口 ==========

-- 设置文本控件内容
-- @param widget_name 控件名 (如 "t0")
-- @param text        文本内容
function mod_screen.set_text(widget_name, text)
    if not widget_name or not text then return end
    -- 格式: t0.txt="内容"
    send_cmd(string.format('%s.txt="%s"', widget_name, tostring(text)))
end

-- 设置数值控件内容
-- @param widget_name 控件名 (如 "n0")
-- @param value       数值
function mod_screen.set_value(widget_name, value)
    if not widget_name or value == nil then return end
    -- 格式: n0.val=123
    send_cmd(string.format("%s.val=%s", widget_name, tostring(value)))
end

-- 发送原始 TJC 指令（供 mod_screen_map 等子模块使用）
-- @param cmd ASCII 指令文本（不含结束符，自动追加 0xFF 0xFF 0xFF）
function mod_screen.send_raw(cmd)
    send_cmd(cmd)
end

-- 直接写入 UART 原始数据（不含结束符，供波形等批量发送使用）
-- @param data 完整的 TJC 指令数据（含 0xFF 0xFF 0xFF 结束符）
function mod_screen.write_raw(data)
    if not hw_initialized then return end
    uart.write(UART_ID, data)
end

-- 切换页面
-- @param page_id 页面编号 (从0开始)
function mod_screen.switch_page(page_id)
    current_page = page_id
    -- 格式: page 1
    send_cmd(string.format("page %d", page_id))
    log.info("SCREEN", "切换到页面:", page_id)
    app_data.update_io("screen", { current_page = page_id })
end

-- 刷新指定控件
-- @param widget_name 控件名
function mod_screen.refresh(widget_name)
    if not widget_name then return end
    -- 格式: ref t0
    send_cmd(string.format("ref %s", widget_name))
end

-- 读取文本控件（屏幕会异步返回字符串数据）
-- @param widget_name 控件名
function mod_screen.get_text(widget_name)
    if not widget_name then return end
    -- 格式: get t0.txt
    send_cmd(string.format("get %s.txt", widget_name))
end

-- 读取数值控件（屏幕会异步返回数值数据）
-- @param widget_name 控件名
function mod_screen.get_value(widget_name)
    if not widget_name then return end
    -- 格式: get n0.val
    send_cmd(string.format("get %s.val", widget_name))
end

-- 通过映射表设置数据
-- @param key  WIDGET_MAP 中的 key (如 "pid_conc")
-- @param val  值
function mod_screen.set_data(key, val)
    local widget = WIDGET_MAP[key]
    if not widget then
        log.warn("SCREEN", "未知控件映射:", key)
        return
    end
    -- 文本控件以 t 开头，数值控件以 n 开头
    if widget:sub(1, 1) == "t" then
        mod_screen.set_text(widget, val)
    else
        mod_screen.set_value(widget, val)
    end
end

-- ========== 请求-响应：数据推送 ==========

-- 从 app_data 获取当前数据并推送到屏幕（按需调用）
function mod_screen.send_all_data()
    local d = app_data.get()

    -- 系统信息
    mod_screen.set_data("uptime", d.sys.uptime)
    if d.sys.device_id and d.sys.device_id ~= "" then
        mod_screen.set_data("device_id", d.sys.device_id)
    end

    -- 报警等级（如果启用）
    if app_data.get_config("alarm_en") then
        mod_screen.set_data("alarm_level", d.alarm.level or 0)
    end

    -- PID 传感器数据（如果启用）
    if app_data.get_config("sensor_pid_en") and d.sensor.pid then
        mod_screen.set_data("pid_conc", d.sensor.pid.conc or 0)
        mod_screen.set_data("pid_voltage", d.sensor.pid.voltage or 0)
    end

    -- IMS 数据（如果启用）
    if app_data.get_config("sensor_ims_en") and d.sensor.ims then
        mod_screen.set_data("ims_count", d.sensor.ims.alarm_count or 0)
        if d.sensor.ims.alarm_names and #d.sensor.ims.alarm_names > 0 then
            mod_screen.set_data("ims_names", table.concat(d.sensor.ims.alarm_names, ","))
        end
    end

    -- 电池数据（如果启用）
    if app_data.get_config("sensor_battery_en") and d.sensor.battery then
        mod_screen.set_data("bat_voltage", string.format("%.2f", d.sensor.battery.voltage or 0))
        mod_screen.set_data("bat_pct", d.sensor.battery.pct or 0)
    end

    -- G-sensor 跌倒检测（如果启用）
    if app_data.get_config("gsensor_en") and d.gsensor then
        mod_screen.set_data("fall_detected", d.gsensor.fall_detected and 1 or 0)
    end

    -- MQTT 连接状态（如果启用）
    if app_data.get_config("mqtt_en") and d.mqtt then
        mod_screen.set_data("mqtt_status", d.mqtt.connected and 1 or 0)
    end

    -- 更新刷新时间戳
    app_data.update_io("screen", { last_refresh = os.time() })
end

-- ========== GNSS 详情数据推送（libgnss 直接读取） ==========

-- GET_RMC: RMC 定位数据（经纬度、速度、时间）
-- t0=纬度  t1=经度  t2=速度  t3=时间
local function handle_get_rmc()
local rmc = libgnss.getRmc(2)
    if not rmc then
        log.warn("SCREEN", "RMC 数据为空")
        return
    end
    -- 纬度 (DD.DDDDDDD 十进制格式)
    mod_screen.set_text("t0", string.format("%.5f", rmc.lat or 0))
    -- 经度 (DDD.DDDDDDD 十进制格式)
    mod_screen.set_text("t1", string.format("%.5f", rmc.lng or 0))
    -- 速度 (节)
    mod_screen.set_text("t2", string.format("%.2f", rmc.speed or 0))
    -- 时间 (UTC)
    if rmc.year and rmc.year > 2000 then
        mod_screen.set_text("t3", string.format("%04d-%02d-%02d %02d:%02d:%02d",
            rmc.year or 0, rmc.month or 0, rmc.day or 0,
            rmc.hour or 0, rmc.min or 0, rmc.sec or 0))
    else
        mod_screen.set_text("t3", "--")
    end
    log.debug("SCREEN", "RMC 已推送到屏幕")
end

-- GET_GSA: 精度因子 PDOP + 定位模式
-- t4=PDOP  t5=定位模式(NO/2D/3D)
local function handle_get_gsa()
local gsa = libgnss.getGsa(0)
    if not gsa then
        log.warn("SCREEN", "GSA 数据为空")
        mod_screen.set_text("t4", "99.99")
        mod_screen.set_text("t5", "NO")
        return
    end
    -- PDOP 精度因子（越小越好）
    mod_screen.set_text("t4", string.format("%.2f", gsa.pdop or 99.99))
    -- 定位模式: 1=未定位 2=2D 3=3D
    local fix_type_map = {[1]="NO", [2]="2D", [3]="3D"}
    mod_screen.set_text("t5", fix_type_map[gsa.fix_type] or tostring(gsa.fix_type or 0))
    log.debug("SCREEN", "GSA 已推送到屏幕")
end

-- GET_GSV: 卫星可见数 + 信号强度
-- t6=可见卫星数
local function handle_get_gsv()
local gsv = libgnss.getGsv()
    if not gsv then
        log.warn("SCREEN", "GSV 数据为空")
        return
    end
    -- 可见卫星总数
    mod_screen.set_text("t6", tostring(gsv.total_sats or 0))
    log.debug("SCREEN", "GSV 已推送到屏幕, 可见卫星:", gsv.total_sats or 0)
end

-- GET_FIX: 是否定位成功
-- t7=定位状态(YES/NO)
local function handle_get_fix()
local fixed = libgnss.isFix()
    mod_screen.set_text("t7", fixed and "YES" or "NO")
    log.debug("SCREEN", "isFix 已推送到屏幕:", fixed)
end

-- GET_LOC: 整型位置数据（getIntLocation）
-- t8=纬度(十进制)  t9=经度(十进制)
local function handle_get_loc()
local lat, lng, speed = libgnss.getIntLocation()
    if not lat or not lng then
        log.warn("SCREEN", "位置数据为空")
        return
    end
    -- getIntLocation 返回 DDDDDDDDD 格式（DD.DDDDDDD * 10000000）
    -- 转换为十进制方便显示
    local lat_dec = lat / 10000000
    local lng_dec = lng / 10000000
    mod_screen.set_text("t8", string.format("%.5f", lat_dec))
    mod_screen.set_text("t9", string.format("%.5f", lng_dec))
    log.debug("SCREEN", "LOC 已推送到屏幕:", lat_dec, lng_dec, "speed:", speed)
end

-- GET_GNSS: GNSS 详情汇总刷新（一次刷新全部 GNSS 数据）
-- 依次调用 RMC / GSA / GSV / FIX / LOC，刷新 t0~t9 全部控件
local function handle_get_gnss_all()
    handle_get_rmc()
    handle_get_gsa()
    handle_get_gsv()
    handle_get_fix()
    handle_get_loc()
    log.info("SCREEN", "GNSS 汇总刷新完成")
end

-- ========== 配置管理数据推送（设置页） ==========

-- 获取当前网络 IP 地址
local function get_net_ip()
    local net_mode = app_data.get_config("net_mode") or "off"
    if net_mode == "ap" then
        local ip = socket.localIP(socket.LWIP_AP)
        if ip and ip ~= "0.0.0.0" then return ip end
        return "192.168.4.1"
    elseif net_mode == "sta" then
        local ip = socket.localIP(socket.LWIP_STA)
        if ip and ip ~= "0.0.0.0" then return ip end
        return ""
    end
    return ""
end

-- 推送网络信息提示到 t4 控件
local function push_net_info()
    local net_mode = app_data.get_config("net_mode") or "off"
    local ip = get_net_ip()
    if net_mode == "ap" then
        local ssid = app_data.get_config("ap_ssid") or "Enboso"
        local pwd = app_data.get_config("ap_password") or ""
        mod_screen.set_text(CFG_WIDGET_INFO, "Connect " .. ssid .. ", pwd:" .. pwd .. ", open http://" .. ip)
    elseif net_mode == "sta" then
        local ssid = app_data.get_config("sta_ssid") or ""
        mod_screen.set_text(CFG_WIDGET_INFO, "Connected " .. ssid .. ", open http://" .. ip)
    else
        mod_screen.set_text(CFG_WIDGET_INFO, "")
    end
end

-- GET_CONFIG: 推送当前 WiFi 模式和蓝牙开关状态到屏幕设置页
-- t0=WiFi模式  t1=蓝牙开关  t4=网络信息提示
local function handle_get_config()
    local net_mode = app_data.get_config("net_mode") or "ap"
    local ble_en = app_data.get_config("ble_en") or false
    local mode_text = "WiFi OFF"
    if net_mode == "ap" then mode_text = "WiFi AP"
    elseif net_mode == "sta" then mode_text = "WiFi STA" end
    local buzzer_en = app_data.get_config("buzzer_en") or false
    mod_screen.set_text(CFG_WIDGET_MODE, mode_text)
    mod_screen.set_text(CFG_WIDGET_BLE, ble_en and "BLE ON" or "BLE OFF")
    mod_screen.set_text(CFG_WIDGET_BUZZER, buzzer_en and "BUZZER ON" or "BUZZER OFF")
    push_net_info()
    log.debug("SCREEN", "配置已推送: net_mode=", net_mode, "ble_en=", ble_en, "buzzer_en=", buzzer_en)
end

-- 前向声明（handle_sta_pull_response 调用后面定义的函数）
local handle_request
local handle_set_net_mode

-- STA 凭据拉取：MCU 主动从屏幕 t4/t5 读取 SSID 和密码
-- 屏幕端发送 printh 70 11 FF FF FF 触发，MCU 回调 get t2.txt / get t3.txt
local function handle_sta_pull()
    if sta_pull_step ~= 0 then
        log.warn("SCREEN", "STA 拉取正在进行中, 忽略重复触发")
        return
    end
    log.info("SCREEN", "STA 拉取凭据: 请求 t2.txt (SSID)")
    sta_pull_step = 1
    sta_pull_ssid = nil
    mod_screen.set_text(CFG_WIDGET_MODE, "Connecting...")
    -- 用定时器延迟发送 get t2.txt，避免在回调中调用 sys.wait
    sys.timerStart(function()
        mod_screen.get_text(CFG_WIDGET_SSID)
    end, 50)
    -- 超时保护：2 秒内未收到响应则放弃
    if sta_pull_timer then sys.timerStop(sta_pull_timer) end
    sta_pull_timer = sys.timerStart(function()
        if sta_pull_step ~= 0 then
            log.error("SCREEN", "STA 拉取 SSID 超时")
            sta_pull_step = 0
            sta_pull_ssid = nil
            mod_screen.set_text(CFG_WIDGET_MODE, "Connect Fail")
        end
        sta_pull_timer = nil
    end, 2000)
end

-- STA 拉取响应处理（从 handle_recv 和半包超时容错两处调用）
-- @param str get 响应的文本内容（已去掉 0x70 前缀和 0xFF 结束符）
local function handle_sta_pull_response(str)
    if sta_pull_step == 1 then
        -- 收到 SSID，继续拉取密码
        sta_pull_ssid = str
        log.info("SCREEN", "STA 拉取 SSID:", str, "hex:", str:toHex())
        sta_pull_step = 2
        -- 用定时器延迟发送 get t3.txt，避免在定时器回调中调用 sys.wait
        if sta_pull_timer then sys.timerStop(sta_pull_timer) end
        sys.timerStart(function()
            mod_screen.get_text(CFG_WIDGET_PWD)
        end, 50)
        sta_pull_timer = sys.timerStart(function()
            if sta_pull_step ~= 0 then
                log.error("SCREEN", "STA 拉取密码超时")
                sta_pull_step = 0
                sta_pull_ssid = nil
                mod_screen.set_text(CFG_WIDGET_MODE, "Connect Fail")
            end
            sta_pull_timer = nil
        end, 2000)
    elseif sta_pull_step == 2 then
        -- 收到密码，执行 STA 连接
        local pwd = str
        local ssid = sta_pull_ssid
        log.info("SCREEN", "STA 拉取密码:", pwd, "hex:", pwd:toHex())
        sta_pull_step = 0
        sta_pull_ssid = nil
        if sta_pull_timer then sys.timerStop(sta_pull_timer); sta_pull_timer = nil end
        handle_set_net_mode("sta|" .. ssid .. "|" .. pwd)
    else
        -- 检查是否是 MQTT 拉取响应
        local mod_screen_mqtt = require "mod_screen_mqtt"
        if mod_screen_mqtt.get_pull_step() ~= 0 then
            mod_screen_mqtt.handle_pull_response(str)
            return
        end
        -- 正常字符串请求
        log.info("SCREEN", "字符串请求:", str)
        app_data.update_io("screen", {
            last_key  = "string_return",
            key_event = str,
        })
        handle_request(str)
    end
end

-- SET_NET_MODE: 设置 WiFi 网络模式
-- @param param "off" / "ap" / "sta|ssid|password"（TJC prints 用 | 分隔避免逗号参数解析冲突）
function handle_set_net_mode(param)
    param = param or ""
    -- 解析 sta|ssid|password 格式（| 分隔）
    local mode, ssid, password
    local sep1 = param:find("|", 1, true)
    if sep1 then
        mode = param:sub(1, sep1 - 1)
        local rest = param:sub(sep1 + 1)
        local sep2 = rest:find("|", 1, true)
        if sep2 then
            ssid = rest:sub(1, sep2 - 1)
            password = rest:sub(sep2 + 1)
        else
            ssid = rest
            password = ""
        end
    else
        mode = param
    end

    if mode ~= "ap" and mode ~= "sta" and mode ~= "off" then
        log.warn("SCREEN", "无效网络模式:", mode)
        return
    end

    -- STA 模式：保存传入的凭据，并做防呆验证
    if mode == "sta" then
        if ssid and ssid ~= "" then
            app_data.set_config("sta_ssid", ssid)
        end
        if password and password ~= "" then
            app_data.set_config("sta_password", password)
        end
        -- 防呆验证：检查 SSID 和密码是否为空
        local eff_ssid = app_data.get_config("sta_ssid") or ""
        local eff_pwd  = app_data.get_config("sta_password") or ""
        if eff_ssid == "" or eff_pwd == "" then
            log.warn("SCREEN", "STA SSID 或密码为空, 连接失败")
            mod_screen.set_text(CFG_WIDGET_MODE, "Connect Fail")
            return
        end
    end

    -- 蓝牙模块通过 UART1 通信，与 WiFi 独立运行
    app_data.set_config("net_mode", mode)

    -- 屏幕立即显示 Connecting...（STA/AP 切换需要时间）
    if mode == "sta" or mode == "ap" then
        mod_screen.set_text(CFG_WIDGET_MODE, "Connecting...")
        mod_screen.set_text(CFG_WIDGET_INFO, "")
    elseif mode == "off" then
        mod_screen.set_text(CFG_WIDGET_MODE, "WiFi OFF")
        mod_screen.set_text(CFG_WIDGET_SSID, "")
        mod_screen.set_text(CFG_WIDGET_PWD, "")
        mod_screen.set_text(CFG_WIDGET_INFO, "")
    end

    sys.publish("NET_MODE_CHANGE", mode)
    log.info("SCREEN", "WiFi 模式已设置:", mode)
end

-- SET_BLE: 设置蓝牙开关
-- @param param "1"/"0" 或 "on"/"off"
local function handle_set_ble(param)
    param = param or ""
    local en = (param == "1" or param:lower() == "true" or param:lower() == "on")
    -- 蓝牙模块通过 UART1 通信，与 WiFi 独立运行
    app_data.set_config("ble_en", en)
    log.info("SCREEN", "蓝牙开关:", en and "ON" or "OFF")
    handle_get_config()
end

-- SET_BUZZER: 设置蜂鸣器开关（toggle 切换）
-- @param param 可选: "1"/"0" 显式指定, 不传则 toggle 切换
local function handle_set_buzzer(param)
    param = param or ""
    local en
    if param == "1" or param:lower() == "true" or param:lower() == "on" then
        en = true
    elseif param == "0" or param:lower() == "false" or param:lower() == "off" then
        en = false
    else
        -- 无参数: toggle 切换
        en = not app_data.get_config("buzzer_en")
    end
    app_data.set_config("buzzer_en", en)
    log.info("SCREEN", "蜂鸣器开关:", en and "ON" or "OFF")
    mod_screen.set_text(CFG_WIDGET_BUZZER, en and "BUZZER ON" or "BUZZER OFF")
end

-- ========== 请求-响应：指令分发表 ==========
-- 屏幕通过 0x70 + 单字节命令码 + 0xFF 0xFF 0xFF 发送请求
--
-- 命令码编码规则（半字节拆分）:
--   高位 (高4bit) = 命令类型: 0x0_=GET查询  0x1_=DIRECT_SET(二进制,无参数)  0x2_=SET设置(ASCII带参数)
--   低位 (低4bit) = 目标对象: 0=ALL 1=SYS 2=SENSOR 3=GNSS 4=RMC 5=GSA 6=GSV 7=FIX 8=LOC 9=CONFIG A=NET_MODE B=BLE
--   注意: 0x1_ 范围为直接设置命令，低位为序号，不遵循目标对象编码
--
-- 二进制命令码速查 (屏幕端用 printh 70 XX FF FF FF 发送):
--   GET 命令 (高位 0x0_):
--     0x00  GET_ALL        — 推送全部数据
--     0x01  GET_SYS        — 推送系统信息
--     0x02  GET_SENSOR     — 推送传感器数据
--     0x03  GET_GNSS       — GNSS 详情汇总刷新（RMC+GSA+GSV+FIX+LOC）
--     0x04  GET_RMC        — RMC 定位数据（经纬度、速度、时间）
--     0x05  GET_GSA        — 精度因子 PDOP + 定位模式
--     0x06  GET_GSV        — 卫星可见数
--     0x07  GET_FIX        — 是否定位成功
--     0x08  GET_LOC        — 整型位置数据（getIntLocation）
--     0x09  GET_CONFIG     — 推送配置状态（WiFi 模式 + 蓝牙开关）
--   DIRECT SET 命令 (高位 0x1_, 二进制无参数, 推荐):
--     0x10  WIFI_OFF       — WiFi 关闭
--     0x11  WIFI_STA       — WiFi STA 模式（MCU 主动从屏幕 t4/t5 拉取凭据）
--     0x12  WIFI_AP        — WiFi AP 模式
--     0x13  BLE_ON         — 蓝牙开启
--     0x14  BLE_OFF        — 蓝牙关闭
--     0x15  MAP_ON         — 地图开启
--     0x16  MAP_OFF        — 地图关闭
--     0x17  MAP_UP         — 地图上移 (北)
--     0x18  MAP_DOWN       — 地图下移 (南)
--     0x19  MAP_LEFT       — 地图左移 (西)
--     0x1A  MAP_RIGHT      — 地图右移 (东)
--     0x22  BUZZER_TOGGLE  — 蜂鸣器直接响/停切换 (GPIO 测试)
--
-- 同时兼容 ASCII 字符串指令（如 "GET_RMC"）
local REQUEST_HANDLERS = {
    -- GET 命令 (高位 0x0_)
    [string.char(0x00)] = mod_screen.send_all_data,
    ["GET_ALL"]         = mod_screen.send_all_data,
    [string.char(0x01)] = function()
        local d = app_data.get()
        mod_screen.set_data("uptime", d.sys.uptime)
        if d.sys.device_id and d.sys.device_id ~= "" then
            mod_screen.set_data("device_id", d.sys.device_id)
        end
        app_data.update_io("screen", { last_refresh = os.time() })
    end,
    ["GET_SYS"]         = nil,  -- 下面补赋值
    [string.char(0x02)] = function()
        local d = app_data.get()
        if app_data.get_config("sensor_pid_en") and d.sensor.pid then
            mod_screen.set_data("pid_conc", d.sensor.pid.conc or 0)
            mod_screen.set_data("pid_voltage", d.sensor.pid.voltage or 0)
        end
        if app_data.get_config("sensor_ims_en") and d.sensor.ims then
            mod_screen.set_data("ims_count", d.sensor.ims.alarm_count or 0)
            if d.sensor.ims.alarm_names and #d.sensor.ims.alarm_names > 0 then
                mod_screen.set_data("ims_names", table.concat(d.sensor.ims.alarm_names, ","))
            end
        end
        if app_data.get_config("sensor_battery_en") and d.sensor.battery then
            mod_screen.set_data("bat_voltage", string.format("%.2f", d.sensor.battery.voltage or 0))
            mod_screen.set_data("bat_pct", d.sensor.battery.pct or 0)
        end
        app_data.update_io("screen", { last_refresh = os.time() })
    end,
    ["GET_SENSOR"]      = nil,  -- 下面补赋值
    [string.char(0x03)] = handle_get_gnss_all,
    ["GET_GNSS"]        = handle_get_gnss_all,
    [string.char(0x04)] = handle_get_rmc,
    ["GET_RMC"]         = handle_get_rmc,
    [string.char(0x05)] = handle_get_gsa,
    ["GET_GSA"]         = handle_get_gsa,
    [string.char(0x06)] = handle_get_gsv,
    ["GET_GSV"]         = handle_get_gsv,
    [string.char(0x07)] = handle_get_fix,
    ["GET_FIX"]         = handle_get_fix,
    [string.char(0x08)] = handle_get_loc,
    ["GET_LOC"]         = handle_get_loc,
    [string.char(0x09)] = handle_get_config,
    ["GET_CONFIG"]      = handle_get_config,
    -- IMS GET 命令 (0x0C = GET_IMS)
    [string.char(0x0C)] = function() sys.publish("IMS_REFRESH") end,
    ["GET_IMS"]         = function() sys.publish("IMS_REFRESH") end,
    -- MQTT GET 命令 (0x0D = GET_MQTT)
    [string.char(0x0D)] = function() sys.publish("MQTT_REFRESH") end,
    ["GET_MQTT"]        = function() sys.publish("MQTT_REFRESH") end,
    -- DIRECT SET 命令 (高位 0x1_, 二进制无参数, 推荐 printh)
    [string.char(0x10)] = function() handle_set_net_mode("off") end,
    [string.char(0x11)] = function() handle_sta_pull() end,
    [string.char(0x12)] = function() handle_set_net_mode("ap") end,
    [string.char(0x13)] = function() handle_set_ble("1") end,
    [string.char(0x14)] = function() handle_set_ble("0") end,
    [string.char(0x15)] = function()
        app_data.set_config("map_en", true)
        sys.publish("MAP_TOGGLE", true)
        log.info("SCREEN", "地图开启")
    end,
    [string.char(0x16)] = function()
        app_data.set_config("map_en", false)
        sys.publish("MAP_TOGGLE", false)
        log.info("SCREEN", "地图关闭")
    end,
    [string.char(0x17)] = function()
        sys.publish("MAP_MOVE", "up")
        log.info("SCREEN", "地图上移 (北)")
    end,
    [string.char(0x18)] = function()
        sys.publish("MAP_MOVE", "down")
        log.info("SCREEN", "地图下移 (南)")
    end,
    [string.char(0x19)] = function()
        sys.publish("MAP_MOVE", "left")
        log.info("SCREEN", "地图左移 (西)")
    end,
    [string.char(0x1A)] = function()
        sys.publish("MAP_MOVE", "right")
        log.info("SCREEN", "地图右移 (东)")
    end,
    -- IMS DIRECT SET 命令 (0x1E~0x21, 二进制无参数)
    [string.char(0x1E)] = function() sys.publish("IMS_READ_LIB") end,
    [string.char(0x1F)] = function() sys.publish("IMS_SWITCH_LIB") end,
    [string.char(0x20)] = function() sys.publish("IMS_SKIP_WARM") end,
    [string.char(0x21)] = function() sys.publish("IMS_TOGGLE_SENS") end,
    -- 蜂鸣器 DIRECT SET 命令 (0x22, toggle 测试响/停, 不受 buzzer_en 限制)
    [string.char(0x22)] = function()
        local api = app_data.get_callback("buzzer_api")
        if not api then
            log.error("SCREEN", "buzzer_api 回调未注册")
            return
        end
        local on = api.toggle_test()
        log.info("SCREEN", "蜂鸣器:", on and "响" or "停")
    end,
    -- MQTT DIRECT SET 命令 (0x23=连接 b1, 0x24=断开 b2)
    [string.char(0x23)] = function() sys.publish("MQTT_CONNECT") end,
    [string.char(0x24)] = function() sys.publish("MQTT_DISCONNECT") end,
    -- SET 命令 (高位 0x2_, ASCII 带参数, 兼容 UART1 指令)
    ["SET_NET_MODE"]    = handle_set_net_mode,
    ["SET_BLE"]         = handle_set_ble,
    ["SET_BUZZER"]     = handle_set_buzzer,
}
-- 补赋值（ASCII 别名指向同一个 handler）
REQUEST_HANDLERS["GET_SYS"]    = REQUEST_HANDLERS[string.char(0x01)]
REQUEST_HANDLERS["GET_SENSOR"] = REQUEST_HANDLERS[string.char(0x02)]

-- 处理屏幕发来的请求指令
-- @param raw_str 屏幕通过 prints 发送的数据（可能是二进制命令码或 ASCII 字符串）
function handle_request(raw_str)
    if not raw_str or raw_str == "" then return end

    -- 优先检查二进制命令码（单字节，见 REQUEST_HANDLERS 注释）
    -- 注意: 0x09 是 TAB 字符，不能先 trim 否则会被吃掉
    if #raw_str == 1 then
        local handler = REQUEST_HANDLERS[raw_str]
        if handler then
            log.info("SCREEN", "处理二进制请求: 0x" .. string.format("%02X", string.byte(raw_str, 1)))
            local ok, err = pcall(handler)
            if not ok then
                log.error("SCREEN", "请求处理失败: 0x" .. string.format("%02X", string.byte(raw_str, 1)), tostring(err))
            end
            app_data.update_io("screen", { last_refresh = os.time() })
            return
        end
    end

    -- ASCII 字符串指令：去除首尾空白后查表
    local cmd_str = raw_str:match("^%s*(.-)%s*$") or raw_str
    if cmd_str == "" then return end

    -- 支持带参数的指令: "SET_NET_MODE ap" → cmd="SET_NET_MODE", param="ap"
    local space_pos = cmd_str:find(" ", 1, true)
    local cmd, param
    if space_pos then
        cmd = cmd_str:sub(1, space_pos - 1)
        param = cmd_str:sub(space_pos + 1):match("^%s*(.-)%s*$")
    else
        cmd = cmd_str
    end

    local handler = REQUEST_HANDLERS[cmd]
    if handler then
        log.info("SCREEN", "处理请求:", cmd, param and ("参数:" .. param) or "")
        local ok, err = pcall(handler, param)
        if not ok then
            log.error("SCREEN", "请求处理失败:", cmd, tostring(err))
        end
        app_data.update_io("screen", { last_refresh = os.time() })
    else
        log.warn("SCREEN", "未知请求指令:", cmd)
    end
end

-- 注册自定义请求 handler（供外部模块扩展）
-- @param cmd  指令字符串
-- @param fn   处理函数
function mod_screen.on_request(cmd, fn)
    if cmd and fn then
        REQUEST_HANDLERS[cmd] = fn
        log.info("SCREEN", "注册请求指令:", cmd)
    end
end

-- 兼容旧接口名
mod_screen.push_data = mod_screen.send_all_data

-- ========== 接收处理 ==========

-- 查找 0xFF 0xFF 0xFF 结束符位置
-- @param buf 缓冲区字符串
-- @return 结束符起始位置, 没有则返回 nil
local function find_cmd_end(buf)
    -- 从缓冲区中查找连续 3 个 0xFF
    for i = 1, #buf - 2 do
        if string.byte(buf, i) == 0xFF
        and string.byte(buf, i + 1) == 0xFF
        and string.byte(buf, i + 2) == 0xFF then
            return i
        end
    end
    return nil
end

-- 解析一条完整指令（去掉结尾 0xFF 0xFF 0xFF 后的数据）
-- @param data 一条完整指令的字节串（含结束符）
-- @return 去掉结束符后的数据字符串
local function extract_payload(data)
    -- 去掉最后 3 个 0xFF
    return string.sub(data, 1, #data - 3)
end

-- 处理接收到的指令
-- @param raw 完整指令（含 0xFF 0xFF 0xFF 结尾）
local function handle_recv(raw)
    local payload = extract_payload(raw)
    if #payload == 0 then return end

    local first_byte = string.byte(payload, 1)

    if first_byte == RECV_TOUCH then
        -- 触控事件: 0x65 + 页面ID + 控件ID + 状态(1=按下 0=松开)
        if #payload >= 4 then
            local page_id   = string.byte(payload, 2)
            local ctrl_id   = string.byte(payload, 3)
            local press     = string.byte(payload, 4)
            current_page = page_id
            local event_str = (press == 1) and "按下" or "松开"
            log.info("SCREEN", string.format("触控: 页面=%d 控件=%d %s", page_id, ctrl_id, event_str))
            app_data.update_io("screen", {
                current_page = page_id,
                last_key     = tostring(ctrl_id),
                key_event    = event_str,
            })

            -- 触控事件仅记录日志，具体操作由屏幕端通过 prints/printh 指令发送
        end

    elseif first_byte == RECV_STRING then
        -- 字符串返回: 0x70 + 字符串数据（可能是 get 响应或 prints 指令）
        local str = string.sub(payload, 2)
        local readable = str:gsub("[^%w%p ]", ".")
        log.info("SCREEN", "RECV_STRING raw_hex:", raw:toHex(), "payload_hex:", payload:toHex(), "str:", readable, "len:", #str, "sta_pull_step:", sta_pull_step)
        handle_sta_pull_response(str)

    elseif first_byte == RECV_NUMBER then
        -- 数值返回: 0x71 + 4字节 int32 (小端序)
        if #payload >= 5 then
            local b0 = string.byte(payload, 2)
            local b1 = string.byte(payload, 3)
            local b2 = string.byte(payload, 4)
            local b3 = string.byte(payload, 5)
            -- 小端序拼接
            local val = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
            -- 处理负数 (int32)
            if val >= 0x80000000 then
                val = val - 0x100000000
            end
            log.info("SCREEN", "数值返回:", val)
            app_data.update_io("screen", {
                last_key  = "number_return",
                key_event = tostring(val),
            })
        end

    elseif first_byte == RECV_PAGE_ID then
        -- 当前页面ID返回: 0x66 + 页面编号
        if #payload >= 2 then
            local page = string.byte(payload, 2)
            current_page = page
            log.info("SCREEN", "当前页面:", page)
            app_data.update_io("screen", { current_page = page })
        end

    elseif first_byte == RECV_WAVE_ACK then
        -- 波形 add 命令应答: 0x1A + 通道号, 静默忽略

    elseif first_byte == RECV_WAVE_READY then
        -- addt 透传就绪: 0xFE, 通知等待方
        sys.publish("ADDT_READY")

    elseif first_byte == RECV_WAVE_DONE then
        -- addt 透传完成: 0xFD, 通知等待方
        sys.publish("ADDT_DONE")

    else
        -- 尝试当 ASCII 文本解析（屏幕 prints 不带 0x70 前缀的容错）
        if #payload >= 3 and string.byte(payload, 1) >= 0x20 and string.byte(payload, 1) <= 0x7E then
            local str = payload
            log.info("SCREEN", "ASCII 请求:", str)
            app_data.update_io("screen", {
                last_key  = "string_return",
                key_event = str,
            })
            handle_request(str)
        else
            log.debug("SCREEN", "收到数据:", payload:toHex())
        end
    end
end

-- ========== UART 接收回调 ==========
-- 回调只负责快速读取数据到 rx_buffer，不做任何解析/handler 执行
-- 处理逻辑在 rx_process_task 中异步执行，避免阻塞回调导致 airlink 缓冲区溢出
local function uart_receive_cb(id, len)
    -- OTA 或文件透传模式下不读取数据，由对应函数直接读取
    if ota_active then return end
    local s = ""
    repeat
        s = uart.read(id, RX_READ_CHUNK)
        if s and #s > 0 then
            rx_buffer = rx_buffer .. s
            -- 缓冲区溢出保护
            if #rx_buffer > RX_BUF_MAX then
                log.warn("SCREEN", "Lua 缓冲区溢出, 清空:", #rx_buffer, "字节")
                rx_buffer = ""
            end
        end
    until s == ""
    -- 通知处理任务有新数据
    if #rx_buffer > 0 then
        sys.publish(SCREEN_RX_EVENT)
    end
end

-- ========== 接收数据处理任务 ==========
-- 异步处理 rx_buffer 中的完整指令，避免在 UART 回调中执行耗时操作
-- （handler 会调用 uart.write 回传数据，阻塞回调会导致 airlink 4096 字节缓冲区溢出）
local function rx_process_task()
    while true do
        sys.waitUntil(SCREEN_RX_EVENT)
        -- 处理缓冲区中的所有完整指令
        while true do
            local end_pos = find_cmd_end(rx_buffer)
            if not end_pos then break end

            -- 提取一条完整指令（含结束符）
            local cmd_len = end_pos + 2  -- 包含 3 个 0xFF
            local raw = string.sub(rx_buffer, 1, cmd_len)
            rx_buffer = string.sub(rx_buffer, cmd_len + 1)

            -- 处理这条指令
            local ok, err = pcall(handle_recv, raw)
            if not ok then
                log.error("SCREEN", "解析异常:", tostring(err))
            end
        end

        -- 半包超时处理
        if #rx_buffer > 0 then
            if rx_timer_id then
                sys.timerStop(rx_timer_id)
            end
            rx_timer_id = sys.timerStart(function()
                if #rx_buffer > 0 then
                    -- STA/MQTT 拉取容错：缓冲区以 0x70 开头时，当 get 响应处理
                    -- 部分 TJC 屏幕型号 get 响应只追加 2 个 0xFF，帧匹配不到 3 个 0xFF
                    local mod_screen_mqtt = require "mod_screen_mqtt"
                    if (sta_pull_step ~= 0 or mod_screen_mqtt.get_pull_step() ~= 0) and string.byte(rx_buffer, 1) == 0x70 then
                        local data = rx_buffer
                        log.info("SCREEN", "半包超时容错 raw_hex:", rx_buffer:toHex(), "len:", #rx_buffer, "sta_pull_step:", sta_pull_step)
                        -- 去掉末尾的 0xFF
                        while #data > 1 and string.byte(data, #data) == 0xFF do
                            data = data:sub(1, -2)
                        end
                        local str = data:sub(2) -- 去掉 0x70 前缀
                        local readable = str:gsub("[^%w%p ]", ".")
                        log.info("SCREEN", "STA 拉取容错 str:", readable, "hex:", str:toHex(), "len:", #str)
                        handle_sta_pull_response(str)
                        rx_buffer = ""
                    else
                        local hex_str = rx_buffer:toHex()
                        local readable = rx_buffer:gsub("[^%w%p ]", ".")
                        log.warn("SCREEN", "半包超时, 丢弃:", #rx_buffer, "字节", "hex:", hex_str, "str:", readable)
                        rx_buffer = ""
                    end
                end
                rx_timer_id = nil
            end, FRAME_TIMEOUT)
        else
            if rx_timer_id then
                sys.timerStop(rx_timer_id)
                rx_timer_id = nil
            end
        end
    end
end

-- ========== 初始化 ==========
function mod_screen.init()
    -- UART11 初始化（固定 115200，缓冲区 10240）
    uart.setup(UART_ID, UART_BAUD, UART_DATABITS, UART_STOPBITS, UART_PARITY, uart.LSB, UART_BUF_SIZE)
    uart.on(UART_ID, "receive", uart_receive_cb)
    hw_initialized = true

    initialized = true
    log.info("SCREEN", "串口屏模块初始化完成, UART11, 波特率:", UART_BAUD)
end

-- ========== 启动 ==========
function mod_screen.start()
    if not initialized then
        log.error("SCREEN", "模块未初始化, 请先调用 mod_screen.init()")
        return
    end

    -- 检查功能开关
    if not app_data.get_config("screen_en") then
        log.info("SCREEN", "串口屏功能未启用 (screen_en=false), 跳过启动")
        return
    end

    -- 更新屏幕连接状态
    app_data.update_io("screen", {
        connected    = true,
        current_page = 0,
        timestamp    = os.time(),
    })

    -- 启动异步接收数据处理任务（与 UART 回调解耦，防止 airlink 缓冲区溢出）
    sys.taskInit(rx_process_task)

    -- 订阅配置变更事件（UART1 CFG 指令修改配置时自动推送更新到屏幕）
    sys.subscribe("CONFIG_CHANGED", function()
        handle_get_config()
    end)

    -- 订阅网络状态事件（mod_ota 连接成功/失败后发布）
    sys.subscribe("NET_STATUS", function(status)
        log.info("SCREEN", "网络状态:", status)
        if status == "connected" then
            handle_get_config()
            push_net_info()
        elseif status == "failed" then
            mod_screen.set_text(CFG_WIDGET_MODE, "Connect Fail")
            mod_screen.set_text(CFG_WIDGET_INFO, "")
        end
    end)

    log.info("SCREEN", "串口屏已启动 (请求-响应模式, 异步处理)")
end

-- ========== 对外接口 ==========

-- 获取当前页面
function mod_screen.get_current_page()
    return current_page
end


-- ========== 注册回调（星型架构：供子模块调用） ==========
-- mod_screen_ota: UART 忙碌状态控制
app_data.register_callback("screen_uart_ctrl", {
    set_ota_active = function(active)
        ota_active = active
    end,
})

-- mod_screen_map / mod_screen_ims: 屏幕指令发送接口
app_data.register_callback("screen_api", {
    send_raw  = mod_screen.send_raw,
    set_text  = mod_screen.set_text,
    write_raw = mod_screen.write_raw,
})

return mod_screen
