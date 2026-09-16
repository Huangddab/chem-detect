--[[
@module  mod_mqtt
@brief   MQTT 通信模块（WiFi 联网 + MQTT 连接/上报/下行）

🤖 整体或部分由 opencode 生成
]]

local app_data = require "app_data"

local mod_mqtt = {}

-- ========== MQTT 参数 ==========
local mqtt_client = nil
local mqtt_connected = false

-- 连接结果标志（connect() 是非阻塞的，需等待 conack/error 回调）
local mqtt_connect_done    = false   -- 本次连接是否已有结果
local mqtt_connect_success = false   -- 连接是否成功

-- 重连请求标志（由 reconnect() 设置，连接协程检测后断开旧连接重连）
local reconnect_request = false

-- 连接失败标志（失败后停止自动重连，等用户点连接按钮才重试）
local connect_failed = false

-- 主题定义
local TOPIC_TELEMETRY  = ""    -- 定时上报主题（init 时拼接 device_id）
local TOPIC_EVENTS     = ""    -- 报警事件主题（init 时拼接 device_id）
local TOPIC_NOTIFY_ALL = ""    -- 群发通知主题（所有设备监听）
local TOPIC_NOTIFY_DEV = ""    -- 单发通知主题（单体设备监听）

-- ========== 初始化 ==========
function mod_mqtt.init()
    local device_id = app_data.get().sys.device_id or "unknown"
    TOPIC_TELEMETRY  = "chem/telemetry/" .. device_id
    TOPIC_EVENTS     = "chem/events/" .. device_id
    TOPIC_NOTIFY_ALL = "chem/notify"               -- 群发：所有设备监听
    TOPIC_NOTIFY_DEV = "chem/" .. device_id .. "/notify"  -- 单发：仅本设备监听
    log.info("MQTT", "模块初始化, 上报主题:", TOPIC_TELEMETRY, "报警主题:", TOPIC_EVENTS, "群发通知:", TOPIC_NOTIFY_ALL, "单发通知:", TOPIC_NOTIFY_DEV)
end

-- ========== notify 消息解析 ==========
-- 已处理的最大快照时间戳 (秒级), 用于丢弃 QoS1 积压的旧快照, 防止误清最新设备列表
local last_snapshot_ts = 0

-- notify 快照超时守护: 超过 NOTIFY_TIMEOUT 秒未收到任何有效 notify 消息,
-- 认为周围无设备 (服务器停发/MQTT 断连), 清空地图设备列表
-- 阈值需大于服务器发送周期 (5s 测试周期建议 30s; 30s 正式周期建议 90s)
local NOTIFY_TIMEOUT = 30
local notify_timeout_timer = nil

-- 重置超时定时器 (每收到一帧有效 notify 消息时调用, 事件驱动, 无常驻协程)
local function reset_notify_timer()
    if notify_timeout_timer then
        sys.timerStop(notify_timeout_timer)
    end
    notify_timeout_timer = sys.timerStart(function()
        notify_timeout_timer = nil
        log.warn("MQTT", "notify 快照超时(", NOTIFY_TIMEOUT, "s 无数据), 清空地图设备列表")
        -- 空快照全量替换, 复用 update_map_devices 自动广播 MAP_DEVICE_UPDATE 清除屏幕标记
        app_data.update_map_devices({})
    end, NOTIFY_TIMEOUT * 1000)
end

-- 归一化时间戳为秒级 (兼容秒/毫秒, >1e12 视为毫秒)
local function normalize_ts(ts)
    ts = tonumber(ts) or 0
    if ts > 1e12 then ts = math.floor(ts / 1000) end
    return ts
end

