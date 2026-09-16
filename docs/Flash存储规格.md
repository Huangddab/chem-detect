# Flash 存储双模式规格书

> **文档版本**: 2.0
> **编写日期**: 2026-08-27
> **目标平台**: Air8000 (LuatOS, Lua 5.3)
> **硬件**: W25Q64JVSSIQ (SPI NOR Flash, 8MB)
> **相关模块**: `mod_flash.lua`
> **文件系统**: LittleFS (VFS, 支持 `r+` 模式原地读写)

---

## 1. 背景与动机

当前 Flash 存储采用**动态滚动模式**：文件达到上限后截断旧数据，保留最近 80%。
截断操作需要重写整个文件，有写放大开销且产生数据断点。

用户希望增加**环形覆盖模式**：根据 Flash 容量和用户设置的三个日志占用百分比自动计算行数上限，
满后不停写，从头覆盖最旧记录（环形），数据永不断档。两种模式可随时切换。

---

## 2. 两种模式定义

### 2.1 动态滚动模式 (Dynamic / 当前已实现)

| 属性 | 说明 |
|------|------|
| 行为 | 文件达到 `MAX_LINES` 后截断保留后 80%，新数据继续写入 |
| 适用场景 | 简单场景，不关心截断开销 |
| 数据连续性 | 有断点（截断时旧数据丢失） |
| 写入开销 | 满后每次截断需重写文件（seek 优化后 < 100ms） |
| 容量分配 | 硬编码常量，不可调 |

**现有参数（不变）**:

| 文件 | MAX_LINES | 截断保留 | 实际行长 |
|------|-----------|----------|----------|
| 浓度 `conc.log` | 100,000 | 80,000 | ~40B/行 |
| 坐标 `gps.log` | 100,000 | 80,000 | ~44B/行 |
| 报警 `alarm.log` | 50,000 | 40,000 | ~28B/行 |

### 2.2 环形覆盖模式 (Ring / 新增)

| 属性 | 说明 |
|------|------|
| 行为 | 文件满后不停写，从文件头部覆盖最旧记录，循环往复 |
| 适用场景 | 长期连续监测，数据永不断档 |
| 数据连续性 | 完整连续（环形，无断点） |
| 写入开销 | 满后每次只写 1 行（seek + write 原地覆盖），无截断 |
| 容量分配 | 用户按百分比分配，灵活可调 |

**环形写入原理**：

```
文件容量 = N 行 (由百分比 × Flash 容量计算)

初始阶段 (追加写入):
  行1 ← 写入位置 0
  行2 ← 写入位置 1
  ...
  行N ← 写入位置 N-1     ← 文件已满

环形阶段 (覆盖写入):
  行N+1 ← 覆盖位置 0  (最旧的行1被覆盖)
  行N+2 ← 覆盖位置 1
  ...
  行2N ← 覆盖位置 N-1

读取时: 从写入位置 +1 开始读，跳过最新写入位置的前一行
```

---

## 3. 可行性分析

### 3.1 ✅ 技术可行性

| 维度 | 评估 | 说明 |
|------|------|------|
| LittleFS 原地写 | ✅ **已验证** | 底层 `luat_fs_lfs2.c` 支持 `r+` 模式 (`LFS_O_RDWR`)，`f:seek()` + `f:write()` 可原地覆盖 |
| 定长行保证 | ✅ **可行** | 环形模式要求每行**定长**，需对变长字段补空格或截断（见 §4.3） |
| 行数估算 | ✅ 已有 | `estimate_lines()` 用 `file_size ÷ line_len` O(1) 估算 |
| 容量百分比计算 | ✅ 可行 | `百分比 × Flash可用容量 ÷ 行长 = max_lines` |
| 写入位置追踪 | ✅ 可行 | 用 `fskv` 持久化写入位置索引，重启不丢失 |
| 模式切换 | ✅ 可行 | `config.flash_mode` 控制，协程内 if 判断 |
| 持久化配置 | ✅ 已有 | `fskv` 已支持 config 持久化 |
| 配置修改 | ✅ 可行 | 屏幕命令码或 MQTT 可动态改 config |

### 3.2 关键技术验证：LittleFS `r+` 模式

从 `LuatOS/luat/vfs/luat_fs_lfs2.c` 源码确认：

