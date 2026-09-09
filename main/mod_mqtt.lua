--[[
@module  mod_mqtt
@brief   MQTT 通信模块（4G 联网 + MQTT 连接/上报/下行）

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

-- 主题前缀（使用 IMEI）
local TOPIC_PREFIX = ""

-- ========== 初始化 ==========
function mod_mqtt.init()
    TOPIC_PREFIX = "safex/" .. (app_data.get().sys.device_id or "unknown")
    log.info("MQTT", "模块初始化, 主题前缀:", TOPIC_PREFIX)
end

-- ========== MQTT 事件回调 ==========
local function mqtt_event_cb(client, event, data, payload, metas)
    -- 连接成功
    if event == "conack" then
        mqtt_connected = true
        mqtt_connect_done = true
        mqtt_connect_success = true
        log.info("MQTT", "连接成功")
        -- 订阅下行主题
        client:subscribe(TOPIC_PREFIX .. "/down", 1)
        client:subscribe(TOPIC_PREFIX .. "/config", 1)
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
        log.info("MQTT", "收到下行:", data, "长度:", payload and #payload or 0)
        -- 保存到 app_data
        app_data.update_mqtt_sub_data(payload)
        -- 发布消息供其他模块处理（可选）
        sys.publish("MQTT_RECV", data, payload)

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
    -- 等待 4G 网络就绪（最多 10 次重试，失败后跳过）
    local net_retry = 0
    while not socket.adapter(socket.dft()) do
        net_retry = net_retry + 1
        if net_retry > 10 then
            log.warn("MQTT", "4G 网络等待超时(10次), 跳过 MQTT 连接")
            return
        end
        log.info("MQTT", "等待 4G 网络就绪... (" .. net_retry .. "/10)")
        sys.waitUntil("IP_READY", 1000)
    end
    -- 多等 1 秒确保网络栈完全就绪
    sys.wait(1000)
    log.info("MQTT", "4G 网络已就绪, 准备连接 MQTT")

    -- 4G 网络连通性测试（HTTP 请求）
    log.info("MQTT", "网络连通性测试...")
    local code, _, body = http.request("GET", "http://www.baidu.com", nil, nil, {timeout=5000}).wait()
    log.info("MQTT", "HTTP 测试结果:", code, body and #body or 0)

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
            sys.wait(2000)
        else
            -- 重新读取配置（支持运行时修改服务器地址）
            local server = app_data.get_config("mqtt_server") or ""
            local port = app_data.get_config("mqtt_port") or 1883

            -- 服务器地址为空时跳过连接，等待用户通过屏幕或 MQTT 配置
            if server == "" then
                log.warn("MQTT", "mqtt_server 为空, 请通过屏幕或 MQTT 配置: mqtt_server=xxx")
                sys.wait(3000)
                goto continue
            end

            local client_id = "safex_" .. (app_data.get().sys.device_id or "unknown")

            log.info("MQTT", "正在连接:", server, port, "client_id:", client_id)

            -- 重置连接结果标志
            mqtt_connect_done = false
            mqtt_connect_success = false

            -- 使用默认网卡（4G）
            mqtt_client = mqtt.create(nil, server, port)
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
                    while not mqtt_connect_done and wait_ms < 15000 do
                        sys.wait(100)
                        wait_ms = wait_ms + 100
                    end

                    if mqtt_connect_success then
                        -- MQTT 连接成功，进入保持循环（同时检查开关）
                        log.info("MQTT", "连接已建立, 进入保持循环")
                        while mqtt_connected do
                            if not app_data.get_config("mqtt_en") then
                                log.info("MQTT", "运行中检测到开关关闭, 主动断开")
                                break
                            end
                            sys.wait(1000)
                        end
                        log.warn("MQTT", "连接已断开, 准备重连")
                    elseif not mqtt_connect_done then
                        log.error("MQTT", "连接超时(15秒无响应)")
                    else
                        log.error("MQTT", "MQTT 握手失败")
                    end
                else
                    log.error("MQTT", "TCP 连接启动失败, 5秒后重试")
                end
            else
                log.error("MQTT", "创建客户端失败")
            end

            -- 清理
            if mqtt_client then
                mqtt_client:close()
                mqtt_client = nil
            end
            log.info("MQTT", "5秒后重连...")
            sys.wait(5000)
        end
        ::continue::
    end
end

-- ========== 定时上报协程 ==========
local function mqtt_publish_task()
    while true do
        -- 检查开关和连接状态
        if app_data.get_config("mqtt_en") and mqtt_connected and mqtt_client then
            -- 获取上报数据
            local report = app_data.get_report_data()
            local ok, json_str = pcall(json.encode, report)
            if ok and json_str then
                local pub_ok = mqtt_client:publish(TOPIC_PREFIX .. "/up", json_str, 0)
                if pub_ok then
                    app_data.update_mqtt_pub_time()
                    log.debug("MQTT", "上报成功, 长度:", #json_str)
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
    -- 始终启动协程，由协程内部检查 mqtt_en 开关
    -- 这样运行时通过 CFG 指令开关 MQTT 都能即时生效
    sys.taskInit(mqtt_connect_task)
    -- sys.taskInit(mqtt_publish_task)

    log.info("MQTT", "MQTT 模块已启动, 开关状态:", app_data.get_config("mqtt_en"))
end

-- ========== 对外接口 ==========
-- 发布事件消息（如跌倒告警）
function mod_mqtt.publish_event(event_type, data)
    if not mqtt_connected or not mqtt_client then
        log.warn("MQTT", "未连接, 无法发布事件")
        return false
    end

    local payload = json.encode({
        type = event_type,
        data = data,
        timestamp = os.time(),
    })
    local ok = mqtt_client:publish(TOPIC_PREFIX .. "/event", payload, 1)
    if ok then
        log.info("MQTT", "事件已发布:", event_type)
    else
        log.warn("MQTT", "事件发布失败:", event_type)
    end
    return ok
end

-- 获取连接状态
function mod_mqtt.is_connected()
    return mqtt_connected
end

return mod_mqtt
