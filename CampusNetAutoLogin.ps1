#requires -version 5.1
<#
    CampusNetAutoLogin - 校园网(Dr.COM ePortal / 哆点)自动登录

    设计要点
      * 账号密码不写死在脚本里：保存在 %LOCALAPPDATA%\CampusNetAutoLogin\config.json
        密码用 Windows DPAPI(当前用户) 加密，配置文件里没有明文。
      * 登录接口从门户前端 a40.js 的实际实现还原：
          GET http://<portal>:801/eportal/portal/login
              ?callback=dr1003&login_method=1
              &user_account=,0,<学号>&user_password=<密码>
              &wlan_user_ip=<本机IP>&wlan_user_mac=<本机MAC>
              &wlan_ac_ip=&wlan_ac_name=&jsVersion=4.1.3&terminal_type=1&lang=zh
        失败时回退到老接口 http://<portal>/drcom/login (DDDDD/upass/0MKKey)。
      * 开机自启动：计划任务(登录时) -> wscript 隐藏窗口 -> 本脚本 daemon 常驻，
        每 Interval 秒检测一次外网，掉线自动重连。

    常用指令
      .\CampusNetAutoLogin.ps1 setup                 交互式设置学号/密码
      .\CampusNetAutoLogin.ps1 show                  查看当前配置
      .\CampusNetAutoLogin.ps1 status                查看门户在线状态
      .\CampusNetAutoLogin.ps1 login                 立即登录一次
      .\CampusNetAutoLogin.ps1 once                  不在线才登录(适合放进计划任务)
      .\CampusNetAutoLogin.ps1 daemon                前台常驻守护
      .\CampusNetAutoLogin.ps1 install               安装开机自启动
      .\CampusNetAutoLogin.ps1 uninstall             卸载开机自启动
      .\CampusNetAutoLogin.ps1 log                   看最近日志
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'login', 'logout', 'status', 'once', 'daemon', 'install', 'uninstall', 'show', 'log')]
    [string]$Action = 'once',

    [string]$Account,
    [string]$Password,
    [string]$Suffix,
    [string]$PortalHost,
    [int]$Interval = 0,
    [int]$Retry = 3,
    [switch]$Force,
    [switch]$Quiet,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# 注意：某些非交互宿主里 $env:LOCALAPPDATA / $env:USERDOMAIN 为空，统一走 .NET API 兜底
function Get-LocalAppData {
    $p = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($p)) { $p = Join-Path $env:USERPROFILE 'AppData\Local' }
    return $p
}

function Get-CurrentUser {
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

$AppDir = Join-Path (Get-LocalAppData) 'CampusNetAutoLogin'
$CfgPath = Join-Path $AppDir 'config.json'
$LogPath = Join-Path $AppDir 'login.log'
$TaskName = 'CampusNetAutoLogin'
$Launcher = Join-Path $AppDir 'start-hidden.vbs'

# ---------------------------------------------------------------- 基础工具

function Ensure-AppDir {
    if (-not (Test-Path -LiteralPath $AppDir)) {
        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Ensure-AppDir
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
    if (-not $Quiet) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN' { Write-Host $line -ForegroundColor Yellow }
            'OK' { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line }
        }
    }
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $CfgPath)) { return $null }
    try { return (Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-Config {
    param($Config)
    Ensure-AppDir
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $CfgPath -Encoding UTF8
}

function Protect-Text {
    param([string]$Text)
    $sec = ConvertTo-SecureString -String $Text -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $sec)
}

function Unprotect-Text {
    param([string]$Protected)
    $sec = ConvertTo-SecureString -String $Protected
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-Http {
    param([string]$Url, [int]$TimeoutSec = 8)
    try {
        return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop)
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp -and ($resp.StatusCode -eq 301 -or $resp.StatusCode -eq 302 -or $resp.StatusCode -eq 307 -or $resp.StatusCode -eq 303)) {
            return [pscustomobject]@{ StatusCode = [int]$resp.StatusCode; Content = ''; Headers = $resp.Headers }
        }
        throw
    }
}

