--[[
@module  mod_sensor
@brief   传感器管理器 — 统一调度 + 数据聚合 + 异常监控
@version 1.1
@date    2026.07.09
@usage
本模块是传感器层的调度协调器：
1. 初始化所有子传感器模块（PID/IMS/Battery）
2. 各子模块已有独立采集协程，本模块不重复采集
3. 每 2 秒聚合一次传感器数据状态，检测异常
4. 传感器连续 3 次无更新时记录警告日志
5. 提供 get_summary() 接口返回所有传感器数据快照
6. 不直接操作硬件，只通过 app_data 读取聚合数据

架构说明:
  各传感器模块（mod_pid 等）自行管理采集协程和数据写入。
  本模块只负责监控各传感器是否正常工作、数据是否过期。

在 main.lua 中调用：
  local mod_sensor = require "mod_sensor"
  mod_sensor.init()
  mod_sensor.start()

🤖 整体或部分由 opencode 生成
]]

local mod_sensor = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 参数 ==========
local MONITOR_INTERVAL  = 2000    -- 监控周期 (ms)
local STALE_THRESHOLD   = 10      -- 数据过期阈值（秒），超过则认为传感器异常
local FAIL_RETRY_LIMIT  = 3       -- 连续异常次数上限，超过后记录告警

-- ========== 子模块引用（延迟加载） ==========
local mod_pid
local mod_ims
local mod_battery

-- ========== 模块状态 ==========
local initialized = false

-- 每个传感器的异常计数
local fail_counts = {
    pid     = 0,
    ims     = 0,
    battery = 0,
}

-- ========== 辅助函数 ==========

-- 检查单个传感器数据是否过期
-- @param sub 传感器子表名
-- @return bool 是否正常（true=正常, false=过期）
local function check_sensor_fresh(sub)
    local sensor = app_data.get().sensor
    if not sensor[sub] then return false end
    local ts = sensor[sub].timestamp or 0
    if ts == 0 then return false end
    local age = os.time() - ts
    return age <= STALE_THRESHOLD
end

-- 传感器开关映射
local SENSOR_SWITCHES = {
    pid     = "sensor_pid_en",
    ims     = "sensor_ims_en",
    battery = "sensor_battery_en",
}

-- 监控所有传感器数据新鲜度（仅监控已启用的传感器）
local function monitor_sensors()
    for sub, switch_key in pairs(SENSOR_SWITCHES) do
        -- 跳过未启用的传感器
        if not app_data.get_config(switch_key) then
            fail_counts[sub] = 0
            goto continue
        end
        local fresh = check_sensor_fresh(sub)
        if fresh then
            fail_counts[sub] = 0
        else
            fail_counts[sub] = fail_counts[sub] + 1
            if fail_counts[sub] == FAIL_RETRY_LIMIT then
                log.warn("SENSOR", string.format(
                    "传感器 %s 连续 %d 次无数据更新, 可能异常",
                    sub, FAIL_RETRY_LIMIT))
            end
        end
        ::continue::
    end
end

-- ========== 初始化 ==========
function mod_sensor.init()
    -- 延迟加载子模块（避免循环依赖）
    mod_pid     = require "mod_pid"
    mod_ims     = require "mod_ims"
    mod_battery = require "mod_battery"

    initialized = true
    log.info("SENSOR", "传感器管理器加载完成")
end

-- ========== 启动 ==========
function mod_sensor.start()
    if not initialized then
        log.error("SENSOR", "模块未初始化, 请先调用 mod_sensor.init()")
        return
    end

    -- 初始化所有子模块（init 只做软件加载，不操作硬件）
    mod_pid.init()
    mod_ims.init()
    mod_battery.init()

    -- 启动所有子模块的采集协程（协程内部会检查各自开关）
    mod_pid.start()
    mod_ims.start()
    mod_battery.start()

    -- 启动监控协程
    sys.taskInit(function()
        -- 等待子模块首次采集
        sys.wait(3000)

        while true do
            -- 检查功能开关
            if not app_data.get_config("sensor_report_en") then
                sys.wait(1000)
                goto continue
            end

            monitor_sensors()

            sys.wait(MONITOR_INTERVAL)
            ::continue::
        end
    end)

    log.info("SENSOR", "传感器管理器已启动, 监控间隔:", MONITOR_INTERVAL, "ms")
end

-- ========== 获取所有传感器数据快照 ==========
-- @return table 传感器数据汇总
function mod_sensor.get_summary()
    return app_data.get().sensor
end

-- ========== 获取传感器健康状态 ==========
-- @return table { pid=true/false, ims=..., battery=... }
function mod_sensor.get_health()
    local health = {}
    for sub, count in pairs(fail_counts) do
        health[sub] = count < FAIL_RETRY_LIMIT
    end
    return health
end

return mod_sensor
