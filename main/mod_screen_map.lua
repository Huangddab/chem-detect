--[[
@module  mod_screen_map
@brief   TJC 串口屏离线地图显示模块 (多坐标系纠偏 + 多设备标记)
@version 1.5
@date    2026.09.10
功能:
  1. 将 WGS84 十进制经纬度转换为 Web Mercator 瓦片编号
  2. 通过 TJC 指令驱动屏幕从 SD 卡加载 4 块瓦片图片
  3. GPS 点定位在屏幕中心 (240, 400)，4 块瓦片围绕中心拼接
  4. 多坐标系纠偏: WGS84/GCJ02/BD09 自动转换, 屏幕指令切换
     - WGS84: GPS 原始坐标 (不纠偏)
     - GCJ02: 火星坐标 (高德/腾讯/谷歌中国区域), 默认
     - BD09:  百度坐标 (百度地图)
     屏幕指令 SET_MAP_OFFSET gcj02 / bd09 / wgs84 切换坐标系
  5. 多设备标记: 从 MQTT chem/{device_id}/notify 消息中提取其他设备 WGS84 坐标
     在地图上用 p1~p8 控件显示设备位置

屏幕布局 (480×800 竖屏, 地图区 480×480 居中):
  ┌─────────────────┐  y=0
  │    (上方留白)    │
  ├─────────────────┤  y=160
  │                 │
  │   480×480       │
  │   地图显示区     │
  │       ★(240,400)│  ← 中心标记 (固定)
  │     p1 p2 p3 ...│  ← 其他设备标记
  ├─────────────────┤  y=640
  │  t2=经度 t3=纬度 │
  └─────────────────┘  y=800

瓦片布局 (256×256 放大2倍 → 512×512, 4块拼成 1024×1024):
  ┌────────┬────────┐
  │  exp0  │  exp1  │   exp0 = (base_x,   base_y)
  ├────────┼────────┤   exp1 = (base_x+1, base_y)
  │  exp2  │  exp3  │   exp2 = (base_x,   base_y+1)
  └────────┴────────┘   exp3 = (base_x+1, base_y+1)

🤖 整体或部分由 opencode 生成
]]

local mod_screen_map = {}

-- ========== 依赖 ==========
local app_data = require "app_data"

-- ========== 常量 ==========
local PI = 3.14159265358979323846
local A  = 6378245.0                -- 克拉索夫斯基椭球体长半轴
local EE = 0.00669342162296594323   -- 克拉索夫斯基椭球体偏心率平方
local X_PI = PI * 3000.0 / 180.0     -- BD09 转换常量

local MAP_ZOOM           = 15      -- 缩放层级
local TILE_SIZE          = 256     -- 原始瓦片大小 (像素)
local TILE_SCALE         = 2       -- 放大倍数 (256→512)
local SCALED_TILE        = TILE_SIZE * TILE_SCALE  -- 512

-- 瓦片编号偏移修正 (不同瓦片源编号方式可能不同, 手动调整)
-- OSM 标准瓦片: 0,0; 高德瓦片: -1,0; 如有偏差在此调整
local TILE_OFFSET_X     = 0       -- 瓦片 X 编号偏移 (OSM 标准: 0)
local TILE_OFFSET_Y     = 0       -- 瓦片 Y 编号偏移 (OSM 标准: 0)

local SCREEN_CENTER_X    = 240     -- 地图中心点 X (屏幕坐标)
local SCREEN_CENTER_Y    = 400     -- 地图中心点 Y (屏幕坐标)
local REFRESH_INTERVAL   = 5000    -- 定时刷新间隔 (ms), 进入地图界面后每 5 秒刷新一次

-- 其他设备位置标记控件 (TJC picture 控件, 屏幕上显示设备图标)
-- 最多支持 8 个设备标记, 按 app_data.map.devices 列表顺序分配
local DEVICE_MARKERS = { "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8" }
local MAX_DEVICES = #DEVICE_MARKERS

-- 设备标记图标尺寸 (像素, 用于居中偏移)
local MARKER_W = 16
local MARKER_H = 16

-- 方向键单次移动步长 (度)
-- zoom=15 时 1 瓦片≈0.011°, STEP=0.003°≈300m, 约半个屏幕可见区域
-- (方向键移动已删除, 注释保留供参考)

-- GPS 跟随刷新阈值 (度): 位置变化超过该值才重刷地图 (约 11m), 过滤定位噪声
local GPS_MOVE_THRESHOLD = 0.0001

