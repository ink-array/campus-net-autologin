#requires -version 5.1
<#
    校园网自动登录 · 便携包安装程序
    - 把程序装到当前用户的 %LOCALAPPDATA%\CampusNetAutoLogin
    - 生成桌面图标、隐藏控制台启动器
    - 注册"登录 Windows 后自动连接"的计划任务
    - 打开设置界面让对方填自己的学号密码（本包不含任何账号信息）
#>
[CmdletBinding()]
param([switch]$NoLaunch)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null

$pkg      = $PSScriptRoot
$srcDir   = Join-Path $pkg 'app'
$dstDir   = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CampusNetAutoLogin'
$me       = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$desktop  = [Environment]::GetFolderPath('Desktop')
$taskName = 'CampusNetAutoLogin'

function Say { param([string]$t, [string]$c = 'Gray') Write-Host $t -ForegroundColor $c }
function Step { param([string]$n, [string]$t) Write-Host ('  [{0}] {1}' -f $n, $t) -ForegroundColor White }

Write-Host ''
Say '  ==================================================' 'Cyan'
Say '     校园网自动登录 · 安装程序' 'Cyan'
Say '  ==================================================' 'Cyan'
Write-Host ''

# ---------------- 0. 完整性检查
$coreSrc = Join-Path $srcDir 'CampusNetAutoLogin.ps1'
$guiSrc = Join-Path $srcDir 'CampusNetAutoLogin.Gui.ps1'
$icoSrc = Join-Path $srcDir 'app.ico'
foreach ($f in @($coreSrc, $guiSrc, $icoSrc)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Say ('  [X] 安装包不完整，缺少: ' + $f) 'Red'
        exit 1
    }
}

# ---------------- 1. 安装目录
if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
Step '1/6' ('安装目录 ' + $dstDir)

# ---------------- 2. 复制程序
foreach ($f in @('CampusNetAutoLogin.ps1', 'CampusNetAutoLogin.Gui.ps1', 'app.ico')) {
    Copy-Item -LiteralPath (Join-Path $srcDir $f) -Destination (Join-Path $dstDir $f) -Force
}
Step '2/6' '程序文件已复制'

# ---------------- 3. 启动器
$corePath = Join-Path $dstDir 'CampusNetAutoLogin.ps1'
$guiPath = Join-Path $dstDir 'CampusNetAutoLogin.Gui.ps1'
$vbsGui = Join-Path $dstDir '启动.vbs'
$vbsDaemon = Join-Path $dstDir 'start-hidden.vbs'

$guiVbs = @"
' 隐藏控制台唤起图形界面
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$guiPath""", 0, False
"@
Set-Content -LiteralPath $vbsGui -Value $guiVbs -Encoding Default

$daemonVbs = @"
' 隐藏控制台启动守护进程
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$corePath"" -Action daemon", 0, False
"@
Set-Content -LiteralPath $vbsDaemon -Value $daemonVbs -Encoding Default
Step '3/6' '启动器已生成'

# ---------------- 4. 桌面图标
$lnkPath = Join-Path $desktop '校园网自动登录.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnkPath)
$sc.TargetPath = 'wscript.exe'
$sc.Arguments = ('"{0}"' -f $vbsGui)
$sc.WorkingDirectory = $dstDir
$sc.IconLocation = ('{0},0' -f (Join-Path $dstDir 'app.ico'))
$sc.Description = '校园网(Dr.COM)开机自动登录'
$sc.WindowStyle = 1
$sc.Save()
Step '4/6' ('桌面图标 ' + $lnkPath)

# ---------------- 5. 计划任务
try {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbsDaemon)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    $trigger.Delay = 'PT15S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description '校园网(Dr.COM)开机自动登录与掉线重连' -Force | Out-Null
    Step '5/6' '已注册计划任务：登录 Windows 后 15 秒自动连接'
}
catch {
    Say '' 
    Say ('  [X] 注册计划任务失败：' + $_.Exception.Message) 'Red'
    Say '      请右键「安装.cmd」→ 以管理员身份运行，然后重新安装。' 'Yellow'
}

# ---------------- 6. 启动守护
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*CampusNetAutoLogin.ps1*daemon*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
Start-Sleep -Milliseconds 600
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbsDaemon) -WindowStyle Hidden
Step '6/6' '后台守护进程已启动（每 30 秒巡检，掉线自动重连）'

# ---------------- 结束提示
Write-Host ''
Say '  --------------------------------------------------' 'DarkGray'
Say '   安装完成' 'Green'
Say '  --------------------------------------------------' 'DarkGray'
Say ('   桌面图标 : ' + $lnkPath)
Say ('   程序目录 : ' + $dstDir)
Say ('   日志文件 : ' + (Join-Path $dstDir 'login.log'))
Write-Host ''
Say '   这个包不含任何账号密码。' 'Yellow'
Say '   接下来会打开设置界面，请填写你自己的学号和密码，' 'Yellow'
Say '   点「保存并登录」即可。' 'Yellow'
Write-Host ''

if (-not $NoLaunch) {
    Start-Sleep -Seconds 1
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbsGui) -WindowStyle Hidden
    Say '   已打开设置界面…' 'Cyan'
}
