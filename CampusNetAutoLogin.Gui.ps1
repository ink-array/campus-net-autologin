#requires -version 5.1
<#
    CampusNetAutoLogin.Gui.ps1  ——  校园网自动登录 · 图形界面
    纯 PowerShell + WinForms（Windows 自带），无第三方依赖。
    由 启动.vbs 以隐藏控制台方式唤起。
#>
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using System.Runtime.InteropServices;

namespace CampusUI
{
    public static class Win32
    {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool ReleaseCapture();
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
    }

    public static class Gfx
    {
        public static GraphicsPath Round(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            int d = radius * 2;
            if (radius <= 0 || r.Width <= d || r.Height <= d) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
        public static Color Mix(Color a, Color b, double t)
        {
            if (t < 0) t = 0; if (t > 1) t = 1;
            return Color.FromArgb(
                (int)(a.R + (b.R - a.R) * t),
                (int)(a.G + (b.G - a.G) * t),
                (int)(a.B + (b.B - a.B) * t));
        }
    }

    public class Card : Panel
    {
        public int Radius = 12;
        public Color FillColor = Color.FromArgb(21, 26, 34);
        public Color BorderColor = Color.FromArgb(35, 43, 54);
        public Card()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(14, 17, 22);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Gfx.Round(r, Radius))
            {
                if (FillColor.A > 0) { using (var b = new SolidBrush(FillColor)) e.Graphics.FillPath(b, path); }
                if (BorderColor.A > 0) { using (var pen = new Pen(BorderColor)) e.Graphics.DrawPath(pen, path); }
            }
        }
    }

    public class PillButton : Control
    {
        public int Radius = 10;
        public Color FillColor = Color.FromArgb(47, 111, 235);
        public Color HoverColor = Color.Empty;
        public Color PressColor = Color.Empty;
        public Color BorderColor = Color.Empty;
        public Color DisabledColor = Color.FromArgb(28, 34, 43);
        private bool hover, press;

        public PillButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            Cursor = Cursors.Hand;
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold);
            ForeColor = Color.White;
            BackColor = Color.FromArgb(14, 17, 22);
            TabStop = false;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; press = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { press = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { press = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            Color fill = Enabled ? FillColor : DisabledColor;
            if (Enabled && press) fill = PressColor.IsEmpty ? Gfx.Mix(fill, Color.Black, 0.18) : PressColor;
            else if (Enabled && hover) fill = HoverColor.IsEmpty ? Gfx.Mix(fill, Color.White, 0.14) : HoverColor;

            using (var path = Gfx.Round(r, Radius))
            {
                if (fill.A > 0) { using (var b = new SolidBrush(fill)) g.FillPath(b, path); }
                if (BorderColor.A > 0) { using (var pen = new Pen(BorderColor)) g.DrawPath(pen, path); }
            }
            Color tc = Enabled ? ForeColor : Color.FromArgb(104, 116, 132);
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, tc,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
        }
    }
}
'@

Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System', 'System.Drawing', 'System.Windows.Forms'
[void][CampusUI.Win32]::SetProcessDPIAware()

