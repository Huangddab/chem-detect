# AGENTS.md - Safex Air8000 Lua 开发规范

## 项目概述
- **项目名称**: Safex 便携式化学毒气检测仪 — Air8000 通信模块
- **平台**: Air8000（LuatOS，Lua 5.3）
- **主控对端**: 外部蓝牙模块 MY-BT503（通过 UART1 通信）
- **工具链**: Luatools 烧录
- **通信接口**: UART1（蓝牙模块通信）、UART11（TJC 串口屏）、UART12（IMS）
- **核心文件**: `app_data.lua`（数据中心）

### 官方代码库

项目根目录下的 `LuatOS-master/` 是 **LuatOS 官方源码库**，包含底层库实现、demo 示例和 API 文档。

**查找 API 用法时，优先在 `LuatOS-master/` 中搜索，不要去网络上搜索。**

| 目录 | 内容 |
|------|------|
| `LuatOS-master/script/libs/` | 扩展库 Lua 源码（如 `exgnss.lua`、`libgnss` 等） |
| `LuatOS-master/testcase/` | 官方单元测试（API 用法最佳参考） |
| `LuatOS-master/olddemo/` | 旧版 demo 示例 |
| `LuatOS-master/module/` | 模块示例工程 |

示例：查找 `libgnss.getRmc()` 的用法和返回值结构
```
LuatOS-master/testcase/unit_testcase_tools/libgnss/scripts/libgnss_test.lua  — 官方测试代码
LuatOS-master/script/libs/exgnss.lua  — exgnss 封装了 libgnss，含完整注释
```

---

## 版本号管理

### 版本格式
```
主版本.次版本.补丁号
示例: 1.0.0
```

### 何时递增

| 变更类型 | 递增方式 | 示例 |
|---------|---------|------|
| 新增功能模块 | 次版本 +1 | 1.0.0 -> 1.1.0 |
| 协议变更 | 次版本 +1 | 1.1.0 -> 1.2.0 |
| Bug 修复 | 补丁号 +1 | 1.2.0 -> 1.2.1 |
| 架构重新设计 | 主版本 +1 | 1.2.1 -> 2.0.0 |

### 如何更新

编辑 `main.lua` 中的 `VERSION` 字段：

```lua
VERSION = "001.000.000"
```

---

## 编码规范

### 文件命名
- 模块文件: `mod_功能.lua`（如 `mod_wdt.lua`、`mod_ble.lua`）
- 应用文件: `app_功能.lua`（如 `app_data.lua`）
- 文档文件: `功能.md`（如 `通信协议文档.md`）
- 全小写加下划线

### 函数命名
- 模块接口: `模块.动作()`（如 `app_data.update_gnss()`）
- 内部函数: `local function 动作()` 或 `local function 模块_动作()`
- 全小写加下划线

### 变量命名
| 类型 | 规范 | 示例 |
|------|------|------|
| 模块本地变量 | `local` + 小写 | `local rx_buffer = ""` |
| 常量 | 全大写加下划线 | `local UART_BAUD = 115200` |
| 数据表字段 | 小写加下划线 | `data.ble.count`、`data.config.ota_en` |

### 注释风格
- 文件头: `--[[ @module 名称 @summary 描述 ]]`
- 函数: 函数上方 `-- 说明`
- 行内: `-- 注释`

### 缩进
- 4 个空格，不使用 Tab

---

## 功能开关系统

所有功能通过 `app_data.config` 表控制：

```lua
config = {
    ble_en         = false,
    gnss_en        = false,
    gsensor_en     = false,
    mqtt_en        = false,
    report_interval = 2,
    ota_en         = true,
    ota_url        = "",
    ap_ssid        = "Enboso",
    ap_password    = "enboso334968",
    sta_ssid       = "",
    sta_password   = "",
    net_mode       = "ap",
    mqtt_server    = "",
    mqtt_port      = 1883,
    sensor_pid_en  = false,
    sensor_ims_en  = false,
    sensor_battery_en = false,
    sensor_report_en  = false,
    led_en         = false,
    buzzer_en      = false,
    screen_en      = true,
    flash_en       = false,
}
```

### 功能开关规则
1. 每个功能模块必须有对应的开关字段
2. 模块代码必须检查开关状态，关闭时停止采集/处理
3. 功能关闭后，对应数据**不出现在上报 JSON 中**
4. 开关可通过屏幕命令码或 MQTT 动态修改

