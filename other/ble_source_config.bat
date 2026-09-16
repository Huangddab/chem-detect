@echo off
chcp 65001 >nul 2>&1
:: ============================================================
::  Safex BLE Pollution Source Config Tool v1.0
::  Single-file BAT+PowerShell hybrid
::  Double-click to run, auto elevate to admin
:: ============================================================
cd /d "%~dp0"

:: Try to elevate (serial port access may need admin)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting admin privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Run embedded PowerShell code
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $ErrorActionPreference='SilentlyContinue'; $script=[System.IO.File]::ReadAllText('%~f0',[System.Text.Encoding]::GetEncoding('utf-8')); $ps=$script -replace '(?s)^.*?#PS_START#','' -replace '#PS_END#.*$',''; Invoke-Expression $ps }"
exit /b

#PS_START#
# ========== 常量 ==========
$BAUD_RATE = 115200
$UUID = "5B198FF269A011EE8C990242AC120002"
$TX_POWER_DEFAULT = "B5"
$RETRY_COUNT = 5
$RESP_TIMEOUT = 2000

# ========== 毒剂类型表 ==========
$AGENT_TYPES = @(
    @{ Idx=1;  Major="0001"; Name="沙林毒剂";   Abbr="GB"  }
    @{ Idx=2;  Major="0002"; Name="芥子气";     Abbr="HD"  }
    @{ Idx=3;  Major="0003"; Name="氯气";       Abbr="CL"  }
    @{ Idx=4;  Major="0004"; Name="氰化氢";     Abbr="HCN" }
    @{ Idx=5;  Major="0005"; Name="光气";       Abbr="CG"  }
    @{ Idx=6;  Major="0006"; Name="路易氏剂";   Abbr="L"   }
    @{ Idx=7;  Major="0007"; Name="塔崩";       Abbr="GA"  }
    @{ Idx=8;  Major="0008"; Name="VX 毒剂";    Abbr="VX"  }
    @{ Idx=9;  Major="FFFF"; Name="测试";       Abbr="TEST"}
)

# ========== 信号强度表 ==========
$TX_POWERS = @(
    @{ Idx=0;  Val="0"; Desc="0 - 最低功率" }
    @{ Idx=1;  Val="1"; Desc="1" }
    @{ Idx=2;  Val="2"; Desc="2" }
    @{ Idx=3;  Val="3"; Desc="3" }
    @{ Idx=4;  Val="4"; Desc="4 - 中等" }
    @{ Idx=5;  Val="5"; Desc="5" }
    @{ Idx=6;  Val="6"; Desc="6" }
    @{ Idx=7;  Val="7"; Desc="7" }
    @{ Idx=8;  Val="8"; Desc="8" }
    @{ Idx=9;  Val="9"; Desc="9" }
    @{ Idx=10; Val="A"; Desc="A" }
    @{ Idx=11; Val="B"; Desc="B" }
    @{ Idx=12; Val="C"; Desc="C" }
    @{ Idx=13; Val="D"; Desc="D" }
    @{ Idx=14; Val="E"; Desc="E" }
    @{ Idx=15; Val="F"; Desc="F - 最高功率" }
)

# ========== 全局串口对象 ==========
$script:serial = $null

# ========== 列举可用串口 (含厂商描述) ==========
function List-SerialPorts {
    $portList = @()
    try {
        $serialPorts = Get-WmiObject -Class Win32_SerialPort -ErrorAction SilentlyContinue
        foreach ($sp in $serialPorts) {
            $portList += @{ Name = $sp.DeviceID; Desc = $sp.Description; Manu = $sp.ProviderType }
        }
    } catch {}
    try {
        $pnpPorts = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\(COM\d+\)' }
        foreach ($pp in $pnpPorts) {
            $comName = ""
            if ($pp.Name -match '\((COM\d+)\)') { $comName = $matches[1] }
            if ($comName -ne "") {
                $devName = $pp.Name -replace '\s*\(COM\d+\)\s*$', ''
                $exists = $false
                for ($i = 0; $i -lt $portList.Count; $i++) {
                    if ($portList[$i].Name -eq $comName) { $exists = $true; break }
                }
                if (-not $exists) {
                    $portList += @{ Name = $comName; Desc = $devName; Manu = $pp.Manufacturer }
                }
            }
        }
    } catch {}
    try {
        $rawPorts = [System.IO.Ports.SerialPort]::GetPortNames()
        foreach ($rp in $rawPorts) {
            $exists = $false
            for ($i = 0; $i -lt $portList.Count; $i++) {
                if ($portList[$i].Name -eq $rp) { $exists = $true; break }
            }
            if (-not $exists) { $portList += @{ Name = $rp; Desc = ""; Manu = "" } }
        }
    } catch {}
    if ($portList.Count -eq 0) {
        Write-Host "  [错误] 未检测到任何串口" -ForegroundColor Red
        return @()
    }
    $portList = $portList | Sort-Object { [int]($_.Name -replace 'COM', '') }
    return $portList
}

