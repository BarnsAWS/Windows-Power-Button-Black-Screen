<#
.SYNOPSIS
    Per-user black-overlay daemon. When the display state goes Off (e.g. the
    laptop power button is pressed and powercfg routes that to "Turn off the
    display"), paints a topmost click-through black window on every monitor so
    the desktop reads as fully blank. Does NOT lock the session, so unattended
    automation (Amazon Quick CUA, etc.) can keep driving browser windows
    underneath.

.DESCRIPTION
    Runs in the user's logon session. Builds a hidden message window to receive
    power-broadcast notifications. Subscribes to GUID_CONSOLE_DISPLAY_STATE.

      data = 0x0  -> display Off  -> ARM overlay (one black window per monitor)
      data = 0x1  -> display On   -> if armed, keep overlay up
      data = 0x2  -> dimmed       -> ignored

    Each overlay is a borderless WS_POPUP layered window with extended styles
    WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT |
    WS_EX_NOACTIVATE. Click-through means synthesized input from CUA tools
    (mouse_event / SendInput / browser DevTools) lands on the windows below.

    Two hotkeys are registered with RegisterHotKey (low-level, fires even if
    the foreground app is full-screen):

      DISMISS  Ctrl+Alt+Shift+End  -> hide overlays, disarm.
      ARM      Ctrl+Alt+Shift+B    -> manually arm without pressing the power
                                      button. Also re-arms if the user moved
                                      the mouse and the display turned back on.

    Designed to be installed by INSTALL.ps1 as a per-user logon Scheduled Task
    so it starts at sign-in and survives the screen saver or display-off cycle.
    The script is fully self-contained: no external assemblies beyond the .NET
    Framework that ships with Windows 10/11.

.NOTES
    PInvoke is done through Add-Type. The script targets PowerShell 5.1 (the
    in-box Windows PowerShell) so it runs without installing PowerShell 7.

.PARAMETER LogPath
    Optional. Append-only log file. Defaults to
    %LOCALAPPDATA%\BlackOverlay\BlackOverlay.log
#>

[CmdletBinding()]
param(
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'BlackOverlay\BlackOverlay.log')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    "$ts $Message" | Add-Content -Path $LogPath -Encoding utf8
}

Write-Log "BlackOverlay starting (pid=$PID, user=$env:USERNAME)"

# ---------------------------------------------------------------------------
# Single-instance guard. A named mutex per user prevents two daemons from
# fighting over the same hotkeys.
# ---------------------------------------------------------------------------

$mutexName = "Global\BlackOverlay-$env:USERNAME"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-Log "Another instance is already running. Exiting."
    return
}

# ---------------------------------------------------------------------------
# PInvoke surface
# ---------------------------------------------------------------------------

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class Native {
    public const int WM_POWERBROADCAST   = 0x0218;
    public const int WM_HOTKEY           = 0x0312;
    public const int PBT_POWERSETTINGCHANGE = 0x8013;

    public const int WS_POPUP            = unchecked((int)0x80000000);
    public const int WS_VISIBLE          = 0x10000000;

    public const int WS_EX_TOPMOST       = 0x00000008;
    public const int WS_EX_TOOLWINDOW    = 0x00000080;
    public const int WS_EX_LAYERED       = 0x00080000;
    public const int WS_EX_TRANSPARENT   = 0x00000020;
    public const int WS_EX_NOACTIVATE    = 0x08000000;

    public const int LWA_ALPHA           = 0x00000002;

    public const int DEVICE_NOTIFY_WINDOW_HANDLE = 0;

    // GUID_CONSOLE_DISPLAY_STATE = {6FE69556-704A-47A0-8F24-C28D936FDA47}
    public static Guid GUID_CONSOLE_DISPLAY_STATE = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");

    [StructLayout(LayoutKind.Sequential)]
    public struct POWERBROADCAST_SETTING {
        public Guid PowerSetting;
        public uint DataLength;
        public byte Data;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid PowerSettingGuid, int Flags);

    [DllImport("user32.dll")]
    public static extern bool UnregisterPowerSettingNotification(IntPtr Handle);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public const uint MOD_ALT     = 0x0001;
    public const uint MOD_CONTROL = 0x0002;
    public const uint MOD_SHIFT   = 0x0004;
    public const uint MOD_NOREPEAT = 0x4000;

    public const uint VK_END = 0x23;
    public const uint VK_B   = 0x42;
}

// Hidden message-only window that the PowerShell host can subscribe to.
public class MessageWindow : NativeWindow {
    public event Action<int, byte> DisplayStateChanged; // power-broadcast subtype, data
    public event Action<int>       HotkeyPressed;       // hotkey id

    private IntPtr powerHandle = IntPtr.Zero;

    public MessageWindow() {
        var cp = new CreateParams {
            Caption = "BlackOverlayMessageWindow",
            X = 0, Y = 0, Width = 0, Height = 0,
            Style = 0,
            ExStyle = Native.WS_EX_TOOLWINDOW
        };
        this.CreateHandle(cp);
        Guid g = Native.GUID_CONSOLE_DISPLAY_STATE;
        powerHandle = Native.RegisterPowerSettingNotification(
            this.Handle, ref g, Native.DEVICE_NOTIFY_WINDOW_HANDLE);
    }