# 把 UI 线程的未处理异常写进文件，避免只弹一个看不清的对话框
$script:crashLog = Join-Path $env:TEMP 'campus_gui_crash.log'
try {
    [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
    [Windows.Forms.Application]::add_ThreadException({
            param($s, $e)
            $t = $e.Exception
            $txt = "==== {0} ====`r`n{1}`r`n--- stack ---`r`n{2}`r`n" -f (Get-Date).ToString('s'), $t.ToString(), $t.StackTrace
            Add-Content -LiteralPath $script:crashLog -Value $txt -Encoding UTF8
        })
}
catch { }

# ---------------------------------------------------------------- DPI / 颜色 / 尺寸

$gfx = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$S = $gfx.DpiX / 96.0
$gfx.Dispose()
if ($S -le 0) { $S = 1 }

function P { param([double]$v) return [int][Math]::Round($v * $S) }
function Hex { param([string]$h) return [Drawing.ColorTranslator]::FromHtml($h) }
function FontOf { param([double]$pt, [string]$style = 'Regular')
    $fs = [Drawing.FontStyle]([Enum]::Parse([Drawing.FontStyle], $style))
    return (New-Object Drawing.Font('Microsoft YaHei UI', $pt, $fs, [Drawing.GraphicsUnit]::Point))
}

$C = @{
    Bg      = Hex '#0E1116'
    Card    = Hex '#151A22'
    Card2   = Hex '#12171E'
    Border  = Hex '#232C38'
    Border2 = Hex '#1E262F'
    Field   = Hex '#0F141B'
    Text    = Hex '#E7EEF8'
    Sub     = Hex '#8794A6'
    Dim     = Hex '#5C6A7C'
    Accent  = Hex '#2F6FEB'
    Accent2 = Hex '#3F80FA'
    Ok      = Hex '#2EA043'
    Err     = Hex '#E5534B'
    Warn    = Hex '#D29922'
    Sec     = Hex '#1E2631'
    SecHov  = Hex '#27313F'
    SecTxt  = Hex '#C8D3E1'
}

$script:core = Join-Path $PSScriptRoot 'CampusNetAutoLogin.ps1'
if (-not (Test-Path -LiteralPath $script:core)) {
    $script:core = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CampusNetAutoLogin\CampusNetAutoLogin.ps1'
}
$script:dataDir = Split-Path -Parent $script:core
$script:cfgPath = Join-Path $script:dataDir 'config.json'
$script:logPath = Join-Path $script:dataDir 'login.log'

$script:job = $null
$script:pending = ''
$script:busy = $false

# ---------------------------------------------------------------- 窗体

$form = New-Object Windows.Forms.Form
$form.Text = '校园网自动登录'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size((P 520), (P 654))
$form.BackColor = $C.Bg
$form.Font = FontOf 9
$form.KeyPreview = $true
$form.ShowInTaskbar = $true

$icoFile = Join-Path $PSScriptRoot 'app.ico'
if (Test-Path -LiteralPath $icoFile) {
    try { $form.Icon = New-Object Drawing.Icon($icoFile) } catch { }
}

$form.Add_Shown({
        $form.Region = New-Object Drawing.Region ([CampusUI.Gfx]::Round((New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)), (P 14)))
        $form.Invalidate()
    })
$form.Add_Paint({
        $g = $_.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $bw = $form.Width - 1
        $bh = $form.Height - 1
        $pen = New-Object Drawing.Pen($C.Border)
        $path = [CampusUI.Gfx]::Round((New-Object Drawing.Rectangle(0, 0, $bw, $bh)), (P 14))
        $g.DrawPath($pen, $path)
        $pen.Dispose(); $path.Dispose()
    })

function Enable-Drag {
    param($ctrl)
    $ctrl.Add_MouseDown({
            [void][CampusUI.Win32]::ReleaseCapture()
            [void][CampusUI.Win32]::SendMessage($form.Handle, 0xA1, 0x2, 0)
        })
}

# ---------------------------------------------------------------- 顶部标题

$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = '校园网自动登录'
$lblTitle.Font = FontOf 13.5 'Bold'
$lblTitle.ForeColor = $C.Text
$lblTitle.AutoSize = $true
$lblTitle.BackColor = $C.Bg
$lblTitle.Location = New-Object Drawing.Point((P 22), (P 15))
$form.Controls.Add($lblTitle)

$lblSub = New-Object Windows.Forms.Label
$lblSub.Text = 'Dr.COM 门户 · 开机自动连接 · 掉线自动重连'
$lblSub.Font = FontOf 8.5
$lblSub.ForeColor = $C.Sub
$lblSub.AutoSize = $true
$lblSub.BackColor = $C.Bg
$lblSub.Location = New-Object Drawing.Point((P 23), (P 47))
$form.Controls.Add($lblSub)

$btnClose = New-Object CampusUI.PillButton
$btnClose.Text = '✕'
$btnClose.Font = FontOf 9
$btnClose.FillColor = [Drawing.Color]::Transparent
$btnClose.HoverColor = (Hex '#2A1B1B')
$btnClose.ForeColor = $C.Sub
$btnClose.Size = New-Object Drawing.Size((P 30), (P 30))
$btnClose.Location = New-Object Drawing.Point((P 468), (P 14))
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

$btnMin = New-Object CampusUI.PillButton
$btnMin.Text = '—'
$btnMin.Font = FontOf 9
$btnMin.FillColor = [Drawing.Color]::Transparent
$btnMin.HoverColor = (Hex '#222A35')
$btnMin.ForeColor = $C.Sub
$btnMin.Size = New-Object Drawing.Size((P 30), (P 30))
$btnMin.Location = New-Object Drawing.Point((P 434), (P 14))
$btnMin.Add_Click({ $form.WindowState = 'Minimized' })
$form.Controls.Add($btnMin)

