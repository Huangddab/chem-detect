--[[
@module  mod_ble
@brief   BLE 蓝牙污染源检测模块 (UART1 AT 指令 + iBeacon 解析)
@version 5.0
@date    2026.09.02
@usage
本模块通过 UART1 (115200 8N1) 与外部蓝牙模块 (MY-BT503-S) 通信：
1. 初始化时发送 AT，等待 OK 确认模块在线
2. 循环发送 AT+SCAN=2 启动扫描，模块返回含广播数据的完整扫描结果
3. 从 +SCAN 行中解析 6 参数 (MAC, RSSI, 广播内容等)
4. 从广播内容中解析 iBeacon 帧 (UUID → Major → Minor)
5. UUID 过滤 → Major 匹配路由表 → RSSI 映射浓度
6. 报警功能暂未实现

协议流程:
  MCU → AT\r\n                    (初始化握手)
  模块 → OK\r\n                   (模块在线)
  MCU → AT+SCAN=2\r\n             (启动扫描, 返回含广播数据)
  模块 → OK\r\n                   (指令已接收)
  模块 → +SCAN=0,MAC,RSSI,type,len,advdata\r\n  (扫描到的设备, 可多条)
  模块 → OK\r\n                   (扫描结束)
  → 循环回到第 2 步

🤖 整体或部分由 opencode 生成
]]

local mod_ble = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 硬件参数 ==========
local UART_ID       = 1
local UART_BAUD     = 115200
local UART_DATABITS = 8
local UART_PARITY   = 0
local UART_STOPBITS = 1

-- ========== AT 指令参数 ==========
local AT_INIT       = "AT\r\n"
local AT_SCAN       = "AT+SCAN=2\r\n"  -- 返回含广播数据的完整扫描结果
local AT_SCAN_TIME  = 20000            -- 扫描时长 (ms)
local AT_RESP_TIMEOUT = 3000          -- AT 握手响应超时 (ms)
local AT_INTER_CYCLE  = 1000           -- 循环间隔 (ms)

-- ========== iBeacon 常量 ==========
local IBEACON_UUID = "5B198FF269A011EE8C990242AC120002"
local IBEACON_COMPANY_ID = "4C00"  -- Apple Company ID

-- ========== 模块状态 ==========
local initialized    = false
local hw_initialized = false
local rx_buffer      = ""

-- ========== RSSI → 浓度线性映射 ==========
-- @param rssi     接收信号强度 (dBm, 负值)
-- @param rssi_near 近距离 RSSI 阈值 (对应 max_conc)
-- @param rssi_far  远距离 RSSI 阈值 (对应 0)
-- @param max_conc  最大浓度值 (ppm)
-- @return number  映射后的浓度 (0 ~ max_conc)
local function rssi_to_conc(rssi, rssi_near, rssi_far, max_conc)
    if rssi >= rssi_near then
        return max_conc
    end
    if rssi <= rssi_far then
        return 0
    end
    local conc = max_conc * (rssi - rssi_far) / (rssi_near - rssi_far)
    return math.floor(conc + 0.5)
end

-- ========== hex 字符串转数字 ==========
-- "0001" → 1, "FFFF" → 65535
local function hex_to_num(hex_str)
    local n = tonumber(hex_str, 16)
    return n
end

-- ========== 从广播数据中解析 iBeacon 帧 ==========
-- @param advdata hex 字符串 (如 "0201061AFF4C0002155B198FF2...")
-- @return table|nil  { uuid=, major=, minor=, tx_power= } 或 nil (非 iBeacon)
local function parse_ibeacon(advdata)
    if not advdata or #advdata < 50 then
        return nil
    end

    -- 搜索 Company ID "4C00" (Apple)
    -- iBeacon 结构: ...FF 4C00 02 15 [UUID 16B] [Major 2B] [Minor 2B] [TXPower 1B]
    -- 在 hex 字符串中搜索 "4C000215"
    local pos = advdata:find("4C000215", 1, true)
    if not pos then
        return nil
    end

    -- pos 指向 "4C00" 的开始位置
    -- UUID 从 pos+8 开始 (跳过 "4C000215"), 共 32 个 hex 字符 (16 字节)
    local uuid = advdata:sub(pos + 8, pos + 8 + 31)
    if #uuid < 32 then
        return nil
    end

    -- Major 从 pos+40 开始, 共 4 个 hex 字符 (2 字节)
    local major_hex = advdata:sub(pos + 40, pos + 43)
    -- Minor 从 pos+44 开始, 共 4 个 hex 字符 (2 字节)
    local minor_hex = advdata:sub(pos + 44, pos + 47)
    -- TX Power 从 pos+48 开始, 共 2 个 hex 字符 (1 字节)
    local tx_power_hex = advdata:sub(pos + 48, pos + 49)

    local major = hex_to_num(major_hex)
    local minor = hex_to_num(minor_hex)

    if not major or not minor then
        return nil
    end

    return {
        uuid     = uuid,
        major    = major,
        minor    = minor,
        tx_power = tx_power_hex,
    }
