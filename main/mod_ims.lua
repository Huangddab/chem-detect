--[[
@module  mod_ims
@brief   IMS 离子迁移谱模块 (UART12) — 便携式化学毒剂报警器
@version 2.0
@date    2026.08.12
@usage
本模块通过 UART12 (WGPIO pin 59/60) 与 IMS 模块通信：
1. 初始化 UART12, 115200 8N1
2. 定时发送读取状态命令 (0x01), 解析响应
3. 检测到毒剂时通过 app_data.update_alarm("ims") 通知
4. 数据通过 app_data.update_sensor("ims", {...}) 写入数据中心

协议: 便携式化学毒剂报警器通信协议 V0.3
帧格式: AA + 目标(1) + 源(1) + 功能码(1) + 数据长度(2,LE) + 数据(N) + CRC16(2,LE) + 0D 0A
地址: 上位机=1, 下位机=2

在 main.lua 中调用：
  local mod_ims = require "mod_ims"
  mod_ims.init()
  mod_ims.start()
]]

local mod_ims = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 硬件参数 ==========
local UART_ID        = 12          -- UART12 (WGPIO pin 59/60)
local UART_BAUD      = 115200      -- 波特率
local UART_DATABITS  = 8
local UART_PARITY    = 0           -- 无校验
local UART_STOPBITS  = 1

-- ========== 协议常量 ==========
local FRAME_HEAD     = 0xAA        -- 帧头
local ADDR_HOST      = 1           -- 上位机地址
local ADDR_DEVICE    = 2           -- 下位机地址
local CMD_GET_STATUS = 0x01        -- 读取状态信息
local CMD_CLEAN      = 0x03        -- 清洗命令
local CMD_SKIP_WARM  = 0x04        -- 跳过预热
local CMD_GET_LIB    = 0x05        -- 读取报警库信息
local CMD_SEL_LIB    = 0x06        -- 选择报警库
local CMD_CALIB      = 0x07        -- 校准命令
local CMD_SEL_SENS   = 0x08        -- 选择灵敏度

-- 仪器状态码
local STATUS = {
    [0] = "预热中",
    [1] = "检测中",
    [2] = "清洁中",
}

-- ========== 缓冲参数 ==========
local RX_BUF_MAX     = 2048        -- 缓冲区上限 (字节) — 状态响应约 822 字节
local FRAME_TIMEOUT  = 3000        -- 半包超时 (ms)
local POLL_INTERVAL  = 2000        -- 轮询间隔 (ms) — 每 2 秒查询一次状态
local RESP_TIMEOUT   = 5000        -- 响应超时 (ms) — 超过此时间未收到有效响应则重置

-- ========== 模块状态 ==========
local initialized    = false
local hw_initialized = false
local rx_buffer      = ""          -- 接收缓冲
local last_rx_time   = 0           -- 上次接收时间 (ms)
local alarm_active   = false       -- 当前是否处于报警状态
local wait_response  = false       -- 是否在等待响应
local last_poll_time = 0           -- 上次发送查询时间
local current_lib    = 1           -- 当前报警库编号 (1 或 2)
local lib_info_raw   = nil         -- 报警库信息原始数据 (CMD_GET_LIB 响应)
local lib_requested  = false      -- 开机后是否已发送过读取报警库请求
local lib_retry_count = 0         -- 报警库读取重试次数
local LIB_MAX_RETRY  = 3          -- 报警库最大重试次数

-- ========== CRC16 算法 (多项式 0x1021) ==========
-- 按协议附录: buffer 从第 2 字节开始, len = 总长度 - 5
local function crc16(data, start_pos, end_pos)
    local crc = 0
    for i = start_pos, end_pos do
        crc = crc ~ (data:byte(i) << 8)
        for _ = 1, 8 do
            if (crc & 0x8000) ~= 0 then
                crc = (crc << 1) ~ 0x1021
            else
                crc = crc << 1
            end
        end
    end
    return crc & 0xFFFF