Enable-Drag $form
Enable-Drag $lblTitle
Enable-Drag $lblSub

# ---------------------------------------------------------------- 状态卡片

$card = New-Object CampusUI.Card
$card.Location = New-Object Drawing.Point((P 22), (P 80))
$card.Size = New-Object Drawing.Size((P 476), (P 106))
$card.Radius = (P 12)
$card.FillColor = $C.Card
$card.BorderColor = $C.Border
$card.BackColor = $C.Bg
$form.Controls.Add($card)

$lblDot = New-Object Windows.Forms.Label
$lblDot.Text = '●'
$lblDot.Font = FontOf 11
$lblDot.ForeColor = $C.Dim
$lblDot.AutoSize = $true
$lblDot.BackColor = $C.Card
$lblDot.Location = New-Object Drawing.Point((P 18), (P 16))
$card.Controls.Add($lblDot)

$lblState = New-Object Windows.Forms.Label
$lblState.Text = '正在检测…'
$lblState.Font = FontOf 11.5 'Bold'
$lblState.ForeColor = $C.Text
$lblState.AutoSize = $true
$lblState.BackColor = $C.Card
$lblState.Location = New-Object Drawing.Point((P 44), (P 13))
$card.Controls.Add($lblState)

$lblInfo = New-Object Windows.Forms.Label
$lblInfo.Text = '—'
$lblInfo.Font = FontOf 8.5
$lblInfo.ForeColor = $C.Sub
$lblInfo.AutoSize = $true
$lblInfo.BackColor = $C.Card
$lblInfo.Location = New-Object Drawing.Point((P 45), (P 47))
$card.Controls.Add($lblInfo)

$lblPortal = New-Object Windows.Forms.Label
$lblPortal.Text = '—'
$lblPortal.Font = FontOf 8.5
$lblPortal.ForeColor = $C.Dim
$lblPortal.AutoSize = $true
$lblPortal.BackColor = $C.Card
$lblPortal.Location = New-Object Drawing.Point((P 45), (P 69))
$card.Controls.Add($lblPortal)

# ---------------------------------------------------------------- 输入区

function New-Field {
    param([string]$Caption, [int]$X, [int]$Y, [int]$W, [switch]$Secret)

    $l = New-Object Windows.Forms.Label
    $l.Text = $Caption
    $l.Font = FontOf 8.5
    $l.ForeColor = $C.Sub
    $l.AutoSize = $true
    $l.BackColor = $C.Bg
    $l.Location = New-Object Drawing.Point($X, $Y)
    $form.Controls.Add($l)

    $box = New-Object CampusUI.Card
    $box.Location = New-Object Drawing.Point($X, ($Y + (P 20)))
    $box.Size = New-Object Drawing.Size($W, (P 40))
    $box.Radius = (P 9)
    $box.FillColor = $C.Field
    $box.BorderColor = $C.Border2
    $box.BackColor = $C.Bg
    $form.Controls.Add($box)

    $tb = New-Object Windows.Forms.TextBox
    $tb.BorderStyle = 'None'
    $tb.BackColor = $C.Field
    $tb.ForeColor = $C.Text
    $tb.Font = (New-Object Drawing.Font('Microsoft YaHei UI', 10))
    $tb.Location = New-Object Drawing.Point((P 13), (P 9))
    $tb.Width = $W - (P 26)
    if ($Secret) { $tb.UseSystemPasswordChar = $true }
    $box.Controls.Add($tb)

    return $tb
}

$txtAccount = New-Field -Caption '学号 / 账号' -X (P 22) -Y (P 204) -W (P 476)

$txtPass = New-Field -Caption '密码（留空表示不修改已保存的密码）' -X (P 22) -Y (P 276) -W (P 476) -Secret
$txtPass.MaxLength = 64

$btnEye = New-Object Windows.Forms.Label
$btnEye.Text = '显示密码'
$btnEye.Font = FontOf 8.5
$btnEye.ForeColor = $C.Accent2
$btnEye.AutoSize = $true
$btnEye.BackColor = $C.Bg
$btnEye.Cursor = 'Hand'
$btnEye.Location = New-Object Drawing.Point((P 452), (P 274))
$btnEye.Add_Click({
        $txtPass.UseSystemPasswordChar = -not $txtPass.UseSystemPasswordChar
        if ($txtPass.UseSystemPasswordChar) { $btnEye.Text = '显示密码' } else { $btnEye.Text = '隐藏密码' }
    })