-- ========== 坐标纠偏算法 (WGS84 → GCJ02 → BD09) ==========

-- 判断坐标是否在中国境内 (粗略判定)
local function in_china(lat, lng)
    return lng >= 72.004 and lng <= 137.8347
       and lat >= 0.8293 and lat <= 55.8271
end

-- 纬度偏移量计算 (GCJ02 内部)
-- 注意: 参考官方 mapTile.lua, 参数为 (x=lon-105, y=lat-35), 即第一个参数是经度偏移
local function transform_lat(x, y)
    local ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y
        + 0.1 * x * y + 0.2 * math.sqrt(math.abs(x))
    ret = ret + (20.0 * math.sin(6.0 * x * PI) + 20.0 * math.sin(2.0 * x * PI)) * 2.0 / 3.0
    ret = ret + (20.0 * math.sin(y * PI) + 40.0 * math.sin(y / 3.0 * PI)) * 2.0 / 3.0
    ret = ret + (160.0 * math.sin(y / 12.0 * PI) + 320.0 * math.sin(y * PI / 30.0)) * 2.0 / 3.0
    return ret
end

-- 经度偏移量计算 (GCJ02 内部)
-- 注意: 参考官方 mapTile.lua, 参数为 (x=lon-105, y=lat-35), 即第一个参数是经度偏移
local function transform_lng(x, y)
    local ret = 300.0 + x + 2.0 * y + 0.1 * x * x
        + 0.1 * x * y + 0.1 * math.sqrt(math.abs(x))
    ret = ret + (20.0 * math.sin(6.0 * x * PI) + 20.0 * math.sin(2.0 * x * PI)) * 2.0 / 3.0
    ret = ret + (20.0 * math.sin(x * PI) + 40.0 * math.sin(x / 3.0 * PI)) * 2.0 / 3.0
    ret = ret + (150.0 * math.sin(x / 12.0 * PI) + 300.0 * math.sin(x / 30.0 * PI)) * 2.0 / 3.0
    return ret
end

-- WGS84 → GCJ02 (火星坐标, 高德/腾讯/谷歌中国区域)
local function wgs84_to_gcj02(lat, lng)
    if not in_china(lat, lng) then
        return lat, lng  -- 中国境外不做转换
    end
    -- 参考官方 mapTile.lua: transformLat(lon-105, lat-35), transformLon(lon-105, lat-35)
    local d_lat = transform_lat(lng - 105.0, lat - 35.0)
    local d_lng = transform_lng(lng - 105.0, lat - 35.0)
    local rad_lat = lat / 180.0 * PI
    local magic = math.sin(rad_lat)
    magic = 1 - EE * magic * magic
    local sqrt_magic = math.sqrt(magic)
    d_lat = (d_lat * 180.0) / ((A * (1 - EE)) / (magic * sqrt_magic) * PI)
    d_lng = (d_lng * 180.0) / (A / sqrt_magic * math.cos(rad_lat) * PI)
    return lat + d_lat, lng + d_lng
end

-- GCJ02 → BD09 (百度坐标)
local function gcj02_to_bd09(lat, lng)
    local z = math.sqrt(lng * lng + lat * lat) + 0.00002 * math.sin(lat * X_PI)
    local theta = math.atan2(lat, lng) + 0.000003 * math.cos(lng * X_PI)
    return z * math.sin(theta) + 0.006, z * math.cos(theta) + 0.0065
end

-- 根据当前坐标系设置, 对 WGS84 原始坐标进行纠偏
-- config.map_coord_system: "wgs84" / "gcj02" / "bd09"
-- @param lat 纬度 (原始 WGS84)
-- @param lng 经度 (原始 WGS84)
-- @return 纠偏后的 lat, lng
local function apply_offset(lat, lng)
    local coord = app_data.get_config("map_coord_system") or "gcj02"
    if coord == "wgs84" then
        return lat, lng
    elseif coord == "bd09" then
        local gcj_lat, gcj_lng = wgs84_to_gcj02(lat, lng)
        return gcj02_to_bd09(gcj_lat, gcj_lng)
    else  -- 默认 gcj02
        return wgs84_to_gcj02(lat, lng)
    end
end

