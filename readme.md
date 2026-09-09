# Safex Air8000 物联网数据采集与上报系统

> 基于 Air8000 模块，为 Safex 便携式化学毒气检测仪提供 4G 通信、定位、蓝牙扫描、跌倒检测及 MQTT 数据上报功能。

## 项目概述

本系统运行在 Air8000 模块上，采用分层架构，各功能模块独立运行，通过数据中心（`app_data`）统一管理数据。支持 4G 蜂窝网络通信、WiFi AP/STA 双模式、USB 网卡（RNDIS/ECM）三种联网方式，并提供 OTA 固件升级功能。

### 核心功能

| 功能 | 模块 | 状态 |
|------|------|------|
| 看门狗防死机 | `mod_wdt` | ✅ 已完成 |
| UART1 数据收发 | `app_data` | ✅ 已完成 |
| 跌倒检测 | `mod_gsensor` | ✅ 已完成 |
| BLE 蓝牙扫描 | `mod_ble` | ✅ 已完成 |
| GNSS 卫星定位 | `mod_gnss` | ✅ 已完成 |
| MQTT 数据上报 (4G) | `mod_mqtt` | ✅ 已完成 |
| OTA 固件升级 | `mod_ota` | ✅ 已完成 |
| 网络模式管理 | `mod_net` | ✅ 已完成 |
| LED 指示灯 ×3 | `mod_led` | ✅ 已完成 |
| 蜂鸣器控制 | `mod_buzzer` | ✅ 已完成 |
| 按键输入 ×3 | `mod_key` | ✅ 已完成 |
| PID 光离子化传感器 | `mod_pid` | ✅ 已完成 |
| 电池电压监控 | `mod_battery` | ✅ 已完成 |
| IMS 离子迁移谱 | `mod_ims` | ✅ 已完成 |
| 报警管理器 | `mod_alarm` | ✅ 已完成 |
| 传感器调度器 | `mod_sensor` | ✅ 已完成 |
| Flash 存储 | `mod_flash` | ✅ 已完成 |
| X5 陶晶池串口屏 | `mod_screen` | ✅ 已完成 |
| 屏幕 OTA + 文件透传 | `mod_screen_ota` | ✅ 已完成 |
| 屏幕地图显示 | `mod_screen_map` | ✅ 已完成 |
| 屏幕 IMS 界面 | `mod_screen_ims` | ✅ 已完成 |
| 屏幕 MQTT 设置界面 | `mod_screen_mqtt` | ✅ 已完成 |

### 已移除模块

| 模块 | 移除原因 |
|------|---------|
| `mod_lcd` | 改用 UART 串口屏，不再需要 QSPI LCD 驱动 |
| `mod_pump` | 泵控制由 IMS 模块管理 |
| `mod_mos` | MOS 传感器不再使用 |
| `mod_sht30` | SHT30 温湿度传感器不再使用 |

### 功能开关

所有功能可通过 UART1 指令动态开关，关闭后对应数据不上报：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `ble_en` | true | BLE 蓝牙扫描 |
| `gnss_en` | false | GNSS 定位 |
| `gsensor_en` | false | G-sensor 跌倒检测 |
| `mqtt_en` | false | MQTT 通信 |
| `report_interval` | 2 | MQTT 上报间隔（秒） |
| `ota_en` | true | OTA 升级 + 网络模式管理 |
| `ota_url` | "" | OTA 服务器地址 |
| `ap_ssid` | "Enboso" | WiFi AP 热点名称 |
| `ap_password` | "enboso334968" | WiFi AP 热点密码 |
| `sta_ssid` | "" | WiFi STA 模式路由器名称 |
| `sta_password` | "" | WiFi STA 模式路由器密码 |
| `net_mode` | "ap" | 网络模式：ap/sta |
| `mqtt_server` | `"49.235.138.220"` | MQTT 服务器地址（空则不连接） |
| `mqtt_port` | 1883 | MQTT 服务器端口 |
| `mqtt_user` | `""` | MQTT 用户名（空=匿名连接） |
| `mqtt_password` | `""` | MQTT 密码（空=无密码） |
| `mqtt_client_id` | `""` | MQTT ClientID（空=自动生成 `safex_<IMEI>`） |
| `mqtt_qos` | 0 | MQTT 上报 QoS 等级 (0/1/2) |
| `sensor_pid_en` | false | PID 光离子化传感器 |
| `sensor_ims_en` | false | IMS 离子迁移谱 |
| `sensor_battery_en` | false | 电池电压监控 |
| `sensor_report_en` | false | 传感器数据上报 |
| `led_en` | false | LED 指示灯 |
| `buzzer_en` | false | 蜂鸣器 |
| `screen_en` | true | 串口屏 (UART11) |
| `flash_en` | false | Flash 存储 |
| `key_en` | true | 按键输入 |