### 上报过滤逻辑
- `sys` 和 `config`：始终上报
- `ble`/`gnss`/`gsensor`/`mqtt`/`led`：仅对应开关开启时上报
- `ota`：`ota_en=true` 或 `state != "idle"` 时上报
- `net_mode` 配置修改后通过 `sys.publish("NET_MODE_CHANGE", mode)` 广播事件，由 `mod_net` 热切换
- 配置相同时跳过 fskv 写入（节省 Flash 寿命）

---

## 文件结构规则

### 新增模块清单
新增模块 `mod_xxx` 时：
1. 创建 `mod_xxx.lua`，实现 `init()` 和 `start()` 接口
2. 在 `app_data.lua` 的 `data` 表中添加对应数据字段
3. 在 `app_data.lua` 中添加 `update_xxx()` 接口
4. 在 `main.lua` 中 `require` 并调用 `init()` + `start()`
5. 更新 `通信协议文档.md` 中的数据结构说明
6. 更新 `readme.md` 中的模块状态

### 数据更新接口
- 所有模块通过 `app_data.update_xxx()` 写入数据
- 永远不要从多个协程直接修改 `data` 表
- 使用 `app_data.set_config()` / `get_config()` 管理开关

### app_data.get() 封装规则
`app_data.get()` 返回的是**只读代理**，拦截所有写入操作：
- **哈希表**（如 `config`、`mqtt`、`sensor.pid`）：通过 metatable `__newindex` 拦截写入，**写入会抛出错误**
- **数组表**（如 `alarm.sources`、`ble.devices`）：返回拷贝，兼容 `#`、`ipairs`、`table.concat` 等 C 函数

```lua
-- ✅ 正确：只读访问
local d = app_data.get()
local temp = d.sensor.pid.conc
local names = table.concat(d.sensor.ims.alarm_names, ",")  -- 数组拷贝，正常工作

-- ❌ 写入会抛出错误：app_data.get() 返回只读数据，请使用 update_xxx() 接口写入
d.mqtt.last_pub_time = os.time()
d.sensor.pid.conc = 100

-- ✅ 正确：使用 update_xxx() 接口写入
app_data.update_mqtt_pub_time()
app_data.update_sensor("pid", { conc = 100 })
```

| 操作 | 正确方式 |
|------|----------|
| 读取数据 | `app_data.get().xxx` |
| 写入数据 | `app_data.update_xxx()` |
| 新增写入字段 | 在 `app_data.lua` 添加对应的 `update_xxx()` 接口 |

### 模块间回调机制
模块间需要**功能调用**（非数据交换）时，通过 `app_data` 回调中介，避免直接 `require`：

```lua
-- 注册方（被调用模块，如 mod_screen.lua 文件末尾）
app_data.register_callback("screen_ota", {
    begin       = mod_screen.ota_begin,
    write_chunk = mod_screen.ota_write_chunk,
    -- ...
})

-- 调用方（如 mod_ota.lua）
local api = app_data.get_callback("screen_ota")
if api then
    local ok, err = api.begin(file_size)
end
```

```
✅ 正确：mod_ota → app_data.get_callback("screen_ota") → mod_screen.ota_begin()
❌ 禁止：mod_ota → require "mod_screen" → mod_screen.ota_begin()
```

### 协程规则
- 使用 `sys.taskInit()` 创建协程
- 延时使用 `sys.wait()`，不要使用阻塞调用
- 定时器使用 `sys.timerStart()` / `sys.timerStop()`

### 耦合性规则
本项目采用星型架构，`app_data` 是中心节点，各模块只与 `app_data` 交互：

1. **模块间禁止直接调用** — `mod_ble` 不能 require `mod_gnss`，模块间互不感知
2. **数据交换通过 app_data** — 读其他模块数据用 `app_data.get().xxx`，写自己的数据用 `app_data.update_xxx()`
3. **业务逻辑放模块内** — `app_data` 只做存储，不做判断/计算（如跌倒判定放 `mod_gsensor`，不放 `app_data`）
4. **模块联动用 config 开关** — 模块间需要联动时，通过 `config` 表间接控制，不直接调用
5. **app_data 只依赖底层库** — `app_data` 不 require 任何 `mod_xxx`，避免循环依赖

