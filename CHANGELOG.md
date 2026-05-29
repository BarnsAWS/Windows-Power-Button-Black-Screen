# Changelog

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
