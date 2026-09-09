--[[
@module  mod_wdt
@summary 看门狗模块 — 防止系统死机，异常时自动重启
@version 1.1
@date    2026.06.29
@usage
本模块实现硬件看门狗功能：
1. 硬件看门狗由 Air8000 底层固件自动启用，超时时间约 20 秒
2. 本模块定期喂狗（每 3 秒一次），防止系统重启
3. 如果系统异常导致无法喂狗，看门狗超时后自动重启模块

参考官方 demo：LuatOS-master/module/Air8000/demo/wdt/internal_wdt.lua

在 main.lua 中调用：
  local mod_wdt = require "mod_wdt"
  mod_wdt.init()
  mod_wdt.start()
]]

local mod_wdt = {}

-- ========== 模块参数 ==========
local FEED_INTERVAL = 3000    -- 喂狗间隔（毫秒），必须小于看门狗超时时间（约20秒）

-- 模块内部状态
local wdt_initialized = false
local feed_timer_id   = nil

--[[
初始化看门狗
Air8000 的硬件看门狗由底层固件自动启用，超时时间约 20 秒
不需要调用 wdt.init()，只需要定期 wdt.feed() 喂狗
]]
function mod_wdt.init()
    -- 检查 wdt 库是否存在
    if wdt == nil then
        log.error("WDT", "wdt库不存在，看门狗功能不可用")
        return
    end

    -- 检查开机原因
    local reason1, reason2, reason3 = pm.lastReson()
    log.info("WDT", "硬件看门狗已由底层固件自动启用, 超时约20秒")
    log.info("WDT", "上次重启原因:", reason1, reason2, reason3)
    -- reason3=8 表示看门狗触发重启

    wdt_initialized = true
end

--[[
喂狗函数
调用 wdt.feed() 重置看门狗计数器
]]
local function feed_dog()
    if wdt_initialized then
        local success = wdt.feed()
        if not success then
            log.warn("WDT", "喂狗失败")
        end
    end
end

--[[
启动定时喂狗
使用 sys.timerLoopStart 定期喂狗
]]
function mod_wdt.start()
    if not wdt_initialized then
        log.error("WDT", "看门狗未初始化，请先调用 mod_wdt.init()")
        return
    end

    -- 启动定时喂狗
    feed_timer_id = sys.timerLoopStart(feed_dog, FEED_INTERVAL)
    log.info("WDT", "定时喂狗已启动, 间隔:", FEED_INTERVAL, "ms")

end

--[[
停止喂狗（慎用！停止后看门狗会超时重启）
仅在需要故意触发重启时使用
]]
function mod_wdt.stop()
    if feed_timer_id then
        sys.timerStop(feed_timer_id)
        feed_timer_id = nil
        log.warn("WDT", "定时喂狗已停止，系统将在约20秒后重启")
    end
end

return mod_wdt
