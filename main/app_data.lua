--[[
@module  app_data
@summary 数据中心层 — 统一数据数组 + 配置管理
@version 3.0
@date    2026.09.02
@usage
本模块是系统的数据中心，职责：
1. 维护统一数据数组（各模块采集的数据集中存储）
2. 管理功能开关 config（持久化到 fskv，掉电不丢失）
3. 对外提供 update_xxx / set_config / get_config 接口
4. 只读代理（get() 返回只读快照，写入用 update_xxx()）
5. 模块间回调中介（register_callback / get_callback）

注意：UART1 用于蓝牙模块通信。

在 main.lua 中调用：
  local app_data = require "app_data"
  app_data.init()   -- 初始化数据数组 + 加载持久化配置
  app_data.start()  -- 启动运行时间更新协程

🤖 整体或部分由 opencode 生成
]]

local app_data = {}
log.info("APP_DATA", "app_data.lua 已加载 v2.1")  -- 调试: 确认新代码生效

-- ========== 数据数组 ==========
local data = {
    -- 功能开关
    config = {
        ble_en         = true,    -- ✅ 蓝牙模块 (UART1 AT 指令模式)
        gnss_en        = true,
        gsensor_en     = false,
        mqtt_en        = false,
        report_interval = 2,    -- 秒（MQTT 上报间隔）
        ota_en         = true,
        ota_url        = "",
        -- WiFi AP 热点配置（OTA 升级用，手机连接热点访问网页）
        ap_ssid        = "Enboso",
        ap_password    = "enboso334968",
        -- 网络模式配置（屏幕选择切换）
        -- "ap"  — WiFi 热点模式（手机连热点访问 OTA）
        -- "sta" — WiFi STA 模式（连接路由器联网）
        net_mode       = "sta",
        -- WiFi STA 模式配置（连接路由器联网）
        sta_ssid       = "ENboso_2.4G",
        sta_password   = "enboso334968",
        -- MQTT 服务器配置（4G 联网，通过 CFG 指令动态配置）
        mqtt_server    = "49.235.138.220",
        mqtt_port      = 1883,
        -- 传感器开关
        sensor_pid_en     = true,   -- ✅ 已测试
        sensor_ims_en     = true,   -- ✅ 已测试
        sensor_battery_en = true,    -- ✅ 已测试 (ADC2 pin42, 2S锂电池, 分压6.1)
        sensor_report_en  = false,
        -- 外设开关
        led_en            = true,   -- ✅ 已测试
        buzzer_en         = true,    -- ✅ 已测试 (GPIO16 pin83, beep/连续/间歇)
        screen_en         = true,    -- ✅ 串口屏 (UART11)
        flash_en          = true,    -- ✅ 已测试 (SPI1 GPIO12, W25Q64 NOR)
        flash_log_conc_en  = false,    -- 浓度记录开关 (写 conc.log)
        flash_log_gps_en   = false,    -- 坐标记录开关 (写 gps.log)
        flash_log_alarm_en = false,    -- 报警记录开关 (写 alarm.log)
        key_en            = true,    -- ✅ 3路按键+消抖+长按
        alarm_en          = false,   -- 报警功能开关
        map_en            = true,    -- 地图显示功能开关
    },

    -- BLE 蓝牙污染源检测 (UART1 AT 指令模式)
    ble = {
        online     = false,    -- 蓝牙模块是否在线 (AT 握手成功)
        scanning   = false,    -- 是否正在扫描
        sources    = {},       -- 当前检测到的污染源列表 { {name=, type=, rssi=, conc=, alarm_level=}, ... }
        max_conc   = 0,        -- 当前最高浓度 (ppm)
        alarm_level = 0,       -- 当前报警等级 (0/2/3)
        timestamp  = 0,
    },

    -- GNSS 定位数据
    gnss = {
        lat       = 0,
        lng       = 0,
        speed     = 0,
        fixed     = false,
        timestamp = 0,
    },

    -- G-sensor 加速度 + 跌倒检测
    gsensor = {
        x             = 0,
        y             = 0,
        z             = 0,
        magnitude     = 0,
        fall_detected = false,
        timestamp     = 0,
    },

    -- MQTT 通信状态
    mqtt = {
        connected    = false,
        server       = "",
        port         = 0,
        last_pub_time = 0,
        last_sub_data = "",
        timestamp    = 0,
    },

    -- OTA 升级状态
    ota = {
        state      = "idle",   -- "idle" / "downloading" / "upgrading" / "success" / "fail"
        progress   = 0,        -- 下载进度 0-100
        version    = "",       -- 当前固件版本
        new_version = "",      -- 新固件版本
        error_msg  = "",       -- 失败原因
    },

    -- 系统信息
    sys = {
        ntp_synced = false,
        uptime     = 0,
        device_id  = "",
    },

    -- 传感器数据（阶段3移植）
    sensor = {
        pid = {
            conc      = 0,      -- 浓度 (ppm)
            raw_adc   = 0,      -- ADC 原始值 (0-4095)
            voltage   = 0,      -- 电压 (V)
            alarm     = false,  -- 报警标志
            timestamp = 0,
        },
        ims = {
            status       = 0,    -- 仪器状态 (0=预热, 1=检测, 2=清洁)
            status_desc  = "未连接",
            fault        = 0,    -- 故障位
            alarm_count  = 0,    -- 报警毒剂数量
            alarm_names  = {},   -- 报警毒剂名称列表
            clean_time   = 0,    -- 清洁剩余时间 (秒)
            sensitivity  = -1,   -- 灵敏度 (0=高, 1=低)
            pos_peak     = {},   -- 正峰谱图 (150点, 单位mV)
            neg_peak     = {},   -- 负峰谱图 (150点, 单位mV)
            -- 报警库信息
            lib_total    = 0,    -- 报警库总数量 (1-5)
            lib_current  = 1,    -- 当前选中的报警库编号
            lib_names    = {},   -- 各报警库名称列表
            lib_loaded   = false,-- 报警库信息是否已加载
            timestamp    = 0,
        },
        battery = {
            voltage   = 0,      -- 电池电压 (V)
            pct       = 0,      -- 电量百分比 (0-100)
            timestamp = 0,
        },
    },

    -- 报警数据（阶段4移植）
    alarm = {
        level     = 0,          -- 报警等级 (0=正常, 2=警告, 3=严重)
        source    = "none",     -- 报警来源 ("pid"/"ims"/"fall"/"ble"/"none")
        sources   = {},         -- 当前所有报警来源列表（支持多源同时报警）
        timestamp = 0,
    },

    -- 地图显示状态
    map = {
        zoom       = 15,         -- 缩放层级
        tile_x     = 0,          -- 当前中心瓦片 X 编号
        tile_y     = 0,          -- 当前中心瓦片 Y 编号
        px         = 0,          -- GPS 点在瓦片内像素 X (0~255)
        py         = 0,          -- GPS 点在瓦片内像素 Y (0~255)
        dx         = 0,          -- 屏幕偏移 X (像素, Phase 2)
        dy         = 0,          -- 屏幕偏移 Y (像素, Phase 2)
        lat        = 0,          -- 当前显示纬度 (十进制)
        lng        = 0,          -- 当前显示经度 (十进制)
        active     = false,      -- 地图是否已激活
        timestamp  = 0,
    },

    -- 多设备组网（预留，项目暂无数据）
    group_info = {
        is_commander = false,    -- 是否指挥官设备
        group_id     = "",       -- 分组编号
        timestamp    = 0,
    },

    -- 化学污染浓度热力图（预留，项目暂无数据）
    heatmap = {
        points       = {},       -- 热力图数据点列表 { {lat=, lng=, conc=}, ... }
        timestamp    = 0,
    },

    -- IO 外设状态（阶段2-5移植）
    io = {
        led = {
            power = true,      -- 电源灯
            alarm = "off",      -- 报警灯 ("off"/"on"/"blink_slow"/"blink_fast")
            comm  = "on",      -- 通信灯
        },
        buzzer = {
            pattern   = "off",  -- 蜂鸣器模式 ("off"/"continuous"/"intermittent")
            timestamp = 0,
        },
        key = {
            last_key   = "",    -- 最后按下的键
            key_event  = "",    -- 按键事件
            timestamp  = 0,
        },
        screen = {
            connected     = false,
            current_page  = 0,
            last_refresh  = 0,
            last_key      = "",  -- 串口屏触控按键
            key_event     = "",  -- 触控事件值
            timestamp     = 0,
        },
        flash = {
            mounted   = false,
            size_kb   = 0,
            free_kb   = 0,
            timestamp = 0,
        },
    },
}