### 网络模式

设备支持三种网络模式，通过屏幕选择或串口指令切换：

| 模式 | 说明 | OTA 访问方式 |
|------|------|-------------|
| `ap` | WiFi 热点模式（默认） | 手机连接热点，访问 `http://192.168.4.1` |
| `sta` | WiFi STA 模式 | 同一 WiFi 下设备访问设备 IP |
| `off` | WiFi 关闭 | 无 OTA 访问 |

> **蓝牙独立运行**：蓝牙模块（MY-BT503）通过 UART1 通信，与 WiFi 独立运行，不占用 Air8000 射频资源，WiFi 和蓝牙可同时工作。

切换方式：
```
通过屏幕命令码切换 WiFi/BLE 模式：
printh 70 10 FF FF FF    WiFi 关闭
printh 70 11 FF FF FF    WiFi STA 模式
printh 70 12 FF FF FF    WiFi AP 模式
printh 70 13 FF FF FF    蓝牙开启
printh 70 14 FF FF FF    蓝牙关闭
```


切换为**热切换**，无需重启。

### 网页功能

通过 OTA 网页可执行以下操作：

| 功能 | 说明 | 文件格式 |
|------|------|----------|
| Air8000 固件 OTA | 升级 Air8000 主控固件（与屏幕无关） | `.bin` (LuatOS FOTA) |
| 屏幕固件 OTA | 升级 X5 陶晶池串口屏固件 | `.tft` (TJC whmi-wri 协议) |
| 文件透传 | 传输地图等资源文件到屏幕 SD 卡 | `.ebs` (MyZip 压缩包) |

> **互斥锁**：以上三种传输操作同时只能进行一个。通过 `transfer_lock` 机制实现互斥，正在进行某操作时，其他操作的 begin 请求会返回 409 错误。

#### 屏幕固件 OTA

- 协议：TJC `whmi-wri` 下载协议
- 通信/下载波特率：固定 115200（Air8000 UART11 硬件限制）
- HTTP 分块传输：默认 16KB，根据设备空余内存动态调整（8KB~64KB）
- Air8000 内部拆分为 4KB 子块发送（TJC 协议要求）
- 使用 zbuff + uart.tx() DMA 发送，提高效率
- 支持中途取消，立即停止传输

#### 文件透传

主要用于向屏幕 SD 卡传输地图等资源文件：

- 协议：TJC `twfile` 透传协议
- 支持 `.ebs` 压缩包批量传输（使用 `other/custom_archive_tool.html` 打包）
- 浏览器端解析 .ebs 格式 + RLE 解压，逐个传输到 SD 卡根目录 (sd0/)
- 每包 1024 字节，支持失败重发（0x04 重发，最多 10 次）
- 响应码：0xFE 就绪 / 0x05 包成功 / 0x04 包失败 / 0xFD 完成 / 0x06 创建失败

#### 网页优化

- HTML 文件 gzip 压缩（55KB → 10KB），减少 TCP 传输时间
- 开机预读 HTML 到内存缓存，首次访问无需读 flash
- 轮询间隔自适应：根据分块大小动态计算
- `/sysinfo` 返回空余内存，网页据此动态调整分块大小

## 硬件要求

- Air8000 模块（合宙）
- SIM 卡（4G 网络 + MQTT）
- GPS 天线（GNSS 定位）
- 加速度传感器（板载 exvib）
- X5 陶晶池串口屏（UART11, pin 48/49）

## 通信协议

Air8000 通过以下接口与外部通信：

