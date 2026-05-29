<#
.SYNOPSIS
    Revert everything INSTALL.ps1 set up.

.DESCRIPTION
    - Stops and unregisters the BlackOverlayDaemon Scheduled Task.
    - Removes %LOCALAPPDATA%\BlackOverlay (script, log).
    - Restores the power button action to Sleep.
    - Re-enables USB selective suspend on the active scheme (the
      installer disabled it to keep USB devices stable while the
      daemon held the system at S0 with display off).

    The "Turn off the display" option remains unhidden in Control Panel
    (harmless and arguably useful).

    No reboot or sign-out required.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'BlackOverlay'),
    [string]$TaskName   = 'BlackOverlayDaemon',
    [switch]$KeepLogs,
    [switch]$SkipPowerButton,
    [switch]$SkipUsbRestore
)

$ErrorActionPreference = 'Stop'

$SUB_BUTTONS   = '4f971e89-eebd-4455-a8de-9e59040e7347'
$PBUTTONACTION = '7648efa3-dd9c-4e3e-b566-50f929386280'
$SLEEP_INDEX   = 1
$SUB_USB       = '2a737441-1930-4402-8d77-b2bebba308a3'
$USB_SUSPEND   = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'

Write-Host "[1/4] Stopping and removing Scheduled Task '$TaskName'..." -ForegroundColor Cyan
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*BlackOverlay.ps1*" } |
    ForEach-Object {
        Write-Host "       Stopping orphan daemon (pid=$($_.ProcessId))..." -ForegroundColor DarkGray
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }

Write-Host "[2/4] Removing $InstallDir ..." -ForegroundColor Cyan
if (Test-Path $InstallDir) {
    if ($KeepLogs) {
        $script = Join-Path $InstallDir 'BlackOverlay.ps1'
        if (Test-Path $script) { Remove-Item -Path $script -Force }
    } else {
        Remove-Item -Path $InstallDir -Recurse -Force
    }
}

if (-not $SkipPowerButton) {
    Write-Host "[3/4] Restoring power button -> Sleep (AC + battery)..." -ForegroundColor Cyan
    & powercfg /setacvalueindex SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION $SLEEP_INDEX | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT $SUB_BUTTONS $PBUTTONACTION $SLEEP_INDEX | Out-Null
    & powercfg /setactive SCHEME_CURRENT | Out-Null
} else {
    Write-Host "[3/4] Skipping powercfg restore (-SkipPowerButton)." -ForegroundColor DarkGray
}

if (-not $SkipUsbRestore) {
    Write-Host "[4/4] Re-enabling USB selective suspend (Windows default)..." -ForegroundColor Cyan
    & powercfg /setacvalueindex SCHEME_CURRENT $SUB_USB $USB_SUSPEND 1 2>$null | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT $SUB_USB $USB_SUSPEND 1 2>$null | Out-Null
    & powercfg /setactive SCHEME_CURRENT | Out-Null
} else {
    Write-Host "[4/4] Skipping USB suspend restore (-SkipUsbRestore)." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Reverted." -ForegroundColor Green
Write-Host "Power button is back to Sleep, daemon removed, USB selective suspend re-enabled." -ForegroundColor Green