$form.Controls.Add($btnEye)

$txtSuffix = New-Field -Caption '运营商后缀（可留空）' -X (P 22) -Y (P 348) -W (P 140)
$txtPortal = New-Field -Caption '门户地址' -X (P 174) -Y (P 348) -W (P 324)

# ---------------------------------------------------------------- 按钮

$btnSave = New-Object CampusUI.PillButton
$btnSave.Text = '保存并登录'
$btnSave.Font = FontOf 9.5 'Bold'
$btnSave.FillColor = $C.Accent
$btnSave.HoverColor = $C.Accent2
$btnSave.Size = New-Object Drawing.Size((P 200), (P 44))
$btnSave.Location = New-Object Drawing.Point((P 22), (P 416))
$form.Controls.Add($btnSave)

$btnCheck = New-Object CampusUI.PillButton
$btnCheck.Text = '检测状态'
$btnCheck.FillColor = $C.Sec
$btnCheck.HoverColor = $C.SecHov
$btnCheck.ForeColor = $C.SecTxt
$btnCheck.Size = New-Object Drawing.Size((P 130), (P 44))
$btnCheck.Location = New-Object Drawing.Point((P 230), (P 416))
$form.Controls.Add($btnCheck)

$btnLog = New-Object CampusUI.PillButton
$btnLog.Text = '打开日志'
$btnLog.FillColor = $C.Sec
$btnLog.HoverColor = $C.SecHov
$btnLog.ForeColor = $C.SecTxt
$btnLog.Size = New-Object Drawing.Size((P 130), (P 44))
$btnLog.Location = New-Object Drawing.Point((P 368), (P 416))
$form.Controls.Add($btnLog)

# ---------------------------------------------------------------- 自启动开关

$lblAuto = New-Object Windows.Forms.Label
$lblAuto.Text = '开机自动连接'
$lblAuto.Font = FontOf 9 'Bold'
$lblAuto.ForeColor = $C.Text
$lblAuto.AutoSize = $true
$lblAuto.BackColor = $C.Bg
$lblAuto.Location = New-Object Drawing.Point((P 22), (P 477))
$form.Controls.Add($lblAuto)

$lblAutoState = New-Object Windows.Forms.Label
$lblAutoState.Text = '读取中…'
$lblAutoState.Font = FontOf 8.5
$lblAutoState.ForeColor = $C.Sub
$lblAutoState.AutoSize = $true
$lblAutoState.BackColor = $C.Bg
$lblAutoState.Location = New-Object Drawing.Point((P 118), (P 479))
$form.Controls.Add($lblAutoState)

$btnAuto = New-Object CampusUI.PillButton
$btnAuto.Text = '…'
$btnAuto.Font = FontOf 8.5
$btnAuto.FillColor = $C.Sec
$btnAuto.HoverColor = $C.SecHov
$btnAuto.ForeColor = $C.SecTxt
$btnAuto.Size = New-Object Drawing.Size((P 84), (P 32))
$btnAuto.Location = New-Object Drawing.Point((P 414), (P 472))
$form.Controls.Add($btnAuto)

# ---------------------------------------------------------------- 日志

$lblLog = New-Object Windows.Forms.Label
$lblLog.Text = '运行日志'
$lblLog.Font = FontOf 8.5
$lblLog.ForeColor = $C.Sub
$lblLog.AutoSize = $true
$lblLog.BackColor = $C.Bg
$lblLog.Location = New-Object Drawing.Point((P 22), (P 510))
$form.Controls.Add($lblLog)

$cardLog = New-Object CampusUI.Card
$cardLog.Location = New-Object Drawing.Point((P 22), (P 528))
$cardLog.Size = New-Object Drawing.Size((P 476), (P 106))
$cardLog.Radius = (P 10)
$cardLog.FillColor = $C.Card2
$cardLog.BorderColor = $C.Border2
$cardLog.BackColor = $C.Bg
$form.Controls.Add($cardLog)