```
✅ 正确：mod_gsensor → app_data.update_gsensor()
❌ 禁止：mod_gsensor → mod_mqtt.publish()  （模块间直接调用）
❌ 禁止：app_data → mod_gsensor.start()    （中心节点反向依赖模块）
❌ 禁止：mod_ota → require "mod_screen"     （用回调中介代替）
```

> **例外**：`main.lua` 作为入口可以 `require` 所有模块并调用 `init()` / `start()`。

---

## Git 提交规范

遵循 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 规范。

### 提交信息格式

```
<类型>[可选范围]: <描述> <emoji>

[可选正文]

🤖 由 opencode 生成
```

### 类型与 emoji

| 类型 | 描述 | emoji | 版本影响 |
|------|------|-------|---------|
| `feat` | 新功能 | ✨ | 次版本 +1 |
| `fix` | Bug 修复 | 🐛 | 补丁号 +1 |
| `refactor` | 代码重构 | ♻️ | 补丁号 +1 |
| `docs` | 文档修改 | 📝 | 无 |
| `chore` | 构建/工具 | 🔧 | 无 |
| `breaking` | 破坏性变更 | 💥 | 主版本 +1 |

### 范围（scope）

`wdt`、`uart`、`gsensor`、`ble`、`gnss`、`mqtt`、`ota`、`led`、`config`、`protocol`

### 示例

```
feat(gsensor): 添加跌倒检测模块 ✨

新增 mod_gsensor.lua，使用 exvib 库采集三轴加速度，
通过合加速度阈值判断跌倒事件，检测结果写入 app_data。

🤖 由 opencode 生成
```

### 提交要求

- 提交小巧、聚焦、原子化
- 每次提交必须包含 ✨
- 描述使用中文，类型和范围使用英文小写

---

## LuatOS 运行规则

### 协程调度
- `sys.run()` 之后不能有任何代码
- 协程内使用 `sys.wait()` 挂起，不使用阻塞调用
- 定时器回调在主线程执行，不要做耗时操作

### 看门狗
- Air8000 底层自动启用硬件看门狗（约 20s 超时）
- `mod_wdt.lua` 每 3 秒调用 `wdt.feed()` 喂狗
- 正常调度器运行时会自动喂底层狗，看门狗仅防系统死锁

### UART1 通信
- 接收回调中只做缓冲，不要做耗时处理
- 半包超时 2 秒，缓冲区上限 1024 字节
- 支持 `\r\n` 和 `\n` 两种换行符
- 兼容串口助手发送的字面量 `\r\n`

---

## 调试规则

### 日志级别
```lua
log.info("TAG", "信息")
log.warn("TAG", "警告")
log.debug("TAG", "调试")
log.error("TAG", "错误")
```

### 串口测试
- UART1 用于蓝牙模块通信
- 使用屏幕命令码 `printh` 指令查询数据（见 `通信协议文档.md` 第十一章）
- 使用 MQTT 查询/修改配置

### GNSS 坐标格式避坑

`libgnss.getRmc()` / `exgnss.rmc()` 的参数决定返回的坐标格式，**务必使用 `2`（十进制）**：

| 参数 | 格式 | 示例（纬度） | 示例（经度） | 用途 |
|------|------|-------------|-------------|------|
| `0` | 度分 `ddmm.mmmmm` | `2232.5860` | `11350.1690` | NMEA 原始格式，**直接当地图坐标会偏移数十公里** |
| `1` | 整数 `DDDDDDDDD` | `225431000` | `1138361500` | 整数格式（×10⁷），适合紧凑传输 |
| `2` | 十进制 `DD.DDDDDDD` | `22.54310` | `113.83615` | **推荐**，可直接用于地图查坐标 |

> **⚠ 踩坑案例**：屏幕显示用 `getRmc(0)` 返回 `11350.1690`，误读为十进制 `113.50169` 去查地图，实际位置从深圳偏移到中山（偏差 ~44km）。正确转换：`113 + 50.169/60 = 113.83615`。

**规则**：
- 所有写入 `app_data` 的经纬度必须使用 `rmc(2)` 十进制格式
- 屏幕显示坐标也必须用 `rmc(2)`，禁止用 `rmc(0)` 度分格式直接显示
- 如需度分格式（如 NMEA 转发），使用后立即转换，不要存储或显示原始值
- GPS 输出的是 WGS84 坐标系，在国内高德/百度地图上查会有 ~500m 偏移，需转 GCJ02