function ConvertFrom-Jsonp {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    $m = [regex]::Match($t, '^[A-Za-z0-9_\.]*\s*\((.*)\)\s*;?\s*$', [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) { $t = $m.Groups[1].Value }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Get-Stamp { return [DateTimeOffset]::Now.ToUnixTimeMilliseconds() }

# ---------------------------------------------------------------- 网络探测

function Get-NetContext {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
    if (-not $route) { return $null }
    $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $ip) { return $null }
    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    $mac = ''
    if ($adapter -and $adapter.MacAddress) { $mac = $adapter.MacAddress.ToLower() }
    return [pscustomobject]@{
        Ip             = $ip.IPAddress
        Mac            = $mac
        Adapter        = if ($adapter) { $adapter.Name } else { '' }
        InterfaceIndex = $route.InterfaceIndex
        Gateway        = $route.NextHop
    }
}

function Test-Online {
    # 注意：generate_204 / ncsi.txt / captive.apple.com 等在本校门户的免认证白名单里，
    # 用它们探测会永远"在线"，所以这里用不在白名单内的地址。
    $probes = @(
        @{ Url = 'http://www.msftconnecttest.com/connecttest.txt'; Expect = 'Microsoft Connect Test' },
        @{ Url = 'http://www.baidu.com/'; Expect = '' }
    )
    foreach ($p in $probes) {
        try {
            $r = Invoke-Http -Url $p.Url -TimeoutSec 8
            if ($r.StatusCode -eq 200 -and $r.Content.Length -gt 0) {
                if ([string]::IsNullOrEmpty($p.Expect)) { return $true }
                if ($r.Content -match [regex]::Escape($p.Expect)) { return $true }
            }
        }
        catch { }
    }
    return $false
}

function Get-PortalStatus {
    param($Config)
    $cfg = $Config
    if (-not $cfg) { return $null }
    $url = 'http://{0}/drcom/chkstatus?callback=dr1002&v={1}&lang=zh' -f $cfg.portalHost, (Get-Stamp)
    try {
        $r = Invoke-Http -Url $url -TimeoutSec 8
        return (ConvertFrom-Jsonp $r.Content)
    }
    catch { return $null }
}

# ---------------------------------------------------------------- 登录实现

function Resolve-PortalConfig {
    param([string]$HostName, [int]$Port)
    return [pscustomobject]@{
        portalHost    = if ($HostName) { $HostName } else { '10.8.0.3' }
        portalPort    = if ($Port -gt 0) { $Port } else { 801 }
        loginMethod   = 1
        accountPrefix = ',0,'
    }
}

function Invoke-PortalLoginOnce {
    param($Config, $Context, [string]$UserName, [string]$PlainPassword, [string]$MacFormat)

    $account = $Config.accountPrefix + $UserName
    if ($Config.accountSuffix -and $account -notlike '*@*') { $account = $account + $Config.accountSuffix }

    $mac = $Context.Mac
    switch ($MacFormat) {
        'nodash' { $mac = ($Context.Mac -replace '-', '').ToUpper() }
        'upper' { $mac = $Context.Mac.ToUpper() }
        default { $mac = $Context.Mac.ToLower() }
    }

    $pairs = [ordered]@{
        callback        = 'dr1003'
        login_method    = $Config.loginMethod
        user_account    = $account
        user_password   = $PlainPassword
        wlan_user_ip    = $Context.Ip
        wlan_user_ipv6  = ''
        wlan_user_mac   = $mac
        wlan_ac_ip      = ''
        wlan_ac_name    = ''
        jsVersion       = '4.1.3'
        terminal_type   = 1
        lang            = 'zh'
        v               = (Get-Stamp)
    }
    $query = ($pairs.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value)
        }) -join '&'
    $url = 'http://{0}:{1}/eportal/portal/login?{2}' -f $Config.portalHost, $Config.portalPort, $query

    $raw = ''
    try { $raw = (Invoke-Http -Url $url -TimeoutSec 20).Content }
    catch { return [pscustomobject]@{ Success = $false; Message = "请求失败: $($_.Exception.Message)"; Raw = ''; Endpoint = 'portal/login' } }

    $json = ConvertFrom-Jsonp $raw
    $ok = $false
    $msg = $raw
    if ($json) {
        $msg = [string]$json.msg
        if ($null -ne $json.result -and ([string]$json.result -eq '1' -or [string]$json.result -eq 'ok')) { $ok = $true }
    }
    elseif ($raw -match 'Dr\.COMWebLoginID_3') { $ok = $true; $msg = '老接口返回成功页' }

    return [pscustomobject]@{ Success = $ok; Message = $msg; Raw = $raw; Endpoint = 'portal/login' }
}

