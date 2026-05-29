<#
.SYNOPSIS
    Install the Power-Button Black-Screen daemon. Pressing the laptop power
    button OR Win+Shift+L (or Ctrl+Alt+Shift+L) blanks every connected display
    under a topmost click-through black overlay, while leaving the user
    session unlocked so automation tools (Amazon Quick CUA, Selenium, headed
    Playwright, etc.) keep their grip on browser windows underneath.

.DESCRIPTION
    Performs four coordinated actions:

      1. Configures powercfg so the short-press of the power button maps to
         "Turn off the display" on AC and battery. The firmware blanks the
         panel; Windows fires GUID_CONSOLE_DISPLAY_STATE = 0.
      2. Neutralises lock-on-idle triggers that would otherwise fire after
         the display goes off. Specifically: clears the secure screen saver
         (ScreenSaverIsSecure=0, ScreenSaveActive=0) and disables Dynamic
         Lock (EnableGoodbye=0). The whole point of this daemon is that the
         session stays UNLOCKED, so any setting that would lock-on-idle has
         to go. The sibling repo Windows-Power-Button-Lock-Without-Sleep
         deliberately sets ScreenSaverIsSecure=1; if you ran that installer
         in the past, this step undoes it so the two repos cannot fight.
      3. Copies BlackOverlay.ps1 into %LOCALAPPDATA%\BlackOverlay\.
      4. Registers a per-user Scheduled Task "BlackOverlayDaemon" that runs
         at logon under the current user with a hidden powershell.exe host.
         The task is also started immediately so the first cycle works
         without a sign-out.

    The daemon paints one click-through black window per monitor as soon as
    GUID_CONSOLE_DISPLAY_STATE goes Off, or when the user presses Win+Shift+L
    or Ctrl+Alt+Shift+L. The session is NOT locked. Mouse and keyboard input
    still reach the windows beneath the overlay (the overlay's extended style
    includes WS_EX_TRANSPARENT). Synthesized input from CUA tools likewise
    passes through.

    Win+L itself cannot be intercepted by user-mode RegisterHotKey calls.
    Winlogon owns it. The published workaround is to set HKCU
    \Software\Microsoft\Windows\CurrentVersion\Policies\System
    \DisableLockWorkstation = 1, but enterprise GPOs commonly forbid HKCU
    policy writes. We pick Win+Shift+L (one shift away, same hand-shape) and
    Ctrl+Alt+Shift+L as a GPO-proof alternate. Both are wired to arm the
    overlay; either works.

    No reboot or sign-out required.

.PARAMETER InstallDir
    Optional. Where to drop BlackOverlay.ps1 and its log. Defaults to
    "$env:LOCALAPPDATA\BlackOverlay".

.PARAMETER TaskName
    Optional. Scheduled Task name. Defaults to "BlackOverlayDaemon".

.PARAMETER SkipPowerButton
    If present, the powercfg edits are skipped. Useful for testing the daemon
    without touching the user's existing power configuration.

.PARAMETER SkipLockGuard
    If present, the lock-on-idle neutralisation step is skipped. Use only if
    you intentionally want the screen saver to stay secure-locked while this
    daemon is running. Default behaviour clears ScreenSaverIsSecure,
    ScreenSaveActive, and EnableGoodbye so the session never auto-locks.

.EXAMPLE
    .\INSTALL.ps1

.EXAMPLE
    # Install the daemon only; leave the power button alone
    .\INSTALL.ps1 -SkipPowerButton

.NOTES
    Run from PowerShell. Admin is NOT required.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'BlackOverlay'),
    [string]$TaskName   = 'BlackOverlayDaemon',
    [switch]$SkipPowerButton,
    [switch]$SkipLockGuard
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Power button -> Turn off the display
#
#    On Modern Standby (S0 Low Power Idle) hardware, the firmware hands
#    "Turn off the display" to the connected-standby path: panel off AND
#    the system drops into S0ix to save power. While in S0ix our daemon's
#    message pump is parked, so the overlay cannot paint until the system
#    wakes again. Result: muscle memory of "press power, screen blanks
#    instantly with overlay" is broken — instead you see a brief sleep
#    and the overlay paints on wake.
#
#    Detect Modern Standby with `powercfg /a` and fall back to "Do nothing"
#    on those boxes, with a clear pointer to the hotkey path. Hotkey-arm
#    is fully reliable on Modern Standby because the daemon paints the
#    overlay BEFORE any firmware-blank request goes out.
# ---------------------------------------------------------------------------

