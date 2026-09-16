--[[
@module  mod_flash
@brief   Flash 存储 — SPI1 外部 NOR Flash 数据记录
@version 3.1
@date    2026.08.10
@usage
本模块通过 SPI1 挂载外部 SPI NOR Flash (W25Q64JVSSIQ)，提供数据持久化。
参考官方 little_flash demo 的初始化流程：
  1. spi.deviceSetup() — SPI 半双工模式
  2. lf.init(spi_device) — 自动识别芯片 (SFDP / JEDEC ID)
  3. lf.mount(flash_device, "/flash") — 挂载 LittleFS 文件系统
  4. fs.fsstat("/flash") — 获取文件系统信息

芯片信息 (W25Q64JVSSIQ):
  - 类型: NOR Flash
  - 容量: 64M-bit = 8MB
  - JEDEC ID: manufacturer=0xEF (Winbond), device=0x4017
  - 封装: SOIC-8
  - 支持 SFDP 自动识别 (lf.init 内部通过 SFDP 探测参数)

接线:
  Air8000           NOR Flash (W25Q64)
  GND               GND
  VDD_EXT           VCC
  GPIO12 (pin ??)   CS   -- NOR 专用片选
  SPI1_SLK (pin 38) CLK
  SPI1_MOSI (pin 40) DI
  SPI1_MISO (pin 39) DO

🤖 整体或部分由 opencode 生成
]]

local mod_flash = {}

-- ========== 加载依赖 ==========
-- 星型架构: 只依赖 app_data, 不依赖其他 mod_xxx
local app_data = require "app_data"

-- Flash 库检测: 优先使用 lf (little_flash), 不支持时回退到 sfud
-- 两者都是 C 固件内置全局变量, 不需要 require
--   lf   — little_flash 库, 提供 init() / mount(), 底层用 LittleFS
--   sfud — sfud 库, 提供 init() / mount() / getDeviceTable(), 底层用 FatFS/lfs
local flash_lib       -- 运行时绑定的 Flash 库对象 (lf 或 sfud)
local flash_lib_name  -- 库名称字符串, 用于日志
if lf then
    flash_lib      = lf
    flash_lib_name = "little_flash"
elseif sfud then
    flash_lib      = sfud
    flash_lib_name = "sfud"
else
    log.error("FLASH", "固件不支持 little_flash (lf) 和 sfud, Flash 模块不可用")
end

-- ========== 硬件参数 (参考官方 little_flash demo) ==========
-- SPI1 引脚说明 (Air8000 核心板固定引脚):
--   SCLK = GPIO15 (pin 38)
--   MISO = GPIO14 (pin 39)  → DO (Flash 输出)
--   MOSI = GPIO13 (pin 40)  → DI (Flash 输入)
--   CS   = GPIO12 (pin 41)   -- NOR 专用片选 (GPIO141 留给 NAND Flash)
local SPI_ID    = 1            -- SPI 总线 ID (SPI1)
local CS_PIN    = 12           -- CS 片选引脚 (GPIO12, NOR Flash)
local CPHA      = 0            -- 时钟相位 (Mode 0)
local CPOL      = 0            -- 时钟极性 (Mode 0)
local DATA_W    = 8            -- 数据宽度 (8 bit)
local BANDRATE  = 20 * 1000 * 1000  -- 波特率 20MHz (与官方 demo 一致, W25Q64 最高支持 50MHz)

-- ========== 文件参数 ==========
local MOUNT_POINT      = "/flash"        -- LittleFS 挂载点
local CONC_FILE        = "/flash/conc.log"   -- 浓度数据记录文件
local ALARM_FILE       = "/flash/alarm.log"  -- 报警事件记录文件
local GNSS_FILE        = "/flash/gps.log"    -- 坐标记录文件
-- 行数上限: 充分利用 8MB Flash 容量
-- 实测: 8MB 可写 235K 条 GPS 记录 (36B/条), 三个文件平分空间
local CONC_MAX_LINES   = 100000         -- 浓度: 10万条, ~4MB (每行~40B)
local ALARM_MAX_LINES  = 50000          -- 报警: 5万条, ~1.4MB (每行~28B)
local GNSS_MAX_LINES   = 100000         -- 坐标: 10万条, ~3.6MB (每行~36B)
local CONC_INTERVAL    = 60000          -- 浓度记录间隔 (ms), 1 分钟一次
local GNSS_INTERVAL   = 30000          -- 坐标记录间隔 (ms), 30 秒一次 (仅定位成功时)

