#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
@module  mqtt_location_sim
@brief   MQTT 位置快照模拟服务器 (测试设备端 chem/notify 快照解析)

功能:
  1. 连接 MQTT Broker 192.168.5.98:1883
  2. 订阅 chem/# 观察设备上报 (telemetry/events)
  3. 每 5 秒向 chem/notify (设备端群发主题, mod_mqtt.lua TOPIC_NOTIFY_ALL)
     发布一帧全量位置快照, 格式与设备端约定的 type=locations 一致
  4. 固定 8 台设备, 每帧随机选取 N 台在线 (未选取的即"下线",
     用于测试设备端"快照缺席即下线"的全量重建逻辑)
  5. 坐标围绕 (22.614, 113.837) 随机游走徘徊, 模拟设备缓慢移动

依赖:
  pip install paho-mqtt

运行:
  python mqtt_location_sim.py

注意:
  设备端订阅的是不带前导斜杠的主题 (chem/notify), 本脚本发布到
  chem/notify 才能被设备收到; 带前导斜杠的 /chem/notify 是不同的主题。

🤖 整体或部分由 opencode 生成
"""

import json
import random
import sys
import time

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("缺少依赖, 请先执行: pip install paho-mqtt")
    sys.exit(1)

# ========== 配置 ==========
BROKER = "192.168.5.98"
PORT = 1883
INTERVAL = 5                                      # 发送间隔 (秒)
TOPIC_PUB = "chem/864793080139046/notify"         # 设备端群发主题 (与 mod_mqtt.lua 一致, 无前导斜杠)
TOPIC_SUB = "chem/#"                              # 观察设备上报的所有 chem 主题

# 固定 8 台设备 IMEI
DEVICE_IDS = [
    "860000012345678",
    "860000012345679",
    "860000012345680",
    "860000012345681",
    "860000012345682",
    "860000012345683",
    "860000012345684",
    "860000012345685",
]

# 徘徊中心与范围
CENTER_LAT = 22.614
CENTER_LNG = 113.837
WANDER_RADIUS = 0.002             # 徘徊半径约 ±200m
STEP = 0.0002                     # 每帧随机游走步长约 20m

# 每台设备独立的随机游走位置状态
_positions = {
    dev_id: {
        "lat": CENTER_LAT + random.uniform(-WANDER_RADIUS, WANDER_RADIUS),
        "lng": CENTER_LNG + random.uniform(-WANDER_RADIUS, WANDER_RADIUS),
    }
    for dev_id in DEVICE_IDS
}


def on_connect(client, userdata, flags, rc, properties=None):
    """连接回调 (兼容 paho-mqtt 1.x / 2.x)"""
    ok = (rc == 0) or getattr(rc, "is_success", False)
    if ok:
        print("已连接 MQTT %s:%d" % (BROKER, PORT))
        client.subscribe(TOPIC_SUB)
        print("已订阅 %s (观察设备上报)" % TOPIC_SUB)
    else:
        print("连接失败 rc=%s" % rc)


def on_disconnect(client, userdata, rc, properties=None):
    print("连接断开 rc=%s, 等待自动重连..." % rc)


def on_message(client, userdata, msg):
    """观察设备上报的遥测/事件消息"""
    payload = msg.payload.decode("utf-8", "replace")
    if len(payload) > 200:
        payload = payload[:200] + "..."
    print("[收] %s: %s" % (msg.topic, payload))


def make_frame():
    """生成一帧全量位置快照 (随机数量的设备, 坐标随机游走)"""
    n = random.randint(1, len(DEVICE_IDS))
    online = random.sample(DEVICE_IDS, n)

    devices = []
    for dev_id in online:
        p = _positions[dev_id]
        # 随机游走一步, 并夹紧在徘徊范围内
        p["lat"] = min(max(p["lat"] + random.uniform(-STEP, STEP),
                           CENTER_LAT - WANDER_RADIUS), CENTER_LAT + WANDER_RADIUS)
        p["lng"] = min(max(p["lng"] + random.uniform(-STEP, STEP),
                           CENTER_LNG - WANDER_RADIUS), CENTER_LNG + WANDER_RADIUS)
        devices.append({
            "device_id": dev_id,
            "lat": round(p["lat"], 5),
            "lng": round(p["lng"], 5),
        })

    return {
        "type": "locations",
        "timestamp": int(time.time()),
        "devices": devices,
    }


def publish_frame(client):
    frame = make_frame()
    payload = json.dumps(frame, separators=(",", ":"))
    info = client.publish(TOPIC_PUB, payload, qos=1)
    if info.rc == mqtt.MQTT_ERR_SUCCESS:
        print("[发] %s (%d 台在线): %s" % (TOPIC_PUB, len(frame["devices"]), payload))
    else:
        print("[发] 失败 rc=%s" % info.rc)


def create_client():
    """创建客户端, 兼容 paho-mqtt 1.x / 2.x 回调 API"""
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    except (AttributeError, TypeError):
        client = mqtt.Client()
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    return client


def main():
    client = create_client()
    client.loop_start()

    # 带重试的首次连接
    while True:
        try:
            client.connect(BROKER, PORT, keepalive=60)
            break
        except Exception as e:
            print("连接 %s 失败: %s, 5 秒后重试..." % (BROKER, e))
            time.sleep(5)

    print("开始发送位置快照, 每 %d 秒一帧, Ctrl+C 退出" % INTERVAL)
    try:
        while True:
            publish_frame(client)
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        print("\n已退出")
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()