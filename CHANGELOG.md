# Changelog

# Changelog

## v1.2 - 2026-05-29

- **Fix: GPO-enforced 15-minute secure screen saver still locked the
  session after v1.1.** Root cause: corporate Intune/GPO pushes
  `ScreenSaverIsSecure=1` to the policy registry path
  (`HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop`),
  which Windows reads ahead of the user-scope path that v1.1's
  lock-guard cleared. Policy values cannot be cleared from user mode
  durably; they get re-applied on every policy refresh.
- The daemon now neutralises the lock at the running-session layer
  instead of fighting the registry:
  - `SystemParametersInfo(SPI_SETSCREENSAVEACTIVE, FALSE)` at startup
    and on a 60s timer. Disables the running-session screen-saver
    dispatch in user32. On GPO-locked boxes this call is denied
    (`Win32Error=0x4ec ERROR_NOT_FOR_YOU_TO_PROCESS`); the daemon
    logs the failure and falls back to:
  - `SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED |
    ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED)` held continuously for
    the daemon's lifetime. Windows checks for any thread holding
    `ES_DISPLAY_REQUIRED` before activating the screen saver; when
    held, the saver does not fire regardless of registry or policy
    state. Verified by `WM_SYSCOMMAND SC_SCREENSAVE` injection test.
- **Fix: Power button + "Turn off the display" caused Modern Standby
  drop on S0ix-capable laptops.** The firmware handed the action to
  the connected-standby path, parking the daemon's message pump until
  wake. Result: muscle memory of "press power, screen blanks instantly
  with overlay" was broken.
  - Installer now probes `powercfg /a` for "S0 Low Power Idle" and on
    Modern Standby hardware maps the power button to `Do nothing`
    instead, so the daemon stays alive. Hotkeys (`Win+Shift+L`,
    `Ctrl+Alt+Shift+B`, `Ctrl+Alt+Shift+L`) are the arm path on those
    machines. On legacy S3-only hardware the power button still maps
    to "Turn off the display" as before.
- New diagnostic logging: daemon emits the active-policy values,
  GPO-bypass status, and ES_* flag set at startup so future
  investigations have evidence in the log.
- Verification block in `INSTALL.ps1` now reports the resolved power
  button action by name and surfaces Modern Standby detection.
- See `INVESTIGATION-2026-05-29.md` for the full root-cause writeup.

## v1.1 - 2026-05-29

- **Fix: session was getting locked after pressing the power button.** Root
  cause: a stale `ScreenSaverIsSecure=1` from a prior install of the sibling
  [Windows-Power-Button-Lock-Without-Sleep](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep)
  repo was still active. With that set, Windows counted the user as idle
  after the power button blanked the display, and the secure screen saver
  fired, locking the session out from under the overlay.
- INSTALL.ps1 now actively neutralises lock-on-idle as a fourth step:
  - `HKCU:\Control Panel\Desktop\ScreenSaverIsSecure = 0`
  - `HKCU:\Control Panel\Desktop\ScreenSaveActive = 0`
  - `HKCU:\...\Winlogon\EnableGoodbye = 0` (Dynamic Lock off)
- New `-SkipLockGuard` switch on INSTALL.ps1 for users who intentionally
  want lock-on-idle to remain on.
- Verification block in INSTALL.ps1 now prints the lock-guard state.
- README documents the lock-guard, why it exists, and the order in which to
  run the sibling repo's installer if you also want sleep-on-idle.

## v1.0 — 2026-05-29

- Initial commit. Branched from
  [Windows-Power-Button-Lock-Without-Sleep](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep)
  but reworked end-to-end: instead of the screen-saver-locks-the-session
  approach, this repo paints a topmost click-through black overlay on every
  monitor while leaving the user session unlocked, so foreground-driven
  browser automation (Amazon Quick CUA, Playwright headed, AutoHotkey)
  can keep operating underneath.
- Power button -> Turn off the display (AC + DC).
- Per-user `BlackOverlayDaemon` Scheduled Task running at logon.
- Daemon subscribes to `GUID_CONSOLE_DISPLAY_STATE` and to global hotkeys:
  - `Ctrl+Alt+Shift+End` — dismiss the overlay.
  - `Ctrl+Alt+Shift+B`   — manually arm.
- One overlay window per monitor, `WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
  WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`.
- INSTALL.ps1 / UNINSTALL.ps1 with `-SkipPowerButton` and `-KeepLogs` switches.
- README and ABOUT documenting the threat model, architecture, automation
  compatibility, and what was tried that did not work.