-- ========== 模块状态 ==========
local initialized = false   -- init() 是否已调用
local mounted     = false   -- 文件系统是否已挂载
local lf_device   = nil     -- little_flash 设备对象 (lf.init 返回)
local spi_device  = nil     -- SPI 设备对象 (全局引用, 防止被 GC 回收)

-- ========== 辅助函数 ==========

-- 格式化时间戳为可读字符串 (用于 CSV 记录)
local function fmt_time(ts)
    if not ts or ts == 0 then
        return os.date("%Y-%m-%d %H:%M:%S")
    end
    return os.date("%Y-%m-%d %H:%M:%S", ts)
end

-- 每个文件的单行字节数 (含 \n), 按格式精确计算
-- GPS:   "%d,%.6f,%.6f,%.1f\n" → 10+1+12+1+13+1+5+1 = 44B (定长)
-- 浓度:  "%d,%.2f,%.1f,%d,%d,%s\n"  → 10+1+6+1+5+1+1+1+1+1+源, 无源时 28B, 取 36 估算偏大
-- 报警:  "%d,%d,%s\n"             → 10+1+1+1+源, 无源时 14B, 取 20 估算偏大
-- 估算用偏小值 (低估行长 → 高估行数 → 提前触发截断, 不会漏)
-- 截断读取用偏大值 (高估行长 → 多读字节 → 保证不漏行)
local LINE_LEN_EST = {  -- 估算用 (偏小, 高估行数)
    [CONC_FILE]  = 36,
    [GNSS_FILE]  = 44,
    [ALARM_FILE] = 20,
}
local LINE_LEN_READ = { -- 截断读取用 (偏大, 多读不漏)
    [CONC_FILE]  = 60,
    [GNSS_FILE]  = 44,
    [ALARM_FILE] = 40,
}
-- 通用默认值 (给 read_last_n 等非文件特定场景用)
local AVG_LINE_LEN = 50

-- 估算文件行数: 用文件大小 ÷ 单行字节数 (O(1), 不遍历文件)
local function estimate_lines(filepath)
    local f = io.open(filepath, "r")
    if not f then return 0 end
    local size = f:seek("end")  -- O(1) 获取文件大小
    f:close()
    local line_len = LINE_LEN_EST[filepath] or AVG_LINE_LEN
    return size // line_len
end

-- 精确截断: 保留文件最后 keep_lines 行, 删除前面的行
-- 用 seek 从尾部读取, 不遍历整个文件
local function truncate_to_last(filepath, keep_lines)
    local f = io.open(filepath, "r")
    if not f then return false end
    local file_size = f:seek("end")
    if file_size == 0 then
        f:close()
        return false
    end
    -- 估算: 用偏小行长 (高估行数, 提前触发截断)
    local est_len = LINE_LEN_EST[filepath] or AVG_LINE_LEN
    local est_total = file_size // est_len
    if est_total <= keep_lines then
        f:close()
        return true
    end
    -- 读取: 按保留比例读取尾部数据, 加 30% 余量
    -- 余量覆盖估算偏差 (est_len 偏小导致 est_total 偏大, ratio 偏小)
    local ratio = keep_lines / est_total
    local read_bytes = math.ceil(file_size * ratio * 1.3)
    if read_bytes > file_size then
        read_bytes = file_size  -- 兜底
    end
    local read_start = file_size - read_bytes
    f:seek("set", read_start)
    local data = f:read(read_bytes) or ""
    f:close()
    -- 按行分割
    local lines = {}
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    -- 第一行可能不完整 (seek 在行中间), 丢弃
    if read_start > 0 and #lines > 0 then
        table.remove(lines, 1)
    end
    -- 只保留最后 keep_lines 行
    local start_idx = #lines - keep_lines + 1
    if start_idx < 1 then start_idx = 1 end
    -- 重写文件
    f = io.open(filepath, "w")
    if not f then return false end
    for i = start_idx, #lines do
        f:write(lines[i] .. "\n")
    end
    f:close()
    return true