```c
// 第 33-34 行: "r+" 模式映射到 LFS_O_RDWR | LFS_O_CREAT
if (!strcmp("r+", mode) ...) {
    flag = LFS_O_RDWR | LFS_O_CREAT;  // 读写模式，保留已有数据
}

// 第 74-78 行: fseek 底层调用 lfs_file_seek
int luat_vfs_lfs2_fseek(...) {
    return lfs_file_seek(fs, file, offset, origin);  // 支持任意位置定位
}

// 第 116-121 行: fwrite 底层调用 lfs_file_write，r+ 模式可写
size_t luat_vfs_lfs2_fwrite(...) {
    // 检查 O_WRONLY 或 O_APPEND 才允许写
    // r+ → LFS_O_RDWR 包含写权限 ✅
}
```

**结论**：`io.open(file, "r+")` + `f:seek(offset)` + `f:write(data)` 在 LittleFS 上完全可用。

### 3.3 ⚠️ 风险点

| 风险 | 等级 | 缓解方案 |
|------|------|----------|
| 变长行覆盖错位 | **高** | 环形模式必须定长行，变长字段补空格/截断（见 §4.3） |
| 写入位置索引丢失 | 中 | 索引持久化到 `fskv`，每次写入后更新 |
| NOR Flash 写放大 | 低 | LittleFS 已处理磨损均衡，原地写只覆盖单行 |
| 模式切换时数据混乱 | 中 | 切换时清空文件，从零开始（见 §5.2） |

### 3.4 ❌ 不影响的方面

- 不影响 GNSS 坐标格式（`rmc(2)` 十进制）
- 不影响 UART1 上报逻辑
- 不影响其他模块（星型架构，通过 config 解耦）

---

## 4. 定长行格式设计

环形模式要求每行**严格等长**，否则覆盖时行边界错位。

### 4.1 定长格式定义

| 文件 | 格式 | 定长策略 | 行长(含`\n`) |
|------|------|----------|-------------|
| GPS | `%d,%.6f,%.6f,%.1f\n` | 已定长 | **38B** |
| 浓度 | `%d,%.2f,%.1f,%d,%d,%-4s,%-64s\n` | `src_type` 补空格到 4B, `src_name` 补空格到 64B | **98B** |
| 报警 | `%d,%.2f,%.1f,%d,%-4s,%-64s\n` | `src_type` 补空格到 4B, `src_name` 补空格到 64B | **96B** |

**字段上限分析**:

| 文件 | 字段 | 类型 | 最大值 | 最大宽度 | 说明 |
|------|------|------|--------|---------|------|
| 浓度 | ts | `%d` | 9999999999 | 10B | Unix 时间戳 (到 2286 年) |
| | conc | `%.2f` | 100.00 | 6B | PID 浓度量程 0~100 ppm |
| 坐标 | ts | `%d` | 9999999999 | 10B | |
| | lat | `%.6f` | 90.000000 | 9B | 纬度 0~90 |
| | lng | `%.6f` | 180.000000 | 10B | 经度 0~180 |
| | spd | `%.1f` | 999.9 | 5B | 速度上限 |
| 报警 | ts | `%d` | 9999999999 | 10B | |
| | conc | `%.2f` | 100.00 | 6B | PID 浓度量程 0~100 ppm |
| | th | `%.1f` | 100.0 | 5B | 报警阈值与浓度同范围 0~100 ppm |
| | level | `%d` | 3 | 1B | 0/2/3 |
| | src_type | `%-4s` | fall | 4B | 报警来源枚举: pid/ims/fall/none, 最长 4 字符 |
| | src_name | `%-64s` | 沙林;芥子气;VX神经毒剂;氯气 | 64B | 毒剂名称拼接 (IMS), 4 个最长名称 59B, 64B 足够; 无名称时全空格 |

### 4.2 定长格式示例

```
GPS (38B/行, 已定长):
1234567890,90.000000,180.000000,999.9\n    ← 各字段最大值示例
1234567890,22.543100,113.836150,12.5\n    ← 典型值

浓度 (98B/行):
1234567890,99.99,100.0,1,3,ims,沙林;芥子气;VX神经毒剂;氯气        \n  ← src_name 30B + 34 空格
1234567890,0.00,50.0,0,0,pid,                                                                \n  ← PID 无毒剂名称, src_name 全空格
1234567890,0.00,50.0,0,0,none,                                                              \n  ← 无报警, src_type=none

报警 (96B/行):
1234567890,99.99,100.0,3,ims,沙林;芥子气;VX神经毒剂;氯气        \n  ← 报警时记录浓度+阈值+等级+来源
1234567890,0.00,50.0,0,none,                                                                \n  ← 无报警, 全空格
```