-- 4 块瓦片控件名 + 屏幕位置(col/row) + 瓦片编号偏移(icol/irow)
-- col/row: 控件在屏幕上的位置 (0=左/上, 1=右/下)
-- icol/irow: 加载哪张瓦片 (相对 base 瓦片的偏移)
local TILES = {
    { name = "exp0", col = 0, row = 0, icol = 0, irow = 0 },  -- 左上位置, 左上瓦片
    { name = "exp1", col = 1, row = 0, icol = 1, irow = 0 },  -- 右上位置, 右上瓦片
    { name = "exp2", col = 0, row = 1, icol = 0, irow = 1 },  -- 左下位置, 左下瓦片
    { name = "exp3", col = 1, row = 1, icol = 1, irow = 1 },  -- 右下位置, 右下瓦片
}

-- ========== 模块状态 ==========
local initialized = false
local screen_api  = nil     -- 屏幕指令发送接口 (来自 callback)

-- base 瓦片状态 (初始加载时的中心瓦片)
local base_tx = 0           -- base 瓦片 X 编号
local base_ty = 0           -- base 瓦片 Y 编号
local base_px = 0           -- GPS 点在 base 瓦片内像素 X (0~255)
local base_py = 0           -- GPS 点在 base 瓦片内像素 Y (0~255)

-- 当前显示的中心坐标 (纠偏后)
local cur_lat = 0
local cur_lng = 0

-- 原始 WGS84 坐标 (坐标系切换时用于重新纠偏)
local orig_lat = 0
local orig_lng = 0

-- 手动微调偏移 (屏幕像素, 仅内存, 调试用)
local manual_offset_x = 0
local manual_offset_y = 0

-- 控件-瓦片映射: 记录每个 exp 控件当前显示的瓦片坐标
-- 用于智能切换时判断哪些瓦片可复用
local control_tiles = {}

-- 前向声明: 其他设备位置标记刷新 (在 display_at 中调用, 定义在后面)
local update_device_markers

-- ========== 数学计算: Web Mercator 投影 ==========

-- 经度 → 瓦片X (浮点)
-- @param lon  经度 (十进制, WGS84)
-- @param zoom 缩放层级
-- @return 浮点瓦片编号 (整数部分=瓦片X, 小数部分=瓦片内位置)
local function lon2tile(lon, zoom)
    return (lon + 180.0) / 360.0 * (2 ^ zoom)
end

-- 纬度 → 瓦片Y (浮点, Web Mercator)
-- @param lat  纬度 (十进制, WGS84)
-- @param zoom 缩放层级
-- @return 浮点瓦片编号
local function lat2tile(lat, zoom)
    local lat_rad = lat * PI / 180.0
    local n = 2 ^ zoom
    return (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / PI) / 2.0 * n
end

-- 完整计算: 经纬度 → 瓦片编号 + 瓦片内像素
-- @param lat  纬度 (十进制)
-- @param lng  经度 (十进制)
-- @param zoom 缩放层级
-- @return tile_x, tile_y, px, py (瓦片编号 + 瓦片内像素 0~255)
local function calc_tile(lat, lng, zoom)
    local tx_f = lon2tile(lng, zoom)
    local ty_f = lat2tile(lat, zoom)
    -- 标准瓦片编号 + 像素 (基于标准 Web Mercator)
    local tile_x = math.floor(tx_f)
    local tile_y = math.floor(ty_f)
    local px = (tx_f - tile_x) * TILE_SIZE
    local py = (ty_f - tile_y) * TILE_SIZE
    -- 瓦片编号偏移修正 (OSM 标准: 0, 高德等: -1)
    tile_x = tile_x + TILE_OFFSET_X
    tile_y = tile_y + TILE_OFFSET_Y
    return tile_x, tile_y, px, py
end

-- ========== 屏幕指令发送 ==========

-- 发送原始 TJC 指令 (通过 mod_screen 的 UART11)
-- @param cmd ASCII 指令文本 (不含结束符, 自动追加 0xFF 0xFF 0xFF)
local function send_cmd(cmd)
    if screen_api and screen_api.send_raw then
        screen_api.send_raw(cmd)
    else
        log.warn("MAP", "屏幕 API 不可用, 无法发送指令")
    end
end

-- ========== 瓦片操作 ==========

-- 构造 SD 卡瓦片路径
-- @param zoom 缩放层级
-- @param tx   瓦片 X 编号
-- @param ty   瓦片 Y 编号
-- @return 路径字符串 (如 "sd0/16/53489/28548.xi")
local function tile_path(zoom, tx, ty)
    return string.format("sd0/%d/%d/%d.xi", zoom, tx, ty)
end