end

-- ========== 解析 +SCAN 行 ==========
-- 预期格式: +SCAN=<mac_type>,<mac>,<rssi>,<adv_type>,<adv_len>,<adv_data>
-- @param line 模块返回的一行 +SCAN 数据
-- @return table|nil  { mac=, rssi=, advdata= } 或 nil
local function parse_scan_line(line)
    if not line or line == "" then return nil end

    -- 匹配 +SCAN= 开头
    if not line:find("+SCAN=", 1, true) then
        return nil
    end

    -- 提取参数部分
    local params_str = line:gsub("^%s*%+SCAN=", "")
    -- 按逗号分割: mac_type, mac, rssi, adv_type, adv_len, adv_data
    -- adv_data 可能包含逗号, 所以只分割前 5 个字段
    local mac_type, mac, rssi_str, adv_type, adv_len, adv_data =
        params_str:match("^(%d+),([%x]+),(%-?%d+),(%d+),(%d+),(.+)%s*$")

    if not mac or not rssi_str then
        return nil
    end

    return {
        mac     = mac,
        rssi    = tonumber(rssi_str),
        advdata = adv_data or "",
    }
end

-- ========== 处理扫描到的 iBeacon 设备 ==========
-- 查路由表、计算浓度、更新数据 (报警功能暂不实现)
local function handle_ibeacon_found(major, minor, rssi, mac)
    -- 查询污染源路由表 (按 major 匹配)
    local route = app_data.get_ble_source(major)
    if not route then
        -- 不在路由表中，不是已知污染源，忽略
        log.debug("BLE", string.format("major=%d 不在路由表中, 忽略", major))
        return
    end

    -- RSSI → 浓度映射
    local conc = rssi_to_conc(rssi, route.rssi_near, route.rssi_far, route.max_conc)

    log.info("BLE", string.format("污染源: %s (major=%d minor=%d), RSSI=%d, 浓度=%dppm",
        route.type, major, minor, rssi, conc))

    -- 更新 BLE 数据中的 sources 列表
    local d = app_data.get()
    local sources = {}
    -- 保留之前的其他污染源 (按 major+minor 去重)
    for _, s in ipairs(d.ble.sources or {}) do
        if not (s.major == major and s.minor == minor) then
            table.insert(sources, s)
        end
    end
    -- 添加/更新当前污染源
    table.insert(sources, {
        major      = major,
        minor      = minor,
        mac        = mac,
        type       = route.type,
        rssi       = rssi,
        conc       = conc,
        alarm_level = 0,  -- 报警功能暂不实现
    })

    -- 计算最高浓度
    local max_conc = 0
    for _, s in ipairs(sources) do
        if s.conc > max_conc then max_conc = s.conc end
    end

    app_data.update_ble({
        sources     = sources,
        max_conc    = max_conc,
        alarm_level = 0,  -- 报警功能暂不实现
    })
end

-- ========== 扫描周期结束时清理过期设备 ==========
local function cleanup_stale_devices()
    local d = app_data.get()
    if d.ble.sources and #d.ble.sources > 0 then
        app_data.update_ble({ sources = {}, max_conc = 0, alarm_level = 0 })
    end
end

-- ========== UART 接收回调 ==========
local function on_uart_receive(id, len)
    local data = uart.read(id, len)
    if data and #data > 0 then
        rx_buffer = rx_buffer .. data
    end
end