### 4.3 变长字段处理

原 `src` 单字段拆分为 `src_type` + `src_name` 两个独立定长字段：

| 字段 | 原格式 | 定长处理 | 实现 |
|------|--------|----------|------|
| `src_type` | `table.concat(alarm.sources, ";")` 变长 | 补空格到 4 字符 | `string.format("%-4s", src_type)` |
| `src_name` (浓度) | `table.concat(ims.alarm_names, ";")` 变长 (IMS 毒剂名称) | 补空格到 64 字符 | `string.format("%-64s", src_name)` |
| `src_name` (报警) | 同上 | 补空格到 64 字符 | `string.format("%-64s", src_name)` |

**`src_type` 取值规则**:

| 值 | 来源 | 说明 |
|----|------|------|
| `pid` | `app_data.alarm.sources` 含 `"pid"` | PID 浓度报警 |
| `ims` | 含 `"ims"` | IMS 毒剂检测报警 |
| `fall` | 含 `"fall"` | 跌倒检测报警 |
| `mos` | 含 `"mos"` | 其他报警 |
| `none` | 无报警 | 无报警源时填充 |

> **多源场景**: 若同时有多个报警来源, `src_type` 取优先级最高的 (ims > fall > pid > mos), `src_name` 取 IMS 毒剂名称。非 IMS 报警时 `src_name` 为空 (全空格)。
>
> **截断保护**: 如果 `src_name` 超过 64 字节 (5 个以上极端长毒剂名拼接), 需截断。IMS 协议每个名称字段 20 字节, 4 个名称拼接 UTF-8 极端 59B, 64B 足够覆盖。
>
> 动态模式下继续使用变长格式 (单 `src` 字段), 不受影响。

### 4.4 字段上限推导依据

所有字段宽度基于代码中的**实际数据定义和业务约束**推导，非估算：

| 字段 | 上限值 | 代码依据 | 代码位置 |
|------|--------|----------|----------|
| **ts** (10B) | `9999999999` | `os.time()` 返回 Unix 时间戳，10 位整数（对应 2286 年） | Lua 标准库 |
| **conc** (6B) | `100.00` | `PID_RANGE = 100`，PID 浓度量程 0~100 ppm，`%.2f` 固定两位小数 | `mod_pid.lua:39` |
| **th** (5B) | `100.0` | 报警阈值与浓度同范围 0~100 ppm (当前硬编码 `50.0`，但可调到 100)，`%.1f` 固定一位小数 | `mod_pid.lua:40`, `mod_flash.lua:355` |
| **over** (1B) | `1` | `conc > th and 1 or 0`，逻辑值 0 或 1 | `mod_flash.lua:356` |
| **level** (1B) | `3` | `calc_alarm_level()` 返回 0/2/3（0=正常, 2=警告, 3=严重） | `app_data.lua:508-518` |
| **lat** (9B) | `90.000000` | 纬度地理范围 0~90，`%.6f` 固定六位小数 | 地理常量 |
| **lng** (10B) | `180.000000` | 经度地理范围 0~180，`%.6f` 固定六位小数 | 地理常量 |
| **spd** (5B) | `999.9` | NMEA 标准速度上限，`%.1f` 固定一位小数 | NMEA 标准 |
| **src_type** (4B) | `fall` | 报警来源枚举: `"pid"/"ims"/"fall"/"mos"/"none"`，最长 4 字符 | `app_data.lua:164` |
| **src_name** (64B) | `沙林;芥子气;VX神经毒剂;氯气` | IMS 毒剂名称拼接，每个名称字段 20B (协议)，4 个最长名称 UTF-8 拼接 = 59B，64B 足够覆盖 | `mod_ims.lua:144-155` |

**行长计算明细**:

