--[[
@module  mod_buzzer
@brief   蜂鸣器控制
@version 1.0
@date    2026.07.03
@usage
本模块控制蜂鸣器（GPIO16）：
1. 支持连续鸣响、间歇鸣响、停止三种模式
2. 支持短促提示音 beep(ms)
3. 按键事件自动触发短促提示音（通过 app_data 联动）
4. 通过 config 开关 buzzer_en 控制

模块通过 app_data.io.buzzer.pattern 读取期望模式，驱动 GPIO 输出。
报警模块通过 app_data.update_io("buzzer", {pattern="continuous"}) 设置模式。

在 main.lua 中调用：
  local mod_buzzer = require "mod_buzzer"
  mod_buzzer.init()
  mod_buzzer.start()

🤖 整体或部分由 opencode 生成
]]

local mod_buzzer = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 硬件引脚定义 ==========
local BUZZER_PIN = 16   -- GPIO16, pin 83

-- ========== 参数 ==========
local TICK_MS              = 50    -- 协程轮询间隔
local INTERMITTENT_PERIOD  = 500   -- 间歇鸣响半周期（ms），500ms on / 500ms off
local KEY_BEEP_MS          = 100   -- 按键提示音时长（ms）

-- ========== 模块内部状态 ==========
local initialized = false
local manual_ctrl = false   -- 手动控制标志（屏幕直接 on/off 时独占 GPIO）
local test_mode = false     -- 测试模式：协程内 toggle 响/停

-- ========== 初始化 ==========
function mod_buzzer.init()
    pcall(function() gpio.close(BUZZER_PIN) end)
    gpio.setup(BUZZER_PIN, 0)  -- 输出，初始低电平
    initialized = true
    log.info("BUZZER", "蜂鸣器模块初始化完成 (GPIO16)")
end

-- ========== 直接控制接口（测试用） ==========
function mod_buzzer.on()
    if not initialized then return end
    manual_ctrl = true
    gpio.set(BUZZER_PIN, 1)
    log.info("BUZZER", "GPIO16 = 1 (on)")
end

function mod_buzzer.off()
    if not initialized then return end
    manual_ctrl = false
    gpio.set(BUZZER_PIN, 0)
    log.info("BUZZER", "GPIO16 = 0 (off)")
end

-- 短促鸣响（使用定时器，可在任意上下文调用）
-- @param ms 鸣响时长（毫秒），默认 200ms
function mod_buzzer.beep(ms)
    if not initialized then return end
    if not app_data.get_config("buzzer_en") then return end
    gpio.set(BUZZER_PIN, 1)
    sys.timerStart(function()
        gpio.set(BUZZER_PIN, 0)
    end, ms or 200)
end

-- 设置蜂鸣器模式（写入 app_data，由协程执行）
-- @param mode "off"/"continuous"/"intermittent"
function mod_buzzer.pattern(mode)
    app_data.update_io("buzzer", {pattern = mode})
end

-- 测试模式：toggle 响/停（不受 buzzer_en 开关限制，由协程驱动 GPIO）
function mod_buzzer.toggle_test()
    test_mode = not test_mode
    if not test_mode then
        gpio.set(BUZZER_PIN, 0)
    end
    log.info("BUZZER", "测试模式:", test_mode and "响" or "停")
    return test_mode
end

-- ========== 启动蜂鸣器驱动协程 ==========
function mod_buzzer.start()
    if not initialized then
        log.error("BUZZER", "蜂鸣器未初始化, 请先调用 mod_buzzer.init()")
        return
    end

    sys.taskInit(function()
        local intermittent_phase = false
        local intermittent_timer = 0
        local last_key_ts = 0
        local beep_remaining = 0  -- 按键提示音剩余时间

        while true do
            -- 测试模式：直接驱动 GPIO，不受 buzzer_en 限制
            if test_mode then
                gpio.set(BUZZER_PIN, 1)
                sys.wait(TICK_MS)
                goto continue
            end
            -- 手动控制模式：协程不干预 GPIO，由屏幕命令独占
            if manual_ctrl then
                sys.wait(100)
                goto continue
            end
            -- 检查功能开关
            if not app_data.get_config("buzzer_en") then
                gpio.set(BUZZER_PIN, 0)
                sys.wait(1000)
                goto continue
            end

            local buzzer_data = app_data.get().io.buzzer
            local key_data = app_data.get().io.key
            local pattern = buzzer_data.pattern or "off"

            -- 按键提示音检测（仅在非报警模式下生效）
            if pattern == "off" then
                if key_data.timestamp ~= 0 and key_data.timestamp ~= last_key_ts then
                    last_key_ts = key_data.timestamp
                    beep_remaining = KEY_BEEP_MS
                end
            else
                -- 报警模式下重置，避免解除后补响
                last_key_ts = key_data.timestamp
            end

            -- 执行模式
            if pattern == "continuous" then
                -- 连续鸣响
                gpio.set(BUZZER_PIN, 1)
                beep_remaining = 0
            elseif pattern == "intermittent" then
                -- 间歇鸣响
                intermittent_timer = intermittent_timer + TICK_MS
                if intermittent_timer >= INTERMITTENT_PERIOD then
                    intermittent_phase = not intermittent_phase
                    intermittent_timer = 0
                end
                gpio.set(BUZZER_PIN, intermittent_phase and 1 or 0)
                beep_remaining = 0
            else
                -- pattern == "off"
                if beep_remaining > 0 then
                    gpio.set(BUZZER_PIN, 1)
                    beep_remaining = beep_remaining - TICK_MS
                    if beep_remaining <= 0 then
                        beep_remaining = 0
                    end
                else
                    gpio.set(BUZZER_PIN, 0)
                end
            end

            sys.wait(TICK_MS)
            ::continue::
        end
    end)

    log.info("BUZZER", "蜂鸣器驱动协程已启动")
end

-- ========== 注册回调（星型架构：供 mod_screen 调用） ==========
app_data.register_callback("buzzer_api", {
    beep       = mod_buzzer.beep,
    on         = mod_buzzer.on,
    off        = mod_buzzer.off,
    toggle_test = mod_buzzer.toggle_test,
})

return mod_buzzer