-- ========== 发送 AT 指令并等待响应 ==========
-- @param cmd    AT 指令字符串 (含 \r\n)
-- @param timeout 等待响应超时 (ms)
-- @return string  模块返回的完整响应
-- @return boolean 是否收到 OK
local function send_at_and_wait(cmd, timeout)
    rx_buffer = ""
    uart.write(UART_ID, cmd)
    log.debug("BLE", "TX:", cmd:gsub("\r", "\\r"):gsub("\n", "\\n"))

    local result = ""
    local elapsed = 0
    local TICK = 50
    while elapsed < timeout do
        if #rx_buffer > 0 then
            result = result .. rx_buffer
            rx_buffer = ""
            if result:find("OK", 1, true) then
                local trimmed = result:gsub("\r", ""):gsub("\n+$", "")
                if #trimmed > 0 then
                    log.info("BLE", "RX:", trimmed)
                end
                return result, true
            end
        end
        sys.wait(TICK)
        elapsed = elapsed + TICK
    end

    if #result > 0 then
        local trimmed = result:gsub("\r", ""):gsub("\n+$", "")
        if #trimmed > 0 then
            log.warn("BLE", "超时, 已收到:", trimmed)
        end
    end
    return result, false
end

-- ========== 初始化 ==========
function mod_ble.init()
    initialized = true
    log.info("BLE", "BLE 污染源检测模块加载完成 (UART1 iBeacon 解析模式)")
end

-- ========== 启动 ==========
function mod_ble.start()
    if not initialized then
        log.error("BLE", "BLE 未初始化, 请先调用 mod_ble.init()")
        return
    end

    sys.taskInit(function()
        while true do
            -- 检查功能开关
            if not app_data.get_config("ble_en") then
                if hw_initialized then
                    uart.close(UART_ID)
                    hw_initialized = false
                    log.info("BLE", "UART1 已关闭")
                end
                sys.wait(1000)
                goto continue
            end

            -- 确保硬件已初始化
            if not hw_initialized then
                uart.setup(UART_ID, UART_BAUD, UART_DATABITS, UART_STOPBITS, UART_PARITY, uart.LSB, 1024)
                uart.on(UART_ID, "receive", on_uart_receive)
                hw_initialized = true
                rx_buffer = ""
                log.info("BLE", "UART1 已初始化, 波特率:", UART_BAUD)

                -- AT 握手
                sys.wait(500)
                local _, ok = send_at_and_wait(AT_INIT, AT_RESP_TIMEOUT)
                if not ok then
                    log.error("BLE", "AT 握手失败, 蓝牙模块不在线, 5 秒后重试")
                    app_data.update_ble({ online = false, scanning = false })
                    uart.close(UART_ID)
                    hw_initialized = false
                    sys.wait(5000)
                    goto continue
                end
                log.info("BLE", "AT 握手成功, 蓝牙模块在线")
                app_data.update_ble({ online = true })

                -- 握手成功后发一次 AT+SCAN=2, 之后持续读取数据不再重发
                local _, scan_ok = send_at_and_wait(AT_SCAN, AT_RESP_TIMEOUT)
                if not scan_ok then
                    log.error("BLE", "AT+SCAN=2 无响应, 5 秒后重试")
                    app_data.update_ble({ scanning = false })
                    sys.wait(5000)
                    goto continue
                end
                app_data.update_ble({ scanning = true })
            end

            -- 持续接收 +SCAN 数据 (AT+SCAN=2 是持续模式, 不会发结束 OK)
            local TICK = 100
            while app_data.get_config("ble_en") do
                if #rx_buffer > 0 then
                    local data = rx_buffer
                    rx_buffer = ""
                    -- 按行解析
                    for line in (data .. "\n"):gmatch("([^\r\n]+)") do
                        if line:find("+SCAN=", 1, true) then
                            -- 解析 +SCAN 行
                            local scan = parse_scan_line(line)
                            if scan and scan.rssi and #scan.advdata > 0 then
                                -- 从广播数据中解析 iBeacon
                                local beacon = parse_ibeacon(scan.advdata)
                                if beacon then
                                    -- UUID 过滤
                                    if beacon.uuid:upper() == IBEACON_UUID then
                                        log.info("BLE", string.format("iBeacon: major=%d minor=%d rssi=%d mac=%s",
                                            beacon.major, beacon.minor, scan.rssi, scan.mac))
                                        handle_ibeacon_found(beacon.major, beacon.minor, scan.rssi, scan.mac)
                                    end
                                end
                            end
                        end
                    end
                end
                sys.wait(TICK)
            end

            -- 内层 while 退出说明 ble_en 被关闭, 回到外层重新检查
            ::continue::
        end
    end)

    if app_data.get_config("ble_en") then
        log.info("BLE", "BLE 污染源检测模块已启动")
    else
        log.info("BLE", "BLE 污染源检测模块已加载（功能开关关闭，待启用）")
    end
end

return mod_ble
