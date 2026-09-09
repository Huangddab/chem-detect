--[[
@module  mod_screen_ota
@brief   屏幕 OTA 固件升级 + 文件透传 (UART11)

功能:
  1. 屏幕固件 OTA: whmi-wri 协议升级屏幕固件 (.tft)
  2. 文件透传: twfile 协议传输地图等资源文件到 SD 卡 (.ebs 压缩包)

本模块从 mod_screen.lua 拆分而来，通过 app_data 回调中介与 mod_screen 协作:
  - mod_screen 注册 "screen_uart_ctrl" 回调，提供 set_ota_active(flag)
    用于 OTA/文件透传期间暂停 mod_screen 的正常 UART 接收
  - 本模块注册 "screen_ota" 回调，供 mod_ota 间接调用 OTA/文件透传接口

硬件:
  Air8000 UART11_TX (pin 49) -> 屏幕 RX
  Air8000 UART11_RX (pin 48) -> 屏幕 TX
  共地, 3.3V 供电

🤖 整体或部分由 opencode 生成
]]

local mod_screen_ota = {}

local app_data = require "app_data"

-- ========== UART 硬件参数（与 mod_screen 一致） ==========
local UART_ID       = 11          -- UART11 (WGPIO pin 48 RX / pin 49 TX)
local UART_BAUD     = 115200      -- 陶晶池屏默认波特率
local UART_DATABITS = 8
local UART_PARITY   = 0           -- 无校验
local UART_STOPBITS = 1
local UART_BUF_SIZE = 10240       -- UART缓冲区大小（大数据传输需要增大）

-- ========== TJC 协议常量 ==========
local CMD_END = string.char(0xFF, 0xFF, 0xFF)

-- ========== 屏幕 OTA 参数 ==========
local SCREEN_OTA_BAUD = 921600      -- 下载波特率
local SCREEN_OTA_CHUNK = 4096       -- 每块传输大小

-- TJC 联机指令: DRAKJHSUYDGBNCJHGJKSHBDN + \xFF\xFF\xFF + \x00 + \xFF\xFF\xFF + connect + \xFF\xFF\xFF
local TJC_CONNECT_CMD = "DRAKJHSUYDGBNCJHGJKSHBDN" .. CMD_END .. "\x00" .. CMD_END .. "connect" .. CMD_END

-- 屏幕 OTA 状态
local screen_ota_mode = false       -- 是否在 OTA 模式（暂停正常通信）
local screen_ota_state = "idle"    -- idle/connecting/uploading/success/fail
local screen_ota_progress = 0
local screen_ota_total = 0
local screen_ota_received = 0
local screen_ota_connect_baud = 0
local screen_ota_cancel_flag = false  -- 取消标志，让运行中的协程立即退出

-- ========== 文件透传参数 ==========
-- TJC 文件透传协议 (twfile) 包头: 3A A1 BB 44 7F FF FE [crc] [packid_lo] [packid_hi] [size_lo] [size_hi]
local FILE_PACK_MAGIC = string.char(0x3a, 0xa1, 0xbb, 0x44, 0x7f, 0xff, 0xfe)

-- 文件透传状态
local file_transfer_mode = false
local file_transfer_state = "idle"    -- idle/transferring/success/fail
local file_transfer_progress = 0
local file_transfer_total = 0
local file_transfer_received = 0
local file_transfer_pack_id = 0
local file_transfer_cancel_flag = false  -- 取消标志，让运行中的协程立即退出

-- ========== DMA 发送缓冲 ==========
local screen_tx_buff = nil        -- 发送缓冲 zbuff
local screen_tx_done = false      -- 发送完成标志

-- ========== 通知 mod_screen UART 忙碌状态 ==========
-- 通过 app_data 回调中介，通知 mod_screen 暂停/恢复正常 UART 接收
local function notify_busy(active)
    local ctrl = app_data.get_callback("screen_uart_ctrl")
    if ctrl and ctrl.set_ota_active then
        ctrl.set_ota_active(active)
    end
end

-- ========== 屏幕 OTA 升级功能 ==========