```lua
-- ✅ 正确：十进制格式
local rmc = exgnss.rmc(2)    -- { lat=22.54310, lng=113.83615, ... }

-- ❌ 错误：度分格式直接当地图坐标
local rmc = exgnss.rmc(0)    -- { lat=2232.5860, lng=11350.1690, ... }

-- 度分转十进制（如确需手动转换）
local function nmea_to_decimal(coord)
    local deg = math.floor(coord / 100)
    local min = coord - deg * 100
    return deg + min / 60
end
```

---

## 代码风格

- 避免不必要的复杂性，卫语句优于嵌套
- 函数只做一件事，体长不超过 50 行
- 单个 `.lua` 文件建议不超过 **500 行**，超过时按职责拆分为独立模块（如 `mod_screen` 拆出 `mod_screen_ota`，`mod_ota` 拆出 `mod_net`）
- 禁止全局变量污染，所有模块返回 `local` 表
- 禁止 `while true do end` 死循环（必须含 `sys.wait()`）
- 字符串拼接用 `..`，大量拼接考虑 table.concat

### HTTP 路由表模式
HTTP 请求处理禁止使用超长 `if/elseif` 链，必须使用路由表分发：

```lua
-- 路由表定义
local ROUTES = {
    { pattern = "/ota/begin",  handler = route_ota_begin,  method = "POST" },
    { pattern = "/ota/status", handler = route_ota_status, method = "GET" },
}

-- 分发函数（固定 8 行）
local function handle_http(fd, method, uri, headers, body)
    for _, route in ipairs(ROUTES) do
        if route.pattern == uri then
            if route.method and route.method ~= method then
                return 405, {["Content-Type"] = "text/plain"}, "Method Not Allowed"
            end
            return route.handler(method, uri, headers, body)
        end
    end
    return 404, {["Content-Type"] = "text/plain"}, "Not Found: " .. uri
end
```

- 每个 handler 函数不超过 30 行，只处理一个路由
- 新增路由只需在 `ROUTES` 表中添加一行
- 共享逻辑提取为辅助函数（如 `async_screen_task`）

### 屏幕命令码编码规则
屏幕（TJC 陶晶池串口屏）与 MCU 通信，**所有命令必须通过 `prints` 或 `printh` 发送**，MCU 不再依赖触控控件 ID 分发。推荐优先使用 `printh`（二进制命令码），计算量更小、解析更快。

```
命令码 0xXY:
  X (高4bit) = 命令类型: 0x0_=GET查询  0x1_=DIRECT_SET(二进制,无参数)  0x2_=SET设置(ASCII带参数)
  Y (低4bit) = 目标对象: 0=ALL 1=SYS 2=SENSOR 3=GNSS 4=RMC 5=GSA 6=GSV 7=FIX 8=LOC 9=CONFIG A=NET_MODE B=BLE
  注意: 0x1_ 范围为直接设置命令，低位为序号，不遵循目标对象编码
```

**GET 命令** — 屏幕端用 `printh 70 XX FF FF FF` 发送二进制命令码：

| 命令码 | printh 指令 | 说明 |
|--------|------------|------|
| `0x00` | `printh 70 00 FF FF FF` | 推送全部数据 |
| `0x01` | `printh 70 01 FF FF FF` | 推送系统信息 |
| `0x02` | `printh 70 02 FF FF FF` | 推送传感器数据 |
| `0x03` | `printh 70 03 FF FF FF` | GNSS 详情汇总 |
| `0x04~0x08` | `printh 70 04~08 FF FF FF` | GNSS 详细数据（RMC/GSA/GSV/FIX/LOC） |
| `0x09` | `printh 70 09 FF FF FF` | 推送配置状态（WiFi 模式 + 蓝牙开关） |

**DIRECT SET 命令** — 屏幕端用 `printh 70 XX FF FF FF` 发送二进制命令码（推荐，无参数固定值设置）：

| 命令码 | printh 指令 | 说明 |
|--------|------------|------|
| `0x10` | `printh 70 10 FF FF FF` | WiFi 关闭 |
| `0x11` | `printh 70 11 FF FF FF` | WiFi STA 模式（MCU 主动从屏幕 t2/t3 拉取凭据） |
| `0x12` | `printh 70 12 FF FF FF` | WiFi AP 模式 |
| `0x13` | `printh 70 13 FF FF FF` | 蓝牙开启 |
| `0x14` | `printh 70 14 FF FF FF` | 蓝牙关闭 |