function Invoke-PortalLoginLegacy {
    param($Config, $Context, [string]$UserName, [string]$PlainPassword)

    $account = $UserName
    if ($Config.accountSuffix -and $account -notlike '*@*') { $account = $account + $Config.accountSuffix }
    $pairs = [ordered]@{
        callback = 'dr1003'
        DDDDD    = $account
        upass    = $PlainPassword
        '0MKKey' = '123456'
        R1       = '00'
        R2       = '0'
        R3       = '0'
        R6       = '0'
        para     = '00'
        v6ip     = ''
        v        = (Get-Stamp)
    }
    $query = ($pairs.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value)
        }) -join '&'
    $url = 'http://{0}/drcom/login?{1}' -f $Config.portalHost, $query

    $raw = ''
    try { $raw = (Invoke-Http -Url $url -TimeoutSec 20).Content }
    catch { return [pscustomobject]@{ Success = $false; Message = "请求失败: $($_.Exception.Message)"; Raw = ''; Endpoint = 'drcom/login' } }

    $json = ConvertFrom-Jsonp $raw
    $ok = $false
    $msg = $raw
    if ($json) {
        $msg = [string]$json.msg
        if ([string]$json.result -eq '1') { $ok = $true }
    }
    if (-not $ok -and $raw -match 'Dr\.COMWebLoginID_3') { $ok = $true; $msg = '成功页' }
    if (-not $ok -and $raw -match 'Dr\.COMWebLoginID_2') { $ok = $false; $msg = '失败页(账号或密码错误)' }
    return [pscustomobject]@{ Success = $ok; Message = $msg; Raw = $raw; Endpoint = 'drcom/login' }
}