-- 解析 type=locations 快照消息 (全量设备数组, 列表缺席即下线)
-- 格式: { type="locations", timestamp=1784024217, devices={ {device_id="", lat=0, lng=0}, ... } }
local function parse_locations_snapshot(parsed)
    local ts = normalize_ts(parsed.timestamp)
    -- 单调递增检查, 不依赖本地时钟 (设备本地时间未同步时依然可靠)
    if ts > 0 and ts <= last_snapshot_ts then
        log.warn("MQTT", "丢弃过期快照 ts=", ts, "已处理 ts=", last_snapshot_ts)
        return
    end
    if type(parsed.devices) ~= "table" then
        log.warn("MQTT", "locations 快照缺少 devices 数组")
        return
    end
    if ts > 0 then last_snapshot_ts = ts end
    app_data.update_map_devices(parsed.devices)
    reset_notify_timer()
end

-- 解析旧单条坐标格式 (兼容服务器切换期间的旧版 payload)
-- 格式: { device_id="", lat=0, lng=0 } 或嵌套 { device_id="", gnss={ lat=0, lng=0 } }
local function parse_single_device(parsed, dev_id)
    if not dev_id then dev_id = parsed.device_id end
    if not dev_id or dev_id == "" then return end
    local lat = parsed.lat or parsed.latitude
    local lng = parsed.lng or parsed.lon or parsed.longitude
    if not lat and type(parsed.gnss) == "table" then
        lat = parsed.gnss.lat or parsed.gnss.latitude
        lng = parsed.gnss.lng or parsed.gnss.lon or parsed.gnss.longitude
    end
    if lat and lng then
        app_data.update_map_device(dev_id, lat, lng)
        reset_notify_timer()
    end
end

-- notify 主题消息总入口 (chem/notify 或 chem/{device_id}/notify)
-- 按 type 字段分发: "locations" 走快照数组, 其余走旧单条坐标格式
local function parse_notify_message(topic, payload)
    -- 匹配 chem/xxx/notify 主题 (提取 device_id), 群发主题 chem/notify 不匹配
    local dev_id = string.match(topic, "^chem/(.+)/notify$")
    -- 仅处理 notify 主题消息
    if not dev_id and topic ~= TOPIC_NOTIFY_ALL then return end
    local ok, parsed = pcall(json.decode, payload)
    if not ok or type(parsed) ~= "table" then
        log.warn("MQTT", "notify 消息 JSON 解析失败:", topic)
        return
    end
    if parsed.type == "locations" then
        parse_locations_snapshot(parsed)
    else
        -- 旧单条格式: 群发主题的 device_id 从 payload 提取
        parse_single_device(parsed, dev_id)
    end
end

-- ========== MQTT 事件回调 ==========
local function mqtt_event_cb(client, event, data, payload, metas)
    -- 连接成功
    if event == "conack" then
        mqtt_connected = true
        mqtt_connect_done = true
        mqtt_connect_success = true
        log.info("MQTT", "连接成功")
        -- 订阅通知主题（群发 + 单发）
        client:subscribe(TOPIC_NOTIFY_ALL, 1)
        client:subscribe(TOPIC_NOTIFY_DEV, 1)
        -- 更新 app_data 状态
        local config = app_data.get().config
        app_data.update_mqtt(true, config.mqtt_server, config.mqtt_port)

    -- 订阅结果
    elseif event == "suback" then
        if data then
            log.info("MQTT", "订阅成功, qos:", payload)
        else
            log.warn("MQTT", "订阅失败, code:", payload)
        end

    -- 接收到服务器下发数据
    elseif event == "recv" then
        log.info("MQTT", "收到下行指令:", data, "数据:", payload and payload or "(空)")
        -- 保存到 app_data
        app_data.update_mqtt_sub_data(payload)
        -- 发布消息供其他模块处理
        sys.publish("MQTT_RECV", data, payload)

        -- 解析 notify 主题消息 (type=locations 快照数组 或 旧单条坐标格式)
        -- 主题格式: chem/{device_id}/notify 或 chem/notify
        if data and payload then
            parse_notify_message(data, payload)
        end

    -- 发送成功
    elseif event == "sent" then
        -- publish 成功回调

    -- 服务器断开
    elseif event == "disconnect" then
        mqtt_connected = false
        log.warn("MQTT", "连接断开")
        app_data.update_mqtt(false, "", 0)

    -- 心跳应答
    elseif event == "pong" then
        -- 心跳正常

    -- 异常
    -- data 可能值: "connect"(TCP连接失败) / "tx"(发送失败) / "conack"(鉴权失败) / "other"
    elseif event == "error" then
        log.error("MQTT", "异常类型:", tostring(data), "详情:", tostring(payload))
        mqtt_connect_done = true
        mqtt_connect_success = false
        mqtt_connected = false
        app_data.update_mqtt(false, "", 0)
    end