end

-- 追加一行到文件, 超过最大行数时截断旧数据 (保留后 80%)
-- 优化: 用文件大小估算行数 (O(1)), 避免每次写入遍历文件
local function append_line(filepath, line, max_lines)
    -- 用估算行数快速判断, 不遍历文件
    local est_lines = estimate_lines(filepath)
    if est_lines >= max_lines then
        -- 达到上限, 执行截断: 保留后 80%
        local keep = math.floor(max_lines * 0.8)
        truncate_to_last(filepath, keep)
    end
    -- 追加新行
    local f = io.open(filepath, "a")
    if f then
        f:write(line .. "\n")
        f:close()
        return true
    end
    return false
end

-- ========== 初始化 ==========
-- 软件初始化, 不涉及硬件操作
-- 在 main.lua 中调用, 早于 start()
function mod_flash.init()
    initialized = true
    log.info("FLASH", "Flash 存储模块初始化完成")
end

-- ========== 启动 ==========
function mod_flash.start()
    if not initialized then
        log.error("FLASH", "模块未初始化, 请先调用 mod_flash.init()")
        return
    end

    -- 固件不支持 Flash 库时, 直接退出
    if not flash_lib then
        log.warn("FLASH", "固件不支持 little_flash/sfud, Flash 模块不启动")
        return
    end

    -- 主协程: 挂载/卸载文件系统 (开关控制)
    sys.taskInit(function()
        while true do
            -- 检查功能开关 (config.flash_en)
            if not app_data.get_config("flash_en") then
                if mounted then
                    -- 开关从开→关: 卸载文件系统, 清理资源
                    mounted = false
                    app_data.update_io("flash", { mounted = false, size_kb = 0, free_kb = 0 })
                    -- 清理 SPI 设备
                    if spi_device then
                        pcall(function() spi_device:close() end)
                        spi_device = nil
                    end
                    lf_device = nil
                    -- [电源控制已取消]
                    log.info("FLASH", "Flash 已停止（开关关闭）")
                end
                sys.wait(1000)
                goto continue
            end

            -- 确保文件系统已挂载
            if not mounted then
                -- [电源控制已取消]
                -- ===== 参考官方 little_flash / sfud demo 的初始化流程 =====
                local ok, err = pcall(function()
                    -- 1. 以对象方式初始化 SPI
                    --    最后一个参数 0 = 半双工模式
                    --    参数: SPI_ID, CS, CPHA, CPOL, dataW, bandrate, MSB, master=1, mode=0
                    spi_device = spi.deviceSetup(SPI_ID, CS_PIN, CPHA, CPOL, DATA_W, BANDRATE, spi.MSB, 1, 0)
                    if not spi_device then
                        error("spi.deviceSetup 返回 nil")
                    end
                    log.info("FLASH", string.format("SPI 初始化成功, 波特率: %dHz", BANDRATE))

                    -- 2. 初始化 Flash 设备
                    --    flash_lib.init 内部通过 SFDP 自动探测芯片参数
                    --    W25Q64JVSSIQ: manufacturer=0xEF, device=0x4017, NOR Flash, 8MB
                    --    SFDP 探测成功后自动配置页大小(256B)、扇区大小(4KB)等参数
                    lf_device = flash_lib.init(spi_device)
                    if not lf_device then
                        error(flash_lib_name .. ".init 返回 nil, Flash 未识别")
                    end
                    log.info("FLASH", flash_lib_name .. " 初始化成功, 设备: " .. tostring(lf_device))

                    -- 3. 挂载文件系统 (LittleFS / lfs)
                    --    首次使用时 mount 内部会自动格式化
                    --    失败时重试一次 (与官方 demo 一致)
                    local mount_ok = flash_lib.mount(lf_device, MOUNT_POINT)
                    if not mount_ok then
                        log.warn("FLASH", "首次挂载失败, 尝试重新挂载...")
                        mount_ok = flash_lib.mount(lf_device, MOUNT_POINT)
                        if not mount_ok then
                            error(flash_lib_name .. ".mount 两次均失败")
                        end
                    end
                    log.info("FLASH", "文件系统挂载成功: " .. MOUNT_POINT)

                    -- 4. 获取文件系统信息 (使用 fs.fsstat, 与官方 demo 一致)
                    --    返回: total_blocks, used_blocks, block_size, fs_type
                    local fs_ok, total_blocks, used_blocks, block_size, fs_type = fs.fsstat(MOUNT_POINT)
                    if fs_ok then
                        local total_kb = total_blocks * block_size // 1024
                        log.info("FLASH", string.format(
                            "文件系统: 总block=%d, 已用=%d, block大小=%d字节, 类型=%s, 总容量=%dKB",
                            total_blocks, used_blocks, block_size, tostring(fs_type), total_kb))
                        -- 更新 app_data 中的 Flash 状态
                        app_data.update_io("flash", {
                            mounted  = true,
                            size_kb  = total_kb,
                            free_kb  = total_kb - (used_blocks * block_size // 1024),
                        })
                    else
                        app_data.update_io("flash", { mounted = true, size_kb = 0, free_kb = 0 })
                    end

                    -- 5. 文件读写验证 (参考 demo 的 test_file_operations)
                    --    写入测试文件 → 读回比对 → 删除, 确认文件系统可用
                    local test_file = MOUNT_POINT .. "/.test"
                    local f = io.open(test_file, "w")
                    if f then
                        local write_data = "Safex Flash Test " .. os.date()
                        f:write(write_data)
                        f:close()
                        local read_data = io.readFile(test_file)
                        if read_data == write_data then
                            log.info("FLASH", "文件读写验证通过")
                        else
                            log.warn("FLASH", "文件读写验证失败, 读取: " .. tostring(read_data))
                        end
                        os.remove(test_file)
                    end
                end)

                -- 挂载失败处理: 清理资源, 10 秒后重试
                if not ok then
                    log.warn("FLASH", "Flash 挂载失败: " .. tostring(err))
                    app_data.update_io("flash", { mounted = false, size_kb = 0, free_kb = 0 })
                    -- 清理 SPI 设备, 释放资源
                    if spi_device then
                        pcall(function() spi_device:close() end)
                        spi_device = nil
                    end
                    lf_device = nil
                    -- [电源控制已取消]
                    -- 不退出协程, 每 10 秒重试一次
                    sys.wait(10000)
                    goto continue
                end

                mounted = true
                log.info("FLASH", "Flash 存储模块就绪")
            end

            sys.wait(1000)
            ::continue::
        end
    end)

    -- 浓度记录协程: 定期写入 PID 浓度 + 报警阈值 + 等级
    -- CSV 格式: 时间戳,PID浓度,报警阈值,是否超限,报警等级,报警来源
    sys.taskInit(function()
        while true do
            -- 未挂载或总开关/子开关关闭时, 空等
            if not mounted
                or not app_data.get_config("flash_en")
                or not app_data.get_config("flash_log_conc_en") then
                sys.wait(1000)
                goto continue
            end

            local sensor = app_data.get().sensor
            local alarm  = app_data.get().alarm
            local ts     = os.time()
            local conc   = sensor.pid.conc or 0
            local th     = 50.0  -- PID 报警阈值 (ppm)
            local over   = conc > th and 1 or 0

            local conc_line = string.format("%d,%.2f,%.1f,%d,%d,%s",
                ts, conc, th, over,
                alarm.level or 0,
                table.concat(alarm.sources or {}, ";"))

            if not append_line(CONC_FILE, conc_line, CONC_MAX_LINES) then
                log.warn("FLASH", "浓度记录写入失败")
            end

            -- 更新最后写入时间到 app_data
            app_data.update_io("flash", { timestamp = ts })

            sys.wait(CONC_INTERVAL)
            ::continue::
        end
    end)

    -- 坐标记录协程: 定期写入 GNSS 坐标 (仅定位成功时)
    -- CSV 格式: 时间戳,纬度,经度,速度
    sys.taskInit(function()
        while true do
            -- 未挂载或总开关/子开关关闭时, 空等
            if not mounted
                or not app_data.get_config("flash_en")
                or not app_data.get_config("flash_log_gps_en") then
                sys.wait(1000)
                goto continue
            end

            -- 仅定位成功时记录坐标
            local gnss = app_data.get().gnss
            if gnss.fixed and gnss.lat ~= 0 and gnss.lng ~= 0 then
                local ts = os.time()
                local gps_line = string.format("%d,%.6f,%.6f,%.1f",
                    ts, gnss.lat, gnss.lng, gnss.speed or 0)
                if not append_line(GNSS_FILE, gps_line, GNSS_MAX_LINES) then
                    log.warn("FLASH", "坐标记录写入失败")
                end
            end

            sys.wait(GNSS_INTERVAL)
            ::continue::
        end
    end)

    -- 报警记录协程: 监控报警等级变化, 等级变化时写入记录
    -- CSV 格式: 时间戳,报警等级,报警来源
    sys.taskInit(function()
        local last_alarm_level = 0
        while true do
            -- 未挂载或总开关/子开关关闭时, 空等
            if not mounted
                or not app_data.get_config("flash_en")
                or not app_data.get_config("flash_log_alarm_en") then
                sys.wait(1000)
                goto continue
            end

            -- 检测报警等级变化 (上升或下降都记录)
            local alarm = app_data.get().alarm
            local level = alarm.level or 0

            if level ~= last_alarm_level then
                local sources_str = table.concat(alarm.sources or {}, ";")
                local alarm_line = string.format("%d,%d,%s",
                    os.time(), level, sources_str)
                if not append_line(ALARM_FILE, alarm_line, ALARM_MAX_LINES) then
                    log.warn("FLASH", "报警记录写入失败")
                end
                last_alarm_level = level
            end

            sys.wait(500)  -- 报警变化检测频率 500ms
            ::continue::
        end
    end)

    if app_data.get_config("flash_en") then
        log.info("FLASH", "Flash 存储模块已启动, 记录间隔:", CONC_INTERVAL, "ms")
    else
        log.info("FLASH", "Flash 模块已加载（开关关闭，待启用）")
    end
end

-- ========== 对外接口 ==========

-- 手动写入浓度记录
-- @param data 浓度数据表 { conc=, threshold=, over=, alarm_level=, source= }
function mod_flash.write_conc(data)
    if not mounted then return end
    data = data or {}
    local line = string.format("%d,%.2f,%.1f,%d,%d,%s",
        os.time(), data.conc or 0, data.threshold or 50.0,
        data.over or 0, data.alarm_level or 0, data.source or "")
    append_line(CONC_FILE, line, CONC_MAX_LINES)
end

-- 手动写入报警记录
-- @param data 报警数据表 { level=, source= }
function mod_flash.write_alarm(data)
    if not mounted then return end
    data = data or {}
    local line = string.format("%d,%d,%s",
        os.time(), data.level or 0, data.source or "none")
    append_line(ALARM_FILE, line, ALARM_MAX_LINES)
end

-- 手动写入坐标记录
-- @param data 坐标数据表 { lat=, lng=, speed= }
function mod_flash.write_gps(data)
    if not mounted then return end
    data = data or {}
    local line = string.format("%d,%.6f,%.6f,%.1f",
        os.time(), data.lat or 0, data.lng or 0, data.speed or 0)
    append_line(GNSS_FILE, line, GNSS_MAX_LINES)
end

-- ========== 读取接口 ==========

-- 读取文件最后 N 行 (通用函数)
-- @param filepath 文件路径
-- @param n        读取行数 (默认 100)
-- @return table   行字符串数组
local function read_last_n(filepath, n)
    n = n or 100
    local f = io.open(filepath, "r")
    if not f then return {} end

    -- 方案: seek 到文件尾部附近, 只读最后几 KB, 不遍历整个文件
    -- 之前用 f:lines() 遍历 235,000 行需要 5 分钟, 现在只需 <100ms
    local file_size = f:seek("end")    -- 移到末尾, 返回文件大小
    if file_size == 0 then
        f:close()
        return {}
    end

    -- 估算读取字节数: 用文件对应行长 × 2 倍余量
    local line_len = LINE_LEN_READ[filepath] or AVG_LINE_LEN
    local read_bytes = n * line_len * 2
    if read_bytes > file_size then
        read_bytes = file_size  -- 文件比预期小, 读全部
    end

    -- seek 到读取起始位置
    local read_start = file_size - read_bytes
    if read_start < 0 then read_start = 0 end
    f:seek("set", read_start)

    -- 一次性读取尾部数据
    local data = f:read(read_bytes) or ""
    f:close()

    -- 按行分割
    local lines = {}
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end

    -- 第一行可能不完整 (seek 位置在行中间), 丢弃
    if read_start > 0 and #lines > 0 then
        table.remove(lines, 1)
    end

    -- 取最后 n 行
    local result = {}
    local start_idx = #lines - n + 1
    if start_idx < 1 then start_idx = 1 end
    for i = start_idx, #lines do
        result[#result + 1] = lines[i]
    end
    return result
end

-- 读取浓度记录
-- @param n 读取最后 N 条 (默认 100)
-- @return table 记录数组 { {ts=,conc=,threshold=,over=,alarm=,source=}, ... }
function mod_flash.read_conc(n)
    if not mounted then return {} end
    local lines = read_last_n(CONC_FILE, n)
    local result = {}
    for _, line in ipairs(lines) do
        local ts, conc, th, over, alarm, source = line:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),(.*)")
        if ts then
            result[#result + 1] = {
                ts        = tonumber(ts) or 0,
                conc      = tonumber(conc) or 0,
                threshold = tonumber(th) or 0,
                over      = tonumber(over) or 0,
                alarm     = tonumber(alarm) or 0,
                source    = source or "",
            }
        end
    end
    return result
end

-- 读取报警记录
-- @param n 读取最后 N 条 (默认 100)
-- @return table 记录数组 { {ts=,level=,source=}, ... }
function mod_flash.read_alarm(n)
    if not mounted then return {} end
    local lines = read_last_n(ALARM_FILE, n)
    local result = {}
    for _, line in ipairs(lines) do
        local ts, level, source = line:match("([^,]+),([^,]+),(.*)")
        if ts then
            result[#result + 1] = {
                ts     = tonumber(ts) or 0,
                level  = tonumber(level) or 0,
                source = source or "none",
            }
        end
    end
    return result
end

-- 读取坐标记录
-- @param n 读取最后 N 条 (默认 100)
-- @return table 记录数组 { {ts=,lat=,lng=,speed=}, ... }
function mod_flash.read_gps(n)
    if not mounted then return {} end
    local lines = read_last_n(GNSS_FILE, n)
    local result = {}
    for _, line in ipairs(lines) do
        local ts, lat, lng, speed = line:match("([^,]+),([^,]+),([^,]+),([^,]+)")
        if ts then
            result[#result + 1] = {
                ts    = tonumber(ts) or 0,
                lat   = tonumber(lat) or 0,
                lng   = tonumber(lng) or 0,
                speed = tonumber(speed) or 0,
            }
        end
    end
    return result
end

-- 获取 Flash 状态
-- @return table { mounted=, size_kb=, free_kb=, timestamp= }
function mod_flash.get_status()
    return app_data.get().io.flash
end

return mod_flash
