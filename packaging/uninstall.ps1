#requires -version 5.1
<#
    校园网自动登录 · 卸载程序
    删除计划任务、结束守护进程、删除桌面图标；配置与日志默认保留（可选删除）
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$dstDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CampusNetAutoLogin'
$desktop = [Environment]::GetFolderPath('Desktop')
$taskName = 'CampusNetAutoLogin'

function Say { param([string]$t, [string]$c = 'Gray') Write-Host $t -ForegroundColor $c }

Write-Host ''
Say '  ==================================================' 'Cyan'
Say '     校园网自动登录 · 卸载' 'Cyan'
Say '  ==================================================' 'Cyan'
Write-Host ''

# 1. 计划任务
$t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($t) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Say '  [1/3] 已删除开机自启动任务' 'Green'
}
else {
    Say '  [1/3] 没有找到开机自启动任务（可能已删除）' 'DarkGray'
}

# 2. 守护进程
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*CampusNetAutoLogin.ps1*daemon*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch { } }
Say ("  [2/3] 已结束后台守护进程 {0} 个" -f $killed) 'Green'

# 3. 桌面图标
$lnk = Join-Path $desktop '校园网自动登录.lnk'
if (Test-Path -LiteralPath $lnk) {
    Remove-Item -LiteralPath $lnk -Force
    Say '  [3/3] 已删除桌面图标' 'Green'
}
else {
    Say '  [3/3] 桌面图标不存在' 'DarkGray'
}

Write-Host ''
$ans = Read-Host '  是否同时删除配置文件和日志？(y/N)'
if ($ans -eq 'y' -or $ans -eq 'Y') {
    # 安全护栏：只允许删自己那个目录，避免变量为空或异常时误删
    $leaf = Split-Path -Leaf $dstDir
    if ($dstDir -and $leaf -eq 'CampusNetAutoLogin' -and (Test-Path -LiteralPath $dstDir)) {
        Remove-Item -LiteralPath $dstDir -Recurse -Force -ErrorAction SilentlyContinue
        Say ('  已删除目录 ' + $dstDir) 'Green'
    }
    else {
        Say '  目录校验未通过，已跳过删除（请手动确认路径）' 'Yellow'
    }
}
else {
    Say ('  配置与日志保留在 ' + $dstDir) 'DarkGray'
}

Write-Host ''
Say '  卸载完成。' 'Cyan'
Write-Host ''
