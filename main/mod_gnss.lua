--[[
@module  mod_gnss
@brief   GNSS 卫星定位模块
@version 1.1
@date    2026.07.01
@usage
本模块使用 Air8000 板载 GNSS 实现卫星定位：
1. 配置 exgnss（开启 AGPS 辅助定位）
2. 订阅 GNSS_STATE 事件监控定位状态（FIXED/LOSE/CLOSE）
3. 定位成功后每 2 秒读取 RMC 数据（经纬度、速度）
4. 定位失败时自动重试，异常时重新初始化
5. 数据通过 app_data.update_gnss() 写入数据中心
6. gnss_en=false 时关闭定位，保留最后位置

参考官方 demo：LuatOS-master/module/Air8000/demo/gnss/exgnss/single/gnss.lua

在 main.lua 中调用：
  local mod_gnss = require "mod_gnss"
  mod_gnss.init()
  mod_gnss.start()

🤖 整体或部分由 opencode 生成
]]

local mod_gnss = {}

-- ========== 加载依赖 ==========
local app_data = require "app_data"  -- 数据中心
local exgnss  -- 延迟加载，init 中赋值

-- ========== 模块参数 ==========
local GNSS_READ_INTERVAL  = 2000     -- 定位成功后读取间隔（毫秒）
local GNSS_INIT_RETRY     = 5000     -- 初始化失败重试间隔（毫秒）
local GNSS_REOPEN_DELAY   = 10000    -- 异常后重新打开间隔（毫秒）
local GNSS_MAX_INIT_RETRY = 5        -- 连续初始化失败上限，超过后延长间隔
local GNSS_INIT_LONG_DELAY= 30000    -- 超过重试上限后的长间隔（毫秒）
local GNSS_AGPS_ENABLE    = true     -- 是否启用 AGPS 辅助定位
local GNSS_MODE           = 1        -- GNSS 模式: 1=全卫星(GPS+北斗), 2=单北斗
local GNSS_TAG            = "safex_gnss"  -- GNSS 应用标签

-- ========== 模块内部状态 ==========
local initialized   = false
local gnss_opened   = false          -- exgnss.open 是否已调用
local gnss_fixed    = false          -- 是否定位成功
local init_retry    = 0              -- 初始化重试计数
local wait_cnt      = 0              -- 等待定位计数（用于降低日志频率）

-- ========== GNSS 状态回调 ==========
-- 官方事件: "FIXED"=定位成功, "LOSE"=定位丢失, "CLOSE"=GNSS关闭
local function gnss_state_cb(event, ticks)
    if event == "FIXED" then
        gnss_fixed = true
        wait_cnt = 0
        log.info("GNSS", "定位成功")
    elseif event == "LOSE" then
        gnss_fixed = false
        wait_cnt = 0
        log.warn("GNSS", "定位丢失")
    elseif event == "CLOSE" then
        gnss_fixed = false
        gnss_opened = false
        wait_cnt = 0
        log.warn("GNSS", "GNSS 已关闭")
    end
end

-- ========== GNSS 定位回调 ==========
-- DEFAULT 模式下，定位成功时调用一次，参数只有 tag
local function gnss_data_cb(tag)
    log.info("GNSS", "定位回调触发, tag:", tag)
end

-- ========== 初始化 ==========
function mod_gnss.init()
    local ok, m = pcall(require, "exgnss")
    if not ok then
        log.error("GNSS", "exgnss 库加载失败:", tostring(m))
        return
    end
    exgnss = m

    initialized = true

    -- 订阅 GNSS 状态事件
    sys.subscribe("GNSS_STATE", gnss_state_cb)

    log.info("GNSS", "GNSS 模块加载完成, AGPS:", GNSS_AGPS_ENABLE and "启用" or "禁用")
end

-- ========== 启动 ==========
function mod_gnss.start()
    if not initialized then
        log.error("GNSS", "GNSS 未初始化, 请先调用 mod_gnss.init()")
        return
    end

    sys.taskInit(function()
        while true do
            -- 检查功能开关
            if not app_data.get_config("gnss_en") then
                -- 开关关闭：关闭 GNSS，保留最后定位数据
                if gnss_opened then
                    pcall(function() exgnss.close(exgnss.DEFAULT, {tag = GNSS_TAG}) end)
                    gnss_opened = false
                    gnss_fixed = false
                    log.info("GNSS", "GNSS 已关闭（功能开关关闭）")
                end
                sys.wait(1000)
                goto continue
            end

            -- 初始化 GNSS 硬件
            if not gnss_opened then
                -- 配置 GNSS 参数
                local setup_ok, setup_err = pcall(function()
                    exgnss.setup({
                        gnssmode    = GNSS_MODE,
                        agps_enable = GNSS_AGPS_ENABLE,
                    })
                end)

                if not setup_ok then
                    log.warn("GNSS", "exgnss.setup 异常:", tostring(setup_err), "尝试继续")
                end

                -- 开启定位（DEFAULT 模式：一直运行直到手动关闭）
                local open_ok, open_err = pcall(function()
                    exgnss.open(exgnss.DEFAULT, {
                        tag = GNSS_TAG,
                        cb  = gnss_data_cb,
                    })
                end)

                if not open_ok then
                    init_retry = init_retry + 1
                    local delay = init_retry >= GNSS_MAX_INIT_RETRY and GNSS_INIT_LONG_DELAY or GNSS_INIT_RETRY
                    log.error("GNSS", "GNSS 打开失败:", tostring(open_err), "重试:", init_retry, ", 等待", delay, "ms")
                    sys.wait(delay)
                    goto continue
                end

                gnss_opened = true
                init_retry = 0
                log.info("GNSS", "GNSS 已开启, 等待定位...")
            end

            -- 等待定位成功
            if not gnss_fixed then
                sys.wait(GNSS_READ_INTERVAL)
                wait_cnt = wait_cnt + 1
                if wait_cnt % 5 == 0 then  -- 每 10 秒打印一次（5 x 2s）
                    log.debug("GNSS", "等待定位中... (" .. (wait_cnt * 2) .. "s)")
                end
                goto continue
            end

            -- 定位成功：定时读取 RMC 数据
            -- rmc(2) 返回十进制经纬度，rmc(0) 返回原始 NMEA 格式
            local rmc = nil
            local rmc_ok, rmc_err = pcall(function()
                rmc = exgnss.rmc(2)
            end)
            if not rmc_ok then
                log.warn("GNSS", "exgnss.rmc 异常:", tostring(rmc_err))
                sys.wait(GNSS_READ_INTERVAL)
                goto continue
            end

            if rmc and rmc.valid then
                -- RMC 数据有效
                local lat   = rmc.lat or 0
                local lng   = rmc.lng or 0
                local speed = rmc.speed or 0

                app_data.update_gnss(lat, lng, speed, true)
                log.debug("GNSS", string.format("定位: %.5f, %.5f, 速度: %.1f", lat, lng, speed))
            else
                -- RMC 数据无效，定位状态异常
                log.warn("GNSS", "RMC 数据无效, 定位状态异常")
                gnss_fixed = false
                sys.wait(GNSS_READ_INTERVAL)
                goto continue
            end

            sys.wait(GNSS_READ_INTERVAL)

            ::continue::
        end
    end)

    if app_data.get_config("gnss_en") then
        log.info("GNSS", "GNSS 定位模块已启动")
    else
        log.info("GNSS", "GNSS 定位模块已加载（功能开关关闭，待启用）")
    end
end

return mod_gnss