end

-- ========== MQTT 连接协程 ==========
local function mqtt_connect_task()
    -- WiFi 就绪由 mqtt_event_loop 保证 (收到 NET_STATUS=connected 才 spawn 本协程)
    while true do
        -- 检查开关：关闭时不连接，已连接则断开
        if not app_data.get_config("mqtt_en") then
            if mqtt_connected and mqtt_client then
                mqtt_client:close()
                mqtt_client = nil
                mqtt_connected = false
                app_data.update_mqtt(false, "", 0)
                log.info("MQTT", "开关已关闭, 断开 MQTT 连接")
            end
            connect_failed = false  -- 开关关闭时重置失败标志
            sys.wait(2000)
        else
            -- 重新读取配置（支持运行时修改服务器地址）
            local server = app_data.get_config("mqtt_server") or ""
            local port = app_data.get_config("mqtt_port") or 1883

            -- 服务器地址为空时跳过连接
            if server == "" then
                log.warn("MQTT", "mqtt_server 为空, 请通过屏幕或 MQTT 配置: mqtt_server=xxx")
                sys.wait(3000)
                goto continue
            end

            -- 上次连接失败，停止自动重连，等用户重新点连接按钮
            if connect_failed and not reconnect_request then
                sys.waitUntil("MQTT_RETRY", 1000)
                goto continue
            end

            local client_id = "safex_" .. (app_data.get().sys.device_id or "unknown")

            log.info("MQTT", "正在连接:", server, port, "client_id:", client_id)

            -- 重置连接结果标志
            mqtt_connect_done = false
            mqtt_connect_success = false

            -- 使用 WiFi STA 网卡
            mqtt_client = mqtt.create(socket.LWIP_STA, server, port)
            if mqtt_client then
                -- 配置认证
                mqtt_client:auth(client_id, "", "", true)
                -- 注册事件回调
                mqtt_client:on(mqtt_event_cb)
                -- 连接服务器（非阻塞，立即返回）
                local ok = mqtt_client:connect()
                if ok then
                    -- connect() 返回 true 仅表示 TCP 连接已启动
                    -- 需等待 conack(成功) 或 error(失败) 回调
                    local wait_ms = 0
                    while not mqtt_connect_done and wait_ms < 15000 and not reconnect_request do
                        sys.wait(100)
                        wait_ms = wait_ms + 100
                    end
                    if reconnect_request then
                        log.info("MQTT", "连接等待中收到重连请求, 中断当前连接")
                        -- 跳过状态发布，直接进入清理重连流程
                        goto reconnect_cleanup
                    end

                    if mqtt_connect_success then
                        -- MQTT 连接成功，进入保持循环（同时检查开关和重连请求）
                        connect_failed = false  -- 连接成功，重置失败标志
                        log.info("MQTT", "连接已建立, 进入保持循环")
                        sys.publish("MQTT_STATUS", "online")
                        while mqtt_connected and not reconnect_request do
                            if not app_data.get_config("mqtt_en") then
                                log.info("MQTT", "运行中检测到开关关闭, 主动断开")
                                break
                            end
                            sys.wait(500)
                        end
                        if reconnect_request then
                            log.info("MQTT", "收到重连请求, 断开旧连接")
                            reconnect_request = false
                        else
                            log.warn("MQTT", "连接已断开, 准备重连")
                            sys.publish("MQTT_STATUS", "disconnected")
                        end
                    elseif not mqtt_connect_done then
                        connect_failed = true
                        log.error("MQTT", "连接超时(15秒无响应)")
                        sys.publish("MQTT_STATUS", "timeout")
                    else
                        connect_failed = true
                        log.error("MQTT", "MQTT 握手失败")
                        sys.publish("MQTT_STATUS", "handshake_fail")
                    end
                else
                    connect_failed = true
                    log.error("MQTT", "TCP 连接启动失败")
                    sys.publish("MQTT_STATUS", "tcp_fail")
                end
            else
                connect_failed = true
                log.error("MQTT", "创建客户端失败")
                sys.publish("MQTT_STATUS", "create_fail")
            end

            ::reconnect_cleanup::
            -- 清理
            if mqtt_client then
                mqtt_client:close()
                mqtt_client = nil
            end
            -- 重连请求时跳过等待，立即重连
            if reconnect_request then
                reconnect_request = false
                connect_failed = false  -- 用户手动重连，重置失败标志
                sys.publish("MQTT_RETRY")  -- 唤醒可能卡在等待的协程
                log.info("MQTT", "用户请求重连, 立即重连...")
            elseif connect_failed then
                log.info("MQTT", "等待用户重新点连接按钮...")
                sys.waitUntil("MQTT_RETRY", 60000)
            else
                log.info("MQTT", "5秒后重连...")
                sys.wait(5000)
            end
        end
        ::continue::
    end