$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = 'None'
$txtLog.ScrollBars = 'None'
$txtLog.BackColor = $C.Card2
$txtLog.ForeColor = (Hex '#93A4B8')
$txtLog.Font = (New-Object Drawing.Font('Consolas', 8))
$txtLog.Location = New-Object Drawing.Point((P 13), (P 10))
$txtLog.Size = New-Object Drawing.Size((P 450), (P 86))
$cardLog.Controls.Add($txtLog)

# ---------------------------------------------------------------- 逻辑

function Read-Cfg {
    if (Test-Path -LiteralPath $script:cfgPath) {
        try { return (Get-Content -LiteralPath $script:cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Set-Busy {
    param([bool]$on)
    $script:busy = $on
    $btnSave.Enabled = -not $on
    $btnCheck.Enabled = -not $on
    $btnLog.Enabled = -not $on
    $btnAuto.Enabled = -not $on
    $btnSave.Text = if ($on) { '处理中…' } else { '保存并登录' }
}

function Refresh-Log {
    if (Test-Path -LiteralPath $script:logPath) {
        $lines = @(Get-Content -LiteralPath $script:logPath -Tail 200 -Encoding UTF8)
        $txtLog.Text = ($lines -join "`r`n")
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
}

function Show-Status {
    param($j)
    if (-not $j -or -not $j.ok) {
        $lblDot.ForeColor = $C.Dim
        $lblState.Text = '尚未配置'
        $lblState.ForeColor = $C.Text
        $lblInfo.Text = '请在下面填写学号与密码'
        $lblPortal.Text = ''
        return
    }
    if ($j.online) {
        $lblDot.ForeColor = $C.Ok
        $lblState.Text = '已连接'
        $lblState.ForeColor = $C.Ok
    }
    else {
        $lblDot.ForeColor = $C.Err
        $lblState.Text = '未认证 / 断线'
        $lblState.ForeColor = $C.Err
    }
    $lblInfo.Text = ('{0}    {1}' -f $j.ip, $j.mac)
    $hrs = 0
    if ($j.oltime) { $hrs = [Math]::Round(($j.oltime / 3600), 1) }
    if ($j.portalResult -eq 1) {
        $lblPortal.Text = ('门户 {0}   已在线 {1} 小时   账号 {2}' -f $j.portal, $hrs, $j.uid)
    }
    else {
        $lblPortal.Text = ('门户 {0}   未获取到在线会话' -f $j.portal)
    }
}

function Refresh-AutoState {
    $t = Get-ScheduledTask -TaskName 'CampusNetAutoLogin' -ErrorAction SilentlyContinue
    if ($t -and $t.State -ne 'Disabled') {
        $lblAutoState.Text = '已开启 · 登录 Windows 后自动连接'
        $lblAutoState.ForeColor = $C.Ok
        $btnAuto.Text = '关闭'
    }
    else {
        $lblAutoState.Text = '未开启（仅本窗口内手动登录）'
        $lblAutoState.ForeColor = $C.Dim
        $btnAuto.Text = '开启'
    }
}

function Start-Core {
    param([string]$Action, [hashtable]$Extra)
    $p = @{ Action = $Action; Json = $true; Quiet = $true }
    if ($Extra) { foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] } }
    $script:pending = $Action
    Set-Busy $true
    $script:job = Start-Job -ScriptBlock {
        param($core, $pp)
        & $core @pp
    } -ArgumentList $script:core, $p
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
        if (-not $script:job) { return }
        if (@('Completed', 'Failed', 'Stopped') -notcontains $script:job.State) { return }

        $out = @(Receive-Job $script:job -ErrorAction SilentlyContinue)
        $jobErr = $script:job.ChildJobs[0].Error
        Remove-Job $script:job -Force
        $script:job = $null

        $json = $null
        foreach ($line in $out) {
            $s = [string]$line
            if ($s.TrimStart().StartsWith('{')) {
                try { $json = $s | ConvertFrom-Json } catch { }
            }
        }

        $what = $script:pending
        $script:pending = ''
        Set-Busy $false
        Refresh-Log

        switch ($what) {
            'status' {
                if ($json -and $json.ok) { Show-Status $json }
                else { $lblState.Text = '检测失败'; $lblDot.ForeColor = $C.Err }
            }
            'login' {
                if ($json -and $json.ok) {
                    $lblDot.ForeColor = $C.Ok
                    $lblState.Text = '登录成功'
                    $lblState.ForeColor = $C.Ok
                }
                else {
                    $lblDot.ForeColor = $C.Err
                    $lblState.Text = '登录失败'
                    $lblState.ForeColor = $C.Err
                    $msg = '未获取到门户响应'
                    if ($json -and $json.tail) {
                        $m = @($json.tail) | Where-Object { $_ -match '\[(ERROR|WARN)\]' } | Select-Object -Last 1
                        if ($m) { $msg = ($m -replace '^\[[^\]]+\]\s*\[[^\]]+\]\s*', '') }
                    }
                    $lblPortal.Text = $msg
                }
                Start-Core -Action 'status'
            }
            'install' { Refresh-AutoState; Start-Core -Action 'status' }
            'uninstall' { Refresh-AutoState }
        }
        if ($jobErr -and $jobErr.Count -gt 0 -and $what -eq 'login') {
            $lblState.Text = '登录异常'
            $lblPortal.Text = [string]$jobErr[0].Exception.Message
        }
    })
$timer.Start()

function Save-Cfg {
    $cfg = Read-Cfg
    $acct = $txtAccount.Text.Trim()
    if (-not $acct) { throw '学号不能为空' }

    $prot = ''
    if ($cfg) { $prot = [string]$cfg.passwordProtected }
    if ($txtPass.Text) {
        $sec = ConvertTo-SecureString -String $txtPass.Text -AsPlainText -Force
        $prot = ConvertFrom-SecureString -SecureString $sec
    }
    if (-not $prot) { throw '密码不能为空' }

    $portal = $txtPortal.Text.Trim()
    if (-not $portal) { $portal = '10.8.0.3:801' }
    $ph = '10.8.0.3'; $pp = 801
    if ($portal -match '^(?<h>[^:]+)(:(?<p>\d+))?') {
        $ph = $Matches['h']
        if ($Matches['p']) { $pp = [int]$Matches['p'] }
    }
    $ph = $ph -replace '^https?://', ''

    $o = [ordered]@{
        account           = $acct
        accountSuffix     = $txtSuffix.Text.Trim()
        passwordProtected = $prot
        portalHost        = $ph
        portalPort        = $pp
        loginMethod       = 1
        accountPrefix     = ',0,'
        intervalSeconds   = 30
        updatedAt         = (Get-Date).ToString('s')
    }
    $dir = Split-Path -Parent $script:cfgPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $o | ConvertTo-Json | Set-Content -LiteralPath $script:cfgPath -Encoding UTF8
}

# ---------------------------------------------------------------- 事件

$btnSave.Add_Click({
        try { Save-Cfg } catch { $lblState.Text = '配置有误'; $lblState.ForeColor = $C.Err; $lblPortal.Text = $_.Exception.Message; return }
        $txtPass.Text = ''
        Start-Core -Action 'login'
    })

$btnCheck.Add_Click({ Start-Core -Action 'status' })

$btnLog.Add_Click({
        if (Test-Path -LiteralPath $script:logPath) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $script:logPath) }
        else { $txtLog.Text = '还没有日志' }
    })