| 文件 | 分项 | 计算 | 合计 |
|------|------|------|------|
| GPS | `ts(10) + ,(1) + lat(9) + ,(1) + lng(10) + ,(1) + spd(5) + \n(1)` | 10+1+9+1+10+1+5+1 | **38B** |
| 浓度 | `ts(10) + ,(1) + conc(6) + ,(1) + th(5) + ,(1) + over(1) + ,(1) + level(1) + ,(1) + src_type(4) + ,(1) + src_name(64) + \n(1)` | 10+1+6+1+5+1+1+1+1+1+4+1+64+1 | **98B** |
| 报警 | `ts(10) + ,(1) + conc(6) + ,(1) + th(5) + ,(1) + level(1) + ,(1) + src_type(4) + ,(1) + src_name(64) + \n(1)` | 10+1+6+1+5+1+1+1+4+1+64+1 | **96B** |

---

## 5. 功能开关与配置设计

### 5.1 新增 config 字段

```lua
config = {
    -- 现有字段...
    flash_en           = true,
    flash_log_conc_en  = false,
    flash_log_gps_en   = false,
    flash_log_alarm_en = false,

    -- ===== 新增字段 =====
    flash_mode           = "dynamic",  -- 存储模式: "dynamic"(滚动) / "ring"(环形)
    -- 环形模式: 三个日志占用 Flash 可用空间的百分比 (总和必须 = 100)
    flash_conc_pct       = 50,         -- 浓度日志百分比 (默认 50%)
    flash_gps_pct        = 30,         -- 坐标日志百分比 (默认 30%)
    flash_alarm_pct      = 20,         -- 报警日志百分比 (默认 20%)
}
```

### 5.2 模式切换规则

| 操作 | 行为 |
|------|------|
| `dynamic → ring` | **清空所有文件**，环形模式从零开始，初始化写入索引 |
| `ring → dynamic` | **清空所有文件**，动态模式从零开始 |
| 修改百分比 | **清空对应文件**，重新计算 max_lines，重置索引 |
| 切换后 | `sys.publish("CONFIG_CHANGED")` 通知屏幕刷新 |

> **设计决策**: 环形模式依赖定长行格式，动态模式用变长格式，两者不兼容。
> 切换时必须清空文件，避免格式混乱。清空前通过屏幕弹窗二次确认。

### 5.3 百分比校验

```lua
-- 校验三个百分比之和 = 100
local function check_percentages(conc_pct, gps_pct, alarm_pct)
    local total = conc_pct + gps_pct + alarm_pct
    return total == 100, total
end
```

---

## 6. 容量自动计算

### 6.1 计算公式

```
Flash 可用容量 = 实际挂载后获取的 free_kb (从 fs.fsstat 获取)
预留开销     = 0.5MB (LittleFS 元数据 + 磨损均衡)
实际可用     = size_kb - 512  (KB)

各文件容量 = 实际可用 × 各自百分比 ÷ 100

各文件行数 = 各文件容量 × 1024 ÷ 行长(字节)
            (向下取整, 保证不超限)
```

### 6.2 计算示例

```
Flash 总量: 8MB = 8192KB
预留开销: 512KB
实际可用: 7680KB = 7,864,320 字节

浓度 (50%): 7680 × 50% = 3840KB = 3,932,160 字节
  行数 = 3,932,160 ÷ 98 = 40,124 行

坐标 (30%): 7680 × 30% = 2304KB = 2,359,296 字节
  行数 = 2,359,296 ÷ 38 = 62,086 行

报警 (20%): 7680 × 20% = 1536KB = 1,572,864 字节
  行数 = 1,572,864 ÷ 96 = 16,384 行

总计: 40,124 + 62,086 + 16,384 = 118,594 行
```

### 6.3 容量速查表

| 浓度% | 坐标% | 报警% | 浓度行数 | 坐标行数 | 报警行数 | 总行数 |
|-------|-------|-------|---------|---------|---------|--------|
| 50 | 30 | 20 | 40,124 | 62,086 | 16,384 | 118,594 |
| 33 | 33 | 34 | 26,481 | 68,295 | 27,852 | 122,628 |
| 60 | 30 | 10 | 48,148 | 62,086 | 8,192 | 118,426 |
| 40 | 40 | 20 | 32,099 | 82,782 | 16,384 | 131,265 |

### 6.4 持久化行数

