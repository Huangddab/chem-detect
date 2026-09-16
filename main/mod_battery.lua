--[[
@module  mod_battery
@brief   电池电压监控
@version 1.1
@date    2026.08.10
@usage
本模块通过 ADC2 监控电池电压：
1. 每 5 秒采样一次, 每次连续读 5 次去极值平均
2. EMA 指数移动平均滤波, 消除电压跳变
3. 转换为电压: V = raw × VREF / 4095 × 分压比
4. 分压比 6.1 (5.1MΩ + 1MΩ), VREF=6.21V (Air8000 ADC2)
5. 估算电池电量百分比 (0-100%)
6. 电量 < 20% 时触发低电量告警
7. 数据通过 app_data.update_sensor("battery", {...}) 写入数据中心

在 main.lua 中调用：
  local mod_battery = require "mod_battery"
  mod_battery.init()
  mod_battery.start()

🤖 整体或部分由 opencode 生成
]]

local mod_battery = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 硬件参数 ==========
local ADC_CHANNEL    = 2           -- LuatOS ADC 通道 2 (ADC2, pin 42)
local ADC_VREF       = 6.21        -- 参考电压 (V) — Air8000 ADC2 量程约 6.21V, 非标准 3.3V
local ADC_MAX        = 4095        -- 12-bit 分辨率

-- ========== 分压参数 ==========
-- 分压电阻: 上臂 5.1MΩ + 下臂 1MΩ
-- 分压比 = (5.1 + 1) / 1 = 6.1
-- 满电 8.4V → ADC ≈ 1.38V (在 1.5V 安全范围内)
local DIVIDER_RATIO  = 6.1         -- 分压比 (实际电压 = ADC电压 × 分压比)
-- 校准系数: 5.1MΩ 高阻抗分压会导致 ADC 读数偏低
-- 实测 6.8V 显示 6.2V → 校准系数 = 6.8 / 6.2 ≈ 1.10
-- 用万用表量实际电压 ÷ 屏幕显示电压 = 校准系数
local CAL_FACTOR     = 1.14        -- 校准系数 (1.0=不校准)

-- ========== 电池参数 (2S 锂电池) ==========
local BAT_FULL       = 8.4         -- 满电电压 (V) (单节4.2V × 2)
local BAT_EMPTY      = 6.4         -- 放电截止电压 (V) (单节3.0V × 2)
local BAT_LOW_TH     = 20          -- 低电量告警阈值 (%)

-- ========== 采样参数 ==========
local SAMPLE_INTERVAL = 5000       -- 采样间隔 (ms)，电池电压变化慢
local SAMPLE_COUNT    = 8          -- 每次连续采样次数（去极值后取平均）
local SAMPLE_DELAY    = 20         -- 单次采样间隔 (ms) — 高阻抗分压需更长充电时间
local EMA_ALPHA       = 0.35       -- EMA 平滑系数 (越大响应越快, 0.35 约 3 次收敛)
local PCT_STEP        = 5          -- 电量百分比量化步长 (避免 1~2% 跳变)

-- ========== 模块状态 ==========
local initialized    = false
local hw_initialized = false
local low_alarm      = false       -- 低电量告警状态
local voltage_ema    = nil         -- EMA 滤波后的电压 (首次采样后初始化)
local reading        = false       -- read() 读取锁, 阻止后台协程关闭 ADC 和双重采样

-- ========== 辅助函数 ==========