> **规则**：屏幕端按钮触发事件代码中，用 `prints`/`printh` 发送对应指令，MCU 统一通过 `REQUEST_HANDLERS` 路由表处理。禁止依赖触控控件 ID 分发业务逻辑。

**STA 模式凭据拉取流程**：屏幕端只需发 `printh 70 11 FF FF FF`，MCU 收到后主动 `get t2.txt` 读取 SSID、`get t3.txt` 读取密码，自动完成 STA 连接。屏幕端需在设置页放置 `t2`（SSID 输入框）和 `t3`（密码输入框）两个文本控件。连接成功后 `t4` 显示 IP 地址和连接信息。

**新增屏幕命令时**：
1. 确定命令类型（GET/DIRECT_SET/SET）和目标对象
2. GET 命令按编码规则计算命令码，在 `REQUEST_HANDLERS` 表中注册
3. DIRECT SET 命令（无参数固定值）分配 `0x1_` 范围命令码，在 `REQUEST_HANDLERS` 表中注册
4. SET 命令（带参数）在 `REQUEST_HANDLERS` 表中注册 ASCII 指令名
5. 更新 `通信协议文档.md` 第十一章速查表
6. 屏幕端 GET/DIRECT SET 用 `printh 70 XX FF FF FF`，带参数 SET 用 `prints "指令"`（需配合 `printh 70` 前缀和 `printh FF FF FF` 结束符）
7. STA 模式优先使用 MCU 拉取方式（`0x11`），避免 `prints` 兼容性问题

**WiFi/BLE 独立运行**：蓝牙模块（MY-BT503）通过 UART1 通信，与 WiFi 独立运行，不占用 Air8000 射频资源，WiFi 和蓝牙可同时工作。配置变更后通过 `sys.publish("CONFIG_CHANGED")` 通知屏幕自动刷新。

---

## 安全与可靠性

### Flash 存储策略

外部 SPI NOR Flash (W25Q64, 8MB) 有两种操作方式，根据数据特性选择：

| 场景 | 方式 | 接口 | 特点 |
|------|------|------|------|
| 低频记录、掉电安全、多文件管理 | **VFS + LittleFS** | `io.open` / `f:seek` / `f:read` | 掉电不丢数据，自动空间管理，有写放大开销 |
| 高频写入、固定结构、不需文件系统 | **直接操作 Flash** | `dev:read(addr, len)` / `dev:write(addr, data)` / `dev:erase(addr, size)` | 速度最快，手动管理地址，掉电可能损坏 |

**判断规则**：
- 浓度日志、坐标记录、报警事件、系统日志 → 用 **VFS + LittleFS**（低频、掉电安全优先）
- 高频波形数据（如 IMS 谱图 800 点/秒、连续 ADC 采样）→ 考虑**直接操作 Flash**（绕过 VFS，固定地址写入）
- 不确定时默认用 VFS，性能不满足再切换

```lua
-- ✅ VFS 方式 (io.open, LittleFS 文件系统, 掉电安全)
local f = io.open("/flash/gps.log", "a")
f:write(line .. "\n")
f:close()

-- ✅ 直接操作 Flash (绕过 VFS, 高速写入, 手动管理地址)
local dev = lf.init(spi_device)
dev:erase(0x100000, 4096)             -- 擦除扇区 (4KB 对齐)
dev:write(0x100000, raw_data, #raw_data)  -- 写入物理地址
local data = dev:read(0x100000, 1024)     -- 读取物理地址
```

**VFS 读取优化**：读取大文件尾部数据时，禁止用 `f:lines()` 遍历整个文件（235K 行需 5 分钟），必须用 `f:seek("end")` 定位到文件尾部再读取：

```lua
-- ✅ 正确：seek 到尾部，只读最后几 KB
local size = f:seek("end")
f:seek("set", size - n * 80)  -- 每行约 40 字节, 读 n 行
local data = f:read(n * 80)

-- ❌ 错误：遍历整个文件（23 万行需 5 分钟, 可能阻塞看门狗）
for l in f:lines() do ... end
```

### 故障恢复策略
| 故障等级 | 处理方式 | 示例 |
|---------|---------|------|
| 轻微 | 记录日志，继续运行 | BLE 单次扫描失败 |
| 中等 | 重试 3 次，失败则降级 | GNSS 定位超时 |
| 严重 | 关闭模块，通知 MCU | MQTT 断连不重连 |
| 致命 | 看门狗复位 | 系统死锁 |

