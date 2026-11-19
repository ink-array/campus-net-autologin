#requires -version 5.1
<#
    构建脚本：把源码和安装模板组装成便携包

    产物
      dist\校园网自动登录_便携包\        解压即用的目录
      dist\校园网自动登录_便携包.zip     分发包
      dist\校园网自动登录_便携包.sha256.txt  校验值

    用法
      powershell -ExecutionPolicy Bypass -File .\build.ps1
      powershell -ExecutionPolicy Bypass -File .\build.ps1 -NoZip
#>
[CmdletBinding()]
param(
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$name = '校园网自动登录_便携包'
$dist = Join-Path $root 'dist'
$pkg  = Join-Path $dist $name
$app  = Join-Path $pkg 'app'

# ---------- 0. 必要文件检查 ----------
$required = @(
    'CampusNetAutoLogin.ps1',
    'CampusNetAutoLogin.Gui.ps1',
    'app.ico',
    'packaging\install.ps1',
    'packaging\uninstall.ps1',
    'packaging\安装.cmd',
    'packaging\卸载.cmd',
    'packaging\使用说明.txt'
)
foreach ($r in $required) {
    $p = Join-Path $root $r
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少必要文件: $r" }
}

# ---------- 1. 清理旧产物（只删本项目的构建目录）----------
if (Test-Path -LiteralPath $pkg) {
    if ((Split-Path -Leaf $pkg) -ne $name) {
        throw "构建目录名不符，拒绝删除: $pkg"
    }
    Remove-Item -LiteralPath $pkg -Recurse -Force
}
New-Item -ItemType Directory -Path $app -Force | Out-Null

# ---------- 2. 组装 ----------
Copy-Item -LiteralPath (Join-Path $root 'CampusNetAutoLogin.ps1')     -Destination $app -Force
Copy-Item -LiteralPath (Join-Path $root 'CampusNetAutoLogin.Gui.ps1') -Destination $app -Force
Copy-Item -LiteralPath (Join-Path $root 'app.ico')                    -Destination $app -Force
Copy-Item -Path (Join-Path $root 'packaging\*')                       -Destination $pkg -Force

# ---------- 3. 统一成 UTF-8 BOM ----------
# PowerShell 5.1 读取无 BOM 的 UTF-8 脚本会把中文解析成乱码，必须带 BOM。
# 注意：.cmd 不要加 BOM —— cmd.exe 会把 BOM 当成命令字符，.cmd 保持纯 ASCII。
$bom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem -LiteralPath $pkg -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1', '.txt') } |
    ForEach-Object {
        $text = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($_.FullName, $text, $bom)
    }

# ---------- 4. 语法自检 ----------
$bad = 0
Get-ChildItem -LiteralPath $app -Filter *.ps1 | ForEach-Object {
    $err = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err)
    if ($err -and $err.Count) {
        $bad++
        Write-Host ("  [语法错误] {0}" -f $_.Name) -ForegroundColor Red
        $err | ForEach-Object { Write-Host ("    行{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    }
}
if ($bad -gt 0) { throw "有 $bad 个脚本存在语法错误，已中止" }

# ---------- 5. 打包与校验 ----------
if (-not $NoZip) {
    $zip = Join-Path $dist ($name + '.zip')
    if ([IO.File]::Exists($zip)) { [IO.File]::Delete($zip) }
    Compress-Archive -Path $pkg -DestinationPath $zip -CompressionLevel Optimal

    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $sumFile = Join-Path $dist ($name + '.sha256.txt')
    Set-Content -LiteralPath $sumFile -Value ("{0}  {1}.zip" -f $hash, $name) -Encoding ASCII
}

# ---------- 6. 报告 ----------
Write-Host ""
Write-Host "构建完成" -ForegroundColor Green
Write-Host ("  输出目录 : {0}" -f $dist)
Get-ChildItem -LiteralPath $pkg -Recurse -File |
    ForEach-Object { Write-Host ("    {0,-46} {1,7:N1} KB" -f $_.FullName.Substring($pkg.Length + 1), ($_.Length / 1KB)) }

if (-not $NoZip) {
    $zip = Join-Path $dist ($name + '.zip')
    Write-Host ("  压缩包   : {0}  ({1:N1} KB)" -f $zip, ((Get-Item -LiteralPath $zip).Length / 1KB))
    Write-Host ("  SHA256   : {0}" -f (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash)
}
Write-Host ""