-- 加载 4 块瓦片到 exp0~exp3 (发送 path 指令)
-- @param tile_x base 瓦片 X 编号
-- @param tile_y base 瓦片 Y 编号
local function load_tiles(tile_x, tile_y)
    for _, t in ipairs(TILES) do
        local tx = tile_x + t.icol
        local ty = tile_y + t.irow
        local path = tile_path(MAP_ZOOM, tx, ty)
        send_cmd(string.format('%s.path="%s"', t.name, path))
        log.info("MAP", t.name, "←", path)
    end
end

-- 更新 4 块瓦片的屏幕位置 (使 GPS 点位于屏幕中心)
-- @param px  GPS 点在 base 瓦片内像素 X (0~255)
-- @param py  GPS 点在 base 瓦片内像素 Y (0~255)
-- @param dx  额外偏移 X (屏幕像素, Phase 2 滚动用, 默认 0)
-- @param dy  额外偏移 Y (屏幕像素, Phase 2 滚动用, 默认 0)
local function update_tile_positions(px, py, dx, dy)
    dx = dx or 0
    dy = dy or 0
    -- 手动微调偏移 (屏幕像素, 仅内存)
    local ox = manual_offset_x
    local oy = manual_offset_y
    -- GPS 点在放大后瓦片中的像素位置
    local scaled_px = px * TILE_SCALE
    local scaled_py = py * TILE_SCALE
    -- exp0 左上角应该在的屏幕坐标
    local base_x = SCREEN_CENTER_X - scaled_px + dx + ox
    local base_y = SCREEN_CENTER_Y - scaled_py + dy + oy
    -- 设置 4 块瓦片位置
    for _, t in ipairs(TILES) do
        local x = math.floor(base_x + t.col * SCALED_TILE)
        local y = math.floor(base_y + t.row * SCALED_TILE)
        send_cmd(string.format("%s.x=%d", t.name, x))
        send_cmd(string.format("%s.y=%d", t.name, y))
    end
end

-- 更新坐标文本 (t2=经度, t3=纬度)
-- @param lat 纬度 (十进制)
-- @param lng 经度 (十进制)
local function update_coord_text(lat, lng)
    send_cmd(string.format('t2.txt="%.5f"', lng))
    send_cmd(string.format('t3.txt="%.5f"', lat))
    local coord = app_data.get_config("map_coord_system") or "gcj02"
    send_cmd(string.format('t4.txt="%s"', coord:upper()))
end

-- 清除地图显示 (隐藏所有瓦片 + 设备标记)
local function clear_tiles()
    for _, t in ipairs(TILES) do
        send_cmd(string.format('%s.path=""', t.name))
    end
    send_cmd('t2.txt="--"')
    send_cmd('t3.txt="--"')
    send_cmd('t4.txt="--"')
    -- 隐藏所有设备标记
    for _, marker in ipairs(DEVICE_MARKERS) do
        send_cmd(string.format("vis %s,0", marker))
    end
    app_data.update_map_state({ active = false })
    log.info("MAP", "地图已清除")
end

-- ========== 核心接口 ==========

-- 在指定坐标显示地图 (计算瓦片 + 加载 + 定位)
-- @param lat 纬度 (十进制, WGS84)
-- @param lng 经度 (十进制, WGS84)
function mod_screen_map.display_at(lat, lng)
    -- 纠偏: 根据坐标系设置自动转换
    local disp_lat, disp_lng = apply_offset(lat, lng)
    local tx, ty, px, py = calc_tile(disp_lat, disp_lng, MAP_ZOOM)
    local coord = app_data.get_config("map_coord_system") or "gcj02"

    -- 打印计算结果
    log.info("MAP", string.format(
        "原始 (%.5f,%.5f) [%s] → 显示 (%.5f,%.5f) zoom=%d 瓦片(%d,%d) 像素(%.1f,%.1f)",
        lat, lng, coord:upper(), disp_lat, disp_lng,
        MAP_ZOOM, tx, ty, px, py))
    log.info("MAP", "瓦片路径:")
    for _, t in ipairs(TILES) do
        log.info("MAP", string.format("  %s: sd0/%d/%d/%d.xi",
            t.name, MAP_ZOOM, tx + t.col, ty + t.row))
    end

    -- 保存 base 状态
    base_tx, base_ty = tx, ty
    base_px, base_py = px, py

    -- 1. 加载 4 块瓦片
    load_tiles(tx, ty)

    -- 2. 设置初始位置 (GPS 点居中, 无偏移)
    sys.wait(100)  -- 等待瓦片加载
    update_tile_positions(px, py, 0, 0)

    -- 3. 显示坐标文本 (显示纠偏后的坐标)
    update_coord_text(disp_lat, disp_lng)

    -- 保存当前坐标
    cur_lat = disp_lat   -- 纠偏后的坐标 (move 方向键用)
    cur_lng = disp_lng
    orig_lat = lat       -- 原始 WGS84 坐标 (坐标系切换时重新纠偏用)
    orig_lng = lng

    -- 初始化控件-瓦片映射 (使用 TILES 表中的 icol/irow)
    control_tiles = {}
    for _, t in ipairs(TILES) do
        control_tiles[t.name] = { tx + t.icol, ty + t.irow }
    end

    -- 4. 更新 app_data
    app_data.update_map_state({
        zoom   = MAP_ZOOM,
        tile_x = tx,
        tile_y = ty,
        px     = px,
        py     = py,
        dx     = 0,
        dy     = 0,
        lat    = disp_lat,
        lng    = disp_lng,
        active = true,
        coord_system = coord,
    })

    -- 5. 更新其他设备位置标记
    update_device_markers()

    log.info("MAP", "=== 地图显示完成 ===")
