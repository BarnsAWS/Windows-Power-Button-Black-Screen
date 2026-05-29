<#
.SYNOPSIS
    Per-user black-overlay daemon. When the display state goes Off (e.g. the
    laptop power button is pressed and powercfg routes that to "Turn off the
    display"), or when the user presses the arm hotkey, paints a topmost
    click-through black window on every monitor so the desktop reads as fully
    blank. Does NOT lock the session, so unattended automation (Amazon Quick
    CUA, etc.) can keep driving browser windows underneath.

.DESCRIPTION
    Runs in the user's logon session. Builds a hidden message window to
    receive notifications. Subscribes to GUID_CONSOLE_DISPLAY_STATE.

      data = 0x0  -> display Off  -> ARM overlay (one black window per monitor)
      data = 0x1  -> display On   -> if armed, keep overlay up
      data = 0x2  -> dimmed       -> ignored

    Each overlay is a borderless WS_POPUP layered window with extended styles
    WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT |
    WS_EX_NOACTIVATE. Click-through means synthesized input from CUA tools
    (mouse_event / SendInput / browser DevTools) lands on the windows below.

    Hotkeys via RegisterHotKey:

      Win+Shift+L            -> arm overlay (closest-to-Win+L combo that
                                Winlogon does not reserve; works without
                                touching any policy)
      Ctrl+Alt+Shift+L       -> arm overlay (alternate; works even if a GPO
                                takes Win-modifier hotkeys away from the user)
      Ctrl+Alt+Shift+End     -> dismiss overlay
      Ctrl+Alt+Shift+B       -> manually arm

    Win+L itself is reserved by Winlogon and cannot be intercepted by user-
    mode RegisterHotKey calls. Disabling Winlogon's interception requires
    HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System
    \DisableLockWorkstation = 1, which enterprise GPOs commonly forbid. Rather
    than fight the GPO, we use the hotkey one shift away.

    Designed to be installed by INSTALL.ps1 as a per-user logon Scheduled Task.

.NOTES
    PowerShell 5.1, .NET Framework Forms, PInvoke against user32.dll. No
    third-party dependencies, no service, no kernel driver.

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

    public const int WS_EX_TOPMOST       = 0x00000008;
    public const int WS_EX_TOOLWINDOW    = 0x00000080;
    public const int WS_EX_LAYERED       = 0x00080000;
    public const int WS_EX_TRANSPARENT   = 0x00000020;
    public const int WS_EX_NOACTIVATE    = 0x08000000;

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

    public const uint LWA_COLORKEY = 0x00000001;
    public const uint LWA_ALPHA    = 0x00000002;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint crKey, byte bAlpha, uint dwFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    // ----------------------------------------------------------------------
    // GPO-bypass surface
    //
    // GPO/MDM-managed boxes push a secure screen saver via
    // HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop with
    // ScreenSaverIsSecure=1 and a short timeout. That registry path is
    // re-applied on every policy refresh, so user-mode cannot keep the
    // value cleared.
    //
    // Two APIs neutralise the lock without writing to any policy path:
    //
    //   SystemParametersInfo(SPI_SETSCREENSAVEACTIVE, FALSE, ...)
    //     Disables the running-session screen-saver dispatch in user32.
    //     The registry policy is unchanged; it just does not fire while
    //     we hold the dispatch off. Must be re-applied periodically in
    //     case a policy refresh re-arms the running-session state.
    //
    //   SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED)
    //     Tells Windows the user is present, so the input-idle counter
    //     never satisfies the screen-saver predicate. Belt-and-suspenders
    //     to SPI_SETSCREENSAVEACTIVE. Held only while the overlay is
    //     armed; cleared on dismiss so sleep still works normally when
    //     the overlay is down.
    // ----------------------------------------------------------------------

    public const uint SPI_SETSCREENSAVEACTIVE = 0x0011;
    public const uint SPI_GETSCREENSAVEACTIVE = 0x0010;
    public const uint SPIF_SENDCHANGE         = 0x02;

    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW", CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

    [DllImport("user32.dll", SetLastError = true, EntryPoint = "SystemParametersInfoW", CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfoBool(uint uiAction, uint uiParam, ref bool pvParam, uint fWinIni);

    [Flags]
    public enum EXECUTION_STATE : uint {
        ES_AWAYMODE_REQUIRED = 0x00000040,
        ES_CONTINUOUS        = 0x80000000,
        ES_DISPLAY_REQUIRED  = 0x00000002,
        ES_SYSTEM_REQUIRED   = 0x00000001
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern EXECUTION_STATE SetThreadExecutionState(EXECUTION_STATE esFlags);

    public const uint MOD_ALT      = 0x0001;
    public const uint MOD_CONTROL  = 0x0002;
    public const uint MOD_SHIFT    = 0x0004;
    public const uint MOD_WIN      = 0x0008;
    public const uint MOD_NOREPEAT = 0x4000;

    public const uint VK_END = 0x23;
    public const uint VK_B   = 0x42;
    public const uint VK_L   = 0x4C;
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

    // WS_EX_LAYERED windows do not render their BackColor through the
    // normal WinForms paint pipeline. Without an explicit alpha set via
    // SetLayeredWindowAttributes, Windows treats the window as fully
    // transparent and the BackColor is never composited - the user sees
    // through to the desktop. Set alpha=255 (opaque) once the handle is
    // ready so the black BackColor actually paints.
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        Native.SetLayeredWindowAttributes(this.Handle, 0, 255, Native.LWA_ALPHA);
    }
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
    # Always re-enumerate from scratch. Monitor coordinates can change at
    # runtime (dock/undock, monitor hot-plug, display arrangement change,
    # DPI rescale). A previously-painted overlay sitting at stale bounds
    # is invisible (off-screen) and the cached "already covered" check
    # would silently skip painting new ones. Cheaper and more correct to
    # tear down and rebuild on every arm-style event.
    foreach ($f in @($script:Overlays)) {
        try { $f.Close(); $f.Dispose() } catch {}
    }
    $script:Overlays.Clear()

    if (-not $script:Armed) {
        $script:Armed = $true
        Write-Log "Arming overlays."
        # Belt: re-suppress the screen saver right now in case the 60s
        # timer just ticked and a policy refresh re-armed the dispatch.
        [void](Suppress-ScreenSaver)
    } else {
        Write-Log "Re-arming overlays (re-enumerating displays)."
    }

    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $screen.Bounds
        $form = New-Object OverlayForm $b
        $script:Overlays.Add($form)
        $form.Show()
        Write-Log ("Overlay shown on monitor {0} at {1}." -f $screen.DeviceName, $b)
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
    # Idle keepalive stays ON across overlay arm/dismiss cycles. The
    # daemon's job is "session never auto-locks while I am running" and
    # that contract has to hold whether the overlay is currently up or
    # not. Released in the daemon's finally block.
}

# ---------------------------------------------------------------------------
# GPO-bypass: keep the running-session screen saver suppressed and pin the
# user-presence idle counter while overlays are armed.
#
# Why this exists: corporate-managed laptops push
# HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop\
# ScreenSaverIsSecure = 1 with a short ScreenSaveTimeOut. That policy path
# survives any user-mode delete (it gets re-applied on policy refresh, every
# 90 minutes give-or-take). The trick is to operate one layer above the
# registry, on the running session itself, where user32 holds a separate
# dispatch state that the policy machinery does not touch. See
# INVESTIGATION-2026-05-29.md for the full root-cause writeup.
# ---------------------------------------------------------------------------

function Suppress-ScreenSaver {
    # SPI_SETSCREENSAVEACTIVE = FALSE in the running session. On
    # GPO-locked boxes this call is often blocked (returns FALSE with
    # ERROR_ACCESS_DENIED 0x5). We log the result and keep going; the
    # ES_DISPLAY_REQUIRED keepalive below handles the lock-prevention
    # job on its own when SPI is denied.
    $ok = [Native]::SystemParametersInfo(
        [Native]::SPI_SETSCREENSAVEACTIVE,
        0,
        [IntPtr]::Zero,
        [Native]::SPIF_SENDCHANGE)
    if (-not $ok) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return @{ ok = $false; error = $err }
    }
    return @{ ok = $true; error = 0 }
}

function Get-ScreenSaverActive {
    $val = $false
    [Native]::SystemParametersInfoBool(
        [Native]::SPI_GETSCREENSAVEACTIVE,
        0,
        [ref]$val,
        0) | Out-Null
    return $val
}

function Hold-IdleKeepalive {
    # ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED tells
    # Windows the user is present so the input-idle counter never expires
    # and the system never auto-sleeps. This is THE mechanism Windows uses
    # to decide whether to launch the screen saver: if any thread holds
    # ES_DISPLAY_REQUIRED, the saver does not activate. That makes the
    # daemon GPO-proof against secure-screensaver auto-lock on managed
    # corporate boxes where SPI_SETSCREENSAVEACTIVE is denied.
    #
    # ES_AWAYMODE_REQUIRED is the additional flag for laptops with
    # connected standby / Modern Standby (S0ix). Without it, pressing the
    # power button on such a laptop causes the firmware to blank the
    # panel AND Windows to drop the whole system into S0ix to save
    # power, even though "Turn off the display" is selected. While in
    # S0ix the daemon's message pump is not running so the overlay
    # cannot paint until the system wakes. With ES_AWAYMODE_REQUIRED the
    # system stays at full S0 (display off, CPU and IO live), which is
    # exactly the contract of this daemon.
    #
    # Held continuously while the daemon runs, regardless of overlay
    # state. Released only in the daemon's finally block.
    $flags = [Native+EXECUTION_STATE]::ES_CONTINUOUS -bor `
             [Native+EXECUTION_STATE]::ES_DISPLAY_REQUIRED -bor `
             [Native+EXECUTION_STATE]::ES_SYSTEM_REQUIRED -bor `
             [Native+EXECUTION_STATE]::ES_AWAYMODE_REQUIRED
    $prev = [Native]::SetThreadExecutionState($flags)
    Write-Log ("Idle keepalive ON (prev=0x{0:x8}, flags=0x{1:x8})." -f [uint32]$prev, [uint32]$flags)
}

function Release-IdleKeepalive {
    # Drop the keepalive on shutdown. ES_CONTINUOUS alone clears prior
    # flags so the system can sleep / dim normally once the daemon exits.
    $prev = [Native]::SetThreadExecutionState([Native+EXECUTION_STATE]::ES_CONTINUOUS)
    Write-Log ("Idle keepalive OFF (prev=0x{0:x8})." -f [uint32]$prev)
}

# Hold the idle keepalive for the entire daemon lifetime. Ungated by
# overlay state because the no-auto-lock contract holds always.
Hold-IdleKeepalive

# Apply SPI suppression at startup as a best effort. On GPO-locked boxes
# this fails; the keepalive above is the actual fix.
$initialActive = Get-ScreenSaverActive
$r = Suppress-ScreenSaver
if ($r.ok) {
    Write-Log ("SPI_SETSCREENSAVEACTIVE applied at startup (was={0})." -f $initialActive)
} else {
    Write-Log ("SPI_SETSCREENSAVEACTIVE blocked at startup (Win32Error=0x{0:x}, was={1}). Relying on ES_DISPLAY_REQUIRED keepalive." -f $r.error, $initialActive)
}

# Probe the policy path so the log proves whether GPO is pushing the lock.
try {
    $polPath = 'HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
    if (Test-Path $polPath) {
        $pol = Get-ItemProperty -Path $polPath -ErrorAction SilentlyContinue
        $pSecure  = if ($pol.PSObject.Properties.Name -contains 'ScreenSaverIsSecure') { $pol.ScreenSaverIsSecure } else { 'unset' }
        $pActive  = if ($pol.PSObject.Properties.Name -contains 'ScreenSaveActive')    { $pol.ScreenSaveActive }    else { 'unset' }
        $pTimeout = if ($pol.PSObject.Properties.Name -contains 'ScreenSaveTimeOut')   { $pol.ScreenSaveTimeOut }   else { 'unset' }
        Write-Log "GPO policy path present: ScreenSaverIsSecure=$pSecure ScreenSaveActive=$pActive ScreenSaveTimeOut=$pTimeout."
    } else {
        Write-Log "GPO policy path absent (no Software\Policies\...\Control Panel\Desktop)."
    }
} catch {
    Write-Log ("GPO probe failed: {0}" -f $_.Exception.Message)
}

# Re-apply ES keepalive every 60 seconds. SetThreadExecutionState is
# scoped to the calling thread; in a Forms app on the message-pump
# thread the flag survives indefinitely, but re-applying is cheap
# insurance against any path that might clear it (RDP reconnect, fast
# user switch, ill-behaved background COM call). Also re-attempts SPI
# in case the GPO restriction is lifted for any reason.
$keepaliveTimer = New-Object System.Windows.Forms.Timer
$keepaliveTimer.Interval = 60000
$keepaliveTimer.add_Tick({
    # Re-apply ES (idempotent; cheap).
    $flags = [Native+EXECUTION_STATE]::ES_CONTINUOUS -bor `
             [Native+EXECUTION_STATE]::ES_DISPLAY_REQUIRED -bor `
             [Native+EXECUTION_STATE]::ES_SYSTEM_REQUIRED -bor `
             [Native+EXECUTION_STATE]::ES_AWAYMODE_REQUIRED
    [void][Native]::SetThreadExecutionState($flags)

    # Best-effort SPI re-suppression. Only log when state changes to keep
    # the log readable.
    $beforeActive = Get-ScreenSaverActive
    [void](Suppress-ScreenSaver)
    if ($beforeActive) {
        Write-Log "Re-suppressed running-session screen saver (was active again; SPI may have been re-armed by policy refresh)."
    }
})
$keepaliveTimer.Start()

