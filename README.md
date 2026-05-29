# Windows Power Button Black Screen (no lock, automation-friendly)

Press the laptop power button to paint every connected monitor black under a topmost click-through overlay, while leaving the user session unlocked. Background work keeps running at full clock, and automation tools that drive a real browser (Amazon Quick CUA, Playwright headed mode, Selenium, AutoHotkey, UI Automation) keep working because nothing is locked and synthesized input still reaches the windows beneath the overlay.

This is the screen-blanking sibling of [Windows-Power-Button-Lock-Without-Sleep](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep). Use that one when you want a real lock; use this one when you need the screen to *look* off but the session must stay interactive for unattended automation.

## TL;DR

| | This repo (Black Screen) | [Lock Without Sleep](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep) |
|---|---|---|
| Power button press | Paints every monitor black under topmost overlay | Turns off display, screen saver locks after idle |
| Session locked? | No | Yes (after the idle timer) |
| CUA / Playwright / Selenium can keep driving browsers? | Yes | No (locked sessions cannot receive synthesized input from foreground-style automation) |
| Real S0 the whole time | Yes | Yes |
| Privacy at the desk | Visual masking only | True OS-level lock |
| Wake by mouse/keyboard? | Yes (display wakes, overlay stays up) | Yes (lock screen appears) |
| Dismiss | Ctrl+Alt+Shift+End | Sign in |

## Why a black overlay instead of a lock?

A locked Windows session aggressively rejects synthesized input that arrives at the desktop. Foreground-driven CUA tools (the kind that move the mouse with `SendInput` and click through the window manager) can no longer reach the browser because the desktop they were targeting is gone — replaced by the secure desktop / lock screen.

For an unattended workflow that must keep automating a browser while the user is not at the desk, the lock is the wrong tool. The right tool is a visual mask over the unlocked desktop. Hence this repo.

The mask:

- Black, fullscreen, one window per monitor (covers all 4+ on a multi-monitor rig).
- Topmost so it sits above every other window.
- Click-through (`WS_EX_TRANSPARENT`) so synthesized mouse and keyboard input falls onto whatever is below.
- Non-activating (`WS_EX_NOACTIVATE`) so it never steals focus from the browser the agent is driving.
- Tool window (`WS_EX_TOOLWINDOW`) so it does not appear in Alt+Tab.

Result: the screen looks off, the session is unlocked, and an agent that is already attached to the foreground browser keeps working uninterrupted.

## Threat model (please read)

This is **not a security boundary**. It is a privacy curtain.

- Anyone who walks up can press `Ctrl+Alt+Shift+End` to dismiss the overlay and see the desktop. Pick a different shortcut in `BlackOverlay.ps1` if you need to be less obvious about it; `Win+L` will still lock the system the proper way.
- The pixels are gone but the unlocked desktop is one taskbar click or one keyboard wake away.
- Use the [lock-without-sleep](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep) repo if your environment requires a real lock.

If your setup is "I leave my laptop running an automation overnight in a private office and want the room to look dark," this is the right tool. If your setup is "I leave my laptop in a public space," it is not.

## Architecture

Two pieces:

1. **`powercfg`** rewrites the power button action to `Turn off the display` on AC and battery. The firmware blanks the panel; the OS fires a `WM_POWERBROADCAST` notification with `GUID_CONSOLE_DISPLAY_STATE` data byte `0`.
2. **`BlackOverlay.ps1`** is a long-running per-user PowerShell daemon registered as a Scheduled Task that runs at logon. It:
   - Builds a hidden message-only window via `NativeWindow`.
   - Calls `RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE)` so the message window receives the display-state events.
   - Calls `RegisterHotKey` for `Ctrl+Alt+Shift+End` (dismiss) and `Ctrl+Alt+Shift+B` (manual arm).
   - On display-off, instantiates one `OverlayForm` per `Screen.AllScreens` entry, each fullscreen at the monitor's bounds, with extended styles `WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`.
   - Runs `Application.Run()` so the message pump dispatches the WM_POWERBROADCAST and WM_HOTKEY messages forever.