百分比修改后计算出的 `max_lines` 需持久化到 `fskv`，避免每次启动重新计算
（Flash 容量可能因磨损而变化，但变化很小，启动时重新计算一次即可）。

---

## 7. 环形写入实现

### 7.1 写入索引

每个文件维护一个**写入位置索引**（当前写到第几行），持久化到 `fskv`：

```lua
-- fskv 中存储的写入索引
-- Key: "flash_idx_conc" / "flash_idx_gps" / "flash_idx_alarm"
-- Value: 整数, 0 ~ max_lines-1
-- 含义: 下一条记录写入的行号 (0-based)
```

### 7.2 写入流程

```lua
-- 环形写入 (核心函数)
local function ring_write(filepath, line, max_lines, idx_key)
    -- 计算写入位置
    local idx = fskv.get(idx_key) or 0
    local offset = idx * LINE_LEN_RING[filepath]

    -- 判断是否追加阶段 (文件还没满)
    local file_size = get_file_size(filepath)
    local est_lines = file_size // LINE_LEN_RING[filepath]

    if est_lines < max_lines then
        -- 追加阶段: 正常 append
        local f = io.open(filepath, "a")
        f:write(line .. "\n")
        f:close()
        -- 更新索引
        fskv.set(idx_key, (idx + 1) % max_lines)
    else
        -- 环形阶段: seek + write 覆盖
        local f = io.open(filepath, "r+")  -- 原地读写模式
        f:seek("set", offset)
        f:write(line .. "\n")
        f:close()
        -- 更新索引 (循环递增)
        fskv.set(idx_key, (idx + 1) % max_lines)
    end
end
```

### 7.3 读取流程

环形模式下，读取最新 N 条数据需要从写入位置**倒推**：

```lua
-- 环形读取最新 N 条
local function ring_read_last_n(filepath, n, max_lines, idx_key)
    local idx = fskv.get(idx_key) or 0
    local line_len = LINE_LEN_RING[filepath]
    local file_size = get_file_size(filepath)
    local est_lines = file_size // line_len

    -- 还没满: 读最后 N 行 (和现有逻辑相同)
    if est_lines <= max_lines and est_lines <= n then
        return read_all_lines(filepath)
    end
    if est_lines < max_lines then
        -- 文件未满, 用现有 seek 尾部读取
        return read_last_n(filepath, n)
    end

    -- 已满 (环形): 从 idx 倒推 N 行
    local result = {}
    local f = io.open(filepath, "r")
    for i = 1, n do
        local read_idx = (idx - i + max_lines) % max_lines
        local offset = read_idx * line_len
        f:seek("set", offset)
        local line = f:read(line_len - 1)  -- 不含 \n
        if line and line ~= "" then
            result[#result + 1] = line
        end
    end
    f:close()
    -- 结果是逆序的 (最新在前), 反转
    local reversed = {}
    for i = #result, 1, -1 do
        reversed[#reversed + 1] = result[i]
    end
    return reversed
end
```

### 7.4 数据新旧判断

环形模式下，读取的数据需要知道时间戳来判断新旧。
由于环形覆盖后旧数据被新数据覆盖，文件中不会同时存在同一时间点的两条记录。
读取时按时间戳排序即可，不需要特殊处理。

---

## 8. 数据结构变更

### 8.1 app_data.io.flash 新增字段

```lua
flash = {
    mounted       = false,   -- 文件系统挂载状态
    size_kb       = 0,       -- 总容量
    free_kb       = 0,       -- 剩余容量
    timestamp     = 0,       -- 最后写入时间戳
    mode          = "dynamic", -- 当前模式
    -- ===== 环形模式新增 =====
    conc_max      = 0,       -- 浓度最大行数 (环形模式自动计算)
    gps_max       = 0,       -- 坐标最大行数
    alarm_max     = 0,       -- 报警最大行数
    conc_lines    = 0,       -- 浓度已写行数
    gps_lines     = 0,       -- 坐标已写行数
    alarm_lines   = 0,       -- 报警已写行数
    conc_wrapped  = false,   -- 浓度是否已环形覆盖 (满过一次)
    gps_wrapped   = false,   -- 坐标是否已环形覆盖
    alarm_wrapped = false,   -- 报警是否已环形覆盖
}
```

---

## 9. 模块接口设计

### 9.1 对外接口 (mod_flash.lua)

