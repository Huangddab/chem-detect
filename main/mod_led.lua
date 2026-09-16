--[[
@module  mod_led
@brief   LED 指示灯控制（UART10 单字节指令协议）
@version 3.0
@date    2026.08.17
@usage
本模块通过 UART10 向外部 LED 控制板发送 1 字节指令，控制红/黄/绿三色 LED。

通信参数：
  波特率 115200, 数据位 8, 停止位 1, 校验无, 流控无
  帧格式：1 字节指令，无帧头校验

指令表：
  0x00 — 熄灭（灯全灭）
  0x01 — 红灯常亮（R=255）
  0x02 — 红灯闪烁（500ms 亮 / 500ms 灭）
  0x03 — 黄灯常亮（R=255, G=180 琥珀黄）
  0x04 — 黄灯闪烁（500ms 亮 / 500ms 灭）
  0x05 — 绿灯常亮（G=255）
  0x06 — 绿灯闪烁（500ms 亮 / 500ms 灭）
  其他 — 忽略（无效指令不做任何操作）

外部模块通过 app_data.update_io("led", {alarm="blink_fast"}) 设置状态。
模块内部将 alarm/power/comm 状态映射为指令码，通过 UART10 发送。

在 main.lua 中调用：
  local mod_led = require "mod_led"
  mod_led.init()
  mod_led.start()
]]

local mod_led = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 硬件参数 ==========
local UART_ID   = 10          -- UART10 (WiFi 芯片, pin 57 TX / pin 58 RX)
local UART_BAUD = 115200      -- 波特率

-- ========== 指令码定义 ==========
local CMD = {
    OFF            = 0x00,    -- 熄灭
    RED_ON         = 0x01,    -- 红灯常亮
    RED_BLINK      = 0x02,    -- 红灯闪烁
    YELLOW_ON      = 0x03,    -- 黄灯常亮
    YELLOW_BLINK   = 0x04,    -- 黄灯闪烁
    GREEN_ON       = 0x05,    -- 绿灯常亮
    GREEN_BLINK    = 0x06,    -- 绿灯闪烁
}

-- ========== 闪烁参数 ==========
local TICK_MS        = 50     -- 协程轮询间隔
local BLINK_PERIOD   = 500    -- 闪烁半周期（ms），完整周期 1000ms

-- ========== 模块内部状态 ==========
local initialized = false
local hw_initialized = false
local last_cmd = nil          -- 上次发送的指令（避免重复发送）

-- ========== 辅助函数 ==========

-- 确保硬件已初始化
local function ensure_hw()
    if not hw_initialized then
        -- 参数: id, baud, databits, stopbits, parity, bit_order, buf_size
        uart.setup(UART_ID, UART_BAUD, 8, 1, 0, uart.LSB, 1024)
        hw_initialized = true
        last_cmd = nil
        log.info("LED", string.format("UART10 已初始化, %d 8N1, buf=1024", UART_BAUD))
    end
end

-- 关闭硬件
local function close_hw()
    if hw_initialized then
        -- 关闭前熄灭
        uart.write(UART_ID, string.char(CMD.OFF))
        pcall(uart.close, UART_ID)
        hw_initialized = false
        last_cmd = nil
        log.info("LED", "UART10 已关闭")
    end
end

-- 发送 1 字节指令到 LED 控制板
-- @param cmd 指令码 (0x00~0x06)
local function send_cmd(cmd)
    if cmd == last_cmd then return end  -- 相同指令不重复发送
    if hw_initialized then
        local tx_data = string.char(cmd)
        local tx_len = uart.write(UART_ID, tx_data)
        last_cmd = cmd
        log.info("LED", string.format("发送指令: 0x%02X (写入 %d 字节)", cmd, tx_len or -1))
    end
end

-- ========== 初始化 ==========
function mod_led.init()
    -- 设置默认状态：电源灯常亮（映射为绿灯常亮）
    app_data.update_io("led", {power = "on"})

    initialized = true
    log.info("LED", "LED 模块初始化完成 (UART10, 115200 8N1)")
end

-- ========== 设置 LED 状态（写入 app_data，由协程执行） ==========
-- @param name  LED名称 ("power"/"alarm"/"comm")
-- @param state 状态：true/false 或 "on"/"off"/"blink_slow"/"blink_fast"
function mod_led.set(name, state)
    if name ~= "power" and name ~= "alarm" and name ~= "comm" then return end
    -- 统一转换为字符串状态
    if type(state) == "boolean" then
        state = state and "on" or "off"
    end
    app_data.update_io("led", {[name] = state})