$btnAuto.Add_Click({
        $t = Get-ScheduledTask -TaskName 'CampusNetAutoLogin' -ErrorAction SilentlyContinue
        if ($t -and $t.State -ne 'Disabled') { Start-Core -Action 'uninstall' }
        else { Start-Core -Action 'install' }
    })

$form.Add_FormClosing({
        $timer.Stop()
        if ($script:job) { Stop-Job $script:job -ErrorAction SilentlyContinue; Remove-Job $script:job -Force -ErrorAction SilentlyContinue }
    })

# ---------------------------------------------------------------- 初始化

$cfg = Read-Cfg
if ($cfg) {
    $txtAccount.Text = [string]$cfg.account
    $txtSuffix.Text = [string]$cfg.accountSuffix
    $txtPortal.Text = ('{0}:{1}' -f $cfg.portalHost, $cfg.portalPort)
}
else {
    $txtPortal.Text = '10.8.0.3:801'
}

Refresh-AutoState
Refresh-Log

$form.Add_Shown({
        if ($cfg) { Start-Core -Action 'status' }
        else {
            $lblDot.ForeColor = $C.Warn
            $lblState.Text = '等待配置'
            $lblState.ForeColor = $C.Warn
            $lblInfo.Text = '填写学号与密码后点“保存并登录”'
            $lblPortal.Text = ''
        }
    })

[void]$form.ShowDialog()