-- TJC 联机：尝试多个波特率发送 connect 指令，等待 comok 响应
local function screen_ota_connect()
    -- 固定 115200 联机
    local bauds = {115200, 9600}
    for _, baud in ipairs(bauds) do
        log.info("SCREEN_OTA", "尝试波特率:", baud)
        uart.setup(UART_ID, baud, UART_DATABITS, UART_PARITY, UART_STOPBITS, uart.LSB, UART_BUF_SIZE)
        sys.wait(50)
        -- 清空接收缓冲
        uart.read(UART_ID, 1024)
        -- 发送联机指令
        uart.write(UART_ID, TJC_CONNECT_CMD)
        -- 轮询读取响应（模拟 Python ser.read 的 timeout 机制）
        local resp = ""
        local waited = 0
        local base_wait = math.floor(1000000 / baud + 30)
        while waited < (base_wait + 200) do
            sys.wait(20)
            waited = waited + 20
            local s = uart.read(UART_ID, 1024)
            if s and #s > 0 then
                resp = resp .. s
                -- 检查 comok 字符串 或 0x1A 首字节（TJC connect 成功响应）
                if resp:find("comok") or string.byte(resp, 1) == 0x1A then
                    screen_ota_connect_baud = baud
                    log.info("SCREEN_OTA", "联机成功! 波特率:", baud, "首字节:", string.byte(resp, 1), "长度:", #resp)
                    return true
                end
            end
        end
        if #resp > 0 then
            log.debug("SCREEN_OTA", "波特率", baud, "收到但无comok/0x1A, 首字节:", string.byte(resp, 1), "长度:", #resp)
        end
    end
    log.error("SCREEN_OTA", "联机失败，所有波特率均无响应")
    return false
end

-- 恢复 UART 到正常通信状态
local function restore_uart()
    sys.wait(300)
    notify_busy(false)
    uart.setup(UART_ID, UART_BAUD, UART_DATABITS, UART_PARITY, UART_STOPBITS, uart.LSB, UART_BUF_SIZE)
    sys.wait(200)
    -- 直接发送 page 0 指令切回主页（不依赖 mod_screen.switch_page）
    uart.write(UART_ID, "page 0" .. CMD_END)
end

-- 屏幕 OTA：开始升级（联机 + 发送下载指令）
-- @param file_size 固件文件大小（字节）
-- @return boolean, string 成功返回 true, 失败返回 false, 错误信息
function mod_screen_ota.ota_begin(file_size)
    if screen_ota_state ~= "idle" and screen_ota_state ~= "fail" and screen_ota_state ~= "success" then
        return false, "正在升级中: " .. screen_ota_state
    end

    screen_ota_mode = true
    notify_busy(true)
    screen_ota_state = "connecting"
    screen_ota_total = file_size
    screen_ota_received = 0
    screen_ota_progress = 0

    log.info("SCREEN_OTA", "开始屏幕固件升级, 文件大小:", file_size, "字节")

    -- 步骤1：联机
    if not screen_ota_connect() then
        screen_ota_state = "fail"
        restore_uart()
        return false, "联机失败"
    end

    -- 清空联机响应的残留数据（屏幕设备信息可能很长，只读了前几字节）
    sys.wait(50)
    uart.read(UART_ID, 1024)

    -- 步骤2：发送 whmi-wri 下载指令
    local download_baud = 115200  -- 下载波特率（可调）
    local cmd = string.format("whmi-wri %d,%d,0", file_size, download_baud)
    log.info("SCREEN_OTA", "发送下载指令:", cmd, "下载波特率:", download_baud)
    uart.write(UART_ID, cmd .. CMD_END)

    -- 步骤3：等待发送完成后立即切换波特率（官方文档：发送后立即切换）
    -- 不等350ms！否则屏幕用新波特率发0x05时Air8000还在旧波特率，收成乱码
    sys.wait(50)  -- 仅等TX FIFO排空
    if download_baud ~= UART_BAUD then
        uart.setup(UART_ID, download_baud, UART_DATABITS, UART_PARITY, UART_STOPBITS, uart.LSB, UART_BUF_SIZE)
        log.info("SCREEN_OTA", "已切换到下载波特率:", download_baud)
    end

    -- 步骤4：等待 0x05 准备信号（屏幕约250ms后返回）
    local wait_count = 0
    while wait_count < 400 do
        if screen_ota_cancel_flag then
            log.info("SCREEN_OTA", "联机被取消")
            screen_ota_state = "fail"
            restore_uart()
            return false, "已取消"
        end
        local resp = uart.read(UART_ID, 128)
        if resp and #resp > 0 then
            log.debug("SCREEN_OTA", "等待0x05收到:", resp:toHex(), "长度:", #resp)
            for i = 1, #resp do
                if string.byte(resp, i) == 0x05 then
                    screen_ota_state = "uploading"
                    log.info("SCREEN_OTA", "设备就绪, 开始传输固件")
                    return true
                end
            end
        end
        sys.wait(10)
        wait_count = wait_count + 1
    end

    log.error("SCREEN_OTA", "设备未响应准备信号 (0x05)")
    screen_ota_state = "fail"
    restore_uart()
    return false, "设备未响应准备信号"
end

-- 屏幕 OTA：发送一块固件数据
-- @param data 二进制数据块
-- @return boolean, string 成功返回 true, 失败返回 false, 错误信息
function mod_screen_ota.ota_write_chunk(data)
    if screen_ota_state ~= "uploading" then
        return false, "状态错误: " .. screen_ota_state
    end
    if not data or #data == 0 then
        return false, "无数据"
    end

    -- 把大数据块拆成 4KB 发给屏幕（TJC 协议要求每块后等 0x05）
    local offset = 1
    local chunk_size = 4096
    while offset <= #data do
        -- 检查取消标志
        if screen_ota_cancel_flag then
            log.info("SCREEN_OTA", "传输被取消")
            return false, "已取消"
        end

        local chunk = string.sub(data, offset, offset + chunk_size - 1)
        local chunk_len = #chunk

        -- 用 zbuff + uart.tx DMA 发送（比 uart.write 字符串更高效）
        screen_tx_buff:write(chunk)
        screen_tx_done = false
        uart.tx(UART_ID, screen_tx_buff, 0, chunk_len)
        -- 等待发送完成回调
        local tx_wait = 0
        while not screen_tx_done and tx_wait < 500 do
            sys.wait(5)
            tx_wait = tx_wait + 5
        end
        screen_tx_buff:del()  -- 清空 zbuff 供下次使用

        -- 等待 0x05 确认信号（5ms 轮询，更快检测）
        local wait_count = 0
        local got_05 = false
        while wait_count < 400 do
            if screen_ota_cancel_flag then
                return false, "已取消"
            end
            local resp = uart.read(UART_ID, 128)
            if resp and #resp > 0 then
                for i = 1, #resp do
                    if string.byte(resp, i) == 0x05 then
                        got_05 = true
                        break
                    end
                end
                if got_05 then break end
            end
            sys.wait(5)
            wait_count = wait_count + 1
        end

        if not got_05 then
            if not screen_ota_cancel_flag then
                log.error("SCREEN_OTA", "等待 0x05 确认超时, 已传:", screen_ota_received)
                screen_ota_state = "fail"
            end
            return false, "响应超时"
        end

        screen_ota_received = screen_ota_received + chunk_len
        screen_ota_progress = math.floor(screen_ota_received * 100 / screen_ota_total)
        offset = offset + chunk_size
    end

    return true
end

-- 屏幕 OTA：完成升级
-- @return boolean 是否成功
function mod_screen_ota.ota_finish()
    if screen_ota_state ~= "uploading" then
        return false, "状态错误: " .. screen_ota_state
    end

    if screen_ota_received >= screen_ota_total then
        screen_ota_state = "success"
        screen_ota_progress = 100
        log.info("SCREEN_OTA", "固件传输完成! 共:", screen_ota_received, "字节")
    else
        screen_ota_state = "fail"
        log.warn("SCREEN_OTA", "固件传输不完整:", screen_ota_received, "/", screen_ota_total)
    end

    restore_uart()
    return screen_ota_state == "success"
end

-- 屏幕 OTA：取消升级
function mod_screen_ota.ota_cancel()
    screen_ota_cancel_flag = true   -- 通知运行中的协程退出
    screen_ota_state = "idle"
    screen_ota_progress = 0
    screen_ota_received = 0
    log.info("SCREEN_OTA", "升级已取消")
    restore_uart()
    screen_ota_cancel_flag = false  -- 恢复标志
end

-- 屏幕 OTA：获取升级状态
-- @return table {state, progress, total, received}
function mod_screen_ota.ota_get_status()
    return {
        state = screen_ota_state,
        progress = screen_ota_progress,
        total = screen_ota_total,
        received = screen_ota_received,
    }
end

-- ========== 文件透传功能 (TJC twfile 协议) ==========

-- 构造 12 字节包头
local function build_pack_header(pack_id, data_size, crc_type)
    local total_size = data_size
    if crc_type == 1 then total_size = total_size + 2 end
    if crc_type == 10 then total_size = total_size + 4 end
    return FILE_PACK_MAGIC
        .. string.char(crc_type % 256)
        .. string.char(pack_id % 256, pack_id // 256 % 256)
        .. string.char(total_size % 256, total_size // 256 % 256)
end

-- 读取 UART 响应（带超时）
local function uart_read_resp(timeout_ms)
    local waited = 0
    while waited < timeout_ms do
        local s = uart.read(UART_ID, 128)
        if s and #s > 0 then return s end
        sys.wait(20)
        waited = waited + 20
    end
    return ""
end

-- 文件透传：开始（发送 twfile 命令，等待 0xFE 响应）
-- @param dest_path 屏幕端目标路径（如 "sd0/image.jpg"）
-- @param file_size 文件大小（字节）
-- @return boolean, string
function mod_screen_ota.file_transfer_begin(dest_path, file_size)
    if file_transfer_state ~= "idle" and file_transfer_state ~= "fail" and file_transfer_state ~= "success" then
        return false, "正在传输中"
    end

    file_transfer_mode = true
    notify_busy(true)
    file_transfer_state = "transferring"
    file_transfer_total = file_size
    file_transfer_received = 0
    file_transfer_progress = 0
    file_transfer_pack_id = 0
    file_transfer_cancel_flag = false

    log.info("SCREEN_FILE", "开始文件透传, 路径:", dest_path, "大小:", file_size)

    -- 发送空指令清空缓冲
    uart.write(UART_ID, string.char(0x00) .. CMD_END)
    sys.wait(50)
    uart.read(UART_ID, 1024)

    -- 发送 twfile 命令
    local cmd = string.format('twfile "%s",%d', dest_path, file_size)
    uart.write(UART_ID, cmd .. CMD_END)

    -- 等待 0xFE 响应（4字节）或 0x06（文件创建失败）
    local resp = uart_read_resp(1000)
    if resp and #resp >= 4 and string.byte(resp, 1) == 0xFE then
        log.info("SCREEN_FILE", "屏幕已就绪, 开始传输")
        return true
    end
    if resp and #resp >= 4 and string.byte(resp, 1) == 0x06 then
        log.error("SCREEN_FILE", "文件创建失败 (0x06), 路径:", dest_path)
        file_transfer_state = "fail"
        file_transfer_mode = false
        restore_uart()
        return false, "文件创建失败: 路径无效或存储空间不足"
    end

    -- 未收到响应，检查是否为 0x06 失败
    if resp and #resp >= 4 and string.byte(resp, 1) == 0x06 then
        log.error("SCREEN_FILE", "文件创建失败 (0x06 重试), 路径:", dest_path)
        file_transfer_state = "fail"
        file_transfer_mode = false
        restore_uart()
        return false, "文件创建失败: 路径无效或存储空间不足"
    end

    log.warn("SCREEN_FILE", "未收到就绪响应, 重试...")
    uart.write(UART_ID, build_pack_header(65535, 0, 0))
    sys.wait(60)
    uart.write(UART_ID, string.char(0x00) .. CMD_END)
    sys.wait(60)
    uart.read(UART_ID, 1024)

    -- 重新发送 twfile
    uart.write(UART_ID, cmd .. CMD_END)
    resp = uart_read_resp(1000)
    if resp and #resp >= 4 and string.byte(resp, 1) == 0xFE then
        log.info("SCREEN_FILE", "屏幕已就绪 (重试成功)")
        return true
    end

    log.error("SCREEN_FILE", "屏幕未响应文件传输命令")
    file_transfer_state = "fail"
    file_transfer_mode = false
    restore_uart()
    return false, "屏幕未响应"
end

-- 文件透传：发送数据包
-- @param data 二进制数据块
-- @return boolean, boolean 成功返回 true, done (true=文件传输完成)
function mod_screen_ota.file_transfer_chunk(data)
    if file_transfer_state ~= "transferring" then
        return false, false, "状态错误"
    end
    if not data or #data == 0 then
        return false, false, "无数据"
    end

    -- 把大数据拆成 1024 字节小包发送（参考官方 C# SerialFileUp）
    local offset = 1
    local pack_size = 1024
    while offset <= #data do
        -- 检查取消标志
        if file_transfer_cancel_flag then
            log.info("SCREEN_FILE", "传输被取消")
            return false, false, "已取消"
        end

        local chunk = string.sub(data, offset, offset + pack_size - 1)
        local chunk_len = #chunk

        -- 清空接收缓冲
        uart.read(UART_ID, 1024)

        -- 发送包头 + 数据（分开写，跟 C# 一致）
        local header = build_pack_header(file_transfer_pack_id, chunk_len, 0)
        uart.write(UART_ID, header)
        uart.write(UART_ID, chunk)

        -- 等待响应: 0x05=包成功, 0x04=包失败(重发), 0xFD=文件完成
        -- 官方文档: 收到0x04或超时500ms，重发本包，PackId不加1
        local retry_count = 0
        local got_resp = false
        while retry_count < 10 do
            if file_transfer_cancel_flag then
                return false, false, "已取消"
            end
            local waited = 0
            while waited < 500 do  -- 官方建议超时500ms
                if file_transfer_cancel_flag then
                    return false, false, "已取消"
                end
                local resp = uart.read(UART_ID, 4)
                if resp and #resp > 0 then
                    local first = string.byte(resp, 1)
                    if first == 0x05 then
                        file_transfer_pack_id = file_transfer_pack_id + 1
                        file_transfer_received = file_transfer_received + chunk_len
                        file_transfer_progress = math.floor(file_transfer_received * 100 / file_transfer_total)
                        got_resp = true
                        break
                    elseif first == 0xFD then
                        file_transfer_received = file_transfer_received + chunk_len
                        file_transfer_progress = 100
                        file_transfer_state = "success"
                        log.info("SCREEN_FILE", "文件传输完成!")
                        return true, true
                    elseif first == 0x04 then
                        -- 包处理失败，重发本包
                        log.warn("SCREEN_FILE", "包失败(0x04), 重发 PackId:", file_transfer_pack_id, "重试:", retry_count + 1)
                        break  -- 跳出等待循环，进入重发
                    end
                end
                sys.wait(10)
                waited = waited + 10
            end

            if got_resp then break end

            -- 超时或收到0x04，重发本包
            sys.wait(30)  -- 官方建议重发前停顿30ms
            uart.read(UART_ID, 1024)  -- 清空缓冲
            local retry_header = build_pack_header(file_transfer_pack_id, chunk_len, 0)
            uart.write(UART_ID, retry_header)
            uart.write(UART_ID, chunk)
            retry_count = retry_count + 1
        end

        if not got_resp then
            log.error("SCREEN_FILE", "重发10次仍失败, PackId:", file_transfer_pack_id)
            file_transfer_state = "fail"
            return false, false, "重发超时"
        end

        offset = offset + pack_size
    end

    return true, false
end

-- 文件透传：完成
function mod_screen_ota.file_transfer_finish()
    if file_transfer_state == "transferring" then
        -- 仍在传输中，发送退出包
        uart.write(UART_ID, build_pack_header(65535, 0, 0))
        file_transfer_state = "fail"
        log.warn("SCREEN_FILE", "文件传输未完成, 发送退出包")
    end
    restore_uart()
    return file_transfer_state == "success"
end

-- 文件透传：取消
function mod_screen_ota.file_transfer_cancel()
    file_transfer_cancel_flag = true   -- 通知运行中的协程立即退出
    uart.write(UART_ID, build_pack_header(65535, 0, 0))
    file_transfer_state = "idle"
    file_transfer_progress = 0
    file_transfer_received = 0
    log.info("SCREEN_FILE", "文件传输已取消")
    restore_uart()
    file_transfer_cancel_flag = false  -- 恢复标志
end

-- 文件透传：获取状态
function mod_screen_ota.file_transfer_get_status()
    return {
        state = file_transfer_state,
        progress = file_transfer_progress,
        total = file_transfer_total,
        received = file_transfer_received,
    }
end

-- ========== 初始化 ==========
function mod_screen_ota.init()
    -- 预分配发送 zbuff（DMA 发送用）
    screen_tx_buff = zbuff.create(4096)

    -- 注册 UART 发送完成回调（DMA 发送完成后触发）
    uart.on(UART_ID, "sent", function(id)
        screen_tx_done = true
    end)

    log.info("SCREEN_OTA", "屏幕 OTA 模块初始化完成")
end

-- ========== 注册回调（星型架构：通过 app_data 中介供 mod_ota 间接调用） ==========
app_data.register_callback("screen_ota", {
    begin             = mod_screen_ota.ota_begin,
    write_chunk       = mod_screen_ota.ota_write_chunk,
    finish            = mod_screen_ota.ota_finish,
    cancel            = mod_screen_ota.ota_cancel,
    get_status        = mod_screen_ota.ota_get_status,
    file_begin        = mod_screen_ota.file_transfer_begin,
    file_chunk        = mod_screen_ota.file_transfer_chunk,
    file_finish       = mod_screen_ota.file_transfer_finish,
    file_cancel       = mod_screen_ota.file_transfer_cancel,
    file_get_status   = mod_screen_ota.file_transfer_get_status,
})

return mod_screen_ota