$SUB_BUTTONS   = '4f971e89-eebd-4455-a8de-9e59040e7347'
$PBUTTONACTION = '7648efa3-dd9c-4e3e-b566-50f929386280'
$TURN_OFF_DISP = 4
$DO_NOTHING    = 0

# Modern Standby probe. `powercfg /a` is the canonical way; the line
# "Standby (S0 Low Power Idle)" appears under "available" only on MS hw.
$pcfg = (& powercfg /a) -join "`n"
$isModernStandby = $pcfg -match 'Standby \(S0 Low Power Idle\)' -and
                   $pcfg -notmatch '(?ms)not available.*Standby \(S0 Low Power Idle\)'

if (-not $SkipPowerButton) {
    Write-Host "[1/5] Unhiding the 'Turn off the display' option..." -ForegroundColor Cyan
    & powercfg /attributes $SUB_BUTTONS $PBUTTONACTION -ATTRIB_HIDE | Out-Null

    if ($isModernStandby) {
        Write-Host "[2/5] Modern Standby (S0ix) detected." -ForegroundColor Yellow
        Write-Host "       Mapping power button -> Do nothing (firmware would otherwise drop the system into S0ix)." -ForegroundColor Yellow
        Write-Host "       Use Win+Shift+L or Ctrl+Alt+Shift+B to arm the overlay." -ForegroundColor Yellow
        & powercfg /setacvalueindex SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION $DO_NOTHING | Out-Null
        & powercfg /setdcvalueindex SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION $DO_NOTHING | Out-Null
    } else {
        Write-Host "[2/5] Setting power button -> Turn off the display (AC + battery)..." -ForegroundColor Cyan
        & powercfg /setacvalueindex SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION $TURN_OFF_DISP | Out-Null
        & powercfg /setdcvalueindex SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION $TURN_OFF_DISP | Out-Null
    }
    & powercfg /setactive SCHEME_CURRENT | Out-Null
} else {
    Write-Host "[1-2/5] Skipping powercfg changes (-SkipPowerButton)." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 2. Neutralise lock-on-idle triggers
#
#    The whole point of this daemon is that the session stays UNLOCKED while
#    the screen looks black. Anything that would auto-lock the session after
#    the display turns off has to go:
#
#      - HKCU:\Control Panel\Desktop\ScreenSaverIsSecure  = 0
#      - HKCU:\Control Panel\Desktop\ScreenSaveActive     = 0
#      - HKCU:\...\Winlogon\EnableGoodbye (Dynamic Lock)  = 0
#
#    The sibling repo Windows-Power-Button-Lock-Without-Sleep deliberately
#    sets ScreenSaverIsSecure=1 (that is its whole job). If you ran that
#    installer at any point in the past, those values still bite this one:
#    after the power button blanks the display, Windows counts you as idle,
#    the secure screen saver fires, the session locks. Undo it here so the
#    two repos cannot fight on the same box.
# ---------------------------------------------------------------------------

if (-not $SkipLockGuard) {
    Write-Host "[3/5] Disabling secure screen saver and Dynamic Lock..." -ForegroundColor Cyan
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaverIsSecure' -Value '0' -Force
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaveActive'    -Value '0' -Force

    $winlogon = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if (Test-Path $winlogon) {
        if (Get-ItemProperty -Path $winlogon -Name 'EnableGoodbye' -ErrorAction SilentlyContinue) {
            Set-ItemProperty -Path $winlogon -Name 'EnableGoodbye' -Value 0 -Force
        }
    }
} else {
    Write-Host "[3/5] Skipping lock-guard (-SkipLockGuard). Session may still auto-lock." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 3. Copy daemon into a stable location
# ---------------------------------------------------------------------------

Write-Host "[4/5] Installing BlackOverlay.ps1 to $InstallDir ..." -ForegroundColor Cyan
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$source = Join-Path $PSScriptRoot 'BlackOverlay.ps1'
if (-not (Test-Path $source)) {
    throw "BlackOverlay.ps1 not found next to INSTALL.ps1 (looked in $PSScriptRoot)."
}
Copy-Item -Path $source -Destination (Join-Path $InstallDir 'BlackOverlay.ps1') -Force

# ---------------------------------------------------------------------------
# 4. Register the per-user logon Scheduled Task
# ---------------------------------------------------------------------------

Write-Host "[5/5] Registering Scheduled Task '$TaskName' (per-user, at logon)..." -ForegroundColor Cyan

$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$daemonPath = Join-Path $InstallDir 'BlackOverlay.ps1'

$action = New-ScheduledTaskAction `
    -Execute $psExe `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$daemonPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Paint a topmost click-through black overlay on every monitor when the display turns off, without locking the session.' | Out-Null

Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 2

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Verification:" -ForegroundColor Green

if (-not $SkipPowerButton) {
    $ac = (& powercfg /query SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION) | Select-String -Pattern 'Current AC Power Setting Index:\s*0x([0-9a-f]+)'
    $dc = (& powercfg /query SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION) | Select-String -Pattern 'Current DC Power Setting Index:\s*0x([0-9a-f]+)'
    $acVal = $ac.Matches[0].Groups[1].Value
    $dcVal = $dc.Matches[0].Groups[1].Value
    $acInt = [Convert]::ToInt32($acVal, 16)
    $dcInt = [Convert]::ToInt32($dcVal, 16)
    $acLabel = switch ($acInt) { 0 {'Do nothing'} 1 {'Sleep'} 2 {'Hibernate'} 3 {'Shut down'} 4 {'Turn off the display'} default {'unknown'} }
    $dcLabel = switch ($dcInt) { 0 {'Do nothing'} 1 {'Sleep'} 2 {'Hibernate'} 3 {'Shut down'} 4 {'Turn off the display'} default {'unknown'} }
    Write-Host "  Power button (AC):     $acVal  ($acLabel)"
    Write-Host "  Power button (DC):     $dcVal  ($dcLabel)"
    if ($isModernStandby) {
        Write-Host "  Modern Standby:        present (S0 Low Power Idle); power button mapped to 'Do nothing'"
        Write-Host "                         to keep the daemon alive. Use Win+Shift+L or Ctrl+Alt+Shift+B."
    } else {
        Write-Host "  Modern Standby:        not present; power button maps to 'Turn off the display'"
    }
}

if (-not $SkipLockGuard) {
    $ssActive = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaveActive'    -ErrorAction SilentlyContinue).ScreenSaveActive
    $ssSecure = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaverIsSecure' -ErrorAction SilentlyContinue).ScreenSaverIsSecure
    $eg = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'EnableGoodbye' -ErrorAction SilentlyContinue).EnableGoodbye
    Write-Host "  ScreenSaveActive:      $ssActive  (0 = no auto screen-saver)"
    Write-Host "  ScreenSaverIsSecure:   $ssSecure  (0 = wake does not require password)"
    Write-Host "  EnableGoodbye:         $(if ($null -eq $eg) { 'not set' } else { $eg })  (0 or unset = Dynamic Lock off)"
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
Write-Host "  Scheduled Task:        $($task.State)"
Write-Host ("  Last run result:       0x{0:x8}" -f ($info.LastTaskResult))
Write-Host "  Daemon path:           $daemonPath"
Write-Host "  Log file:              $(Join-Path $InstallDir 'BlackOverlay.log')"
Write-Host ""
Write-Host "Daemon log tail (proof hotkeys registered):" -ForegroundColor Green
Get-Content -Path (Join-Path $InstallDir 'BlackOverlay.log') -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }

Write-Host ""
Write-Host "Smoke test:" -ForegroundColor Yellow
if ($isModernStandby) {
    Write-Host "  - Press the power button.        (Modern Standby - does nothing now, use a hotkey)" -ForegroundColor Yellow
} else {
    Write-Host "  - Press the power button.        Every monitor goes black." -ForegroundColor Yellow
}
Write-Host "  - Press Win+Shift+L.             Every monitor goes black." -ForegroundColor Yellow
Write-Host "  - Press Ctrl+Alt+Shift+L.        Same (alternate)." -ForegroundColor Yellow
Write-Host "  - Press Ctrl+Alt+Shift+B.        Same (alternate, no Win/L modifiers)." -ForegroundColor Yellow
Write-Host "  - Move the mouse:                Screen wakes, overlay stays." -ForegroundColor Yellow
Write-Host "  - Press Ctrl+Alt+Shift+End.      Dismiss." -ForegroundColor Yellow
Write-Host ""
Write-Host "Session is NOT locked. CUA tools (Amazon Quick, Playwright, AHK)" -ForegroundColor Yellow
Write-Host "can keep driving browser windows underneath the overlay." -ForegroundColor Yellow