end

-- ========== WiFi 状态事件监听 (常驻) ==========
-- 订阅 NET_STATUS: WiFi 就绪时启动 MQTT 连接协程, WiFi 失败时断开
-- 解决: STA 失败后重切 STA 能自动重连 (之前一次性协程结束就不再重启)
local mqtt_connecting = false  -- 连接协程是否在运行 (防重入)

local function sta_ready()
    if socket.adapter(socket.LWIP_STA) then
        local ip = socket.localIP(socket.LWIP_STA)
        return ip and ip ~= "0.0.0.0"
    end
    return false
end

local function mqtt_event_loop()
    local last_status = nil
    sys.subscribe("NET_STATUS", function(status)
        last_status = status
        sys.publish("MQTT_NET_EVENT")  -- 唤醒本监听协程
    end)

    -- 开机时若 WiFi 已就绪 (NET_STATUS 事件可能已发过), 直接触发
    if sta_ready() then
        last_status = "connected"
        sys.publish("MQTT_NET_EVENT")
    end

    while true do
        sys.waitUntil("MQTT_NET_EVENT")
        local status = last_status
        last_status = nil

        if status == "connected" then
            -- WiFi 就绪, 启动 MQTT 连接协程 (防重入, mqtt_en 由连接协程内部检查)
            if not mqtt_connecting then
                log.info("MQTT", "WiFi 已就绪, 启动 MQTT 连接")
                mqtt_connecting = true
                sys.taskInit(function()
                    mqtt_connect_task()
                    mqtt_connecting = false
                end)
            end
        elseif status == "failed" then
            -- WiFi 失败, 断开 MQTT (连接协程内部会检测到并进入重连循环)
            if mqtt_connected and mqtt_client then
                log.warn("MQTT", "WiFi 失败, 断开 MQTT")
                mqtt_client:close()
                mqtt_client = nil
                mqtt_connected = false
                app_data.update_mqtt(false, "", 0)
            end
        end
    end
end

-- ========== 构造 telemetry 上报数据 ==========
local function build_telemetry()
    -- 获取完整上报数据（sys/gnss/sensor/alarm 等，按开关过滤）
    local report = app_data.get_report_data()
    -- WiFi 信号强度
    local rssi = 0
    local ok, info = pcall(wlan.getInfo)
    if ok and info and type(info.rssi) == "number" then
        rssi = info.rssi
    end
    report.rssi = rssi
    -- 设备模式
    report.mode = "monitor"
    return report
end