-- ========== fskv 配置持久化 ==========
local FSKV_CONFIG_KEY = "safex_config"  -- fskv 中存储配置的 key

-- 从 fskv 加载配置，没有则写入默认值
local function load_config_from_flash()
    fskv.init()

    -- 打印 fskv 空间状态
    local used, total, kv_count = fskv.status()
    log.info("APP", string.format("fskv 空间: 已用 %d / 总计 %d 字节, 剩余 %d 字节, KV数 %d", used, total, total - used, kv_count))

    local saved = fskv.get(FSKV_CONFIG_KEY)
    if saved and type(saved) == "table" then
        -- 以 flash 数据为准，合并默认值防止新增字段缺失
        for k, v in pairs(data.config) do
            if saved[k] ~= nil then
                data.config[k] = saved[k]
            end
        end
        log.info("APP", "从 Flash 加载配置成功")
    else
        -- flash 中没有数据，写入默认值
        fskv.set(FSKV_CONFIG_KEY, data.config)
        log.info("APP", "Flash 无配置, 已写入默认值")
    end
end

-- 保存配置到 fskv
local function save_config_to_flash()
    fskv.set(FSKV_CONFIG_KEY, data.config)
    log.debug("APP", "配置已保存到 Flash")
end

-- ========== 获取精简上报数据（按功能开关过滤，关闭的模块不上报） ==========
function app_data.get_report_data()
    local report = {}

    -- 系统基础信息（设备ID + 运行时间）
    report.sys = {
        uptime     = data.sys.uptime,
        device_id  = data.sys.device_id,
        ntp_synced = data.sys.ntp_synced,
    }

    -- GNSS 定位状态（按开关过滤）
    if data.config.gnss_en then
        report.gnss = {
            lat       = data.gnss.lat,
            lng       = data.gnss.lng,
            speed     = data.gnss.speed,
            fixed     = data.gnss.fixed,
            timestamp = data.gnss.timestamp,
        }
    end

    -- G-sensor 跌倒检测（按开关过滤）
    if data.config.gsensor_en then
        report.gsensor = {
            fall_detected = data.gsensor.fall_detected,
            magnitude     = data.gsensor.magnitude,
            timestamp     = data.gsensor.timestamp,
        }
    end

    -- 传感器数据（按开关过滤）
    if data.config.sensor_report_en then
        local sensor_report = {}
        if data.config.sensor_pid_en then
            sensor_report.pid = {
                conc      = data.sensor.pid.conc,
                voltage   = data.sensor.pid.voltage,
                alarm     = data.sensor.pid.alarm,
                timestamp = data.sensor.pid.timestamp,
            }
        end
        if data.config.sensor_ims_en then
            sensor_report.ims = {
                status       = data.sensor.ims.status,
                status_desc  = data.sensor.ims.status_desc,
                alarm_count  = data.sensor.ims.alarm_count,
                alarm_names  = data.sensor.ims.alarm_names,
                fault        = data.sensor.ims.fault,
                timestamp    = data.sensor.ims.timestamp,
            }
        end
        if data.config.sensor_battery_en then
            sensor_report.battery = {
                voltage   = data.sensor.battery.voltage,
                pct       = data.sensor.battery.pct,
                timestamp = data.sensor.battery.timestamp,
            }
        end
        if next(sensor_report) then
            report.sensor = sensor_report
        end
    end

    -- 地图状态（按开关过滤）
    if data.config.map_en then
        report.map = {
            zoom      = data.map.zoom,
            tile_x    = data.map.tile_x,
            tile_y    = data.map.tile_y,
            lat       = data.map.lat,
            lng       = data.map.lng,
            active    = data.map.active,
            timestamp = data.map.timestamp,
        }
    end

    -- 报警状态（始终上报）
    report.alarm = {
        level     = data.alarm.level,
        source    = data.alarm.source,
        sources   = data.alarm.sources,
        timestamp = data.alarm.timestamp,
    }

    -- 多设备组网（预留，暂无数据）
    report.group_info = {
        is_commander = data.group_info.is_commander,
        group_id     = data.group_info.group_id,
    }

    -- 化学污染浓度热力图（预留，暂无数据）
    report.heatmap = {
        points = data.heatmap.points,
    }

    return report
