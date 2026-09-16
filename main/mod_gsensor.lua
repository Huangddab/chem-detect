--[[
@module  mod_gsensor
@brief   G-sensor 加速度采集 + 跌倒检测
@version 1.0
@date    2026.06.30
@usage
本模块使用 Air8000 板载 exvib 加速度传感器实现跌倒检测：
1. 通过 exmux 打开 I2C0 总线，exvib 以 8g 量程采集三轴加速度
2. 每 100ms 轮询读取 xyz 数据，计算合加速度
3. 跌倒检测状态机：正常 → 冲击检测 → 静止确认 + 角度判断 → 跌倒确认
4. 跌倒确认后 60 秒冷却期内保持 fall_detected=true
5. 连续读取失败 5 次自动重新初始化传感器
6. 数据通过 app_data.update_gsensor() 写入数据中心

参考官方 demo：LuatOS-master/module/Air8000/demo/gsensor/vibration/vibration.lua

在 main.lua 中调用：
  local mod_gsensor = require "mod_gsensor"
  mod_gsensor.init()
  mod_gsensor.start()

🤖 整体或部分由 opencode 生成
]]

local mod_gsensor = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"  -- 数据中心

-- ========== 加载扩展库 ==========
local exvib   -- 延迟加载，init 中赋值
local exmux   -- 延迟加载，init 中赋值

-- ========== 模块参数 ==========
local SAMPLE_INTERVAL   = 100      -- 采样间隔（毫秒），10Hz
local IMPACT_THRESHOLD  = 2.0      -- 冲击阈值（g），自由落体后的着陆冲击
local STILLNESS_LOW     = 0.4      -- 静止判定下限（g）
local STILLNESS_HIGH    = 1.6      -- 静止判定上限（g）
local STILLNESS_DURATION = 2000    -- 静止持续时长（毫秒）
local IMPACT_TIMEOUT    = 3000     -- 冲击后等待静止的超时（毫秒）
local ANGLE_THRESHOLD   = 45       -- 角度变化阈值（度），站立→倒地的方向变化
local FALL_COOLDOWN     = 10000    -- 跌倒冷却时间（毫秒）
local STABLE_LOW        = 0.9      -- 稳定状态合加速度下限（g）
local STABLE_HIGH       = 1.1      -- 稳定状态合加速度上限（g）
local MAX_FAIL_COUNT    = 5        -- 连续读取失败上限，超过后重新初始化

-- ========== 状态机定义 ==========
local STATE_NORMAL   = 0           -- 正常监测
local STATE_IMPACT   = 1           -- 检测到冲击，等待静止确认
local STATE_COOLDOWN = 2           -- 跌倒已确认，冷却中

-- ========== 硬件配置 ==========
local INT_PIN       = gpio.WAKEUP2 -- 传感器中断引脚（开发板固定 WAKEUP2）
local HARDWARE_ENV  = "DEV_BOARD_8000_V2.0"

-- ========== 模块内部状态 ==========
local initialized     = false
local hw_initialized  = false      -- 硬件是否已初始化
local fail_count      = 0          -- 连续读取失败计数
local state           = STATE_NORMAL
local stable_gravity  = {x = 0, y = 0, z = 1}  -- 最后稳定重力方向
local pre_impact      = {x = 0, y = 0, z = 1}  -- 冲击前重力方向
local stillness_start = 0          -- 静止开始时间戳（ms）
local impact_time     = 0          -- 冲击发生时间戳（ms）
local cooldown_start  = 0          -- 冷却开始时间戳（ms）

-- ========== 辅助函数 ==========

-- 计算合加速度
local function calc_magnitude(x, y, z)
    return math.sqrt(x * x + y * y + z * z)
end

