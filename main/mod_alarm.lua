--[[
@module  mod_alarm
@brief   报警管理器 — 监控报警等级变化，联动蜂鸣器/LED
@version 1.0
@date    2026.07.03
@usage
本模块是报警联动核心：
1. 每 200ms 轮询 app_data.alarm.level，检测等级变化
2. 报警等级 ≥2 时驱动蜂鸣器：
   - 等级 3 (严重)：连续鸣响 + LED 快闪
   - 等级 2 (警告)：间歇鸣响 + LED 慢闪
   - 等级 0 (正常)：停止蜂鸣器 + LED 灭
3. 报警等级变化时记录日志（可选写入 Flash）
4. 通过 app_data.io.led / app_data.io.buzzer 设置外设状态
5. 不直接操作 GPIO，通过 app_data 间接控制 mod_led / mod_buzzer

注意: 传感器模块（mod_pid/mod_ims/mod_gsensor）各自调用
      app_data.update_alarm() / clear_alarm() 维护报警来源，
      app_data 内部自动计算综合等级。
      本模块只负责监控等级变化并联动外设。

在 main.lua 中调用：
  local mod_alarm = require "mod_alarm"
  mod_alarm.init()
  mod_alarm.start()

🤖 整体或部分由 opencode 生成
]]

local mod_alarm = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"

-- ========== 参数 ==========
local POLL_INTERVAL   = 200       -- 轮询间隔 (ms)
local LOG_LEVEL_NAMES = { [0] = "正常", [2] = "警告", [3] = "严重" }

-- ========== 模块状态 ==========
local initialized   = false
local last_level    = 0           -- 上次报警等级（用于变化检测）

-- ========== 内部函数 ==========

-- 根据报警等级设置外设联动状态
local function apply_alarm_action(level)
    if level >= 3 then
        -- 严重：蜂鸣器连续鸣响 + LED 快闪
        app_data.update_io("buzzer", { pattern = "continuous" })
        app_data.update_io("led", { alarm = "blink_fast" })
    elseif level >= 2 then
        -- 警告：蜂鸣器间歇鸣响 + LED 慢闪
        app_data.update_io("buzzer", { pattern = "intermittent" })
        app_data.update_io("led", { alarm = "blink_slow" })
    else
        -- 正常：蜂鸣器停止 + LED 灭
        app_data.update_io("buzzer", { pattern = "off" })
        app_data.update_io("led", { alarm = "off" })
    end
end

-- ========== 初始化 ==========
function mod_alarm.init()
    initialized = true
    last_level  = 0
    log.info("ALARM", "报警管理器加载完成")
end

-- ========== 启动 ==========
function mod_alarm.start()
    if not initialized then
        log.error("ALARM", "模块未初始化, 请先调用 mod_alarm.init()")
        return
    end

    sys.taskInit(function()
        while true do
            -- 检查功能开关
            if not app_data.get_config("alarm_en") then
                -- 开关关闭：确保外设恢复常态
                if last_level ~= 0 then
                    apply_alarm_action(0)
                    last_level = 0
                end
                sys.wait(POLL_INTERVAL)
                goto continue
            end

            local alarm = app_data.get().alarm
            local level = alarm.level or 0

            -- 检测等级变化
            if level ~= last_level then
                local source = alarm.source or "none"
                local sources_str = table.concat(alarm.sources or {}, ",")

                if level > 0 then
                    log.warn("ALARM", string.format(
                        "报警触发! 等级=%d(%s) 来源=%s 全部来源=[%s]",
                        level, LOG_LEVEL_NAMES[level] or "?",
                        source, sources_str))
                else
                    log.info("ALARM", string.format(
                        "报警解除, 恢复正常 (之前等级=%d(%s))",
                        last_level, LOG_LEVEL_NAMES[last_level] or "?"))
                end

                -- 联动外设
                apply_alarm_action(level)
                last_level = level
            end

            sys.wait(POLL_INTERVAL)

            ::continue::
        end
    end)

    if app_data.get_config("alarm_en") then
        log.info("ALARM", "报警管理器已启动, 轮询间隔:", POLL_INTERVAL, "ms")
    else
        log.info("ALARM", "报警管理器已加载（功能开关关闭，待启用）")
    end
end

-- ========== 手动触发报警检查 ==========
-- 外部可调用此函数立即检查报警状态（不等待轮询周期）
function mod_alarm.check()
    local alarm = app_data.get().alarm
    local level = alarm.level or 0
    if level ~= last_level then
        apply_alarm_action(level)
        last_level = level
    end
end

-- ========== 获取当前报警等级 ==========
function mod_alarm.get_level()
    return app_data.get().alarm.level or 0
end

return mod_alarm