end

-- ========== 对外接口 ==========

-- 只读代理工厂：拦截所有写操作，读操作转发到原始表
-- 哈希表 → 返回代理（__newindex 拦截写入并抛出错误）
-- 数组表 → 返回浅拷贝（兼容 #, ipairs, table.concat 等 C 函数）
local function make_readonly(tbl, cache)
    cache = cache or {}
    if cache[tbl] then return cache[tbl] end

    -- 数组类表（t[1] 非 nil）：返回浅拷贝
    -- 必须返回真实表，因为 table.concat / # 等 C 函数绕过 metatable
    if tbl[1] ~= nil then
        local copy = {}
        for i = 1, #tbl do
            local v = tbl[i]
            copy[i] = type(v) == "table" and make_readonly(v, cache) or v
        end
        cache[tbl] = copy
        return copy
    end

    -- 哈希类表：返回只读代理
    local original = tbl
    local proxy = setmetatable({}, {
        __index = function(_, k)
            local v = original[k]
            if type(v) == "table" then
                return make_readonly(v, cache)
            end
            return v
        end,
        __newindex = function(_, k, v)
            error("app_data.get() 返回只读数据，请使用 update_xxx() 接口写入", 2)
        end,
        __pairs = function(_)
            return pairs(original)
        end,
    })
    cache[tbl] = proxy
    return proxy