```
+-------------------------+        powercfg writes AC+DC button index = 4
| User presses power btn  | -----> Firmware turns the panel off
+-------------------------+              |
                                         v
                              GUID_CONSOLE_DISPLAY_STATE = 0
                                         |
                                         v
+--------------------------------------------------+
| BlackOverlay.ps1 message window                  |
|   WndProc receives WM_POWERBROADCAST             |
|   Walks Screen.AllScreens                        |
|   Spawns one click-through OverlayForm per screen|
+--------------------------------------------------+
                                         |
                                         v
   +---------+ +---------+ +---------+ +---------+
   | mon 1   | | mon 2   | | mon 3   | | mon 4   |
   |  black  | |  black  | |  black  | |  black  |
   +---------+ +---------+ +---------+ +---------+

   (foreground browser windows still receive synthesized input
    because every overlay is WS_EX_TRANSPARENT + WS_EX_NOACTIVATE)
```

No service, no kernel driver, no third-party dependency. Pure Windows PowerShell + .NET Framework Forms + a small PInvoke surface.

## Quick install

From a normal (non-elevated) PowerShell prompt in the cloned repo:

```powershell
.\INSTALL.ps1
```

What this does:

1. Sets `Power button -> Turn off the display` on AC and battery (`powercfg`).
2. Copies `BlackOverlay.ps1` to `%LOCALAPPDATA%\BlackOverlay\BlackOverlay.ps1`.
3. Registers a per-user Scheduled Task `BlackOverlayDaemon` that runs at logon under your user account with `-WindowStyle Hidden`.
4. Starts the task immediately.

To install the daemon without touching `powercfg`:

```powershell
.\INSTALL.ps1 -SkipPowerButton
```

Useful if you want the manual hotkey only and prefer not to repurpose the power button.

## Use

| Action | How |
|---|---|
| Arm overlay (auto) | Press the laptop power button. |
| Arm overlay (manual) | `Ctrl+Alt+Shift+B` |
| Dismiss overlay | `Ctrl+Alt+Shift+End` |
| Wake screen without dismissing | Move the mouse or press a key — display wakes, overlay stays. |

The daemon is stateful: the overlay stays armed across display-off / display-on cycles. Walking back to the desk, jiggling the mouse, looking at the keyboard — none of those dismiss it. Only the dismiss hotkey or `UNINSTALL.ps1` does.

If you hot-plug a new monitor while the overlay is armed, the daemon does not auto-cover it. Press `Ctrl+Alt+Shift+B` to refresh: the daemon walks `Screen.AllScreens` again and adds an overlay window for any monitor that is not already covered.

## Verification

```powershell
# Power button mapping
powercfg /query SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280

# Scheduled Task
Get-ScheduledTask -TaskName BlackOverlayDaemon | Format-List State, TaskName, Author

# Daemon log
Get-Content "$env:LOCALAPPDATA\BlackOverlay\BlackOverlay.log" -Tail 30
```

Expected:

- Power button index `0x00000004` on AC and DC.
- Scheduled task state `Running`.
- The log shows `BlackOverlay starting`, then a `Listening for power-broadcast and hotkeys` line.

Smoke test:

1. Open a browser, navigate somewhere, then press the power button.
2. All monitors go black instantly.
3. Run a CUA / AHK / Playwright script that targets the browser. It should still click and type without errors.
4. Press `Ctrl+Alt+Shift+End`. Overlay disappears, you see the browser exactly where the agent left it.

## Compatibility with automation tools

The overlay is `WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`, which means:

| Tool | Works under the overlay? | Notes |
|---|---|---|
| **Amazon Quick CUA — DOM mode** | Yes | DOM injection ignores the OS window stack entirely. |
| **Amazon Quick CUA — visual mode** | Partial | Mouse / keyboard land on the right window. **Screenshots see black.** Use DOM mode if the agent depends on screenshots. |
| **Playwright (headed)** | Yes | Driven through CDP / WebSocket; the renderer keeps painting offscreen. |
| **Selenium WebDriver** | Yes | Same as Playwright. |
| **AutoHotkey `Send` / `Click`** | Yes | Keystrokes and clicks pass through. |
| **UI Automation / FlaUI** | Yes | Property-based; bypasses the window stack. |
| **Sikuli / image-template tools** | No | They take screenshots and match by pixel. The overlay is opaque to GDI capture. |
| **OBS / Teams screen share** | Sees black on whichever overlay-covered monitor it captures. | Use OBS window-capture (not display-capture) of the specific window you want to share. |