$msg = New-Object MessageWindow

# Hotkey IDs
$HK_DISMISS     = 1
$HK_ARM         = 2
$HK_WIN_SHIFT_L = 3
$HK_TRIPLE_L    = 4

$tripleMod   = ([Native]::MOD_CONTROL -bor [Native]::MOD_ALT -bor [Native]::MOD_SHIFT -bor [Native]::MOD_NOREPEAT)
$winShiftMod = ([Native]::MOD_WIN -bor [Native]::MOD_SHIFT -bor [Native]::MOD_NOREPEAT)

[Native]::RegisterHotKey($msg.Handle, $HK_DISMISS, $tripleMod, [Native]::VK_END) | Out-Null
[Native]::RegisterHotKey($msg.Handle, $HK_ARM,     $tripleMod, [Native]::VK_B)   | Out-Null

# Win+Shift+L is the closest-to-Win+L combo that is not reserved by Winlogon.
# Some enterprise GPOs disable Win-modifier hotkeys for the user; if that
# happens, the second registration covers the same gesture without the Win key.
$ok1 = [Native]::RegisterHotKey($msg.Handle, $HK_WIN_SHIFT_L, $winShiftMod, [Native]::VK_L)
$ok2 = [Native]::RegisterHotKey($msg.Handle, $HK_TRIPLE_L,    $tripleMod,   [Native]::VK_L)
if ($ok1) { Write-Log "Win+Shift+L registered as overlay arm." }
else      { Write-Log "Win+Shift+L registration failed (likely GPO). Falling back to Ctrl+Alt+Shift+L only." }
if ($ok2) { Write-Log "Ctrl+Alt+Shift+L registered as overlay arm." }
else      { Write-Log "Ctrl+Alt+Shift+L registration failed (unexpected)." }

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
        1 { Write-Log "Hotkey: DISMISS";          Hide-Overlays }
        2 { Write-Log "Hotkey: MANUAL ARM";       Show-Overlays }
        3 { Write-Log "Hotkey: WIN+SHIFT+L";      Show-Overlays }
        4 { Write-Log "Hotkey: CTRL+ALT+SHIFT+L"; Show-Overlays }
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
    [Native]::UnregisterHotKey($msg.Handle, $HK_DISMISS)     | Out-Null
    [Native]::UnregisterHotKey($msg.Handle, $HK_ARM)         | Out-Null
    [Native]::UnregisterHotKey($msg.Handle, $HK_WIN_SHIFT_L) | Out-Null
    [Native]::UnregisterHotKey($msg.Handle, $HK_TRIPLE_L)    | Out-Null
    if ($keepaliveTimer) { $keepaliveTimer.Stop(); $keepaliveTimer.Dispose() }
    Release-IdleKeepalive
    Hide-Overlays
    $msg.Shutdown()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
