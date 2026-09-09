--[[
@module  mod_key
@brief   按键输入 ×3（左/右/确认）+ 消抖 + 长按检测
@version 1.1
@date    2026.07.30
@usage
本模块管理 3 个按键：
1. KEY_L（GPIO153, pin 52）：左键
2. KEY_R（GPIO147, pin 53）：右键
3. KEY_EN（GPIO146, pin 54）：确认键，长按 3 秒触发特殊事件

按键采用轮询方式（20ms 间隔），内部上拉，低电平有效：
- 消抖：连续 3 次读取一致（60ms）确认状态变化
- 短按：按下时触发 "press" 事件
- 长按：按住 3 秒触发 "long_press" 事件（仍按住时触发）
- 释放：触发 "release" 事件

按键事件写入 app_data.io.key，其他模块通过 app_data 读取。
蜂鸣器自动响应按键事件（通过 app_data 联动，无需直接调用 mod_buzzer）。

在 main.lua 中调用：
  local mod_key = require "mod_key"
  mod_key.init()
  mod_key.start()

🤖 整体或部分由 opencode 生成
]]

local mod_key = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 硬件引脚定义 ==========
-- WGPIO 引脚编号映射（LuatOS 使用简化编号）
-- GPIO153 = WGPIO 0, GPIO147 = WGPIO 1, GPIO146 = WGPIO 2
local KEY_PINS = {
    {name = "key_l", pin = 153}, -- GPIO153, pin 52, KEY_L 左键 (WGPIO)
    {name = "key_r", pin = 147}, -- GPIO147, pin 53, KEY_R 右键 (WGPIO)
    {name = "key_en", pin = 146}, -- GPIO146, pin 54, KEY_EN 确认键 (WGPIO)
}

-- ========== 参数 ==========
local POLL_MS       = 20    -- 轮询间隔
local DEBOUNCE_READ = 3     -- 消抖读取次数（3 × 20ms = 60ms）
local LONG_PRESS_MS = 3000  -- 长按阈值

-- ========== 模块内部状态 ==========
local initialized = false

-- ========== 初始化 ==========
function mod_key.init()
    for _, key in ipairs(KEY_PINS) do
        pcall(function() gpio.close(key.pin) end)
        -- 输入模式，内部上拉
        gpio.setup(key.pin, nil, gpio.PULLUP)
    end
    initialized = true
    log.info("KEY", "按键模块初始化完成 (key_l=GPIO153/pin52, key_r=GPIO147/pin53, key_en=GPIO146/pin54)")
end

-- ========== 启动按键轮询协程 ==========
function mod_key.start()
    if not initialized then
        log.error("KEY", "按键未初始化, 请先调用 mod_key.init()")
        return
    end

    sys.taskInit(function()
        -- 每个键的状态
        local key_state = {}          -- 当前确认状态（true=按下）
        local key_debounce = {}       -- 消抖计数器
        local key_debounce_val = {}   -- 消抖期间的读取值
        local key_press_time = {}     -- 按下时间戳（ms）
        local long_press_fired = {}   -- 长按是否已触发

        for i = 1, #KEY_PINS do
            key_state[i] = false
            key_debounce[i] = 0
            key_debounce_val[i] = false
            key_press_time[i] = 0
            long_press_fired[i] = false
        end

        while true do
            -- 检查功能开关
            if not app_data.get_config("key_en") then
                sys.wait(1000)
                goto continue
            end

            for i, key in ipairs(KEY_PINS) do
                -- 读取 GPIO（低电平 = 按下）
                local raw = gpio.get(key.pin)
                local pressed = (raw == 0)

                -- 消抖逻辑
                if pressed ~= key_state[i] then
                    -- 状态与当前确认值不同，开始/继续消抖
                    if pressed == key_debounce_val[i] then
                        key_debounce[i] = key_debounce[i] + 1
                    else
                        key_debounce_val[i] = pressed
                        key_debounce[i] = 1
                    end

                    -- 消抖通过，确认状态变化
                    if key_debounce[i] >= DEBOUNCE_READ then
                        key_state[i] = pressed
                        key_debounce[i] = 0

                        if pressed then
                            -- 按下事件
                            key_press_time[i] = mcu.ticks()
                            long_press_fired[i] = false
                            app_data.update_io("key", {
                                last_key  = key.name,
                                key_event = "press",
                                timestamp = os.time(),
                            })
                            log.info("KEY", key.name, "press")
                        else
                            -- 释放事件
                            app_data.update_io("key", {
                                last_key  = key.name,
                                key_event = "release",
                                timestamp = os.time(),
                            })
                            log.info("KEY", key.name, "release")
                        end
                    end
                else
                    -- 状态一致，重置消抖
                    key_debounce[i] = 0
                end

                -- 长按检测（按键保持按下状态）
                if key_state[i] and not long_press_fired[i] then
                    local duration = mcu.ticks() - key_press_time[i]
                    if duration >= LONG_PRESS_MS then
                        long_press_fired[i] = true
                        app_data.update_io("key", {
                            last_key  = key.name,
                            key_event = "long_press",
                            timestamp = os.time(),
                        })
                        log.info("KEY", key.name, "long_press")
                    end
                end
            end

            sys.wait(POLL_MS)
            ::continue::
        end
    end)

    log.info("KEY", "按键轮询协程已启动")
end

-- ========== 手动读取按键状态 ==========
-- @return table { key_l=false/true, key_r=false/true, key_en=false/true }
function mod_key.read()
    local state = {}
    for _, key in ipairs(KEY_PINS) do
        local raw = gpio.get(key.pin)
        state[key.name] = (raw == 0)  -- 低电平 = 按下
    end
    return state
end

return mod_key