The deciding question is always **does the tool look at the screen, or does it talk to the application?** Anything that looks at the screen sees black. Anything that talks to the application is fine.

## What the script changes

| Setting | Where | After install |
|---|---|---|
| Power button (AC + DC) | `powercfg SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION` | `Turn off the display` (index 4) |
| Daemon script | `%LOCALAPPDATA%\BlackOverlay\BlackOverlay.ps1` | Copied from the repo |
| Daemon log | `%LOCALAPPDATA%\BlackOverlay\BlackOverlay.log` | Created on first run, append-only |
| Scheduled Task | `\BlackOverlayDaemon` (Task Scheduler library) | At-logon, current user, `-WindowStyle Hidden`, runs forever |

The install does **not** touch:

- Screen saver (`HKCU:\Control Panel\Desktop`).
- Sleep timeouts (`powercfg standby-timeout-*`).
- Dynamic Lock (`EnableGoodbye`).
- Lid-close action.

If you want the daemon **and** a long-tail real sleep on AC, run [Windows-Power-Button-Lock-Without-Sleep's](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep) `INSTALL.ps1 -SleepACMinutes 360` first, then run this repo's `INSTALL.ps1`. The sleep configuration survives because they touch different registry paths.

## Trade-offs and edge cases

- **No real lock.** Anyone with physical access can dismiss the overlay or wake the screen and click around. See the threat-model section above.
- **Hot-plug monitors do not auto-cover.** Press `Ctrl+Alt+Shift+B` to refresh. Continuous monitor enumeration on a 100 ms timer was rejected for battery reasons (laptop wake-from-sleep with a docked monitor is a common case).
- **The daemon shows nothing in the system tray.** Intentional. If you want a tray icon, replace the `MessageWindow` with a `NotifyIcon`. The daemon is otherwise stateless and the design favors zero footprint.
- **Hotkey collisions.** `Ctrl+Alt+Shift+End` and `Ctrl+Alt+Shift+B` are unusual enough that no shipping software the author has run binds them, but this is not guaranteed. If a binding fails, the daemon logs the failure and keeps running. Override by editing `BlackOverlay.ps1` and changing the `VK_*` constants.
- **Multiple monitors with HDR.** The overlay form fills `Screen.Bounds`, which is in DIPs. On scaled displays the result is correctly sized. HDR overlays render as standard sRGB black; that is fine for visual masking.
- **High-DPI taskbar peek.** Some Win11 builds occasionally show a 1 px taskbar artifact on the primary monitor when a topmost layered window is created. The daemon's `WS_EX_TOOLWINDOW` style suppresses this in testing on Win11 23H2 and 24H2, but the artifact has been seen briefly on 22H2 with display drivers older than 31.x.

## Uninstall

```powershell
.\UNINSTALL.ps1
```

What this does:

- Stops and unregisters the Scheduled Task.
- Kills any orphan `powershell.exe` processes still running `BlackOverlay.ps1`.
- Deletes `%LOCALAPPDATA%\BlackOverlay` (pass `-KeepLogs` to keep the log).
- Restores the power button to `Sleep` on AC and DC.

The "Turn off the display" option remains unhidden in Control Panel (harmless).

## Files

- `INSTALL.ps1` — installer (no admin required).
- `UNINSTALL.ps1` — uninstaller.
- `BlackOverlay.ps1` — long-running per-user daemon. The interesting code lives here.
- `ABOUT.md` — design notes, what was tried that did not work, why each decision was made.
- `CHANGELOG.md` — version history.

## License

MIT. See [LICENSE](LICENSE).

## Source References

- [Microsoft Learn — `powercfg` command-line options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)
- [Microsoft Learn — `RegisterPowerSettingNotification`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerpowersettingnotification)
- [Microsoft Learn — `WM_POWERBROADCAST`](https://learn.microsoft.com/en-us/windows/win32/power/wm-powerbroadcast)
- [Microsoft Learn — `GUID_CONSOLE_DISPLAY_STATE`](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids)
- [Microsoft Learn — Extended Window Styles (`WS_EX_TRANSPARENT`, `WS_EX_LAYERED`, `WS_EX_NOACTIVATE`)](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles)
- [Microsoft Learn — `RegisterHotKey`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)