# ========== 打开串口 ==========
function Open-SerialPort($portName) {
    try {
        $script:serial = New-Object System.IO.Ports.SerialPort
        $script:serial.PortName = $portName
        $script:serial.BaudRate = $BAUD_RATE
        $script:serial.DataBits = 8
        $script:serial.Parity = "None"
        $script:serial.StopBits = "One"
        $script:serial.ReadTimeout = 500
        $script:serial.WriteTimeout = 500
        $script:serial.Open()
        return $true
    } catch {
        Write-Host "  [错误] 打开串口失败: $_" -ForegroundColor Red
        return $false
    }
}

# ========== 关闭串口 ==========
function Close-SerialPort {
    if ($script:serial -and $script:serial.IsOpen) { $script:serial.Close() }
    $script:serial = $null
}

# ========== 发送 AT 指令并等待 OK ==========
function Send-ATCommand {
    param([string]$cmd, [int]$maxRetries = $RETRY_COUNT)
    for ($retry = 1; $retry -le $maxRetries; $retry++) {
        Write-Host "    [发送 $retry/$maxRetries] $cmd" -NoNewline
        try {
            $script:serial.DiscardInBuffer()
            $script:serial.Write($cmd + "`r`n")
        } catch {
            Write-Host " → 发送异常" -ForegroundColor Red
            Start-Sleep -Milliseconds 500
            continue
        }
        $response = ""
        $startTime = Get-Date
        $timeout = $RESP_TIMEOUT
        $gotOK = $false
        while (([datetime](Get-Date) - $startTime).TotalMilliseconds -lt $timeout) {
            try {
                while ($script:serial.BytesToRead -gt 0) {
                    $ch = $script:serial.ReadChar()
                    $response += [char]$ch
                    if ($response -match "OK") { $gotOK = $true }
                }
            } catch {}
            if ($gotOK) { break }
            Start-Sleep -Milliseconds 10
        }
        Start-Sleep -Milliseconds 100
        try {
            while ($script:serial.BytesToRead -gt 0) {
                $ch = $script:serial.ReadChar()
                $response += [char]$ch
            }
        } catch {}
        $cleanResp = $response -replace "`r", "" -replace "`n+", " | " -replace "\|$", ""
        if ($gotOK) {
            Write-Host " → OK" -ForegroundColor Green
            return $true, $cleanResp
        }
        Write-Host " → 无响应" -ForegroundColor Yellow
    }
    Write-Host "    [失败] 重试 $maxRetries 次未收到 OK" -ForegroundColor Red
    return $false, ""
}