| 接口 | 用途 |
|------|------|
| UART1 | 蓝牙模块通信 (MY-BT503) |
| UART11 | TJC 串口屏 (115200, 二进制命令码) |
| UART12 | IMS 离子迁移谱 |
| MQTT | 4G 联网远程通信 |
| HTTP | OTA 固件升级 + 文件传输 |

> UART1 用于蓝牙模块通信。

- 详细协议文档：[通信协议文档.md](docs/通信协议文档.md)
- 传感器规格：[传感器及外设规格.md](docs/传感器及外设规格.md)
- 引脚映射：[引脚定义文档.md](docs/引脚定义文档.md)
- 移植规格：[传感器移植规格.md](docs/传感器移植规格.md)
- 软件规格：[软件规格说明书.md](docs/软件规格说明书.md)
- 核心板接线：[核心板引脚对照表.md](docs/核心板引脚对照表.md)
- 多设备组网：[多设备组网与训练模式.md](docs/多设备组网与训练模式.md)
- 化学污染热力图：[化学污染浓度热力图.md](docs/化学污染浓度热力图.md)

## 使用方法

1. 使用 Luatools 工具将 `main/` 目录下所有文件烧录到 Air8000
2. 打开串口调试工具（115200, 8N1）查看日志
3. 通过屏幕命令码或 MQTT 控制功能开关或查询数据

### 快速测试指令

```
屏幕命令码（TJC printh 指令）：
printh 70 00 FF FF FF    推送全部数据
printh 70 01 FF FF FF    推送系统信息
printh 70 02 FF FF FF    推送传感器数据
printh 70 09 FF FF FF    推送配置状态
printh 70 0D FF FF FF    推送 MQTT 配置和状态
printh 70 22 FF FF FF    蜂鸣器响/停 toggle
printh 70 23 FF FF FF    MQTT 开关 toggle

MQTT 设置（TJC prints 指令，配合 printh 70 + printh FF FF FF）：
prints "SET_MQTT_SERVER 49.235.138.220"
prints "SET_MQTT_PORT 1883"
prints "SET_MQTT_USER admin"
prints "SET_MQTT_PASS mypassword"
prints "SET_MQTT_EN 1"
```

## 文件结构

```
safex_lua_code/
├── main/                        # 项目源码目录
│   ├── main.lua                 # 主程序入口
│   ├── mod_wdt.lua              # 看门狗模块
│   ├── app_data.lua             # 数据中心（统一数据 + UART1 收发）
│   ├── mod_gsensor.lua          # G-sensor + 跌倒检测
│   ├── mod_ble.lua              # BLE 蓝牙扫描
│   ├── mod_gnss.lua             # GNSS 卫星定位
│   ├── mod_mqtt.lua             # MQTT 通信（4G 联网 + MQTT 收发）
│   ├── mod_ota.lua              # OTA 固件升级（HTTP 路由 + FOTA）
│   ├── mod_net.lua              # 网络模式管理（WiFi AP/STA + 热切换）
│   ├── mod_led.lua              # LED 指示灯 ×3
│   ├── mod_buzzer.lua           # 蜂鸣器控制
│   ├── mod_key.lua              # 按键输入 ×3
│   ├── mod_pid.lua              # PID 光离子化传感器（ADC0）
│   ├── mod_battery.lua          # 电池电压监控（ADC2）
│   ├── mod_ims.lua              # IMS 离子迁移谱（UART12）
│   ├── mod_alarm.lua            # 报警管理器
│   ├── mod_sensor.lua           # 传感器管理器
│   ├── mod_flash.lua            # Flash 存储（SPI1 NAND）
│   ├── mod_screen.lua           # X5 陶晶池串口屏（UART11 TJC 协议 + 请求-响应）
│   ├── mod_screen_ota.lua       # 屏幕 OTA 固件升级 + 文件透传（whmi-wri / twfile）
│   ├── mod_screen_map.lua       # 屏幕地图显示（离线瓦片地图）
│   ├── mod_screen_ims.lua       # 屏幕 IMS 界面（IMS 数据推送 + 按钮事件）
│   ├── mod_screen_mqtt.lua      # 屏幕 MQTT 设置界面（配置推送 + SET 指令）
│   ├── web/
│   │   ├── ota.html             # OTA 升级网页（gzip 压缩后烧录）
│   │   └── ota.html.gz         # gzip 压缩版（烧录到 /luadb/）
│   └── ...
├── docs/                        # 项目文档
│   ├── 软件规格说明书.md          # 软件规格说明书 (SRS)
│   ├── 传感器及外设规格.md        # 传感器及外设规格
│   ├── 引脚定义文档.md            # 引脚映射文档
│   ├── 核心板引脚对照表.md        # 核心板接线文档
│   ├── 传感器移植规格.md          # 移植规格文档
│   ├── 通信协议文档.md           # 串口通信协议文档
│   ├── Flash存储规格.md           # Flash 存储规格
│   ├── 屏幕地图开发文档.md        # 屏幕地图显示
│   ├── 多设备组网与训练模式.md    # 组网与训练模式
│   ├── 化学污染浓度热力图.md      # 热力图方案（指挥官集中计算）
│   └── pins_air8000.json        # Air8000 引脚定义
├── other/
│   └── custom_archive_tool.html # .ebs 压缩包打包工具（MyZip 格式）
├── AGENTS.md                    # AI 开发规范
└── readme.md                    # 本文件
```