function Test-PortalReachable {
    param($Config)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Config.portalHost, 80, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(2000, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Connect-CampusNet {
    param($Config, [int]$MaxAttempt = 3, [switch]$SkipOnlineCheck)

    if (-not $Config) { Write-Log '还没有配置账号，请先运行 setup' 'ERROR'; return $false }
    if (-not $Config.account) { Write-Log '配置里没有学号，请先运行 setup' 'ERROR'; return $false }

    $script:OffCampus = $false
    $script:OffCampusWait = 60

    # 没有默认网关/IP -> 网卡还没连上（开机初期），短间隔重试
    if (-not (Get-NetContext)) {
        $script:OffCampus = $true
        $script:OffCampusWait = 15
        Write-Log '本机还没有可用 IPv4/网关(网卡未就绪)，稍后重试' 'WARN'
        return $false
    }

    # 有网关但门户不可达 -> 已不在校园网，放慢到 5 分钟
    if (-not (Test-PortalReachable $Config)) {
        $script:OffCampus = $true
        $script:OffCampusWait = 300
        Write-Log ('门户 {0} 不可达，当前不在校园网环境，稍后再试' -f $Config.portalHost) 'WARN'
        return $false
    }

    if (-not $SkipOnlineCheck -and (Test-Online)) {
        Write-Log '外网可达，当前已在线，无需登录' 'OK'
        return $true
    }

    $ctx = Get-NetContext
    if (-not $ctx) { Write-Log '没有可用的默认网关/本机IP，可能未连上校园WiFi' 'WARN'; return $false }

    try { $plain = Unprotect-Text $Config.passwordProtected }
    catch { Write-Log '密码解密失败(换过Windows账户或配置文件被拷贝到别的机器)，请重新运行 setup' 'ERROR'; return $false }

    $best = $null
    for ($i = 1; $i -le $MaxAttempt; $i++) {
        Write-Log ("第 {0} 次尝试登录: 账号={1} IP={2} MAC={3}" -f $i, $Config.account, $ctx.Ip, $ctx.Mac)

        $res = Invoke-PortalLoginOnce -Config $Config -Context $ctx -UserName $Config.account -PlainPassword $plain -MacFormat 'dash'
        Write-Log ("  [portal/login] {0} -> {1}" -f $res.Success, $res.Message) $(if ($res.Success) { 'OK' } else { 'INFO' })
        if ($res.Success) { $best = $res; break }

        # MAC 格式可能被门户挑，换一种再试
        if ($res.Message -match 'MAC|mac|终端') {
            $res2 = Invoke-PortalLoginOnce -Config $Config -Context $ctx -UserName $Config.account -PlainPassword $plain -MacFormat 'nodash'
            Write-Log ("  [portal/login/mac-nodash] {0} -> {1}" -f $res2.Success, $res2.Message) $(if ($res2.Success) { 'OK' } else { 'INFO' })
            if ($res2.Success) { $best = $res2; break }
        }

        # 已经在线也算成功
        if ($res.Message -match '已经在线|已在线') { $best = $res; break }

        # 回退老接口
        $legacy = Invoke-PortalLoginLegacy -Config $Config -Context $ctx -UserName $Config.account -PlainPassword $plain
        Write-Log ("  [drcom/login] {0} -> {1}" -f $legacy.Success, $legacy.Message) $(if ($legacy.Success) { 'OK' } else { 'INFO' })
        if ($legacy.Success) { $best = $legacy; break }

        Start-Sleep -Seconds ([Math]::Min(5 * $i, 20))
    }

    if (-not $best) { Write-Log '登录失败，请核对学号/密码；如果是运营商账号(@cmcc/@dx/@lt)，用 -Suffix 指定后缀' 'ERROR'; return $false }

    # 登录接口说成功，还要确认外网真的通了
    for ($k = 0; $k -lt 6; $k++) {
        Start-Sleep -Seconds 2
        if (Test-Online) { Write-Log '登录成功，外网已连通' 'OK'; return $true }
    }
    Write-Log '门户返回成功，但外网仍不通(可能限速/欠费/需要网页二次确认)' 'WARN'
    return $false
}

# ---------------------------------------------------------------- 各动作

function Invoke-Setup {
    Ensure-AppDir
    $cfg = Get-Config
    if (-not $cfg) { $cfg = Resolve-PortalConfig $PortalHost 0 }

    $name = $Account
    if (-not $name) {
        $hint = if ($cfg.account) { " [当前: $($cfg.account)]" } else { '' }
        $name = Read-Host "学号/账号$hint"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $cfg.account }
    }
    if (-not $name) { Write-Log '学号不能为空' 'ERROR'; return }

    $pwd = $Password
    if ([string]::IsNullOrEmpty($pwd)) {
        $sec = Read-Host '密码(输入时不显示)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $pwd = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ([string]::IsNullOrEmpty($pwd)) { Write-Log '密码不能为空' 'ERROR'; return }

    $sfx = $Suffix
    if ($null -eq $sfx) { $sfx = if ($cfg.accountSuffix) { $cfg.accountSuffix } else { '' } }

    $hostName = if ($PortalHost) { $PortalHost } else { $cfg.portalHost }

    $obj = [pscustomobject]@{
        account           = $name
        accountSuffix     = $sfx
        passwordProtected = (Protect-Text $pwd)
        portalHost        = $hostName
        portalPort        = $cfg.portalPort
        loginMethod       = 1
        accountPrefix     = ',0,'
        intervalSeconds   = if ($cfg.intervalSeconds) { $cfg.intervalSeconds } else { 30 }
        updatedAt         = (Get-Date).ToString('s')
    }
    Save-Config $obj
    Write-Log ("已保存: 账号={0}{1}  门户={2}:{3}  密码已用DPAPI加密" -f $name, $sfx, $hostName, $obj.portalPort) 'OK'
    Write-Log ("配置文件: {0}" -f $CfgPath)
}

function Invoke-Show {
    $cfg = Get-Config
    if (-not $cfg) { Write-Host '尚未配置，请运行: .\CampusNetAutoLogin.ps1 setup'; return }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host '---------------- 当前配置 ----------------'
    Write-Host ("账号        : {0}{1}" -f $cfg.account, $cfg.accountSuffix)
    Write-Host ("密码        : ******(DPAPI 加密保存)")
    Write-Host ("门户        : http://{0}:{1}" -f $cfg.portalHost, $cfg.portalPort)
    Write-Host ("账号前缀    : {0}" -f $cfg.accountPrefix)
    Write-Host ("守护间隔    : {0} 秒" -f $cfg.intervalSeconds)
    Write-Host ("配置文件    : {0}" -f $CfgPath)
    Write-Host ("开机自启动  : {0}" -f $(if ($task) { '已安装 (' + $task.State + ')' } else { '未安装' }))
    Write-Host '------------------------------------------'
}

function Invoke-Status {
    $cfg = Get-Config
    if (-not $cfg) {
        if ($Json) { '{"ok":false,"error":"no-config"}' } else { Write-Host '尚未配置，请先设置账号密码' }
        return
    }
    $online = Test-Online
    $ctx = Get-NetContext
    $st = Get-PortalStatus $cfg

    $ip = ''; $mac = ''; $adapter = ''
    if ($ctx) { $ip = $ctx.Ip; $mac = $ctx.Mac; $adapter = $ctx.Adapter }
    $pres = $null; $uid = ''; $olt = 0
    if ($st) {
        $pres = $st.result; $uid = [string]$st.uid
        if ($st.oltime) { $olt = [double]$st.oltime }
    }

    if ($Json) {
        $o = [ordered]@{
            ok = $true; online = [bool]$online; ip = $ip; mac = $mac; adapter = $adapter
            portalResult = $pres; uid = $uid; oltime = $olt
            account = $cfg.account; suffix = [string]$cfg.accountSuffix
            portal = ('{0}:{1}' -f $cfg.portalHost, $cfg.portalPort)
        }
        Write-Output ($o | ConvertTo-Json -Compress)
        return
    }

    Write-Host ("外网连通    : {0}" -f $(if ($online) { '是' } else { '否' }))
    if ($ctx) { Write-Host ("本机        : {0}  MAC {1}  网卡 {2}" -f $ctx.Ip, $ctx.Mac, $ctx.Adapter) }
    if ($st) {
        Write-Host ("门户状态    : result={0}  账号={1}" -f $st.result, $st.uid)
        if ($st.oltime) { Write-Host ("在线时长    : {0:N1} 小时" -f ($st.oltime / 3600)) }
    }
    else { Write-Host '门户状态    : 无法获取(drcom/chkstatus)' }
}

function Invoke-Logout {
    $cfg = Get-Config
    if (-not $cfg) { return }
    $ctx = Get-NetContext
    if (-not $ctx) { Write-Log '无本机IP' 'WARN'; return }
    $url = 'http://{0}:{1}/eportal/portal/logout?callback=dr1004&user_account={2}&wlan_user_ip={3}&wlan_user_mac={4}&jsVersion=4.1.3&v={5}&lang=zh' -f `
        $cfg.portalHost, $cfg.portalPort, [uri]::EscapeDataString($cfg.account), $ctx.Ip, $ctx.Mac, (Get-Stamp)
    try {
        $r = Invoke-Http -Url $url -TimeoutSec 15
        Write-Log ("注销返回: {0}" -f $r.Content.Trim()) 'WARN'
    }
    catch { Write-Log ("注销失败: {0}" -f $_.Exception.Message) 'ERROR' }
}

function Invoke-Daemon {
    $cfg = Get-Config

    # 全新安装、还没填账号时：静静待机，不要反复尝试/刷日志
    if (-not $cfg -or -not $cfg.account) {
        Write-Log '尚未配置账号，守护进程待机中（在界面里填好学号密码即可）' 'WARN'
        while ($true) {
            Start-Sleep -Seconds 20
            $cfg = Get-Config
            if ($cfg -and $cfg.account) { Write-Log '检测到账号配置，开始工作'; break }
        }
    }

    $every = if ($Interval -gt 0) { $Interval } else { if ($cfg.intervalSeconds) { $cfg.intervalSeconds } else { 30 } }

    Write-Log ("守护进程启动: 每 {0} 秒检查一次, 账号 {1}" -f $every, $cfg.account)
    $wasOnline = $null
    $failStreak = 0

    while ($true) {
        try {
            $online = Test-Online
            if ($online) {
                if ($wasOnline -ne $true) { Write-Log '在线' 'OK'; $wasOnline = $true }
                $failStreak = 0
            }
            else {
                if ($wasOnline -ne $false) { Write-Log '检测到未认证/掉线，开始登录' 'WARN'; $wasOnline = $false }
                $cfg = Get-Config
                if (Connect-CampusNet -Config $cfg -MaxAttempt $Retry -SkipOnlineCheck) {
                    $wasOnline = $true
                    $failStreak = 0
                }
                else {
                    $failStreak++
                    if ($script:OffCampus) {
                        # 网卡未就绪(开机初期) 15 秒重试；已不在校园网则 5 分钟
                        Start-Sleep -Seconds ([int]$script:OffCampusWait)
                        continue
                    }
                    $backoff = [Math]::Min(300, 30 * [Math]::Pow(2, [Math]::Min($failStreak, 4)))
                    Write-Log ("登录未成功，{0} 秒后再试" -f [int]$backoff) 'WARN'
                    Start-Sleep -Seconds ([int]$backoff)
                    continue
                }
            }
        }
        catch { Write-Log ("守护循环异常: {0}" -f $_.Exception.Message) 'ERROR' }

        Start-Sleep -Seconds $every
    }
}

function Invoke-Install {
    Ensure-AppDir
    $src = $PSCommandPath
    $dst = Join-Path $AppDir 'CampusNetAutoLogin.ps1'
    if ($src -and $src -ne $dst) { Copy-Item -LiteralPath $src -Destination $dst -Force }

    $vbs = @"
' 隐藏窗口启动守护进程(避免黑框一闪)
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$dst"" -Action daemon", 0, False
"@
    Set-Content -LiteralPath $Launcher -Value $vbs -Encoding ASCII

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $Launcher)
    $who = Get-CurrentUser
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $who
    $trigger.Delay = 'PT15S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description '校园网(Dr.COM)开机自动登录与掉线重连' -Force | Out-Null

    Write-Log ("已安装开机自启动: 任务 {0} (登录后15秒启动, 常驻守护)" -f $TaskName) 'OK'
    Write-Log ("程序副本: {0}" -f $dst)

    # 立刻起一个守护，省得等下次开机（先结束旧实例，避免双守护）
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*CampusNetAutoLogin.ps1*daemon*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
    Start-Sleep -Seconds 1
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $Launcher) -WindowStyle Hidden
    Write-Log '守护进程已在后台启动'
}

function Invoke-Uninstall {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Log '已删除计划任务' 'OK' }
    else { Write-Log '没有找到计划任务' 'WARN' }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*CampusNetAutoLogin.ps1*' -and $_.CommandLine -like '*daemon*' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force; Write-Log ("已结束守护进程 {0}" -f $_.ProcessId) 'OK' } catch { } }
    Write-Log '配置文件保留，如需清空请删除目录: ' + $AppDir
}

function Invoke-LogTail {
    if (-not (Test-Path -LiteralPath $LogPath)) { Write-Host '还没有日志'; return }
    Get-Content -LiteralPath $LogPath -Tail 30 -Encoding UTF8
}

# ---------------------------------------------------------------- 入口

Ensure-AppDir

switch ($Action) {
    'setup' { Invoke-Setup }
    'show' { Invoke-Show }
    'status' { Invoke-Status }
    'login' {
        $cfg = Get-Config
        $ok = Connect-CampusNet -Config $cfg -MaxAttempt $Retry -SkipOnlineCheck:([bool]$Force)
        if ($Json) {
            $tail = @()
            if (Test-Path -LiteralPath $LogPath) { $tail = @(Get-Content -LiteralPath $LogPath -Tail 12 -Encoding UTF8) }
            Write-Output ([ordered]@{ ok = [bool]$ok; tail = $tail } | ConvertTo-Json -Compress)
            return
        }
        if (-not $ok) { exit 1 }
    }
    'once' {
        $cfg = Get-Config
        $ok = Connect-CampusNet -Config $cfg -MaxAttempt 1
        if ($Json) {
            $tail = @()
            if (Test-Path -LiteralPath $LogPath) { $tail = @(Get-Content -LiteralPath $LogPath -Tail 12 -Encoding UTF8) }
            Write-Output ([ordered]@{ ok = [bool]$ok; tail = $tail } | ConvertTo-Json -Compress)
            return
        }
        if (-not $ok) { exit 1 }
    }
    'daemon' { Invoke-Daemon }
    'logout' { Invoke-Logout }
    'install' { Invoke-Install }
    'uninstall' { Invoke-Uninstall }
    'log' { Invoke-LogTail }
}