end

-- 获取只读数据快照（代理模式）
-- 所有写入操作都会抛出错误，引导使用 update_xxx() 接口
-- 数组类子表返回拷贝，兼容 #, ipairs, table.concat 等 C 函数
function app_data.get()
    return make_readonly(data)
end

-- 更新 BLE 数据
-- @param fields 字段表 { online=, scanning=, sources=, max_conc=, alarm_level= }
function app_data.update_ble(fields)
    if type(fields) == "table" then
        for k, v in pairs(fields) do
            data.ble[k] = v
        end
        data.ble.timestamp = os.time()
    end
end

-- ========== 蓝牙污染源路由表（fskv 持久化） ==========
local FSKV_BLE_SOURCES_KEY = "safex_ble_sources"

-- 默认污染源路由表（9 种毒剂类型, 与 ble_source_config.bat 一致）
local ble_sources = {
    { major = 1,    type = "沙林毒剂",   rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
    { major = 2,    type = "芥子气",     rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
    { major = 3,    type = "氯气",       rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
    { major = 4,    type = "氰化氢",     rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
    { major = 5,    type = "光气",       rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
    { major = 6,    type = "路易氏剂",   rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
    { major = 7,    type = "塔崩",       rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
    { major = 8,    type = "VX 毒剂",    rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
    { major = 65535, type = "测试",       rssi_near = -30, rssi_far = -80, max_conc = 100, warn_conc = 50 },
}

-- 从 fskv 加载污染源路由表
local function load_ble_sources_from_flash()
    local saved = fskv.get(FSKV_BLE_SOURCES_KEY)
    if saved and type(saved) == "table" and #saved > 0 then
        ble_sources = saved
        log.info("APP", "从 Flash 加载蓝牙污染源路由表:", #ble_sources, "条")
    else
        fskv.set(FSKV_BLE_SOURCES_KEY, ble_sources)
        log.info("APP", "Flash 无蓝牙污染源路由表, 已写入默认 9 条路由")
    end
end

-- 保存污染源路由表到 fskv
local function save_ble_sources_to_flash()
    fskv.set(FSKV_BLE_SOURCES_KEY, ble_sources)
    log.debug("APP", "蓝牙污染源路由表已保存到 Flash")
end

-- 查询污染源路由表（按 Major 匹配）
-- @param major 污染源类型编码 (数字)
-- @return table|nil  匹配到的路由 { major=, type=, rssi_near=, rssi_far=, max_conc=, warn_conc= }
function app_data.get_ble_source(major)
    if not major then return nil end
    for _, s in ipairs(ble_sources) do
        if s.major == major then
            return s
        end
    end
    return nil
end

-- 获取全部污染源路由表
function app_data.get_ble_sources()
    return ble_sources
end

-- 添加污染源路由
-- @param entry { major=1, type="沙林", rssi_near=-30, rssi_far=-80, max_conc=100, warn_conc=50 }
function app_data.add_ble_source(entry)
    if not entry or not entry.major then
        return false, "major 不能为空"
    end
    local major = tonumber(entry.major)
    if not major then
        return false, "major 必须是数字"
    end
    -- major 去重
    for _, s in ipairs(ble_sources) do
        if s.major == major then
            return false, "major 已存在: " .. major
        end
    end
    -- 设置默认值
    local item = {
        major     = major,
        type      = entry.type or "未分类",
        rssi_near = tonumber(entry.rssi_near) or -30,
        rssi_far  = tonumber(entry.rssi_far) or -80,
        max_conc  = tonumber(entry.max_conc) or 100,
        warn_conc = tonumber(entry.warn_conc) or 50,
    }
    table.insert(ble_sources, item)
    save_ble_sources_to_flash()
    log.info("APP", "添加蓝牙污染源: major=" .. major .. ", type=" .. item.type)
    return true, item
end

-- 删除污染源路由
-- @param major 污染源类型编码 (数字或数字字符串)
function app_data.remove_ble_source(major)
    if not major then return false, "major 不能为空" end
    major = tonumber(major)
    if not major then return false, "major 必须是数字" end
    for i, s in ipairs(ble_sources) do
        if s.major == major then
            table.remove(ble_sources, i)
            save_ble_sources_to_flash()
            log.info("APP", "删除蓝牙污染源: major=" .. major)
            return true, major
        end
    end
    return false, "未找到 major: " .. major
end

-- 更新 GNSS 数据
function app_data.update_gnss(lat, lng, speed, fixed)
    data.gnss.lat       = lat or 0
    data.gnss.lng       = lng or 0
    data.gnss.speed     = speed or 0
    data.gnss.fixed     = fixed or false
    data.gnss.timestamp = os.time()
end

-- 更新 G-sensor 数据
function app_data.update_gsensor(x, y, z, magnitude, fall)
    data.gsensor.magnitude     = magnitude or 0
    data.gsensor.fall_detected = fall or false
    data.gsensor.x             = x or 0
    data.gsensor.y             = y or 0
    data.gsensor.z             = z or 0
    data.gsensor.timestamp     = os.time()
end

-- 更新 MQTT 状态
function app_data.update_mqtt(connected, server, port)
    data.mqtt.connected = connected or false
    if server then data.mqtt.server = server end
    if port then data.mqtt.port = port end
    data.mqtt.timestamp = os.time()
end

-- 更新 MQTT 下行数据（收到服务器下发消息时调用）
function app_data.update_mqtt_sub_data(payload)
    data.mqtt.last_sub_data = payload or ""
    data.mqtt.timestamp = os.time()
end

-- 更新 MQTT 上报时间（发布消息成功后调用）
function app_data.update_mqtt_pub_time()
    data.mqtt.last_pub_time = os.time()
end

-- 更新 OTA 状态
function app_data.update_ota(state, progress, new_version, error_msg, version)
    data.ota.state       = state or data.ota.state
    data.ota.progress    = progress or data.ota.progress
    if new_version then data.ota.new_version = new_version end
    if error_msg then data.ota.error_msg = error_msg end
    if version then data.ota.version = version end
end

-- 更新传感器子表
-- @param sub    子表名 ("pid"/"ims"/"battery")
-- @param fields 字段表 { key=value, ... }
function app_data.update_sensor(sub, fields)
    if data.sensor[sub] and type(fields) == "table" then
        for k, v in pairs(fields) do
            data.sensor[sub][k] = v
        end
        data.sensor[sub].timestamp = os.time()
    end
end

-- ========== 报警等级自动计算 ==========
-- 等级规则：
--   IMS 检测到毒剂           → 3 (严重)
--   跌倒检测触发             → 3 (严重)
--   BLE 污染源超阈值        → 3 (严重)
--   PID 报警                 → 2 (警告)
--   无报警                   → 0 (正常)
local function calc_alarm_level(sources)
    for _, s in ipairs(sources) do
        if s == "ims" or s == "fall" or s == "ble" then
            return 3  -- IMS/跌倒/BLE污染源 → 严重
        end
        if s == "pid" then
            return 2  -- PID 单独预警
        end
    end
    return 0
end

-- 触发报警（添加来源，等级自动计算）
-- @param source 报警来源 ("pid"/"ims"/"fall"/"ble")
function app_data.update_alarm(source)
    if not source or source == "none" then return end
    -- 去重添加
    local found = false
    for _, s in ipairs(data.alarm.sources) do
        if s == source then found = true break end
    end
    if not found then
        table.insert(data.alarm.sources, source)
    end
    -- 自动计算等级
    data.alarm.level  = calc_alarm_level(data.alarm.sources)
    data.alarm.source = data.alarm.sources[1]
    data.alarm.timestamp = os.time()
end

-- 清除指定报警来源（等级自动重新计算）
-- @param source 要清除的报警来源 ("pid"/"ims"/"fall")
function app_data.clear_alarm(source)
    for i = #data.alarm.sources, 1, -1 do
        if data.alarm.sources[i] == source then
            table.remove(data.alarm.sources, i)
        end
    end
    -- 重新计算等级
    data.alarm.level  = calc_alarm_level(data.alarm.sources)
    data.alarm.source = #data.alarm.sources > 0 and data.alarm.sources[1] or "none"
    data.alarm.timestamp = os.time()
end

-- 更新地图显示状态
-- @param fields 字段表 { tile_x=..., tile_y=..., lat=..., ... }
function app_data.update_map_state(fields)
    if type(fields) == "table" then
        for k, v in pairs(fields) do
            data.map[k] = v
        end
        data.map.timestamp = os.time()
    end
end

-- 更新 IO 外设子表
-- @param category 子表名 ("led"/"buzzer"/"key"/"screen"/"flash")
-- @param fields   字段表 { key=value, ... }
function app_data.update_io(category, fields)
    if data.io[category] and type(fields) == "table" then
        for k, v in pairs(fields) do
            data.io[category][k] = v
        end
    end
end

-- 设置功能开关
function app_data.set_config(key, value)
    if data.config[key] ~= nil then
        -- 布尔值转换：字符串 "0"/"1" → false/true
        if type(data.config[key]) == "boolean" and type(value) == "string" then
            value = (value == "1" or value:lower() == "true")
        end
        -- 数值转换
        if type(data.config[key]) == "number" and type(value) == "string" then
            value = tonumber(value) or value
        end
        -- 值未变化，跳过存储（节省 Flash 寿命）
        if data.config[key] == value then
            return true
        end
        data.config[key] = value
        save_config_to_flash()  -- 同步写入 fskv
        log.info("APP", "配置已更新:", key, "=", tostring(value))
        return true
    else
        log.warn("APP", "未知配置项:", key)
        return false
    end
end

-- 获取功能开关
function app_data.get_config(key)
    return data.config[key]
end

-- ========== 模块回调注册（星型架构中介） ==========
-- 模块间通过回调间接调用，避免直接 require 其他 mod_xxx
-- 注册方：mod_screen.register_callback("screen_ota", { begin=..., ... })
-- 调用方：local api = app_data.get_callback("screen_ota")
local callbacks = {}

function app_data.register_callback(name, fn)
    callbacks[name] = fn
end

function app_data.get_callback(name)
    return callbacks[name]
end

-- ========== 初始化 ==========
function app_data.init()
    -- 从 fskv 加载持久化配置
    load_config_from_flash()

    -- 从 fskv 加载蓝牙污染源路由表
    load_ble_sources_from_flash()

    -- 获取 IMEI
    data.sys.device_id = mobile.imei() or ""

    log.info("APP", "数据中心初始化成功 (UART1 已改用于蓝牙模块通信)")
    log.info("APP", "设备ID:", data.sys.device_id)
end

-- ========== 启动 ==========
function app_data.start()
    -- 运行时间更新协程
    sys.taskInit(function()
        local start_tick = mcu.ticks()
        while true do
            sys.wait(1000)
            data.sys.uptime = (mcu.ticks() - start_tick) // 1000
        end
    end)

    log.info("APP", "数据中心已启动")
end

return app_data
