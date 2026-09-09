--[[
@module  mod_screen_map
@brief   TJC 串口屏离线地图显示模块 (阈值方式瓦片切换)
@version 1.1
@date    2026.07.24
功能:
  1. 将 WGS84 十进制经纬度转换为 Web Mercator 瓦片编号
  2. 通过 TJC 指令驱动屏幕从 SD 卡加载 4 块瓦片图片
  3. GPS 点定位在屏幕中心 (240, 400)，4 块瓦片围绕中心拼接
  4. 方向键移动: 累积偏移 <256px 只做偏移滚动, >=256px 智能切换瓦片
  5. 智能切换: 复用旧瓦片, 只加载新增瓦片, 减少闪烁和 SD 卡读取
  6. 切换后余值出现在另一侧, 瓦片反向移动抵消偏移

屏幕布局 (480×800 竖屏, 地图区 480×480 居中):
  ┌─────────────────┐  y=0
  │    (上方留白)    │
  ├─────────────────┤  y=160
  │                 │
  │   480×480       │
  │   地图显示区     │
  │       ★(240,400)│  ← 中心标记 (固定)
  │                 │
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

local MAP_ZOOM           = 15      -- 缩放层级
local TILE_SIZE          = 256     -- 原始瓦片大小 (像素)
local TILE_SCALE         = 2       -- 放大倍数 (256→512)
local SCALED_TILE        = TILE_SIZE * TILE_SCALE  -- 512

local SCREEN_CENTER_X    = 240     -- 地图中心点 X (屏幕坐标)
local SCREEN_CENTER_Y    = 400     -- 地图中心点 Y (屏幕坐标)
local SWITCH_THRESHOLD   = 256     -- 瓦片切换阈值 (=SCALED_TILE/2, 半瓦片)
local REFRESH_INTERVAL   = 1000    -- 刷新间隔 (ms)

-- 方向键单次移动步长 (度)
-- zoom=15 时 1 瓦片≈0.011°, STEP=0.003°≈300m, 约半个屏幕可见区域
local MOVE_STEP          = 0.003

-- 阶段1 测试坐标 (深圳, WGS84 十进制)
local TEST_LAT = 22.614118393557618
local TEST_LNG = 113.83699825861532

-- 4 块瓦片控件名 + 相对 base 的行列偏移
local TILES = {
    { name = "exp0", col = 0, row = 0 },  -- 左上
    { name = "exp1", col = 1, row = 0 },  -- 右上
    { name = "exp2", col = 0, row = 1 },  -- 左下
    { name = "exp3", col = 1, row = 1 },  -- 右下
}

-- ========== 模块状态 ==========
local initialized = false
local screen_api  = nil     -- 屏幕指令发送接口 (来自 callback)

-- base 瓦片状态 (初始加载时的中心瓦片)
local base_tx = 0           -- base 瓦片 X 编号
local base_ty = 0           -- base 瓦片 Y 编号
local base_px = 0           -- GPS 点在 base 瓦片内像素 X (0~255)
local base_py = 0           -- GPS 点在 base 瓦片内像素 Y (0~255)

-- 当前显示的中心坐标 (方向键移动时更新)
local cur_lat = 0
local cur_lng = 0

-- 控件-瓦片映射: 记录每个 exp 控件当前显示的瓦片坐标
-- 用于智能切换时判断哪些瓦片可复用
local control_tiles = {}

-- 最近一次 smart_switch 的控件分配 (供动态定位使用)
local last_assign = nil

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
    local tile_x = math.floor(tx_f)
    local tile_y = math.floor(ty_f)
    local px = (tx_f - tile_x) * TILE_SIZE
    local py = (ty_f - tile_y) * TILE_SIZE
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
        local tx = tile_x + t.col
        local ty = tile_y + t.row
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
    -- GPS 点在放大后瓦片中的像素位置
    local scaled_px = px * TILE_SCALE
    local scaled_py = py * TILE_SCALE
    -- exp0 左上角应该在的屏幕坐标
    local base_x = SCREEN_CENTER_X - scaled_px + dx
    local base_y = SCREEN_CENTER_Y - scaled_py + dy
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
end

-- 清除地图显示 (隐藏所有瓦片)
local function clear_tiles()
    for _, t in ipairs(TILES) do
        send_cmd(string.format('%s.path=""', t.name))
    end
    send_cmd('t2.txt="--"')
    send_cmd('t3.txt="--"')
    app_data.update_map_state({ active = false })
    log.info("MAP", "地图已清除")
end

-- ========== 核心接口 ==========

-- 在指定坐标显示地图 (计算瓦片 + 加载 + 定位)
-- @param lat 纬度 (十进制, WGS84)
-- @param lng 经度 (十进制, WGS84)
function mod_screen_map.display_at(lat, lng)
    local tx, ty, px, py = calc_tile(lat, lng, MAP_ZOOM)

    -- 打印计算结果 (便于验证瓦片编号是否与 SD 卡文件匹配)
    log.info("MAP", string.format(
        "坐标 (%.5f, %.5f) zoom=%d → 瓦片 (%d, %d) 像素 (%.1f, %.1f)",
        lat, lng, MAP_ZOOM, tx, ty, px, py))
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

    -- 3. 显示坐标文本
    update_coord_text(lat, lng)

    -- 保存当前坐标
    cur_lat = lat
    cur_lng = lng

    -- 初始化控件-瓦片映射 (固定映射: exp0=左上, exp1=右上, exp2=左下, exp3=右下)
    control_tiles = {
        exp0 = { tx,     ty     },
        exp1 = { tx + 1, ty     },
        exp2 = { tx,     ty + 1 },
        exp3 = { tx + 1, ty + 1 },
    }
    last_assign = nil  -- 重置为固定分配

    -- 4. 更新 app_data
    app_data.update_map_state({
        zoom   = MAP_ZOOM,
        tile_x = tx,
        tile_y = ty,
        px     = px,
        py     = py,
        dx     = 0,
        dy     = 0,
        lat    = lat,
        lng    = lng,
        active = true,
    })

    log.info("MAP", "=== 地图显示完成 ===")
end

-- ========== 智能瓦片切换 (阈值方式) ==========
-- 只负责加载新瓦片 + 控件映射, 不负责定位
-- 定位由 move() 中的 update_tile_positions_dynamic 完成

-- @param new_tx, new_ty  新 base 瓦片编号 (已 shift 后的)
local function smart_switch(new_tx, new_ty)
    local new_set = {
        { new_tx,     new_ty     },
        { new_tx + 1, new_ty     },
        { new_tx,     new_ty + 1 },
        { new_tx + 1, new_ty + 1 },
    }
    local ctrl_names = { "exp0", "exp1", "exp2", "exp3" }

    -- 为每个新位置分配控件: 优先复用已有相同瓦片的控件
    local used = {}
    local assign = {}

    for i = 1, 4 do
        local nt = new_set[i]
        for _, ctrl in ipairs(ctrl_names) do
            if not used[ctrl] then
                local ct = control_tiles[ctrl]
                if ct and ct[1] == nt[1] and ct[2] == nt[2] then
                    assign[i] = ctrl
                    used[ctrl] = true
                    break
                end
            end
        end
        if not assign[i] then
            for _, ctrl in ipairs(ctrl_names) do
                if not used[ctrl] then
                    assign[i] = ctrl
                    used[ctrl] = true
                    break
                end
            end
        end
    end

    -- 只对瓦片变化的控件发 path 指令
    local reload_count = 0
    for i = 1, 4 do
        local ctrl = assign[i]
        local nt = new_set[i]
        local ct = control_tiles[ctrl]
        if not ct or ct[1] ~= nt[1] or ct[2] ~= nt[2] then
            local path = tile_path(MAP_ZOOM, nt[1], nt[2])
            send_cmd(string.format('%s.path="%s"', ctrl, path))
            log.info("MAP", ctrl, "←", path, "(新加载)")
            reload_count = reload_count + 1
        else
            log.info("MAP", ctrl, "复用瓦片 (" .. nt[1] .. "," .. nt[2] .. ")")
        end
    end
    log.info("MAP", string.format("智能切换: 重载 %d 块, 复用 %d 块", reload_count, 4 - reload_count))

    -- 等待新瓦片加载
    sys.wait(100)

    -- 更新控件-瓦片映射
    for i = 1, 4 do
        control_tiles[assign[i]] = { new_set[i][1], new_set[i][2] }
    end

    -- 记录控件分配 (供动态定位使用)
    last_assign = assign
end

-- 动态定位: 更新 4 块瓦片屏幕位置 (支持动态控件分配)
-- @param eff_px  GPS 相对 base 的有效像素 X (可超出 0~255)
-- @param eff_py  GPS 相对 base 的有效像素 Y
local function update_tile_positions_dynamic(eff_px, eff_py)
    local scaled_px = eff_px * TILE_SCALE
    local scaled_py = eff_py * TILE_SCALE
    local base_x = SCREEN_CENTER_X - scaled_px
    local base_y = SCREEN_CENTER_Y - scaled_py

    if last_assign then
        -- smart_switch 后的动态分配
        for i = 1, 4 do
            local ctrl = last_assign[i]
            local col = (i - 1) % 2
            local row = (i - 1) // 2
            local x = math.floor(base_x + col * SCALED_TILE)
            local y = math.floor(base_y + row * SCALED_TILE)
            send_cmd(string.format("%s.x=%d", ctrl, x))
            send_cmd(string.format("%s.y=%d", ctrl, y))
        end
    else
        -- 固定分配 (初始加载后, 未发生过 smart_switch)
        for _, t in ipairs(TILES) do
            local x = math.floor(base_x + t.col * SCALED_TILE)
            local y = math.floor(base_y + t.row * SCALED_TILE)
            send_cmd(string.format("%s.x=%d", t.name, x))
            send_cmd(string.format("%s.y=%d", t.name, y))
        end
    end
end

-- ========== 方向键移动 (阈值方式) ==========

-- 方向键移动地图中心 (上北下南左西右东)
-- 累积偏移超 SWITCH_THRESHOLD(256px=半瓦片) 才切换瓦片
-- 切换后余值出现在另一侧, 瓦片反向移动抵消偏移
-- @param direction "up"/"down"/"left"/"right"
function mod_screen_map.move(direction)
    if not app_data.get_config("map_en") then return end
    if cur_lat == 0 and cur_lng == 0 then return end

    local new_lat, new_lng = cur_lat, cur_lng
    if direction == "up" then
        new_lat = cur_lat + MOVE_STEP
    elseif direction == "down" then
        new_lat = cur_lat - MOVE_STEP
    elseif direction == "left" then
        new_lng = cur_lng - MOVE_STEP
    elseif direction == "right" then
        new_lng = cur_lng + MOVE_STEP
    else
        return
    end

    new_lat = math.max(-85.0, math.min(85.0, new_lat))
    new_lng = math.max(-180.0, math.min(180.0, new_lng))

    -- 计算新坐标的瓦片编号和像素
    local new_tx, new_ty, new_px, new_py = calc_tile(new_lat, new_lng, MAP_ZOOM)

    -- 计算相对于 base 的有效像素 (可超出 0~255)
    local eff_px = new_px + (new_tx - base_tx) * TILE_SIZE
    local eff_py = new_py + (new_ty - base_ty) * TILE_SIZE

    -- 计算屏幕偏移 (放大后的像素)
    local offset_x = (eff_px - base_px) * TILE_SCALE
    local offset_y = (eff_py - base_py) * TILE_SCALE

    log.info("MAP", string.format("方向键 %s: (%.5f,%.5f)→(%.5f,%.5f) 偏移(%.0f,%.0f)px",
        direction, cur_lat, cur_lng, new_lat, new_lng, offset_x, offset_y))

    -- 阈值判断: 偏移超过半瓦片(256px)时切换
    local shifted = false
    local shift_tx, shift_ty = 0, 0

    if math.abs(offset_x) >= SWITCH_THRESHOLD then
        -- 只有 shift 后偏移更小时才切换 (避免死区循环)
        local after = offset_x - (offset_x > 0 and SCALED_TILE or -SCALED_TILE)
        if math.abs(after) < math.abs(offset_x) then
            shift_tx = offset_x > 0 and 1 or -1
            shifted = true
        end
    end
    if math.abs(offset_y) >= SWITCH_THRESHOLD then
        local after = offset_y - (offset_y > 0 and SCALED_TILE or -SCALED_TILE)
        if math.abs(after) < math.abs(offset_y) then
            shift_ty = offset_y > 0 and 1 or -1
            shifted = true
        end
    end

    if shifted then
        -- 切换 base 瓦片 (反方向移动抵消偏移)
        base_tx = base_tx + shift_tx
        base_ty = base_ty + shift_ty
        log.info("MAP", string.format("阈值切换: base→(%d,%d) 原偏移(%.0f,%.0f)",
            base_tx, base_ty, offset_x, offset_y))

        -- 智能加载新瓦片 (复用旧瓦片)
        smart_switch(base_tx, base_ty)

        -- 重新计算有效像素 (base 已变, 余值出现在另一侧)
        eff_px = new_px + (new_tx - base_tx) * TILE_SIZE
        eff_py = new_py + (new_ty - base_ty) * TILE_SIZE
        offset_x = (eff_px - base_px) * TILE_SCALE
        offset_y = (eff_py - base_py) * TILE_SCALE
        log.info("MAP", string.format("切换后余值: 偏移(%.0f,%.0f)px", offset_x, offset_y))
    else
        log.info("MAP", string.format("偏移滚动: (%.0f,%.0f)px", offset_x, offset_y))
    end

    -- 更新 4 块瓦片位置 (GPS 点始终居中)
    update_tile_positions_dynamic(eff_px, eff_py)

    -- 更新坐标文本
    update_coord_text(new_lat, new_lng)

    -- 更新状态
    cur_lat = new_lat
    cur_lng = new_lng
    app_data.update_map_state({
        tile_x = base_tx, tile_y = base_ty,
        px = base_px, py = base_py,
        dx = offset_x, dy = offset_y,
        lat = new_lat, lng = new_lng,
    })
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
                mod_screen_map.display_at(TEST_LAT, TEST_LNG)
            end)
        else
            log.info("MAP", "收到 MAP_TOGGLE 关闭指令")
            clear_tiles()
        end
    end)

    -- 订阅方向键移动事件 (屏幕 0x17~0x1A 命令触发)
    -- 注意: sys.subscribe 回调在主线程执行, 不能直接 sys.wait
    --       用 sys.taskInit 包装, 使 move/display_at 中的 sys.wait 可正常工作
    sys.subscribe("MAP_MOVE", function(direction)
        sys.taskInit(function()
            mod_screen_map.move(direction)
        end)
    end)

-- 开机不自动显示地图, 由屏幕开关 (0x15/0x16) 按需触发
-- 如果上次关机时 map_en=true, 屏幕会自动发送 0x15 开启指令触发显示

    -- Phase 2 预留: GPS 实时刷新循环
    -- while true do
    --     sys.wait(REFRESH_INTERVAL)
    --     local d = app_data.get()
    --     if d.gnss.fixed and d.gnss.lat > 0 then
    --         -- 计算偏移并更新瓦片位置
    --     end
    -- end

    log.info("MAP", "地图模块已启动 (阈值方式, 测试坐标=%.5f, %.5f)", TEST_LAT, TEST_LNG)
end

return mod_screen_map