```lua
-- 获取当前模式
-- @return string "dynamic" / "ring"
mod_flash.get_mode()

-- 切换模式 (清空文件, 重新初始化)
-- @param mode "dynamic" / "ring"
-- @return boolean 成功与否
mod_flash.set_mode(mode)

-- 设置百分比 (环形模式专用)
-- @param conc_pct 浓度百分比 (0-100)
-- @param gps_pct 坐标百分比 (0-100)
-- @param alarm_pct 报警百分比 (0-100)
-- @return boolean 成功与否 (校验总和=100)
mod_flash.set_percentages(conc_pct, gps_pct, alarm_pct)

-- 清空指定文件
-- @param name "conc" / "gps" / "alarm" / "all"
-- @return boolean 成功与否
mod_flash.erase_file(name)

-- 获取各文件状态
-- @return table { conc={lines=, max=, wrapped=}, gps={...}, alarm={...} }
mod_flash.get_files_status()

-- 重新计算环形模式行数 (Flash 容量变化时调用)
-- @return boolean 成功与否
mod_flash.recalc_ring_capacity()
```

### 9.2 append_line 分模式处理

```lua
local function append_line(filepath, line, max_lines)
    local mode = app_data.get_config("flash_mode") or "dynamic"

    if mode == "ring" then
        -- 环形模式: 用定长行 + seek 覆盖
        -- 1. 格式化定长行
        local line_fixed = format_fixed_line(filepath, line)
        -- 2. 环形写入
        local idx_key = IDX_KEYS[filepath]  -- "flash_idx_conc" 等
        ring_write(filepath, line_fixed, max_lines, idx_key)
        return true
    else
        -- 动态模式: 现有逻辑 (变长行 + 截断 80%)
        local est_lines = estimate_lines(filepath)
        if est_lines >= max_lines then
            local keep = math.floor(max_lines * 0.8)
            truncate_to_last(filepath, keep)
        end
        local f = io.open(filepath, "a")
        if f then f:write(line .. "\n"); f:close(); return true end
        return false
    end
end
```

---

## 10. 屏幕命令码扩展

> Flash 配置通过屏幕命令码或 MQTT 控制。

### 10.1 屏幕命令码

| 命令码 | 屏幕端指令 | 说明 |
|--------|-----------|------|
| `0x20` | `printh 70 20 FF FF FF` | 切换为动态滚动模式 |
| `0x21` | `printh 70 21 FF FF FF` | 切换为环形覆盖模式 |
| `0x22` | `printh 70 22 FF FF FF` | 清空浓度文件 |
| `0x23` | `printh 70 23 FF FF FF` | 清空坐标文件 |
| `0x24` | `printh 70 24 FF FF FF` | 清空报警文件 |
| `0x25` | `printh 70 25 FF FF FF` | 清空全部文件 |
| `0x26` | `printh 70 26 FF FF FF` | 重算容量 (Flash 容量变化时) |

> 修改任一百分比后，自动校验三者之和 = 100，不满足则拒绝并返回错误。

### 10.2 数据查询

| 命令码 | 说明 |
|--------|------|
| `0x02` | 推送传感器数据（含 Flash 状态在 io.flash 中） |

---

## 11. 上报 JSON 结构

### 11.1 环形模式

```json
{
    "io": {
        "flash": {
            "mounted": true,
            "size_kb": 8192,
            "free_kb": 6400,
            "timestamp": 1234567890,
            "mode": "ring",
            "conc_max": 40124,
            "gps_max": 62086,
            "alarm_max": 16384,
            "conc_lines": 48231,
            "gps_lines": 62086,
            "alarm_lines": 3210,
            "conc_wrapped": false,
            "gps_wrapped": true,
            "alarm_wrapped": false
        }
    }
}
```

### 11.2 动态模式

```json
{
    "io": {
        "flash": {
            "mounted": true,
            "size_kb": 8192,
            "free_kb": 100,
            "timestamp": 1234567890,
            "mode": "dynamic",
            "conc_max": 100000,
            "gps_max": 100000,
            "alarm_max": 50000,
            "conc_lines": 82000,
            "gps_lines": 95000,
            "alarm_lines": 12000,
            "conc_wrapped": false,
            "gps_wrapped": false,
            "alarm_wrapped": false
        }
    }
}
```

---