end

-- ========== 其他设备位置标记 ==========

-- 计算设备坐标在屏幕上的像素位置
-- @param dev_lat  设备纬度 (WGS84)
-- @param dev_lng  设备经度 (WGS84)
-- @return x, y  屏幕像素坐标 (可能超出地图区域, 调用方判断可见性)
local function calc_device_screen_pos(dev_lat, dev_lng)
    -- 纠偏后计算瓦片编号和像素
    local disp_lat, disp_lng = apply_offset(dev_lat, dev_lng)
    local tx, ty, px, py = calc_tile(disp_lat, disp_lng, MAP_ZOOM)
    -- 相对于 base 瓦片的有效像素
    local eff_px = px + (tx - base_tx) * TILE_SIZE
    local eff_py = py + (ty - base_ty) * TILE_SIZE
    -- 放大后屏幕坐标 (与 update_tile_positions 一致的算法)
    local scaled_px = eff_px * TILE_SCALE
    local scaled_py = eff_py * TILE_SCALE
    local x = SCREEN_CENTER_X - base_px * TILE_SCALE + scaled_px + manual_offset_x
    local y = SCREEN_CENTER_Y - base_py * TILE_SCALE + scaled_py + manual_offset_y
    return math.floor(x), math.floor(y)
end

-- 更新所有其他设备的位置标记 (p1~p8)
-- 从 app_data.map.devices 读取设备列表, 依次定位到屏幕
update_device_markers = function()
    local d = app_data.get()
    local devices = d.map.devices
    local count = #devices
    if count > MAX_DEVICES then count = MAX_DEVICES end

    for i = 1, MAX_DEVICES do
        if i <= count then
            local dev = devices[i]
            if dev.lat ~= 0 and dev.lng ~= 0 then
                local x, y = calc_device_screen_pos(dev.lat, dev.lng)
                -- 居中偏移 (图标中心对准坐标点)
                x = x - MARKER_W // 2
                y = y - MARKER_H // 2
                send_cmd(string.format("%s.x=%d", DEVICE_MARKERS[i], x))
                send_cmd(string.format("%s.y=%d", DEVICE_MARKERS[i], y))
                -- 显示标记 (vis=1)
                send_cmd(string.format("vis %s,1", DEVICE_MARKERS[i]))
                log.info("MAP", string.format("设备标记 %s ← %s (%d,%d)",
                    DEVICE_MARKERS[i], dev.device_id, x, y))
            end
        else
            -- 隐藏多余标记 (vis=0)
            send_cmd(string.format("vis %s,0", DEVICE_MARKERS[i]))
        end
    end
end

-- ========== 初始化 ==========
function mod_screen_map.init()
    -- 获取屏幕指令发送接口 (通过 app_data 回调中介, 避免直接 require mod_screen)
    screen_api = app_data.get_callback("screen_api")
    if not screen_api then
        log.warn("MAP", "screen_api 回调未注册, 地图功能不可用")
        return
    end

    initialized = true
    log.info("MAP", "地图模块初始化完成")
end

-- 设置手动微调偏移 (仅内存, 不写 fskv, 调试用)
-- @param x X 方向偏移 (屏幕像素, 正=右移 负=左移)
-- @param y Y 方向偏移 (屏幕像素, 正=下移 负=上移)
function mod_screen_map.set_manual_offset(x, y)
    manual_offset_x = x or 0
    manual_offset_y = y or 0
    log.info("MAP", string.format("手动偏移设置: x=%d, y=%d", manual_offset_x, manual_offset_y))