-- 计算两个三维向量之间的夹角（度）
local function calc_angle(v1, v2)
    local dot = v1.x * v2.x + v1.y * v2.y + v1.z * v2.z
    local m1  = math.sqrt(v1.x * v1.x + v1.y * v1.y + v1.z * v1.z)
    local m2  = math.sqrt(v2.x * v2.x + v2.y * v2.y + v2.z * v2.z)
    if m1 == 0 or m2 == 0 then return 0 end
    local cos_val = dot / (m1 * m2)
    -- 钳制到 [-1, 1]，避免浮点误差导致 acos 域错误
    if cos_val > 1 then cos_val = 1 end
    if cos_val < -1 then cos_val = -1 end
    return math.deg(math.acos(cos_val))
end

-- 初始化传感器硬件（必须在协程内调用，因为 exmux.open 内部有 sys.wait）
local function init_sensor_hw()
    exmux.setup(HARDWARE_ENV)
    exmux.open("i2c0")
    exvib.open(3)  -- 8g 量程（跌倒检测推荐）
    gpio.debounce(INT_PIN, 100)
end

-- 关闭传感器硬件（必须在协程内调用）
local function close_sensor_hw()
    pcall(function() gpio.close(INT_PIN) end)
    pcall(function() exvib.close() end)
    sys.wait(100)
    pcall(function() exmux.close("i2c0") end)
    hw_initialized = false
end

-- 重新初始化传感器（I2C 通信异常恢复，必须在协程内调用）
local function reinit_sensor()
    close_sensor_hw()
    sys.wait(200)
    init_sensor_hw()
end

-- ========== 跌倒检测状态机 ==========
-- 处理一次采样数据，返回是否检测到跌倒

local function process_sample(x, y, z, mag)
    local fall = false
    local now = mcu.ticks()

    if state == STATE_NORMAL then
        -- 记录稳定状态下的重力方向（用于冲击后角度对比）
        if mag > STABLE_LOW and mag < STABLE_HIGH then
            stable_gravity.x = x
            stable_gravity.y = y
            stable_gravity.z = z
        end
        -- 已有高级别报警时跳过冲击检测（避免蜂鸣器/LED 振动误触发）
        local alarm_level = app_data.get().alarm.level or 0
        if alarm_level >= 2 then
            return false
        end
        -- 检测冲击：合加速度超过阈值
        if mag > IMPACT_THRESHOLD then
            state = STATE_IMPACT
            pre_impact.x = stable_gravity.x
            pre_impact.y = stable_gravity.y
            pre_impact.z = stable_gravity.z
            stillness_start = 0
            impact_time = now
            log.warn("VIB", string.format(
                ">>> 冲击! mag=%.2fg (阈值%.1f) 冲击前方向: %.2f,%.2f,%.2f",
                mag, IMPACT_THRESHOLD,
                pre_impact.x, pre_impact.y, pre_impact.z
            ))
        end

    elseif state == STATE_IMPACT then
        local elapsed = now - impact_time
        -- 等待静止：合加速度回到 ~1g 范围
        if mag > STILLNESS_LOW and mag < STILLNESS_HIGH then
            if stillness_start == 0 then
                stillness_start = now
                -- log.info("VIB", string.format(
                --     "进入静止范围 mag=%.2f (%.1f~%.1f), 开始计时",
                --     mag, STILLNESS_LOW, STILLNESS_HIGH
                -- ))
            end
            local still_elapsed = now - stillness_start
            -- 静止持续达标 → 检查角度变化
            if still_elapsed >= STILLNESS_DURATION then
                local cur_vec = {x = x, y = y, z = z}
                local angle = calc_angle(pre_impact, cur_vec)
                -- log.info("VIB", string.format(
                --     "静止达标 %dms (需%dms) 当前: %.2f,%.2f,%.2f 角度变化: %.1f° (阈值%d°)",
                --     still_elapsed, STILLNESS_DURATION,
                --     x, y, z, angle, ANGLE_THRESHOLD
                -- ))
                if angle > ANGLE_THRESHOLD then
                    fall = true
                    state = STATE_COOLDOWN
                    cooldown_start = now
                    log.warn("VIB", "跌倒确认! 进入冷却")

                else
                    state = STATE_NORMAL
                    log.info("VIB", string.format(
                        "判定结果: 误判(角度不足) %.1f° < %d°, 恢复正常",
                        angle, ANGLE_THRESHOLD
                    ))
                end
            end
        else
            -- 不在静止范围，重置静止计时
            if stillness_start ~= 0 then
                -- log.info("VIB", string.format(
                --     "脱离静止范围 mag=%.2f, 重置静止计时",
                --     mag
                -- ))
                stillness_start = 0
            end
            -- 冲击后超时仍未静止 → 误判
            if elapsed > IMPACT_TIMEOUT then
                state = STATE_NORMAL
                log.info("VIB", string.format(
                    "判定结果: 误判(超时未静止) %dms > %dms, 恢复正常",
                    elapsed, IMPACT_TIMEOUT
                ))
            end
        end

    elseif state == STATE_COOLDOWN then
        -- 冷却期内保持跌倒状态
        fall = true
        local cd_elapsed = now - cooldown_start
        if cd_elapsed >= FALL_COOLDOWN then
            state = STATE_NORMAL
            log.info("VIB", "跌倒冷却结束, 恢复检测")
        end
    end

    return fall