    public void Shutdown() {
        if (powerHandle != IntPtr.Zero) {
            Native.UnregisterPowerSettingNotification(powerHandle);
            powerHandle = IntPtr.Zero;
        }
        this.DestroyHandle();
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == Native.WM_POWERBROADCAST &&
            m.WParam.ToInt32() == Native.PBT_POWERSETTINGCHANGE &&
            m.LParam != IntPtr.Zero) {
            var ps = (Native.POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(Native.POWERBROADCAST_SETTING));
            if (ps.PowerSetting == Native.GUID_CONSOLE_DISPLAY_STATE) {
                if (DisplayStateChanged != null) DisplayStateChanged(Native.PBT_POWERSETTINGCHANGE, ps.Data);
            }
        }
        else if (m.Msg == Native.WM_HOTKEY) {
            int id = m.WParam.ToInt32();
            if (HotkeyPressed != null) HotkeyPressed(id);
        }
        base.WndProc(ref m);
    }
}

// One topmost click-through black window per monitor.
public class OverlayForm : Form {
    public OverlayForm(Rectangle bounds) {
        this.FormBorderStyle = FormBorderStyle.None;
        this.ShowInTaskbar   = false;
        this.TopMost         = true;
        this.BackColor       = Color.Black;
        this.Bounds          = bounds;
        this.StartPosition   = FormStartPosition.Manual;
        this.Cursor          = Cursors.Default;
    }

    protected override CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_TOPMOST
                       |  Native.WS_EX_TOOLWINDOW
                       |  Native.WS_EX_LAYERED
                       |  Native.WS_EX_TRANSPARENT
                       |  Native.WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation { get { return true; } }
}
'@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Overlay management
# ---------------------------------------------------------------------------

$script:Overlays = New-Object System.Collections.Generic.List[OverlayForm]
$script:Armed    = $false

function Show-Overlays {
    if ($script:Armed) {
        # Already up. Re-cover any monitor that came online (hot-plug).
        foreach ($f in @($script:Overlays)) {
            if ($f.IsDisposed) { $script:Overlays.Remove($f) | Out-Null }
        }
    } else {
        $script:Armed = $true
        Write-Log "Arming overlays."
    }

    $current = @{}
    foreach ($f in $script:Overlays) {
        if (-not $f.IsDisposed) { $current[$f.Bounds.ToString()] = $true }
    }

    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $screen.Bounds
        if (-not $current.ContainsKey($b.ToString())) {
            $form = New-Object OverlayForm $b
            $script:Overlays.Add($form)
            $form.Show()
            Write-Log ("Overlay shown on monitor {0} at {1}." -f $screen.DeviceName, $b)
        }
    }
}

function Hide-Overlays {
    if (-not $script:Armed) { return }
    $script:Armed = $false
    Write-Log "Dismissing overlays."
    foreach ($f in @($script:Overlays)) {
        try { $f.Close(); $f.Dispose() } catch {}
    }
    $script:Overlays.Clear()
}

# ---------------------------------------------------------------------------
# Wire up
# ---------------------------------------------------------------------------

$msg = New-Object MessageWindow

# Hotkey IDs
$HK_DISMISS = 1
$HK_ARM     = 2

# DISMISS = Ctrl+Alt+Shift+End
[Native]::RegisterHotKey(
    $msg.Handle,
    $HK_DISMISS,
    ([Native]::MOD_CONTROL -bor [Native]::MOD_ALT -bor [Native]::MOD_SHIFT -bor [Native]::MOD_NOREPEAT),
    [Native]::VK_END) | Out-Null

# ARM = Ctrl+Alt+Shift+B
[Native]::RegisterHotKey(
    $msg.Handle,
    $HK_ARM,
    ([Native]::MOD_CONTROL -bor [Native]::MOD_ALT -bor [Native]::MOD_SHIFT -bor [Native]::MOD_NOREPEAT),
    [Native]::VK_B) | Out-Null

$msg.add_DisplayStateChanged({
    param($subtype, $data)
    switch ($data) {
        0 { Write-Log "GUID_CONSOLE_DISPLAY_STATE: Off (0). Arming overlays."; Show-Overlays }
        1 { Write-Log "GUID_CONSOLE_DISPLAY_STATE: On (1). Overlay stays $(if ($script:Armed) { 'armed' } else { 'idle' })." }
        2 { Write-Log "GUID_CONSOLE_DISPLAY_STATE: Dim (2). Ignoring." }
    }
})

$msg.add_HotkeyPressed({
    param($id)
    switch ($id) {
        1 { Write-Log "Hotkey: DISMISS";  Hide-Overlays }
        2 { Write-Log "Hotkey: MANUAL ARM"; Show-Overlays }
    }
})

Write-Log "Listening for power-broadcast and hotkeys."

# ---------------------------------------------------------------------------
# Run the message loop. Application.Run pumps WM_POWERBROADCAST and WM_HOTKEY
# into MessageWindow.WndProc.
# ---------------------------------------------------------------------------

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    Write-Log "Shutting down."
    [Native]::UnregisterHotKey($msg.Handle, $HK_DISMISS) | Out-Null
    [Native]::UnregisterHotKey($msg.Handle, $HK_ARM)     | Out-Null
    Hide-Overlays
    $msg.Shutdown()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