-- ========== 定时上报协程 ==========
local function mqtt_publish_task()
    while true do
        -- 检查开关和连接状态
        if app_data.get_config("mqtt_en") and mqtt_connected and mqtt_client then
            local report = build_telemetry()
            local ok, json_str = pcall(json.encode, report)
            if ok and json_str then
                local pub_ok = mqtt_client:publish(TOPIC_TELEMETRY, json_str, 1)
                if pub_ok then
                    app_data.update_mqtt_pub_time()
                    log.debug("MQTT", "上报成功, 主题:", TOPIC_TELEMETRY, "长度:", #json_str)
                else
                    log.warn("MQTT", "上报失败")
                end
            else
                log.warn("MQTT", "JSON 编码失败:", tostring(json_str))
            end

            -- 按配置间隔上报
            local interval = app_data.get_config("report_interval") or 2
            sys.wait(interval * 1000)
        else
            -- 开关关闭或未连接，等待后重试
            sys.wait(1000)
        end
    end
end

-- ========== 启动 ==========
function mod_mqtt.start()
    -- 常驻事件监听: 等 WiFi 就绪后启动 MQTT 连接 (替代直接启动 mqtt_connect_task)
    sys.taskInit(mqtt_event_loop)
    sys.taskInit(mqtt_publish_task)  -- 启动定时上报协程

    -- 订阅报警触发事件（由 app_data.update_alarm 广播）
    sys.subscribe("ALARM_TRIGGER", function(source, level, detail)
        sys.taskInit(function()
            if mqtt_connected then
                local event_data = {
                    source = source,
                    level = level,
                }
                -- 合并报警详情（如 IMS 的毒剂名称、PID 的浓度值）
                if type(detail) == "table" then
                    for k, v in pairs(detail) do
                        event_data[k] = v
                    end
                end
                mod_mqtt.publish_event("alarm", event_data)
            end
        end)
    end)

    -- 订阅报警清除事件（由 app_data.clear_alarm 广播）
    sys.subscribe("ALARM_CLEAR", function(source)
        sys.taskInit(function()
            if mqtt_connected then
                mod_mqtt.publish_event("clear", {
                    source = source,
                })
            end
        end)
    end)

    log.info("MQTT", "MQTT 模块已启动, 开关状态:", app_data.get_config("mqtt_en"))
end

-- ========== 对外接口 ==========
-- 发布事件消息（如跌倒告警）
-- 发布报警事件到 chem/events/{device_id} 主题
-- @param event_type 事件类型 ("alarm"/"clear"/"fall")
-- @param data 事件数据表
function mod_mqtt.publish_event(event_type, data)
    if not mqtt_connected or not mqtt_client then
        log.warn("MQTT", "未连接, 无法发布事件")
        return false
    end

    local payload = json.encode({
        type      = event_type,
        data      = data,
        device_id = app_data.get().sys.device_id or "",
        timestamp = os.time() * 1000,
    })
    local ok = mqtt_client:publish(TOPIC_EVENTS, payload, 1)
    if ok then
        log.info("MQTT", "报警事件已发布:", event_type, "主题:", TOPIC_EVENTS)
    else
        log.warn("MQTT", "报警事件发布失败:", event_type)
    end
    return ok
end

-- 请求重连（断开旧连接，连接新地址）
-- 由 mod_screen_mqtt 拉取新地址后调用
function mod_mqtt.reconnect()
    reconnect_request = true
    connect_failed = false  -- 重置失败标志
    sys.publish("MQTT_RETRY")  -- 唤醒可能卡在等待的协程
    -- 断开旧连接（无论是否已连接）
    mqtt_connected = false
    if mqtt_client then
        log.info("MQTT", "reconnect: 断开旧连接")
        mqtt_client:close()
    end
    app_data.update_mqtt(false, "", 0)
end

-- 获取连接状态
function mod_mqtt.is_connected()
    return mqtt_connected
end

-- ========== 注册回调（星型架构：供 mod_screen_mqtt 调用） ==========
app_data.register_callback("mqtt_api", {
    reconnect = mod_mqtt.reconnect,
})

return mod_mqtt