end

-- ========== 构建请求帧 ==========
-- @param cmd 功能码
-- @param data 数据区 (字符串, 可为空)
-- @return 完整帧字符串
local function build_request(cmd, data)
    data = data or ""
    local data_len = #data
    -- 帧头 + 目标 + 源 + 功能码 + 数据长度(LE) + 数据
    local prefix = string.char(
        FRAME_HEAD,       -- AA
        ADDR_DEVICE,      -- 目标=下位机(2)
        ADDR_HOST,        -- 源=上位机(1)
        cmd               -- 功能码
    ) .. string.pack("<I2", data_len) .. data  -- 数据长度(小端) + 数据

    -- CRC: 从 byte[2] 到数据区结尾, 即 prefix[2..end]
    local crc = crc16(prefix, 2, #prefix)

    -- 返回完整帧: prefix + CRC(LE) + 0D 0A
    local frame = prefix .. string.pack("<I2", crc) .. "\r\n"
    -- log.info("IMS", "TX:", frame:toHex())
    return frame
end

-- ========== 解析状态响应 (cmd 0x01) ==========
-- 数据区结构 (808 或 812 字节):
--   0:     仪器状态 (0=预热, 1=检测, 2=清洁)
--   1:     故障位
--   2:     报警物质数量 (0=无, 1-10)
--   3-6:   清洁剩余时间 (UInt32, LE)
--   7-26:  报警物质名称1 (20字节, UTF8)
--   27-46: 报警物质名称2
--   ...
--   187-206: 报警物质名称10
--   207-506: 正峰谱图 (150点×2字节, LE, mV)
--   507-806: 负峰谱图 (同上)
--   807:   仪器灵敏度 (0=高, 1=低)
local function parse_status_response(data)
    if #data < 10 then
        log.warn("IMS", "状态数据过短:", #data)
        return nil
    end

    -- 仪器状态
    local status = data:byte(1)
    -- 故障位
    local fault = data:byte(2)
    -- 报警物质数量
    local alarm_count = data:byte(3)
    -- 清洁剩余时间
    local clean_time = string.unpack("<I4", data, 4)

    -- 报警物质名称 (0-indexed byte 7 起 = Lua 1-indexed byte 8)
    local alarm_names = {}
    for i = 1, alarm_count do
        local offset = 8 + (i - 1) * 20
        if offset + 19 <= #data then
            local name_bytes = data:sub(offset, offset + 19)
            -- 去掉尾部 0x00
            local name = name_bytes:gsub("\0+$", "")
            if #name > 0 then
                alarm_names[#alarm_names + 1] = name
            end
        end
    end

    -- 正峰谱图 (byte 207-506, 150点×2字节, LE, mV)
    -- 0-indexed byte 207 = 1-indexed byte 208
    local pos_peak = {}
    if #data >= 507 then
        for i = 1, 150 do
            pos_peak[i] = string.unpack("<I2", data, 207 + (i - 1) * 2 + 1)
        end
    end

    -- 负峰谱图 (byte 507-806, 同上)
    local neg_peak = {}
    if #data >= 807 then
        for i = 1, 150 do
            neg_peak[i] = string.unpack("<I2", data, 507 + (i - 1) * 2 + 1)
        end
    end

    -- 灵敏度 (byte 807, 最后一字节)
    local sensitivity = -1
    if #data >= 808 then
        sensitivity = data:byte(808)
    end

    return {
        status       = status,
        status_desc  = STATUS[status] or "未知",
        fault        = fault,
        alarm_count  = alarm_count,
        alarm_names  = alarm_names,
        clean_time   = clean_time,
        sensitivity  = sensitivity,
        pos_peak     = pos_peak,
        neg_peak     = neg_peak,
    }
end

-- ========== 解析报警库响应 (cmd 0x05) ==========
-- 数据区结构 (102 字节):
--   byte 0:      报警库总数量 (1-5)
--   byte 1:      当前选中库 bitmap (低5位, BIT0=1号库)
--   byte 2~21:   1号库名称 (20字节, UTF8, 不足填0)
--   byte 22~41:  2号库名称
--   byte 42~61:  3号库名称
--   byte 62~81:  4号库名称
--   byte 82~101: 5号库名称
local function parse_lib_response(data)
    if #data < 2 then
        log.warn("IMS", "报警库数据过短:", #data)
        return nil
    end

    local total = data:byte(1)
    local cur_mask = data:byte(2)

    -- 提取各库名称
    local lib_names = {}
    for i = 1, total do
        local offset = 2 + (i - 1) * 20 + 1  -- Lua 1-indexed: byte 3 起
        if offset + 19 <= #data then
            local name_bytes = data:sub(offset, offset + 19)
            local name = name_bytes:gsub("\0+$", "")  -- 去掉尾部 0x00
            if name == "" then name = "未命名" end
            lib_names[i] = name
        end
    end

    -- 找出当前选中的库编号
    local cur_lib = 1
    for i = 1, total do
        if (cur_mask >> (i - 1)) & 1 == 1 then
            cur_lib = i
            break
        end
    end

    log.info("IMS", string.format("报警库: 总数=%d 当前=%d mask=0x%02X 名称=%s",
        total, cur_lib, cur_mask, table.concat(lib_names, ", ")))

    return {
        lib_total   = total,
        lib_current = cur_lib,
        lib_names   = lib_names,
        lib_loaded  = true,
    }
end

-- ========== 从缓冲区提取完整帧 ==========
-- 帧格式: AA + dst(1) + src(1) + cmd(1) + len(2,LE) + data(N) + CRC(2,LE) + 0D 0A
local function extract_frame()
    if #rx_buffer < 10 then
        return nil  -- 最小帧 10 字节 (无数据区的请求)
    end

    -- 查找帧头
    local start_idx = rx_buffer:find(string.char(FRAME_HEAD), 1, true)
    if not start_idx then
        rx_buffer = ""
        return nil
    end

    -- 丢弃帧头之前的无效数据
    if start_idx > 1 then
        rx_buffer = rx_buffer:sub(start_idx)
    end

    -- 需要至少 7 字节才能读取数据长度 (AA + dst + src + cmd + len_lo + len_hi)
    if #rx_buffer < 7 then
        return nil
    end

    -- 读取数据区长度 (小端, 在 byte[5..6])
    local data_len = string.unpack("<I2", rx_buffer, 5)
    -- 完整帧长度 = header(1) + dst(1) + src(1) + cmd(1) + len(2) + data(N) + crc(2) + crlf(2) = 10 + N
    local frame_len = 10 + data_len

    -- 数据未接收完整
    if #rx_buffer < frame_len then
        return nil
    end

    -- 提取完整帧
    local frame = rx_buffer:sub(1, frame_len)
    rx_buffer = rx_buffer:sub(frame_len + 1)

    -- 校验帧尾 (0D 0A)
    if frame:byte(frame_len - 1) ~= 0x0D or frame:byte(frame_len) ~= 0x0A then
        log.warn("IMS", "帧尾错误, 丢弃:", frame:sub(frame_len - 1):toHex())
        return nil, "bad_frame"  -- 帧已消费但校验失败
    end

    -- CRC 校验: 从 byte[2] 到数据区结尾 (frame_len - 4)
    -- CRC 覆盖: dst + src + cmd + len + data = frame[2..frame_len-4]
    local crc_calc = crc16(frame, 2, frame_len - 4)
    local crc_recv = string.unpack("<I2", frame, frame_len - 3)
    if crc_calc ~= crc_recv then
        log.warn("IMS", string.format("CRC 校验失败: 计算=%04X 接收=%04X", crc_calc, crc_recv))
        return nil, "bad_frame"  -- 帧已消费但校验失败
    end

    return frame
end

-- ========== 解析帧 ==========
local function parse_frame(frame)
    if #frame < 10 then
        return nil
    end

    -- 检查帧头
    if frame:byte(1) ~= FRAME_HEAD then
        return nil
    end

    -- 解析帧头
    local dst = frame:byte(2)   -- 目标地址
    local src = frame:byte(3)   -- 源地址
    local cmd = frame:byte(4)   -- 功能码
    local data_len = string.unpack("<I2", frame, 5)
    local data = frame:sub(7, 7 + data_len - 1)

    -- 只处理下位机(源=2)发给上位机(目标=1)的响应
    if src ~= ADDR_DEVICE or dst ~= ADDR_HOST then
        log.warn("IMS", string.format("地址不符: dst=%d src=%d (期望 dst=1 src=2)", dst, src))
        return nil
    end

    -- 按功能码解析
    if cmd == CMD_GET_STATUS then
        local result = parse_status_response(data)
        if result then
            -- log.debug("IMS", string.format("状态: %s 报警:%d 故障:0x%02X 清洁剩余:%ds",
            --     result.status_desc, result.alarm_count, result.fault, result.clean_time))
        end
        return result
    elseif cmd == CMD_CLEAN then
        local ok = data:byte(1)
        log.info("IMS", "清洗命令响应:", ok == 0 and "成功" or "失败")
        return { cmd = "clean", result = ok }
    elseif cmd == CMD_SKIP_WARM then
        local ok = data:byte(1)
        log.info("IMS", "跳过预热响应:", ok == 0 and "成功" or "失败")
        return { cmd = "skip_warmup", result = ok }
    elseif cmd == CMD_GET_LIB then
        log.info("IMS", "报警库信息, 数据长度:", #data)
        local lib_info = parse_lib_response(data)
        return { cmd = "get_lib", data = data, parsed = lib_info }
    elseif cmd == CMD_SEL_LIB then
        local ok = data:byte(1)
        log.info("IMS", "选择报警库响应:", ok == 0 and "成功" or "失败")
        return { cmd = "sel_lib", result = ok }
    elseif cmd == CMD_CALIB then
        local ok = data:byte(1)
        log.info("IMS", "校准命令响应:", ok == 0 and "成功" or "失败")
        return { cmd = "calibrate", result = ok }
    elseif cmd == CMD_SEL_SENS then
        local ok = data:byte(1)
        log.info("IMS", "选择灵敏度响应:", ok == 0 and "成功" or "失败")
        return { cmd = "sel_sensitivity", result = ok }
    else
        log.warn("IMS", "未知功能码:", cmd)
        return nil
    end
end

-- ========== UART 接收回调 ==========
local function on_uart_receive(id, len)
    local data = uart.read(id, len)
    if data and #data > 0 then
        rx_buffer = rx_buffer .. data
        last_rx_time = mcu.ticks()
        -- 缓冲区溢出保护
        if #rx_buffer > RX_BUF_MAX then
            log.warn("IMS", "缓冲区溢出, 清空:", #rx_buffer)
            rx_buffer = ""
        end
    end
end

-- ========== 初始化 ==========
function mod_ims.init()
    initialized = true
    log.info("IMS", "IMS 离子迁移谱模块加载完成 (协议 V0.3)")
end

-- ========== 启动 ==========
function mod_ims.start()
    if not initialized then
        log.error("IMS", "模块未初始化, 请先调用 mod_ims.init()")
        return
    end

    sys.taskInit(function()
        while true do
            -- 检查功能开关
            if not app_data.get_config("sensor_ims_en") then
                if hw_initialized then
                    uart.close(UART_ID)
                    hw_initialized = false
                    wait_response = false
                    if alarm_active then
                        alarm_active = false
                        app_data.clear_alarm("ims")
                    end
                    app_data.update_sensor("ims", {
                        status = 0, status_desc = "未连接", alarm_count = 0,
                        alarm_names = {}, fault = 0, clean_time = 0, sensitivity = -1,
                        pos_peak = {}, neg_peak = {},
                        lib_total = 0, lib_current = 1, lib_names = {}, lib_loaded = false,
                    })
                    lib_requested = false
                    lib_retry_count = 0
                    lib_info_raw = nil
                    log.info("IMS", "UART12 已关闭")
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
                log.info("IMS", "UART12 已初始化, 波特率:", UART_BAUD)
            end

            -- 检查半包超时
            if #rx_buffer > 0 and (mcu.ticks() - last_rx_time) > FRAME_TIMEOUT then
                log.warn("IMS", "半包超时, 丢弃缓冲区:", #rx_buffer, "字节")
                rx_buffer = ""
                wait_response = false
            end

            -- 响应超时保护: 超过 RESP_TIMEOUT 未收到有效响应则重置
            if wait_response and (mcu.ticks() - last_poll_time) > RESP_TIMEOUT then
                log.warn("IMS", "响应超时, 重置等待状态")
                wait_response = false
                -- 报警库读取失败重试 (开机自动读取场景)
                if lib_requested and not lib_info_raw and lib_retry_count < LIB_MAX_RETRY then
                    lib_retry_count = lib_retry_count + 1
                    log.warn("IMS", string.format("报警库读取重试 %d/%d", lib_retry_count, LIB_MAX_RETRY))
                    sys.timerStart(function()
                        if hw_initialized and not wait_response then
                            local lib_frame = build_request(CMD_GET_LIB)
                            uart.write(UART_ID, lib_frame)
                            wait_response = true
                            last_poll_time = mcu.ticks()
                        end
                    end, 1000)
                end
            end

            -- 定时发送状态查询
            if not wait_response then
                local now = mcu.ticks()
                if now - last_poll_time >= POLL_INTERVAL then
                    local frame = build_request(CMD_GET_STATUS)
                    uart.write(UART_ID, frame)
                    last_poll_time = now
                    wait_response = true
                    -- log.debug("IMS", "已发送状态查询")
                end
            end

            -- 尝试解析帧
            local frame, err = extract_frame()
            if frame then
                wait_response = false
                local result = parse_frame(frame)
                if result and result.cmd == "get_lib" then
                    -- 报警库信息响应
                    log.info("IMS", "RX:", frame:toHex())
                    lib_info_raw = result.data
                    sys.publish("IMS_LIB_INFO", result.data)
                    log.info("IMS", "报警库信息已接收, 数据长度:", #result.data)
                    -- 解析结果写入数据中心
                    if result.parsed then
                        app_data.update_sensor("ims", result.parsed)
                        current_lib = result.parsed.lib_current
                        lib_retry_count = 0  -- 重置重试计数
                        sys.publish("IMS_LIB_LOADED")
                        log.info("IMS", "报警库信息已解析并写入数据中心")
                    end
                elseif result and result.status_desc then
                    -- 状态响应: 检查报警
                    local has_alarm = result.alarm_count > 0
                    if has_alarm and not alarm_active then
                        alarm_active = true
                        app_data.update_alarm("ims", { names = result.alarm_names })
                        log.warn("IMS", "检测到毒剂! 数量:", result.alarm_count,
                            "名称:", table.concat(result.alarm_names, ", "))
                    elseif not has_alarm and alarm_active then
                        alarm_active = false
                        app_data.clear_alarm("ims")
                        log.info("IMS", "毒剂报警解除")
                    end

                    -- 写入数据中心
                    app_data.update_sensor("ims", result)
                    sys.publish("IMS_DATA_UPDATE")

                    -- 开机后首次成功通信时自动读取报警库 (延迟1秒, 非阻塞)
                    if not lib_requested then
                        lib_requested = true
                        sys.timerStart(function()
                            if hw_initialized and not wait_response then
                                local lib_frame = build_request(CMD_GET_LIB)
                                uart.write(UART_ID, lib_frame)
                                wait_response = true
                                last_poll_time = mcu.ticks()
                                log.info("IMS", "开机自动读取报警库命令已发送")
                            end
                        end, 1000)
                    end
                end
            elseif err == "bad_frame" then
                -- 帧已消费但 CRC/帧尾校验失败, 重置等待状态以便下次重新查询
                wait_response = false
                log.debug("IMS", "坏帧已丢弃, 重置等待状态")
            end

            sys.wait(100)  -- 短周期轮询
            ::continue::
        end
    end)

    if app_data.get_config("sensor_ims_en") then
        log.info("IMS", "IMS 离子迁移谱模块已启动")
    else
        log.info("IMS", "IMS 模块已加载（开关关闭，待启用）")
    end
end

-- ========== 对外接口 ==========

-- 获取当前 IMS 数据
function mod_ims.get_data()
    return app_data.get().sensor.ims
end

-- 读取报警库信息 (发送 CMD_GET_LIB, 响应通过 IMS_LIB_LOADED 事件返回)
function mod_ims.get_library()
    if not hw_initialized then return false end
    -- 设置等待状态, 阻止主循环在报警库响应到达前发送状态查询
    wait_response = true
    last_poll_time = mcu.ticks()
    local frame = build_request(CMD_GET_LIB)
    uart.write(UART_ID, frame)
    log.info("IMS", "发送读取报警库命令")
    return true
end

-- 获取当前报警库编号
function mod_ims.get_current_lib()
    return current_lib
end

-- 设置当前报警库编号 (内部跟踪, 不发送命令)
function mod_ims.set_current_lib(lib)
    current_lib = lib or 1
end

-- 获取报警库信息原始数据
function mod_ims.get_lib_info()
    return lib_info_raw
end

-- 发送清洗命令
-- @param minutes 清洗时间(分), >=30 开始清洗, <30 停止加热
function mod_ims.clean(minutes)
    if not hw_initialized then return false end
    local data = string.pack("<I2", minutes or 30)
    local frame = build_request(CMD_CLEAN, data)
    uart.write(UART_ID, frame)
    log.info("IMS", "发送清洗命令:", minutes, "分钟")
    return true
end

-- 跳过预热
function mod_ims.skip_warmup()
    if not hw_initialized then return false end
    local frame = build_request(CMD_SKIP_WARM)
    uart.write(UART_ID, frame)
    log.info("IMS", "发送跳过预热命令")
    return true
end

-- 选择报警库
-- @param lib_index 库编号 (1-5)
function mod_ims.select_library(lib_index)
    if not hw_initialized then return false end
    local mask = 1 << ((lib_index or 1) - 1)
    local data = string.char(mask)
    local frame = build_request(CMD_SEL_LIB, data)
    uart.write(UART_ID, frame)
    log.info("IMS", "选择报警库:", lib_index)
    return true
end

-- 选择灵敏度
-- @param level 0=高灵敏度, 1=低灵敏度
function mod_ims.set_sensitivity(level)
    if not hw_initialized then return false end
    local data = string.char(level or 0)
    local frame = build_request(CMD_SEL_SENS, data)
    uart.write(UART_ID, frame)
    log.info("IMS", "设置灵敏度:", level == 0 and "高" or "低")
    return true
end

-- 校准
function mod_ims.calibrate()
    if not hw_initialized then return false end
    local frame = build_request(CMD_CALIB)
    uart.write(UART_ID, frame)
    log.info("IMS", "发送校准命令")
    return true
end

-- ========== 注册回调（星型架构：供 mod_screen_ims 调用） ==========
app_data.register_callback("ims_api", {
    get_data        = mod_ims.get_data,
    get_lib         = mod_ims.get_library,
    select_lib      = mod_ims.select_library,
    skip_warmup     = mod_ims.skip_warmup,
    set_sens        = mod_ims.set_sensitivity,
    get_current_lib = mod_ims.get_current_lib,
    set_current_lib = mod_ims.set_current_lib,
    get_lib_info    = mod_ims.get_lib_info,
})

return mod_ims