end

-- ========== 启动 LED 驱动协程 ==========
function mod_led.start()
    if not initialized then
        log.error("LED", "LED 未初始化, 请先调用 mod_led.init()")
        return
    end

    sys.taskInit(function()
        -- UART10 位于 WiFi 芯片，需等待 WiFi 初始化完成后才能使用
        sys.wait(3000)

        local blink_phase = false       -- 闪烁相位（true=亮, false=灭）
        local blink_timer = 0           -- 闪烁计时器

        while true do
            -- 检查功能开关
            if not app_data.get_config("led_en") then
                close_hw()
                sys.wait(1000)
                goto continue
            end

            -- 确保硬件已初始化
            ensure_hw()

            -- 首次初始化后立即点亮绿灯
            if last_cmd == nil then
                send_cmd(CMD.GREEN_ON)
            end

            local d = app_data.get()
            local io_led = d.io.led

            -- 优先级：alarm > power > comm
            -- 报警灯最高优先级，其次电源灯，最后通信灯
            local alarm_state = io_led.alarm or "off"
            local power_state = io_led.power
            local comm_state  = io_led.comm or "off"

            -- 统一 power 布尔值转字符串
            if type(power_state) == "boolean" then
                power_state = power_state and "on" or "off"
            end
            -- 统一 comm 布尔值转字符串
            if type(comm_state) == "boolean" then
                comm_state = comm_state and "on" or "off"
            end

            -- 根据优先级决定当前输出的颜色和模式
            local color = nil    -- "red" / "yellow" / "green" / nil
            local mode  = nil    -- "on" / "blink" / nil

            if alarm_state == "on" then
                color, mode = "red", "on"
            elseif alarm_state == "blink_slow" or alarm_state == "blink_fast" then
                color, mode = "red", "blink"
            elseif alarm_state == "off" then
                -- 报警关闭，看电源灯
                if power_state == "on" or power_state == true then
                    color, mode = "green", "on"
                elseif power_state == "blink_slow" or power_state == "blink_fast" then
                    color, mode = "green", "blink"
                end
                -- 电源灯也关，看通信灯
                if not color then
                    if comm_state == "on" or comm_state == true then
                        color, mode = "yellow", "on"
                    elseif comm_state == "blink_slow" or comm_state == "blink_fast" then
                        color, mode = "yellow", "blink"
                    end
                end
            end

            -- 计算目标指令码
            local target_cmd = CMD.OFF  -- 默认熄灭
            if color == "red" then
                target_cmd = (mode == "blink") and CMD.RED_BLINK or CMD.RED_ON
            elseif color == "yellow" then
                target_cmd = (mode == "blink") and CMD.YELLOW_BLINK or CMD.YELLOW_ON
            elseif color == "green" then
                target_cmd = (mode == "blink") and CMD.GREEN_BLINK or CMD.GREEN_ON
            end

            -- 闪烁指令处理：闪烁时需要交替发送 常亮 / 熄灭
            if mode == "blink" then
                blink_timer = blink_timer + TICK_MS
                if blink_timer >= BLINK_PERIOD then
                    blink_phase = not blink_phase
                    blink_timer = 0
                end
                -- 亮相位发送对应常亮指令，灭相位发送熄灭指令
                if blink_phase then
                    if color == "red" then
                        target_cmd = CMD.RED_ON
                    elseif color == "yellow" then
                        target_cmd = CMD.YELLOW_ON
                    elseif color == "green" then
                        target_cmd = CMD.GREEN_ON
                    end
                else
                    target_cmd = CMD.OFF
                end
            else
                -- 非闪烁模式重置闪烁状态
                blink_phase = false
                blink_timer = 0
            end

            -- 发送指令（send_cmd 内部会去重）
            send_cmd(target_cmd)

            sys.wait(TICK_MS)
            ::continue::
        end
    end)

    log.info("LED", "LED 驱动协程已启动 (UART10)")
end

-- ========== 直接发送指令码（测试用, 跳过 app_data 逻辑） ==========
-- @param cmd 指令码 (0x00~0x06)
function mod_led.set_raw(cmd)
    if not initialized then return end
    ensure_hw()
    last_cmd = nil  -- 强制下次发送
    send_cmd(cmd)
end

return mod_led