### UART1 通信安全
- 接收数据有 XOR 校验（可选），校验失败返回 `err,CHECKSUM`
- 缓冲区溢出保护（>1024 字节自动清空）
- 半包超时 2 秒自动丢弃
- 未知指令返回 `err,UNKNOWN_CMD`

### 传输互斥锁
固件 OTA / 屏幕 OTA / 文件传输三者**同时只能进行一个**，通过 `mod_ota.lua` 中的 `transfer_lock` 变量实现互斥：

| 锁状态 | 含义 |
|--------|------|
| `"none"` | 空闲，可以开始任一传输 |
| `"fw_ota"` | 固件 OTA 进行中 |
| `"screen_ota"` | 屏幕 OTA 进行中 |
| `"file_transfer"` | 文件传输进行中 |

```lua
-- 获取锁（begin 路由调用）
local ok, holder = acquire_transfer("fw_ota")
if not ok then
    return 409, ..., json.encode({ok = false, error = "正在进行其他传输: " .. holder})
end

-- 释放锁（cancel / finish / 失败时调用）
release_transfer()
```

#### 锁的获取与释放时机
| 操作 | 获取锁 | 释放锁 |
|------|--------|--------|
| 固件 OTA | `route_ota_begin` | `route_ota_cancel` / 失败 / 成功后重启 |
| 屏幕 OTA | `route_screen_ota_begin` | `route_screen_ota_finish` / `route_screen_ota_cancel` / 失败 |
| 文件传输 | `route_screen_file_begin` | `route_screen_file_finish` / `route_screen_file_cancel` / 失败 |

#### 异步失败自动释放
屏幕 OTA 和文件传输使用异步任务（`sys.taskInit`），失败时可能无法同步释放锁。以下机制确保锁不会泄漏：
- `async_screen_task` 在任务完成后检查结果，失败时自动释放
- chunk 路由在每次请求前检查上一次任务结果，失败则释放
- status 路由检查底层状态，若已进入终态（success/fail/idle）则释放

#### HTTP 响应中的锁状态
所有 status 路由和 `/sysinfo` 响应中包含 `transfer_lock` 字段，供前端判断当前状态。

---

## AI 署名规则

**始终在每个被修改文件的顶部注明 AI 代理信息。**

示例：
```lua
--[[
@module  mod_gsensor
@brief   G-sensor 加速度采集 + 跌倒检测

🤖 整体或部分由 opencode 生成
]]
```

**切勿删除任何 AI 署名。**

---

## 提交前检查清单

- [ ] 无阻塞调用（用 `sys.wait()` 代替 `sys.waitUntil()` 死等）
- [ ] 无全局变量泄漏（所有变量 `local`）
- [ ] 新功能模块有对应 `config` 开关
- [ ] 关闭开关时对应数据不上报
- [ ] `main.lua` 中已 require 并初始化新模块
- [ ] 新模块有 `update_xxx()` 接口写入 `app_data`
- [ ] 未通过 `app_data.get()` 返回值写入数据（使用 `update_xxx()`）
- [ ] 模块间无直接 `require`（功能调用用 `register_callback` 中介）
- [ ] HTTP 处理使用路由表（无超长 if/elseif 链）
- [ ] 新增屏幕命令按半字节编码规则分配命令码
- [ ] 屏幕命令使用 `prints`/`printh` 发送，禁止依赖触控控件 ID 分发业务逻辑
- [ ] WiFi/BLE 独立运行（蓝牙通过 UART1，不占用射频）
- [ ] 传输操作（OTA/文件传输）使用互斥锁，不可同时进行
- [ ] 引用的数据字段确实存在于 `app_data` 的 `data` 表中
- [ ] `通信协议文档.md` 已更新数据结构
- [ ] 源码中无密钥或敏感信息
- [ ] 文件顶部有 AI 署名
- [ ] 单文件不超过 500 行（超过时按职责拆分模块）
- [ ] GNSS 坐标使用 `rmc(2)` 十进制格式，禁止用 `rmc(0)` 度分格式直接显示或存储
- [ ] Flash 读取大文件用 `f:seek` 定位尾部，禁止 `f:lines()` 遍历整个文件
- [ ] 提交信息包含 ✨