## 12. 屏幕显示设计

### 12.1 Flash 设置页

```
┌──────────────────────────────────┐
│  Flash 存储                       │
│                                  │
│  模式: [动态滚动] [环形覆盖]      │  ← 切换按钮
│                                  │
│  ── 容量分配 (环形模式) ──        │
│  浓度: ████████████░░░ 50%        │  ← 滑动条/数字
│  坐标: ███████░░░░░░░░ 30%        │
│  报警: █████░░░░░░░░░░ 20%        │
│  总计: 100%  ✅                   │  ← 自动校验
│                                  │
│  ── 计算结果 ──                   │
│  浓度: ~40,124 行 (3.7MB)       │  ← 自动计算
│  坐标: 62,086 行 (2.2MB)        │
│  报警: 16,384 行 (1.5MB)        │
│                                  │
│  ── 文件状态 ──                   │
│  浓度: 48231/40124  ████████⟳  │  ← 满后环形图标 ⟳
│  坐标: 62086/62086  ██████████⟳  │  ← 满后环形图标 ⟳
│  报警: 3210/16384   █░░░░░░░░░    │
│                                  │
│  [清空浓度] [清空坐标] [清空报警]   │
│  [全部清空]                       │
└──────────────────────────────────┘
```

### 12.2 屏幕命令码 (TJC printh)

| 命令码 | printh 指令 | 说明 |
|--------|------------|------|
| `0x20` | `printh 70 20 FF FF FF` | 切换为动态模式 |
| `0x21` | `printh 70 21 FF FF FF` | 切换为环形模式 |
| `0x22` | `printh 70 22 FF FF FF` | 清空浓度文件 |
| `0x23` | `printh 70 23 FF FF FF` | 清空坐标文件 |
| `0x24` | `printh 70 24 FF FF FF` | 清空报警文件 |
| `0x25` | `printh 70 25 FF FF FF` | 清空全部文件 |
| `0x26` | `printh 70 26 FF FF FF` | 重算容量 (Flash 容量变化时) |

---

## 13. 定长行格式常量

```lua
-- 环形模式定长行字节数 (含 \n)
local LINE_LEN_RING = {
    [CONC_FILE]  = 98,   -- 浓度: 10+1+6+1+5+1+1+1+1+1+4+1+64+1 = 98
    [GNSS_FILE]  = 38,   -- 坐标: 10+1+9+1+10+1+5+1 = 38
    [ALARM_FILE] = 96,   -- 报警: 10+1+6+1+5+1+1+1+4+1+64+1 = 96
}

-- 环形模式格式化函数
local function format_fixed_line(filepath, data)
    if filepath == GNSS_FILE then
        return string.format("%d,%.6f,%.6f,%.1f\n",
            data.ts, data.lat, data.lng, data.speed)
    elseif filepath == CONC_FILE then
        return string.format("%d,%.2f,%.1f,%d,%d,%-4s,%-64s\n",
            data.ts, data.conc, data.th, data.over,
            data.level, data.src_type or "none", data.src_name or "")
    elseif filepath == ALARM_FILE then
        return string.format("%d,%.2f,%.1f,%d,%-4s,%-64s\n",
            data.ts, data.conc, data.th, data.level, data.src_type or "none", data.src_name or "")
    end
end

-- fskv 索引键名
local IDX_KEYS = {
    [CONC_FILE]  = "flash_idx_conc",
    [GNSS_FILE]  = "flash_idx_gps",
    [ALARM_FILE] = "flash_idx_alarm",
}
```

---

## 14. 实现计划

### 阶段 1: 基础框架

| 步骤 | 文件 | 内容 |
|------|------|------|
| 1 | `app_data.lua` | config 新增 `flash_mode` / `flash_*_pct` 字段 |
| 2 | `app_data.lua` | `io.flash` 新增 `*_max` / `*_lines` / `*_wrapped` 字段 |
| 3 | `app_data.lua` | `set_config` 增加百分比校验 (总和 = 100) |
| 4 | `mod_flash.lua` | 定义定长行常量和格式化函数 |
| 5 | `mod_flash.lua` | 实现 `ring_write()` 环形写入 |
| 6 | `mod_flash.lua` | 实现 `ring_read_last_n()` 环形读取 |
| 7 | `mod_flash.lua` | `append_line` 分模式调度 |

