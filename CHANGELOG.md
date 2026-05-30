# Changelog

# Changelog

## v1.6 - 2026-05-29

- **Fix: overlays only covered ~80% of each monitor on high-DPI laptops.**
  After v1.4 made the layered windows opaque, the user reported the
  overlay still left uncovered strips on the right and bottom of every
  monitor. Root cause: the daemon process was DPI-unaware, so
  `Screen.AllScreens` returned DPI-scaled bounds (e.g. 2048x1152 for a
  2560x1440 monitor at 125%). The forms were being created at those
  scaled bounds and painting at scaled physical pixels, leaving 512px
  on the right and 288px on the bottom of every monitor uncovered.

  Fix: call `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`
  immediately after the type definitions load, before any Form is
  created. This must be done before the first Form because the DPI
  context is locked in at first window creation. Also added a belt
  `SetWindowPos(handle, HWND_TOPMOST, X, Y, W, H, SWP_NOACTIVATE | SWP_FRAMECHANGED)`
  in `OverlayForm.OnHandleCreated` so the layered-window CreateWindowEx
  path cannot subtly drift the bounds.

- **Hotkey behavior: arm/dismiss is now toggle.** Pressing Win+Shift+L,
  Ctrl+Alt+Shift+L, or Ctrl+Alt+Shift+B while the overlay is up now
  dismisses it; pressing again arms. Old behavior was always-arm
  (Ctrl+Alt+Shift+End for dismiss only). Old dismiss hotkey still
  works as a dedicated unconditional dismiss. Log lines are now
  `Hotkey: TOGGLE (WIN+SHIFT+L)` etc.

- Verified: 4 overlay forms at native rectangles (DISPLAY4 now
  reports 2560x1440 not 2048x1152), `alpha=255 flags=0x2` on every
  form, toggle ARM/DISMISS cycle is symmetric.

## v1.4 - 2026-05-29

- **Fix: overlays were invisible (the actual visual bug).** The forms
  set `WS_EX_LAYERED` in their CreateParams but never called
  `SetLayeredWindowAttributes`, so Windows treated them as fully
  transparent. The forms were correctly created, sized, topmost, and
  click-through, but the BackColor was never composited because layered
  windows do not paint via the normal WinForms paint pipeline without
  explicit alpha configuration. The user-visible symptom was the system
  tray bell icon flickering on hotkey press (taskbar repaint as the
  "invisible" overlay forms were created and shown), but the screen
  staying entirely visible.

  Fix: override `OnHandleCreated` on `OverlayForm` and call
  `SetLayeredWindowAttributes(handle, 0, 255, LWA_ALPHA)` so the
  window is opaque black. Verified with `GetLayeredWindowAttributes`:
  all 4 overlay forms now report `alpha=255 flags=0x2`.

## v1.3 - 2026-05-29

- **Fix: hotkey re-arm did nothing after monitor topology change.**
  Caused by `Show-Overlays` keying its "is this monitor already
  covered" check off the previously-cached `Bounds`. After a dock
  disconnect, undock, or display rearrangement, the cached overlays
  were sitting at coordinates pointing nowhere and `Show-Overlays`
  thought all current monitors were already covered, so it skipped
  painting. The new `Show-Overlays` always tears down every existing
  overlay and re-enumerates `Screen.AllScreens` on every arm event.
  New log line `Re-arming overlays (re-enumerating displays).` makes
  the behavior visible. Verified by the new `_test_rearm.ps1` test
  injecting WM_HOTKEY id=3 twice in a row.
- **Fix: USB devices dropping during Modern Standby cycles.** On
  S0ix-capable laptops with a USB-C dock, USB selective suspend was
  tearing down the dock's USB4/TB tunnel during connected-standby
  entry, and the tunnel did not always re-enumerate cleanly on wake.
  Installer now disables USB selective suspend on the active power
  scheme (per-user-scheme, no admin needed). UNINSTALL.ps1 re-enables
  it. The Modern Standby `Do nothing` power-button mapping shipped in
  v1.2 already prevented power-button-driven S0ix entry; this v1.3
  change covers the idle-driven case.
- Verification block in `INSTALL.ps1` now reports the USB selective
  suspend state alongside the lock-guard state.
- New `-SkipUsbRestore` switch on `UNINSTALL.ps1` for the rare case
  where USB suspend should stay disabled after uninstall.

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
  browser automation (Playwright headed, AutoHotkey, computer-use agents)
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