## 架构设计

```
┌────────────────────────────────────────────────────┐
│                    main.lua                         │
│               （入口 + 模块加载）                    │
├──────┬──────┬──────┬──────┬──────┬──────┬──────┬────┤
│mod_  │mod_  │mod_  │mod_  │mod_  │mod_  │mod_  │mod_ │
│wdt   │gsensor│ble  │gnss  │mqtt  │ota   │pid   │battery│
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼────┤
│mod_  │mod_  │mod_  │mod_  │mod_  │mod_  │mod_  │
│ims   │alarm │sensor│flash │screen│led   │buzzer│key  │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┴─────┤
│      │      │      │      │      │      │           │
│      ▼      ▼      ▼      ▼      ▼      ▼           ▼
┌──────────────────────────────────────────────────────┐
│                   app_data.lua                       │
│            数据中心（统一数据 + UART1 收发）          │
├──────────────────────────────────────────────────────┤
│  data.config │ data.ble │ data.gnss │ data.gsensor   │
│  data.sensor │ data.alarm │ data.io │ data.mqtt      │
│  data.ota    │ data.sys                               │
├──────────────────────────────────────────────────────┤
│               屏幕命令码 (UART11) + MQTT (4G)        │
└──────────────────────────────────────────────────────┘
```

### 星型架构规则

- 各模块只与 `app_data` 交互，模块间禁止直接 `require`
- 数据交换通过 `app_data.get()`（只读代理）/ `app_data.update_xxx()`（写入）
- 模块间功能调用通过 `app_data.register_callback()` / `get_callback()` 中介
- 模块联动通过 `sys.publish()` 事件广播（如 `NET_MODE_CHANGE`）

```
✅ mod_gsensor → app_data.update_gsensor()          （数据写入）
✅ mod_ota → app_data.get_callback("screen_ota")     （功能调用）
❌ mod_ota → require "mod_screen"                    （禁止直接依赖）
```

## LuatOS API 参考

| 功能 | 库 |
|------|------|
| 协程调度 | `sys`（sys.taskInit / sys.wait / sys.timerStart） |
| 串口通信 | `uart` |
| 看门狗 | `wdt` |
| 4G 网络 | `mobile` |
| GNSS 定位 | `exgnss` |
| BLE 蓝牙 | `bluetooth` |
| G-sensor | `exvib` |
| ADC 采集 | `adc`（PID/电池） |
| GPIO 控制 | `gpio`（LED/蜂鸣器/按键） |
| WiFi AP/STA | `wlan`（createAP / connect / setMode） |
| USB 网卡 | `mobile.config(CONF_USB_ETHERNET)` |
| HTTP 服务器 | `httpsrv` |
| DHCP 服务器 | `dhcpsrv` |
| 网络驱动 | `netdrv`（ipv4 / ready） |
| JSON 编解码 | `json` |
| MQTT | `mqtt` |
| KV 存储 | `fskv`（配置持久化） |
| FOTA 升级 | `fota` |
