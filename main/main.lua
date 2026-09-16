--[[
@module  main
@summary Safex 物联网数据采集与上报系统
@version 5.3
@date    2026.09.02
@usage
基于 Air8000 模块的分层架构物联网系统：
1. 看门狗防死机
2. 蓝牙模块通信（UART1）
3. 跌倒检测（exvib 加速度传感器）
4. BLE 蓝牙扫描
5. GNSS 卫星定位
6. MQTT 通信（4G 联网）
7. 屏幕显示 + OTA 升级（UART11 TJC）
]]

-- 项目配置
PROJECT = "safex_lua_code"
VERSION = "001.010.000"

-- ========== 加载模块 ==========

-- 看门狗（最先加载，防止后续初始化卡死）
local mod_wdt = require "mod_wdt"

-- 数据中心（必须第二个加载，其他模块依赖它）
local app_data = require "app_data"

-- LED 指示灯模块
local mod_led = require "mod_led"

-- 蜂鸣器模块
local mod_buzzer = require "mod_buzzer"

-- 按键输入模块
local mod_key = require "mod_key"

-- G-sensor 跌倒检测模块
local mod_gsensor = require "mod_gsensor"

-- 传感器管理器（统一调度 PID/IMS/Battery）
local mod_sensor = require "mod_sensor"

-- 报警管理器（监控报警等级，联动蜂鸣器/LED）
local mod_alarm = require "mod_alarm"

-- Flash 存储模块（SPI1 外部 Flash 数据记录）
local mod_flash
do
    local ok, mod = pcall(require, "mod_flash")
    if ok then
        mod_flash = mod
    else
        log.error("MAIN", "mod_flash 加载失败: " .. tostring(mod))
    end
end

-- 串口屏模块（UART11 X5 陶晶池串口屏）
local mod_screen = require "mod_screen"

-- 屏幕 OTA + 文件透传模块（从 mod_screen 拆分）
local mod_screen_ota = require "mod_screen_ota"

-- 屏幕地图显示模块（离线瓦片地图）
local mod_screen_map = require "mod_screen_map"

-- 屏幕 IMS 界面模块（IMS 数据推送 + 按钮事件处理）
local mod_screen_ims = require "mod_screen_ims"

-- 屏幕 MQTT 界面模块（MQTT 配置推送 + 按钮事件处理）
local mod_screen_mqtt = require "mod_screen_mqtt"

-- BLE 蓝牙扫描模块
local mod_ble = require "mod_ble"

-- GNSS 卫星定位模块
local mod_gnss = require "mod_gnss"

-- MQTT 通信模块
local mod_mqtt = require "mod_mqtt"

-- OTA 固件升级模块（HTTP 路由 + FOTA 固件写入）
local mod_ota = require "mod_ota"

-- 网络模式管理模块（WiFi AP/STA + 网络热切换）
local mod_net = require "mod_net"

-- ========== 初始化模块 ==========

-- 看门狗初始化 + 启动（必须最先执行）
mod_wdt.init()
mod_wdt.start()

-- 数据中心初始化（UART1 收发 + 定时上报）
app_data.init()

-- LED 初始化 + 启动（3 路 LED 指示灯）
mod_led.init()
mod_led.start()

-- 蜂鸣器 初始化 + 启动（蜂鸣器控制）
mod_buzzer.init()
mod_buzzer.start()

-- 按键 初始化 + 启动（3 路按键 + 消抖 + 长按）
mod_key.init()
mod_key.start()

-- G-sensor 初始化 + 启动（加速度采集 + 跌倒检测）
mod_gsensor.init()
mod_gsensor.start()

-- 传感器管理器 初始化 + 启动（统一调度 PID/IMS/Battery）
mod_sensor.init()
mod_sensor.start()

-- 报警管理器 初始化 + 启动（监控报警等级，联动蜂鸣器/LED）
mod_alarm.init()
mod_alarm.start()

-- Flash 存储 初始化 + 启动（SPI1 数据记录）
if mod_flash then
    mod_flash.init()
    mod_flash.start()
else
    log.warn("MAIN", "mod_flash 未加载, 跳过初始化")
end

-- 串口屏 初始化 + 启动（UART11 X5 陶晶池串口屏）
mod_screen.init()
mod_screen_ota.init()  -- 屏幕 OTA 初始化（注册 UART sent 回调 + 预分配 zbuff）
mod_screen_map.init()  -- 屏幕地图初始化（获取屏幕 API 回调）
mod_screen_ims.init()  -- 屏幕 IMS 界面初始化（获取屏幕 + IMS API 回调）
mod_screen_mqtt.init()  -- 屏幕 MQTT 界面初始化（获取屏幕 API 回调）
mod_screen.start()
mod_screen_map.start()  -- 屏幕地图启动（阶段1: 固定坐标瓦片显示）
mod_screen_ims.start()  -- 屏幕 IMS 界面启动（订阅按钮事件）
mod_screen_mqtt.start()  -- 屏幕 MQTT 界面启动（订阅 MQTT 事件）

-- BLE 初始化 + 启动（蓝牙扫描）
mod_ble.init()
mod_ble.start()

-- GNSS 初始化 + 启动（卫星定位）
mod_gnss.init()
mod_gnss.start()

-- MQTT 初始化 + 启动（WiFi STA 联网 + MQTT 通信）
mod_mqtt.init()
mod_mqtt.start()

-- OTA 初始化 + 启动（HTTP 路由 + FOTA 固件升级）
mod_ota.init()
mod_ota.start()

-- 网络管理 初始化 + 启动（WiFi AP/STA + 网络热切换）
mod_net.init()
mod_net.start()

-- 数据中心启动（UART1 收发 + 定时上报，最后启动确保各模块数据就绪）
app_data.start()

-- ========== 硬件测试（独立文件, 需要时取消注释） ==========
-- 所有硬件模块测试代码已移至 test_main.lua, 与主程序解耦
-- 使用方法: 取消下面一行注释即可加载测试文件
require "test_main"

-- ========== 内存 + Flash 监控（每 30 秒打印一次） ==========
sys.timerLoopStart(function()
    -- 内存使用
    local lua_total, lua_used, lua_peak = rtos.meminfo()
    local sys_total, sys_used, sys_peak = rtos.meminfo("sys")
    log.info(string.format("MEM Lua: %d/%dKB (%.1f%%) 峰值%.1f%% | Sys: %d/%dKB (%.1f%%) 峰值%.1f%%",
        lua_used // 1024, lua_total // 1024, lua_used / lua_total * 100, lua_peak / lua_total * 100,
        sys_used // 1024, sys_total // 1024, sys_used / sys_total * 100, sys_peak / sys_total * 100))
    -- Flash (fskv) 使用
    local used, total, kv_count = fskv.status()
    log.info(string.format("FSKV: %d/%dKB (%.1f%%) KV数%d",
        used // 1024, total // 1024, used / total * 100, kv_count))
end, 30000)

-- 用户代码已结束
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!