end

-- ========== 初始化 ==========
-- 仅加载扩展库，硬件初始化推迟到 start() 协程中（exmux.open 内部有 sys.wait）
function mod_gsensor.init()
    local ok1, m1 = pcall(require, "exvib")
    local ok2, m2 = pcall(require, "exmux")
    if not ok1 or not ok2 then
        log.error("VIB", "exvib/exmux 库加载失败")
        return
    end
    exvib = m1
    exmux = m2

    initialized = true
    log.info("VIB", "G-sensor 库加载完成")
end

-- ========== 启动 ==========
function mod_gsensor.start()
    if not initialized then
        log.error("VIB", "G-sensor 未初始化, 请先调用 mod_gsensor.init()")
        return
    end

    sys.taskInit(function()
        while true do
            -- 检查功能开关
            if not app_data.get_config("gsensor_en") then
                -- 开关关闭：关闭硬件，重置状态机，等待重新开启
                if hw_initialized then
                    close_sensor_hw()
                    state = STATE_NORMAL
                    app_data.update_gsensor(0, 0, 0, 0, false)
                    log.info("VIB", "G-sensor 硬件已关闭")
                end
                sys.wait(1000)
                goto continue
            end

            -- 开关开启：确保硬件已初始化
            if not hw_initialized then
                init_sensor_hw()
                hw_initialized = true
                log.info("VIB", "G-sensor 硬件初始化完成, 量程: 8g, 采样间隔:", SAMPLE_INTERVAL, "ms")
            end

            sys.wait(SAMPLE_INTERVAL)

            -- 读取三轴加速度
            local x, y, z = exvib.read_xyz()
            if not x then
                fail_count = fail_count + 1
                -- log.warn("VIB", "读取失败, 连续:", fail_count)
                if fail_count >= MAX_FAIL_COUNT then
                    fail_count = 0
                    reinit_sensor()
                end
                goto continue
            end
            fail_count = 0

            -- 计算合加速度并运行状态机
            local mag  = calc_magnitude(x, y, z)
            local fall = process_sample(x, y, z, mag)

            -- 写入数据中心
            app_data.update_gsensor(x, y, z, mag, fall)

            -- 判定结果日志（跌倒时告警，正常时静默）
            -- if fall then
            --     log.warn("VIB", string.format(
            --         "判定结果: 跌倒 | x=%.2f y=%.2f z=%.2f mag=%.2f state=%d",
            --         x, y, z, mag, state
            --     ))
            -- end

            ::continue::
        end
    end)

    if app_data.get_config("gsensor_en") then
        log.info("VIB", "G-sensor 跌倒检测已启动")
    else
        log.info("VIB", "G-sensor 模块已加载（开关关闭，待启用）")
    end
end

return mod_gsensor