end

-- ========== 启动 ==========
function mod_screen_map.start()
    if not initialized then
        log.warn("MAP", "模块未初始化, 跳过启动")
        return
    end

    -- 检查功能开关
    if not app_data.get_config("screen_en") then
        log.info("MAP", "屏幕功能未启用 (screen_en=false), 跳过地图启动")
        return
    end

    -- 订阅地图开关事件 (屏幕 0x15/0x16 命令触发)
    sys.subscribe("MAP_TOGGLE", function(enable)
        if enable then
            log.info("MAP", "收到 MAP_TOGGLE 开启指令")
            sys.taskInit(function()
                sys.wait(100)  -- 等待屏幕页面切换就绪
                -- 直接用 app_data.gnss 坐标: 未定位时为测试坐标初始值, 有定位时被 update_gnss 覆盖
                local gnss = app_data.get().gnss
                mod_screen_map.display_at(gnss.lat, gnss.lng)
            end)
        else
            log.info("MAP", "收到 MAP_TOGGLE 关闭指令")
            clear_tiles()
        end
    end)

    -- 订阅坐标系变更事件 (屏幕 SET_MAP_OFFSET 指令触发)
    sys.subscribe("MAP_OFFSET_CHANGED", function()
        log.info("MAP", "收到 MAP_OFFSET_CHANGED, 重新加载地图")
        if orig_lat ~= 0 and orig_lng ~= 0 then
            sys.taskInit(function()
                -- 使用保存的原始 WGS84 坐标重新纠偏, 避免二次纠偏
                mod_screen_map.display_at(orig_lat, orig_lng)
            end)
        end
    end)

    -- 订阅手动偏移变更事件 (屏幕 0x26 命令触发, MCU 从 t5/t6 拉取后发布)
    sys.subscribe("MAP_TILE_OFFSET_CHANGED", function(x, y)
        log.info("MAP", string.format("收到 MAP_TILE_OFFSET_CHANGED: x=%d, y=%d", x, y))
        mod_screen_map.set_manual_offset(x, y)
        if orig_lat ~= 0 and orig_lng ~= 0 then
            sys.taskInit(function()
                mod_screen_map.display_at(orig_lat, orig_lng)
            end)
        end
    end)

    -- 订阅其他设备坐标更新事件 (MQTT notify 消息解析后触发, 快照/单条两种来源)
    -- 仅刷新设备标记位置, 不重新加载瓦片
    sys.subscribe("MAP_DEVICE_UPDATE", function()
        log.info("MAP", "收到设备坐标更新")
        -- 地图激活时才刷新标记
        if app_data.get().map.active then
            sys.taskInit(function()
                update_device_markers()
            end)
        end
    end)

-- 开机不自动显示地图, 由屏幕开关 (0x15/0x16) 按需触发
-- 如果上次关机时 map_en=true, 屏幕会自动发送 0x15 开启指令触发显示

    -- 地图定时刷新循环: 地图激活时, 每 5 秒刷新一次
    -- 1. 自己设备坐标: GNSS 坐标变化超过阈值时重绘地图 (display_at 含设备标记刷新)
    -- 2. 其他设备坐标: 坐标没变时单独刷新设备标记
    -- 退出地图 (0x16) 时 map.active=false, 循环自动跳过刷新
    sys.taskInit(function()
        while true do
            sys.wait(REFRESH_INTERVAL)
            if app_data.get().map.active then
                local gnss = app_data.get().gnss
                local dlat = math.abs(gnss.lat - orig_lat)
                local dlng = math.abs(gnss.lng - orig_lng)
                if dlat > GPS_MOVE_THRESHOLD or dlng > GPS_MOVE_THRESHOLD then
                    log.info("MAP", string.format("GPS 跟随刷新: (%.5f, %.5f)", gnss.lat, gnss.lng))
                    mod_screen_map.display_at(gnss.lat, gnss.lng)
                else
                    update_device_markers()
                end
            end
        end
    end)

    local coord = app_data.get_config("map_coord_system") or "gcj02"
    local gnss0 = app_data.get().gnss
    log.info("MAP", string.format("地图模块已启动 (阈值方式, 初始坐标=%.5f, %.5f, 坐标系=%s)",
        gnss0.lat, gnss0.lng, coord:upper()))
end

return mod_screen_map
