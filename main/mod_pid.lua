--[[
@module  mod_pid
@brief   PID 光离子化传感器采集
@version 1.1
@date    2026.08.10
@usage
本模块通过 ADC0 采集 PID 传感器信号：
1. 每秒读取一次 ADC 原始值 (0-4095)
2. 转换为电压: V = raw × 3.3 / 4095
3. 转换为浓度: ppm = (V - 0.045) / (2.5 - 0.045) × 量程
4. 浓度 > 50.0 ppm 时触发报警标志
5. 报警时通过 app_data.update_alarm("pid") 通知
6. 报警解除时通过 app_data.clear_alarm("pid") 通知
7. 数据通过 app_data.update_sensor("pid", {...}) 写入数据中心

在 main.lua 中调用：
  local mod_pid = require "mod_pid"
  mod_pid.init()
  mod_pid.start()

🤖 整体或部分由 opencode 生成
]]

local mod_pid = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 硬件参数 ==========
local ADC_CHANNEL    = 0           -- LuatOS ADC 通道 0 (ADC0, pin 75)
local ADC_VREF       = 3.3         -- 参考电压 (V) — ADC0 标准量程 3.3V
local ADC_MAX        = 4095        -- 12-bit 分辨率

-- ========== 转换参数 ==========
-- PID 输出电压范围: 0.045V ~ 2.5V (参考 4S PID 文档)
-- 浓度转换: ppm = (V - 0.045) / (2.5 - 0.045) × 量程
local PID_V_MIN      = 0.045       -- PID 输出最小电压 (V), 对应 0 ppm
local PID_V_MAX      = 2.5         -- PID 输出最大电压 (V), 对应满量程
local PID_RANGE      = 100         -- PID 满量程 (ppm), 根据传感器规格调整
local PID_ALARM_TH   = 50.0        -- 报警阈值 (ppm)

-- ========== 采样参数 ==========
local SAMPLE_INTERVAL = 1000       -- 采样间隔 (ms)

-- ========== 模块状态 ==========
local initialized    = false
local hw_initialized = false
local alarm_active   = false       -- 当前是否处于报警状态

-- ========== 辅助函数 ==========

-- ADC 原始值 → 电压
local function raw_to_voltage(raw)
    return raw * ADC_VREF / ADC_MAX
end

-- 电压 → 浓度 (线性映射: 0.045V=0ppm, 2.5V=满量程)
local function voltage_to_ppm(voltage)
    if voltage <= PID_V_MIN then return 0 end
    if voltage >= PID_V_MAX then return PID_RANGE end
    local ppm = (voltage - PID_V_MIN) / (PID_V_MAX - PID_V_MIN) * PID_RANGE
    return math.floor(ppm * 10 + 0.5) / 10  -- 保留1位小数
end

-- ========== 初始化 ==========
function mod_pid.init()
    initialized = true
    log.info("PID", "PID 传感器模块加载完成")
end

-- ========== 启动 ==========
function mod_pid.start()
    if not initialized then
        log.error("PID", "模块未初始化, 请先调用 mod_pid.init()")
        return
    end

    sys.taskInit(function()
        while true do
            -- 检查功能开关
            if not app_data.get_config("sensor_pid_en") then
                if hw_initialized then
                    pcall(adc.close, ADC_CHANNEL)
                    hw_initialized = false
                    -- 报警解除
                    if alarm_active then
                        alarm_active = false
                        app_data.clear_alarm("pid")
                    end
                    app_data.update_sensor("pid", {
                        conc = 0, raw_adc = 0, voltage = 0, alarm = false
                    })
                    log.info("PID", "ADC 已关闭")
                end
                sys.wait(1000)
                goto continue
            end

            -- 确保硬件已初始化
            if not hw_initialized then
                adc.open(ADC_CHANNEL)
                hw_initialized = true
                log.info("PID", "ADC0 已打开, 采样间隔:", SAMPLE_INTERVAL, "ms")
            end

            sys.wait(SAMPLE_INTERVAL)

            -- 读取 ADC
            local raw, vol_mv = adc.read(ADC_CHANNEL)
            if not raw or raw < 0 then
                log.warn("PID", "ADC 读取失败")
                goto continue
            end

            local voltage = raw_to_voltage(raw)
            local conc    = voltage_to_ppm(voltage)
            local alarm   = conc > PID_ALARM_TH

            -- 报警状态变化时通知 app_data
            if alarm and not alarm_active then
                alarm_active = true
                app_data.update_alarm("pid")
                log.warn("PID", string.format(
                    "报警触发! conc=%.1f ppm > %.1f ppm", conc, PID_ALARM_TH))
            elseif not alarm and alarm_active then
                alarm_active = false
                app_data.clear_alarm("pid")
                log.info("PID", string.format(
                    "报警解除, conc=%.1f ppm", conc))
            end

            -- 写入数据中心
            app_data.update_sensor("pid", {
                conc    = conc,
                raw_adc = raw,
                voltage = voltage,
                alarm   = alarm,
            })

            ::continue::
        end
    end)

    if app_data.get_config("sensor_pid_en") then
        log.info("PID", "PID 传感器已启动")
    else
        log.info("PID", "PID 模块已加载（开关关闭，待启用）")
    end
end

-- ========== 手动读取一次 ==========
-- @return conc, raw_adc, voltage, alarm
function mod_pid.read()
    if not hw_initialized then
        adc.open(ADC_CHANNEL)
        hw_initialized = true
    end
    local raw, _ = adc.read(ADC_CHANNEL)
    if not raw or raw < 0 then
        return 0, 0, 0, false
    end
    local voltage = raw_to_voltage(raw)
    local conc    = voltage_to_ppm(voltage)
    local alarm   = conc > PID_ALARM_TH
    return conc, raw, voltage, alarm
end

return mod_pid
