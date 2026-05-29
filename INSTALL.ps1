<#
.SYNOPSIS
    Install the Power-Button Black-Screen daemon. Pressing the laptop power
    button blanks every connected display under a topmost click-through black
    overlay, while leaving the user session unlocked so automation tools
    (Amazon Quick CUA, Selenium, headed Playwright, etc.) keep their grip on
    browser windows underneath.

.DESCRIPTION
    Performs three coordinated actions:

      1. Configures powercfg so the short-press of the power button maps to
         "Turn off the display" on AC and battery. The firmware blanks the
         panel; Windows fires GUID_CONSOLE_DISPLAY_STATE = 0.
      2. Copies BlackOverlay.ps1 into %LOCALAPPDATA%\BlackOverlay\.
      3. Registers a per-user Scheduled Task "BlackOverlayDaemon" that runs at
         logon under the current user with a hidden powershell.exe host. The
         task is also started immediately so the first cycle works without a
         sign-out.

    The daemon paints one click-through black window per monitor as soon as
    GUID_CONSOLE_DISPLAY_STATE goes Off. The session is NOT locked. Mouse and
    keyboard input still reach the windows beneath the overlay (the overlay's
    extended style includes WS_EX_TRANSPARENT). Synthesized input from CUA
    tools likewise passes through.

    No reboot or sign-out required.

.PARAMETER InstallDir
    Optional. Where to drop BlackOverlay.ps1 and its log. Defaults to
    "$env:LOCALAPPDATA\BlackOverlay".

.PARAMETER TaskName
    Optional. Scheduled Task name. Defaults to "BlackOverlayDaemon".

.PARAMETER SkipPowerButton
    If present, the powercfg edits are skipped. Useful for testing the daemon
    without touching the user's existing power configuration.

.EXAMPLE
    .\INSTALL.ps1

.EXAMPLE
    # Install the daemon only; leave the power button alone
    .\INSTALL.ps1 -SkipPowerButton

.NOTES
    Run from PowerShell. Admin is NOT required: powercfg /setacvalueindex on
    SCHEME_CURRENT and HKCU writes only need user privilege. The Scheduled Task
    is registered under the current user with -RunLevel Limited.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'BlackOverlay'),
    [string]$TaskName   = 'BlackOverlayDaemon',
    [switch]$SkipPowerButton
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Power button -> Turn off the display
# ---------------------------------------------------------------------------

$SUB_BUTTONS   = '4f971e89-eebd-4455-a8de-9e59040e7347'
$PBUTTONACTION = '7648efa3-dd9c-4e3e-b566-50f929386280'
$TURN_OFF_DISP = 4

if (-not $SkipPowerButton) {
    Write-Host "[1/4] Unhiding the 'Turn off the display' option..." -ForegroundColor Cyan
    & powercfg /attributes $SUB_BUTTONS $PBUTTONACTION -ATTRIB_HIDE | Out-Null

    Write-Host "[2/4] Setting power button -> Turn off the display (AC + battery)..." -ForegroundColor Cyan
    & powercfg /setacvalueindex SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION $TURN_OFF_DISP | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION $TURN_OFF_DISP | Out-Null
    & powercfg /setactive SCHEME_CURRENT | Out-Null
} else {
    Write-Host "[1-2/4] Skipping powercfg changes (-SkipPowerButton)." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 2. Copy daemon into a stable location
# ---------------------------------------------------------------------------

Write-Host "[3/4] Installing BlackOverlay.ps1 to $InstallDir ..." -ForegroundColor Cyan
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$source = Join-Path $PSScriptRoot 'BlackOverlay.ps1'
if (-not (Test-Path $source)) {
    throw "BlackOverlay.ps1 not found next to INSTALL.ps1 (looked in $PSScriptRoot)."
}
Copy-Item -Path $source -Destination (Join-Path $InstallDir 'BlackOverlay.ps1') -Force

# ---------------------------------------------------------------------------
# 3. Register the per-user logon Scheduled Task
# ---------------------------------------------------------------------------

Write-Host "[4/4] Registering Scheduled Task '$TaskName' (per-user, at logon)..." -ForegroundColor Cyan

$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$daemonPath = Join-Path $InstallDir 'BlackOverlay.ps1'

# Using powershell.exe with -WindowStyle Hidden so the message-only window stays out of the taskbar.
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

# Idempotent re-register
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

# Kick it off now so the user does not have to sign out.
Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 1

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Verification:" -ForegroundColor Green

if (-not $SkipPowerButton) {
    $ac = (& powercfg /query SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION) | Select-String -Pattern 'Current AC Power Setting Index:\s*0x([0-9a-f]+)'
    $dc = (& powercfg /query SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION) | Select-String -Pattern 'Current DC Power Setting Index:\s*0x([0-9a-f]+)'
    Write-Host "  Power button (AC):     $($ac.Matches[0].Groups[1].Value)  (4 = Turn off the display)"
    Write-Host "  Power button (DC):     $($dc.Matches[0].Groups[1].Value)  (4 = Turn off the display)"
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
Write-Host "  Scheduled Task:        $($task.State)"
Write-Host "  Last run result:       0x{0:x8}" -f ($info.LastTaskResult)
Write-Host "  Daemon path:           $daemonPath"
Write-Host "  Log file:              $(Join-Path $InstallDir 'BlackOverlay.log')"
Write-Host ""
Write-Host "Smoke test:" -ForegroundColor Yellow
Write-Host "  - Press the power button. Every monitor goes black." -ForegroundColor Yellow
Write-Host "  - Move the mouse: the screen wakes, but the overlay stays up." -ForegroundColor Yellow
Write-Host "  - Press Ctrl+Alt+Shift+End to dismiss." -ForegroundColor Yellow
Write-Host "  - Press Ctrl+Alt+Shift+B to arm manually (without using the power button)." -ForegroundColor Yellow
Write-Host ""
Write-Host "Session is NOT locked. CUA tools (Amazon Quick, Playwright, AHK)" -ForegroundColor Yellow
Write-Host "can keep driving browser windows underneath the overlay." -ForegroundColor Yellow
