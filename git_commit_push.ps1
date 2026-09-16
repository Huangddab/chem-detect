# git_commit_push.ps1
# 多设备位置快照功能链提交脚本 (两个原子提交 + push)
# 运行: powershell -ExecutionPolicy Bypass -File .\git_commit_push.ps1

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

Write-Host "==> 检查 git 仓库..." -ForegroundColor Cyan
if (-not (Test-Path .git)) {
    Write-Host "不在 git 仓库根目录, 退出" -ForegroundColor Red
    exit 1
}

# 提交 1: 设备端快照解析 + 超时守护 + WiFi 调参 + 文档 + 版本
Write-Host "`n==> 提交 1: 设备端快照解析与超时守护" -ForegroundColor Cyan
git add main/app_data.lua main/mod_mqtt.lua main/mod_screen_map.lua main/main.lua docs/通信协议文档.md
$staged = git diff --cached --name-only
if (-not $staged) {
    Write-Host "  无改动, 跳过" -ForegroundColor Yellow
} else {
    $msg1 = @"
feat(mqtt): 多设备位置快照解析与超时守护 ✨

新增 type=locations 全量快照解析（devices 数组缺席即下线），兼容旧单条坐标格式；
过期快照单调递增检查丢弃（不依赖本地时钟），时间戳兼容秒/毫秒；
app_data 新增 update_map_devices 全量替换接口；
notify 消息 30 秒超时守护自动清空设备列表并清除屏幕标记；
WiFi 就绪等待重试 30 -> 50 次；VERSION 001.004.000 -> 001.006.001。

🤖 由 opencode 生成
"@
    $tmp1 = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp1, $msg1, [System.Text.UTF8Encoding]::new($false))
    git commit -F $tmp1
    Remove-Item $tmp1
    Write-Host "  提交完成" -ForegroundColor Green
}

# 提交 2: 模拟服务器工具
Write-Host "`n==> 提交 2: MQTT 位置快照模拟服务器" -ForegroundColor Cyan
git add other/mqtt_location_sim.py
$staged = git diff --cached --name-only
if (-not $staged) {
    Write-Host "  无改动, 跳过" -ForegroundColor Yellow
} else {
    $msg2 = @"
feat(tools): 新增 MQTT 位置快照模拟服务器 ✨

Python + paho-mqtt 实现，每 5 秒向 chem/notify 发布随机 1~8 台设备的
全量位置快照，坐标围绕 (22.614, 113.837) 随机游走，
用于设备端快照解析与超时守护联调测试。

🤖 由 opencode 生成
"@
    $tmp2 = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp2, $msg2, [System.Text.UTF8Encoding]::new($false))
    git commit -F $tmp2
    Remove-Item $tmp2
    Write-Host "  提交完成" -ForegroundColor Green
}

# 推送
Write-Host "`n==> 推送到远程..." -ForegroundColor Cyan
git push
Write-Host "  推送完成" -ForegroundColor Green

# 结果
Write-Host "`n==> 当前状态:" -ForegroundColor Cyan
git status --short
Write-Host "`n最近 3 条提交:" -ForegroundColor Cyan
git log --oneline -3
Write-Host "`n完成。" -ForegroundColor Green