# ========== 主流程 ==========
function Main {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  Safex 蓝牙污染源批量配置工具 v1.0" -ForegroundColor Cyan
    Write-Host "  iBeacon 广播设置 (MY-BT503-S)" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    # ===== 第一步: 选择串口 =====
    Write-Host "[第一步] 选择串口" -ForegroundColor Yellow
    Write-Host ""
    $ports = List-SerialPorts
    if ($ports.Count -eq 0) {
        Write-Host "请检查串口驱动是否安装, 按任意键退出..." -ForegroundColor Red
        [Console]::ReadKey() | Out-Null
        return
    }
    Write-Host "  检测到以下串口:"
    for ($i = 0; $i -lt $ports.Count; $i++) {
        $p = $ports[$i]
        $desc = $p.Desc
        $manu = $p.Manu
        $suffix = ""
        if ($desc -ne "" -and $manu -ne "") {
            $suffix = "  ($manu / $desc)"
        } elseif ($desc -ne "") {
            $suffix = "  ($desc)"
        } elseif ($manu -ne "") {
            $suffix = "  ($manu)"
        }
        Write-Host ("  {0,2}. {1}{2}" -f ($i+1), $p.Name, $suffix)
    }
    Write-Host ""
    $portChoice = Read-Host "请选择串口编号 (1-$($ports.Count))"
    $portIdx = [int]$portChoice - 1
    if ($portIdx -lt 0 -or $portIdx -ge $ports.Count) {
        Write-Host "无效选择" -ForegroundColor Red
        return
    }
    $portName = $ports[$portIdx].Name
    $portDesc = $ports[$portIdx].Desc
    if ($portDesc -ne "") {
        Write-Host "  $portName ($portDesc)" -ForegroundColor Green
    } else {
        Write-Host "  $portName" -ForegroundColor Green
    }
    Write-Host ""

    if (-not (Open-SerialPort $portName)) {
        Write-Host "按任意键退出..." -ForegroundColor Red
        [Console]::ReadKey() | Out-Null
        return
    }
    Write-Host "  串口已打开: $portName @ $BAUD_RATE bps" -ForegroundColor Green
    Write-Host ""

    # ===== AT 握手 =====
    Write-Host "[握手] 测试蓝牙模块连接..." -ForegroundColor Yellow
    $atOK, $_ = Send-ATCommand "AT" $RETRY_COUNT
    if (-not $atOK) {
        Write-Host ""
        Write-Host "  蓝牙模块无响应! 请检查:" -ForegroundColor Red
        Write-Host "  1. 蓝牙模块是否已上电" -ForegroundColor Red
        Write-Host "  2. TX/RX 是否接反" -ForegroundColor Red
        Write-Host "  3. 串口是否被其他程序占用" -ForegroundColor Red
        Close-SerialPort
        Write-Host ""
        Write-Host "按任意键退出..." -ForegroundColor Red
        [Console]::ReadKey() | Out-Null
        return
    }
    Write-Host "  蓝牙模块在线!" -ForegroundColor Green
    Write-Host ""

    # ===== 第二步: 选择信号强度 =====
    Write-Host "[第二步] 选择信号强度 (AT+TXPOWER)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  可选功率等级:"
    foreach ($p in $TX_POWERS) {
        Write-Host ("  {0,2}. {1}" -f ($p.Idx+1), $p.Desc)
    }
    Write-Host ""
    $txChoice = Read-Host "请选择信号强度编号 (1-16, 默认 5=中等)"
    if ([string]::IsNullOrWhiteSpace($txChoice)) { $txChoice = "5" }
    $txIdx = [int]$txChoice - 1
    if ($txIdx -lt 0 -or $txIdx -ge $TX_POWERS.Count) {
        Write-Host "无效选择, 使用默认值 5" -ForegroundColor Yellow
        $txIdx = 4
    }
    $txPower = $TX_POWERS[$txIdx].Val
    Write-Host "  信号强度: $txPower" -ForegroundColor Green
    Write-Host ""

    # ===== 选择广播间隔 =====
    Write-Host "  请输入广播间隔 (AT+ADVIN, 单位 ms, 默认 152)"
    $advInInput = Read-Host "广播间隔 (1-10000, 默认 152)"
    if ([string]::IsNullOrWhiteSpace($advInInput)) { $advInInput = "152" }
    $advInVal = [int]$advInInput
    if ($advInVal -lt 1 -or $advInVal -gt 10000) {
        Write-Host "无效间隔, 使用默认值 152ms" -ForegroundColor Yellow
        $advInVal = 152
    }
    Write-Host "  广播间隔: ${advInVal}ms" -ForegroundColor Green
    Write-Host ""

    # ===== 第三步: 选择毒剂类型 =====
    Write-Host "[第三步] 选择毒剂类型 (AT+ADVDATA)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  可选毒剂类型:"
    foreach ($a in $AGENT_TYPES) {
        Write-Host ("  {0,2}. [{1}] {2} ({3})" -f $a.Idx, $a.Major, $a.Name, $a.Abbr)
    }
    Write-Host ""
    $agentChoice = Read-Host "请选择毒剂编号 (1-$($AGENT_TYPES.Count))"
    $agentIdx = [int]$agentChoice - 1
    if ($agentIdx -lt 0 -or $agentIdx -ge $AGENT_TYPES.Count) {
        Write-Host "无效选择" -ForegroundColor Red
        Close-SerialPort
        return
    }
    $agent = $AGENT_TYPES[$agentIdx]
    Write-Host "  已选择: $($agent.Name) ($($agent.Abbr)), Major=$($agent.Major)" -ForegroundColor Green
    Write-Host ""

    # 输入 Minor
    $minorInput = Read-Host "请输入设备编号 Minor (1-65535, 默认 1)"
    if ([string]::IsNullOrWhiteSpace($minorInput)) { $minorInput = "1" }
    $minorVal = [int]$minorInput
    if ($minorVal -lt 1 -or $minorVal -gt 65535) {
        Write-Host "无效编号, 使用默认值 1" -ForegroundColor Yellow
        $minorVal = 1
    }
    $minorHex = "{0:X4}" -f $minorVal
    Write-Host "  设备编号 Minor: $minorHex" -ForegroundColor Green
    Write-Host ""

    # ===== 确认 =====
    $advdata = "4C000215${UUID}$($agent.Major)$minorHex$TX_POWER_DEFAULT"
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "配置确认:" -ForegroundColor Cyan
    Write-Host "  串口:       $portName" -ForegroundColor White
    Write-Host "  波特率:     $BAUD_RATE" -ForegroundColor White
    Write-Host "  信号强度:   $txPower" -ForegroundColor White
    Write-Host "  广播间隔:   ${advInVal}ms" -ForegroundColor White
    Write-Host "  毒剂:       $($agent.Name) ($($agent.Abbr))" -ForegroundColor White
    Write-Host "  Major:      $($agent.Major)" -ForegroundColor White
    Write-Host "  Minor:      $minorHex" -ForegroundColor White
    Write-Host "  ADVDATA:    $advdata" -ForegroundColor Yellow
    Write-Host "             4C00=Apple 02=15=iBeacon UUID=$UUID Major=$($agent.Major) Minor=$minorHex TX=B5" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    $confirm = Read-Host "确认写入? (Y/n)"
    if ($confirm -ne "Y" -and $confirm -ne "y" -and $confirm -ne "") {
        Write-Host "已取消" -ForegroundColor Yellow
        Close-SerialPort
        return
    }
    Write-Host ""

    # ===== 执行配置 =====
    Write-Host "[配置中] 开始写入..." -ForegroundColor Yellow
    Write-Host ""

    Write-Host "[1/6] 设置广播地址类型 AT+ADVADDR=0" -ForegroundColor Cyan
    $ok1, $resp1 = Send-ATCommand "AT+ADVADDR=0"
    if (-not $ok1) { Write-Host "  AT+ADVADDR 设置失败, 继续后续步骤..." -ForegroundColor Red }
    Write-Host ""

    Write-Host "[2/6] 设置低功耗模式 AT+LPM=1" -ForegroundColor Cyan
    $ok2, $resp2 = Send-ATCommand "AT+LPM=1"
    if (-not $ok2) { Write-Host "  AT+LPM 设置失败, 继续后续步骤..." -ForegroundColor Red }
    Write-Host ""

    Write-Host "[3/6] 清空蓝牙设备名 AT+LENAME= " -ForegroundColor Cyan
    $ok3, $resp3 = Send-ATCommand "AT+LENAME= "
    if (-not $ok3) { Write-Host "  AT+LENAME 设置失败, 继续后续步骤..." -ForegroundColor Red }
    Write-Host ""

    Write-Host "[4/6] 设置发射功率 AT+TXPOWER=$txPower" -ForegroundColor Cyan
    $ok4, $resp4 = Send-ATCommand "AT+TXPOWER=$txPower"
    if (-not $ok4) { Write-Host "  AT+TXPOWER 设置失败, 继续后续步骤..." -ForegroundColor Red }
    Write-Host ""

    Write-Host "[5/6] 设置广播间隔 AT+ADVIN=$advInVal" -ForegroundColor Cyan
    $ok5b, $resp5b = Send-ATCommand "AT+ADVIN=$advInVal"
    if (-not $ok5b) { Write-Host "  AT+ADVIN 设置失败, 继续后续步骤..." -ForegroundColor Red }
    Write-Host ""

    Write-Host "[6/6] 设置广播数据 AT+ADVDATA=$advdata" -ForegroundColor Cyan
    $ok6, $resp6 = Send-ATCommand "AT+ADVDATA=$advdata"
    if (-not $ok6) { Write-Host "  AT+ADVDATA 设置失败!" -ForegroundColor Red }
    Write-Host ""

    # ===== 第四步: 验证设置结果 =====
    Write-Host "[第四步] 验证设置结果" -ForegroundColor Yellow
    Write-Host ""
    Start-Sleep -Milliseconds 500

    Write-Host "查询 AT+ADVADDR..." -ForegroundColor Cyan
    $qOk1, $qResp1 = Send-ATCommand "AT+ADVADDR" 3
    Write-Host "  → $qResp1" -ForegroundColor $(if ($qOk1) {"Green"} else {"Red"})
    Write-Host ""

    Write-Host "查询 AT+LPM..." -ForegroundColor Cyan
    $qOk2, $qResp2 = Send-ATCommand "AT+LPM" 3
    Write-Host "  → $qResp2" -ForegroundColor $(if ($qOk2) {"Green"} else {"Red"})
    Write-Host ""

    Write-Host "查询 AT+LENAME..." -ForegroundColor Cyan
    $qOk3, $qResp3 = Send-ATCommand "AT+LENAME" 3
    Write-Host "  → $qResp3" -ForegroundColor $(if ($qOk3) {"Green"} else {"Red"})
    Write-Host ""

    Write-Host "查询 AT+TXPOWER..." -ForegroundColor Cyan
    $qOk4, $qResp4 = Send-ATCommand "AT+TXPOWER" 3
    Write-Host "  → $qResp4" -ForegroundColor $(if ($qOk4) {"Green"} else {"Red"})
    Write-Host ""

    Write-Host "查询 AT+ADVIN..." -ForegroundColor Cyan
    $qOk5b, $qResp5b = Send-ATCommand "AT+ADVIN" 3
    Write-Host "  → $qResp5b" -ForegroundColor $(if ($qOk5b) {"Green"} else {"Red"})
    Write-Host ""

    Write-Host "查询 AT+ADVDATA..." -ForegroundColor Cyan
    $qOk6, $qResp6 = Send-ATCommand "AT+ADVDATA" 3
    Write-Host "  → $qResp6" -ForegroundColor $(if ($qOk6) {"Green"} else {"Red"})
    Write-Host ""

    # ===== 结果汇总 =====
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "配置完成!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "设置结果:" -ForegroundColor White
    Write-Host "  毒剂类型:   $($agent.Name) ($($agent.Abbr))" -ForegroundColor White
    Write-Host "  Major:      $($agent.Major)" -ForegroundColor White
    Write-Host "  Minor:      $minorHex" -ForegroundColor White
    Write-Host "  TX Power:   $txPower" -ForegroundColor White
    Write-Host "  ADVIN:      ${advInVal}ms" -ForegroundColor White
    Write-Host "  ADVDATA:    $advdata" -ForegroundColor Yellow
    Write-Host "             4C00=Apple 02=15=iBeacon UUID=$UUID Major=$($agent.Major) Minor=$minorHex TX=B5" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "验证查询结果:" -ForegroundColor White
    Write-Host "  AT+ADVADDR  = $qResp1" -ForegroundColor $(if ($qOk1) {"Green"} else {"Red"})
    Write-Host "  AT+LPM      = $qResp2" -ForegroundColor $(if ($qOk2) {"Green"} else {"Red"})
    Write-Host "  AT+LENAME   = $qResp3" -ForegroundColor $(if ($qOk3) {"Green"} else {"Red"})
    Write-Host "  AT+TXPOWER   = $qResp4" -ForegroundColor $(if ($qOk4) {"Green"} else {"Red"})
    Write-Host "  AT+ADVIN     = $qResp5b" -ForegroundColor $(if ($qOk5b) {"Green"} else {"Red"})
    Write-Host "  AT+ADVDATA   = $qResp6" -ForegroundColor $(if ($qOk6) {"Green"} else {"Red"})
    Write-Host ""

    Close-SerialPort
    Write-Host "串口已关闭" -ForegroundColor Gray
    Write-Host ""
    $again = Read-Host "是否继续配置下一个设备? (Y/n)"
    if ($again -eq "Y" -or $again -eq "y" -or $again -eq "") {
        Main
    }
}

# ========== 启动 ==========
Main
#PS_END#