-- 多次采样去极值平均 (消除瞬时噪声)
-- @return 平均 raw 值, 或 nil(失败)
local function read_adc_filtered()
    local samples = {}
    for _ = 1, SAMPLE_COUNT do
        local raw, _ = adc.read(ADC_CHANNEL)
        if raw and raw >= 0 then
            samples[#samples + 1] = raw
        end
        sys.wait(SAMPLE_DELAY)
    end
    if #samples < 3 then return nil end
    -- 排序, 去掉最大值和最小值, 取中间平均
    table.sort(samples)
    local sum = 0
    for i = 2, #samples - 1 do
        sum = sum + samples[i]
    end
    return sum / (#samples - 2)
end

-- ADC 原始值 → 电池电压
local function raw_to_voltage(raw)
    local adc_vol = raw * ADC_VREF / ADC_MAX
    return adc_vol * DIVIDER_RATIO * CAL_FACTOR
end

-- 电池电压 → 电量百分比 (量化到 PCT_STEP 步长, 避免跳变)
local function voltage_to_pct(voltage)
    if voltage >= BAT_FULL then return 100 end
    if voltage <= BAT_EMPTY then return 0 end
    local pct = (voltage - BAT_EMPTY) / (BAT_FULL - BAT_EMPTY) * 100
    pct = math.floor(pct + 0.5)
    -- 量化到 PCT_STEP 的倍数 (如 30, 35, 40...)
    pct = math.floor(pct / PCT_STEP) * PCT_STEP
    return pct
end

-- ========== 初始化 ==========
function mod_battery.init()
    initialized = true
    log.info("BAT", "电池监控模块加载完成")
end

-- ========== 启动 ==========
function mod_battery.start()
    if not initialized then
        log.error("BAT", "模块未初始化, 请先调用 mod_battery.init()")
        return
    end

    sys.taskInit(function()
        while true do
            -- 检查功能开关
            if not app_data.get_config("sensor_battery_en") then
                if hw_initialized then
                    pcall(adc.close, ADC_CHANNEL)
                    hw_initialized = false
                    app_data.update_sensor("battery", {
                        voltage = 0, pct = 0
                    })
                    log.info("BAT", "ADC 已关闭")
                end
                sys.wait(1000)
                goto continue
            end

            -- 确保硬件已初始化
            if not hw_initialized then
                adc.open(ADC_CHANNEL)
                hw_initialized = true
                log.info("BAT", "ADC2 已打开, 采样间隔:", SAMPLE_INTERVAL, "ms")
            end

            sys.wait(SAMPLE_INTERVAL)

            -- read() 正在读取时跳过本次后台采样, 避免双重更新 EMA
            if reading then goto continue end

            -- 多次采样去极值平均
            local raw = read_adc_filtered()
            if not raw then
                log.warn("BAT", "ADC 采样失败 (有效样本不足)")
                goto continue
            end

            local voltage_new = raw_to_voltage(raw)

            -- EMA 平滑滤波: voltage = α × 新值 + (1-α) × 历史值
            if not voltage_ema then
                voltage_ema = voltage_new              -- 首次采样直接使用
            else
                voltage_ema = EMA_ALPHA * voltage_new + (1 - EMA_ALPHA) * voltage_ema
            end

            local voltage = voltage_ema
            local pct     = voltage_to_pct(voltage)

            -- 低电量告警状态变化
            if pct < BAT_LOW_TH and not low_alarm then
                low_alarm = true
                log.warn("BAT", string.format(
                    "低电量告警! pct=%d%% < %d%%, voltage=%.2fV", pct, BAT_LOW_TH, voltage))
            elseif pct >= BAT_LOW_TH and low_alarm then
                low_alarm = false
                log.info("BAT", string.format(
                    "电量恢复, pct=%d%%", pct))
            end

            -- 写入数据中心
            app_data.update_sensor("battery", {
                voltage = voltage,
                pct     = pct,
            })

            ::continue::
        end
    end)

    if app_data.get_config("sensor_battery_en") then
        log.info("BAT", "电池监控已启动")
    else
        log.info("BAT", "电池模块已加载（开关关闭，待启用）")
    end
end

-- ========== 手动读取一次 ==========
-- @return voltage, pct (已滤波)
function mod_battery.read()
    reading = true  -- 加锁, 阻止后台协程关闭 ADC 和双重采样
    -- 确保 ADC 已打开
    if not hw_initialized then
        adc.open(ADC_CHANNEL)
        hw_initialized = true
    end
    local raw = read_adc_filtered()
    reading = false  -- 解锁
    if not raw then
        return 0, 0
    end
    local voltage_new = raw_to_voltage(raw)
    -- EMA 平滑
    if not voltage_ema then
        voltage_ema = voltage_new
    else
        voltage_ema = EMA_ALPHA * voltage_new + (1 - EMA_ALPHA) * voltage_ema
    end
    local pct = voltage_to_pct(voltage_ema)
    return voltage_ema, pct
end

return mod_battery