### 阶段 2: 容量计算与索引

| 步骤 | 文件 | 内容 |
|------|------|------|
| 8 | `mod_flash.lua` | 实现 `calc_ring_capacity()` 从百分比计算行数 |
| 9 | `mod_flash.lua` | fskv 持久化写入索引 (`flash_idx_*`) |
| 10 | `mod_flash.lua` | 模式切换时清空文件 + 重置索引 |

### 阶段 3: 对外接口

| 步骤 | 文件 | 内容 |
|------|------|------|
| 11 | `mod_flash.lua` | `get_mode()` / `set_mode()` |
| 12 | `mod_flash.lua` | `set_percentages()` |
| 13 | `mod_flash.lua` | `erase_file()` / `get_files_status()` |
| 14 | `mod_flash.lua` | `recalc_ring_capacity()` |

### 阶段 4: 通信与屏幕

| 步骤 | 文件 | 内容 |
|------|------|------|
| 15 | `app_data.lua` | UART1 `CFG` 支持 `flash_mode` / `flash_*_pct` |
| 16 | `app_data.lua` | UART1 新增 `FLASH_ERASE` 指令 |
| 17 | `app_data.lua` | 上报 JSON 增加环形模式字段 |
| 18 | `mod_screen.lua` | Flash 设置页 UI |
| 19 | `mod_screen.lua` | 屏幕命令码 `0x20`~`0x26` 处理 |
| 20 | `通信协议文档.md` | 更新指令速查表 |

---

## 15. 测试用例

### 15.1 动态模式 (回归测试)

| 用例 | 步骤 | 预期 |
|------|------|------|
| 滚动截断 | 写入超过 MAX_LINES | 截断保留 80%，继续写 |
| 模式切换 | 动态→环形 | 清空文件，环形从零开始 |

### 15.2 环形模式

| 用例 | 步骤 | 预期 |
|------|------|------|
| 追加阶段 | 写入 < max_lines | 正常追加，`wrapped` = false |
| 首次满 | 写入 = max_lines | 文件满，`wrapped` = false，下一行触发环形 |
| 环形覆盖 | 写入 > max_lines | 从位置 0 覆盖，`wrapped` = true |
| 环形读取 | 读最新 100 条 | 从 idx 倒推 100 行，按时间排序返回 |
| 多轮覆盖 | 写入 > 2 × max_lines | 索引正确循环，数据无错位 |
| 重启恢复 | 写入中重启 | fskv 索引恢复，继续从上次位置写入 |
| 百分比校验 | 设 `conc_pct=70, gps_pct=10, alarm_pct=10` | 总和 ≠ 100，拒绝 |
| 容量计算 | 设 `conc=50%, gps=30%, alarm=20%` | 自动算出行数，总和 < 7.5MB |
| 手动清空 | `erase_file("conc")` | 文件清空，索引归零，`wrapped` = false |
| 定长验证 | 浓度行 src 变长 | 补空格到 10B，行总长 = 42B |

### 15.3 模式切换

| 用例 | 步骤 | 预期 |
|------|------|------|
| 动态→环形 | 切换 `flash_mode=ring` | 清空所有文件，初始化索引，`wrapped` = false |
| 环形→动态 | 切换 `flash_mode=dynamic` | 清空所有文件，使用硬编码 MAX_LINES |
| 频繁切换 | 快速切换 3 次 | 最后一次生效，文件被清空 |

---

## 16. 注意事项

1. **定长行是环形模式的生命线**：变长行覆盖会导致行边界错位，所有数据报废
2. **写入索引必须持久化**：重启后从 fskv 恢复，否则环形位置丢失
3. **模式切换清空文件**：两种模式行格式不兼容（定长 vs 变长），切换必须清空
4. **动态模式完全不变**：现有 `CONC_MAX_LINES` 等常量和变长行格式保持原样
5. **百分比持久化**：`flash_*_pct` 通过 `fskv` 持久化，重启不丢失
6. **fskv 空间**：新增 3 个索引键 + 3 个百分比键，总共 < 100 字节，不影响 fskv 性能
7. **文件行数限制**：`mod_flash.lua` 预计新增 ~150 行，总行数可能超 500 行，
   考虑将环形逻辑拆分到 `mod_flash_ring.lua`
