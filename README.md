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

1. Sets `Power button -> Turn off the display` on AC and battery (`powercfg`). On Modern Standby (S0ix) hardware the power button is instead set to `Do nothing` so the firmware does not drop the system into connected standby; on those machines, use a hotkey (see below).
2. Disables the secure screen saver (`ScreenSaverIsSecure=0`, `ScreenSaveActive=0`) and Dynamic Lock (`EnableGoodbye=0`) so nothing auto-locks the session after the display turns off. See [Why the lock-guard?](#why-the-lock-guard) below.
3. Copies `BlackOverlay.ps1` to `%LOCALAPPDATA%\BlackOverlay\BlackOverlay.ps1`.
4. Registers a per-user Scheduled Task `BlackOverlayDaemon` that runs at logon under your user account with `-WindowStyle Hidden`.
5. Starts the task immediately.

The daemon also holds `SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED)` for its entire lifetime. This is the GPO bypass: corporate-managed laptops push `ScreenSaverIsSecure=1` to the policy registry path, which user-mode cannot clear durably. But the screen-saver activation predicate Windows uses is *"any thread holding `ES_DISPLAY_REQUIRED`"*, and that operates on the running session, not the registry. The daemon holding the flag means the saver never fires regardless of policy. See [GPO bypass](#gpo-bypass) below for the full mechanism.

To install the daemon without touching `powercfg`:

```powershell
.\INSTALL.ps1 -SkipPowerButton
```

Useful if you want the manual hotkey only and prefer not to repurpose the power button.

To install without disabling the secure screen saver / Dynamic Lock:

```powershell
.\INSTALL.ps1 -SkipLockGuard
```

Use only if you intentionally want lock-on-idle to stay on. Default behaviour clears it because lock-on-idle defeats the whole point of this daemon (the session must stay unlocked).

### Why the lock-guard?

If you previously installed the sibling repo [Windows-Power-Button-Lock-Without-Sleep](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep), it set:

- `HKCU:\Control Panel\Desktop\ScreenSaverIsSecure = 1`
- `HKCU:\Control Panel\Desktop\ScreenSaveActive = 1`
- `HKCU:\Control Panel\Desktop\ScreenSaveTimeOut = 180` (or whatever you passed)

That state survives uninstalls of *that* repo's `UNINSTALL.ps1` only partially — and even on a clean Windows install, an enterprise GPO can flip these on. With those values active and this repo's daemon running, the flow is:

1. Power button pressed → display off → overlay armed (correct).
2. 180 seconds later Windows counts the user as idle → secure screen saver fires → **session locks**.

The lock-guard step in step 2 of the installer clears those values up front so the two repos cannot fight on the same box and so a stale screen-saver setting never quietly re-locks the session.

## GPO bypass

On a corporate-managed laptop the v1.1 lock-guard is necessary but not sufficient. Intune / GPO pushes the same screen-saver values to a *different* registry path that the policy engine owns:

```
HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop\
    ScreenSaverIsSecure = 1
    ScreenSaveActive    = 1
    ScreenSaveTimeOut   = 900    (typically 15 min)
```

Windows reads the policy path ahead of the user-scope path. User-mode code cannot clear policy values durably; they are re-applied on every policy refresh (about every 90 minutes). Same for the `SystemParametersInfo(SPI_SETSCREENSAVEACTIVE, FALSE)` API call: on managed boxes it returns FALSE with `Win32Error=0x4ec` (`ERROR_NOT_FOR_YOU_TO_PROCESS`).

The right answer is to operate one layer above the registry, on the *running session itself*. Windows decides whether to launch the screen saver by checking whether any thread is holding `ES_DISPLAY_REQUIRED` via `SetThreadExecutionState`. If the daemon holds it, the saver does not fire — regardless of registry, policy, or anything else. This is the same mechanism PowerPoint, Teams, and OBS use to keep the display alive during presentations.

The daemon holds:

```
ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED
```

continuously for its entire lifetime. Released only when the daemon shuts down (the `finally` block of the message loop). The flags mean:

| Flag | Effect |
|---|---|
| `ES_CONTINUOUS` | Persist these flags until cleared, instead of one-shot |
| `ES_DISPLAY_REQUIRED` | Suppresses screen-saver activation and display-off idle timeout |
| `ES_SYSTEM_REQUIRED` | Suppresses sleep on idle |
| `ES_AWAYMODE_REQUIRED` | On Modern Standby (S0ix) hardware, prevents the system from dropping into connected standby |

The daemon also calls `SystemParametersInfo(SPI_SETSCREENSAVEACTIVE, FALSE)` at startup and every 60 seconds as a best effort. On unmanaged machines that succeeds and is a belt-and-suspenders win. On GPO-locked machines it is denied; the log records the failure and the `ES_*` keepalive does the actual work.

The daemon log makes the GPO state explicit at startup, so future investigations have evidence:

```
Idle keepalive ON (prev=0x80000000, flags=0x80000043).
SPI_SETSCREENSAVEACTIVE blocked at startup (Win32Error=0x4ec, was=False). Relying on ES_DISPLAY_REQUIRED keepalive.
GPO policy path present: ScreenSaverIsSecure=1 ScreenSaveActive=1 ScreenSaveTimeOut=900.
```

## Modern Standby (S0ix) hardware

Some laptops (most modern ARM and many Intel Tiger Lake+ devices) only support `Standby (S0 Low Power Idle) Network Connected` — confirm with `powercfg /a`. On those machines, mapping the power button to "Turn off the display" causes the firmware to drop the *entire system* into S0ix to save power, parking every user-mode message pump including the daemon's. The overlay cannot paint until the system wakes, which defeats the muscle-memory the daemon is supposed to support.

The installer probes for Modern Standby and on those machines maps the power button to **`Do nothing`** instead. Use `Win+Shift+L`, `Ctrl+Alt+Shift+L`, or `Ctrl+Alt+Shift+B` to arm the overlay. The daemon paints overlays before any firmware-blank happens, so this path is fully reliable on Modern Standby hardware.

The reason this cannot be fixed at the daemon layer alone is that `SetThreadExecutionState(ES_AWAYMODE_REQUIRED)` only blocks *idle-driven* connected standby entry. Power-button-driven entry on Modern Standby goes through a different kernel path that does not consult execution-state flags. Disabling Connected Standby system-wide via `HKLM:\System\CurrentControlSet\Control\Power\CsEnabled = 0` would also fix it but requires admin and a reboot, which is out of scope for a per-user daemon.

## USB-C dock and Modern Standby

Modern Standby + USB-C dock is a notorious failure mode. When the system enters S0ix, the firmware's power broker tears down USB selective-suspend-eligible devices, which on Modern Standby boxes includes the USB4 / Thunderbolt tunnel that the dock rides over. On wake, the tunnel does not always re-enumerate cleanly: external displays stay dark, the dock's downstream USB hubs disappear, and `Get-PnpDevice -Class Monitor` shows the external monitors with `Present=False` until the user physically unplugs and replugs the cable.

The installer disables USB selective suspend on the active power scheme as part of step 3 of the install. This is per-user-scheme, requires no admin, and is reversible by `UNINSTALL.ps1`. Combined with the v1.2 Modern Standby `Do nothing` power-button mapping (which prevents power-button-driven S0ix entry) and the v1.2 `ES_AWAYMODE_REQUIRED` keepalive (which prevents idle-driven S0ix entry while the daemon runs), the dock should stay enumerated continuously while the daemon is alive.

If you ever do find your dock wedged after a Modern Standby cycle, the cleanest reset is to physically unplug the USB-C cable, wait 10 seconds, and plug it back in. `pnputil /restart-device` against the dock's USB4 router can also work but requires admin.

## Use

| Action | How |
|---|---|
| Arm overlay (auto, S3 hardware) | Press the laptop power button. |
| Toggle overlay (arm or dismiss) | `Ctrl+Alt+Shift+B`, `Win+Shift+L`, or `Ctrl+Alt+Shift+L` |
| Dismiss overlay (unconditional) | `Ctrl+Alt+Shift+End` |
| Wake screen without dismissing | Move the mouse or press a key. Display wakes, overlay stays. |

On Modern Standby (S0ix) laptops the power button is intentionally mapped to `Do nothing` (see [Modern Standby (S0ix) hardware](#modern-standby-s0ix-hardware) above), so use a hotkey to arm. The daemon paints the overlay before any firmware-blank request goes out, which is fully reliable.

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

- Power button index `0x00000004` on AC and DC (S3 laptops) or `0x00000000` (`Do nothing`, on Modern Standby laptops).
- Scheduled task state `Running`.
- The log shows `BlackOverlay starting`, then `Idle keepalive ON`, then a `Listening for power-broadcast and hotkeys` line.

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
| Power button (AC + DC) | `powercfg SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION` | `Turn off the display` (index 4) on S3 hardware, or `Do nothing` (index 0) on Modern Standby hardware |
| Secure screen saver | `HKCU:\Control Panel\Desktop\ScreenSaverIsSecure` | `0` (cleared by lock-guard; skip with `-SkipLockGuard`) |
| Auto screen saver | `HKCU:\Control Panel\Desktop\ScreenSaveActive` | `0` (cleared by lock-guard; skip with `-SkipLockGuard`) |
| Dynamic Lock | `HKCU:\...\Winlogon\EnableGoodbye` | `0` if previously set (cleared by lock-guard) |
| USB selective suspend | `powercfg SCHEME_CURRENT SUB_USB USBSELECTIVESUSPEND` | `0` on AC and DC (cleared by lock-guard) - prevents USB-C dock tunnels from being torn down during connected-standby cycles. Restored to `1` by `UNINSTALL.ps1`. |
| Running-session screen saver | `SystemParametersInfo(SPI_SETSCREENSAVEACTIVE)` | Best-effort `FALSE` at startup and every 60s. Denied on GPO-locked boxes; the ES keepalive picks up the slack. |
| Thread execution state | `SetThreadExecutionState` (held by daemon thread) | `ES_CONTINUOUS \| ES_DISPLAY_REQUIRED \| ES_SYSTEM_REQUIRED \| ES_AWAYMODE_REQUIRED`. This is the GPO bypass. |
| Daemon script | `%LOCALAPPDATA%\BlackOverlay\BlackOverlay.ps1` | Copied from the repo |
| Daemon log | `%LOCALAPPDATA%\BlackOverlay\BlackOverlay.log` | Created on first run, append-only |
| Scheduled Task | `\BlackOverlayDaemon` (Task Scheduler library) | At-logon, current user, `-WindowStyle Hidden`, runs forever |

The install does **not** touch:

- Sleep timeouts (`powercfg standby-timeout-*`).
- Lid-close action.
- The `SCRNSAVE.EXE` registry value (only `ScreenSaverIsSecure` and `ScreenSaveActive` are cleared, so your chosen screen saver binary stays selected — it just no longer fires automatically).

If you want the daemon **and** a long-tail real sleep on AC, run this repo's `INSTALL.ps1` first, then run [Windows-Power-Button-Lock-Without-Sleep's](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep) `INSTALL.ps1 -SleepACMinutes 360 -SkipPowerButton -SkipScreenSaver`. The sleep configuration survives because they touch different registry paths. **Do not** run that repo's installer with the screen-saver step enabled while this daemon is also running — the secure screen saver will lock the session out from under the overlay.

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
