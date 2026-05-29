# About

The screen-blanking sibling of [Windows-Power-Button-Lock-Without-Sleep](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep). Same goal — press the power button, screen looks off, work keeps running. Different mechanism — a topmost click-through black overlay instead of an OS-level lock.

## Why does this exist?

Long-running browser automation. Specifically: I run [Amazon Quick](https://github.com/BarnsAWS/Amazon-Quick) CUA jobs that take 30–90 minutes and need a real browser, real mouse cursor, real keystroke synthesis. They have to keep going while I'm not at the desk, and the screens have to *look* off so I'm not staring at four bright monitors from the next room.

The original "lock without sleep" repo gets the second half right but breaks the first half. A locked Windows session is a hostile environment for any automation that drives the foreground:

- The desktop the agent was targeting is gone — replaced by the secure desktop / lock screen.
- Synthesized input via `SendInput` and `mouse_event` no longer lands on the browser. Windows routes it to the secure desktop instead.
- Browser windows are still alive (the renderer keeps composing) but no foreground-driver tool can reach them.

For pure-DOM automation (Selenium, Playwright over CDP, headless browsers) the lock is fine. For visual / foreground-driver automation the lock is a non-starter.

So: keep the desktop unlocked, paint over it with a curtain. The curtain is a real top-level window, but with extended styles that make it transparent to input and invisible to focus management. Synthesized clicks pass through. The browser keeps cooking.

## Design principles

- **Idempotent.** Running INSTALL.ps1 twice is safe.
- **Reversible.** UNINSTALL.ps1 puts the power button back, removes the daemon, deletes the install dir.
- **Per-user.** No admin required. Power button settings on `SCHEME_CURRENT` and the Scheduled Task under the current user both work at user privilege.
- **No third-party dependencies.** PowerShell 5.1, .NET Framework, PInvoke against `user32.dll`. Nothing to install, nothing to sign.
- **No telemetry.** Scripts make no network calls.
- **Minimum surface.** One installer, one uninstaller, one daemon. The daemon does not draw a tray icon, does not write registry settings, does not write to a config file. Hotkeys are constants in the source. If you don't like them, edit the source.

## Why a click-through topmost window?

Three options for masking the desktop without locking it:

1. **Set every monitor's gamma to (0,0,0).** Works as a visual blank. Breaks the moment any other process changes gamma (HDR toggles, calibration tools, games). Recovers awkwardly. Rejected.
2. **Spawn a fullscreen black borderless window per monitor with `WS_EX_TRANSPARENT` and `WS_EX_NOACTIVATE`.** What this repo does. The window is real, so capture tools either see black (display-capture) or see what is behind it (window-capture of the underlying app). Input passes through.
3. **Run a fullscreen exclusive-mode app like a black D3D fullscreen.** Works. Forces a display-mode change that confuses some external monitors and adds 100–500 ms when arming. Rejected.

Option 2 wins because it is small, fast, recovers cleanly, and does not interfere with any other process.

## Why `GUID_CONSOLE_DISPLAY_STATE` and not a hotkey alone?

The whole point of this trick is the muscle memory: tap the power button, screen blanks, walk away. The user does not want to remember a hotkey under normal use.

`GUID_CONSOLE_DISPLAY_STATE` is the right Windows event for "the display went off." It fires regardless of *why* the display went off:

- The user pressed the power button (with `powercfg` set to "Turn off the display").
- The user closed the lid (if `lidclose` is mapped to "Turn off the display").
- The screen saver fired and `ScreenSaveActive` triggered.
- The display timed out via `monitor-timeout-*`.

This means the same daemon covers all four of those triggers without separate code paths. The hotkey is for the override case where you want the overlay without touching the power button.

## What was tried that didn't work

- **`SetSystemPowerState(SuspendAllowed=FALSE, MonitorOff=TRUE)` directly.** Works to turn the display off, but doesn't paint anything. You still need a separate trigger or overlay to mask the screen between display-off and display-wake events.
- **A WPF window with `AllowsTransparency=True` and a Black brush.** Builds correctly. But WPF transparent windows on Windows trigger DWM software rendering paths, which interact poorly with `WS_EX_TRANSPARENT`. Mouse passthrough is unreliable on per-monitor DPI setups. Switched to WinForms, which uses raw GDI for the form and lets us push the click-through behavior cleanly through `WS_EX_TRANSPARENT`.
- **A single huge window covering all four monitors as one virtual rect.** Cheaper to spawn but breaks taskbar / DWM behavior on monitors that have different DPI scales. One window per monitor is correct.
- **Hooking `WM_SYSCOMMAND` with `SC_MONITORPOWER` instead of subscribing to `GUID_CONSOLE_DISPLAY_STATE`.** Works for screen-saver-driven blanks. Does NOT fire when `powercfg` blanks the display via the power button. The power-button path goes through the kernel power manager and surfaces as `GUID_CONSOLE_DISPLAY_STATE`, not as `WM_SYSCOMMAND`. Use the right event.
- **Using a global keyboard hook to detect the power button.** The firmware consumes the power button event before any user-mode hook sees it on most laptops. Same root cause that defeated AutoHotkey in the lock repo's design notes. Always go through `powercfg` + display-state notification.
- **Clearing `HKCU:\Control Panel\Desktop\ScreenSaverIsSecure` to defeat the secure screen saver.** Works on unmanaged machines. Useless on Intune/GPO-managed boxes that re-apply `\Software\Policies\Microsoft\Windows\Control Panel\Desktop\ScreenSaverIsSecure=1` on every policy refresh. The fix is to operate at the running-session layer with `SetThreadExecutionState(ES_DISPLAY_REQUIRED)`, which Windows checks before activating the screen saver and which the policy engine cannot override. See README's [GPO bypass](README.md#gpo-bypass) section.
- **Killing `scrnsave.scr` whenever it spawns.** Considered as a fallback for GPO-locked boxes. Rejected because (a) it races: the screen saver locks the session in the same SCM call that launches `.scr`, so by the time we see the process the lock is in flight, and (b) it is whack-a-mole if the policy specifies a different `.scr` (ribbons, mystify, third-party). `ES_DISPLAY_REQUIRED` short-circuits at the activation predicate, one level up.
- **Mapping the power button to "Turn off the display" on Modern Standby (S0ix) hardware.** The firmware hands the action to the connected-standby path, parking every user-mode message pump including the daemon's. The overlay can't paint until the system wakes. Switched to mapping the power button to `Do nothing` on Modern Standby boxes and using the hotkey instead. Detection via `powercfg /a`.
- **`SetThreadExecutionState(ES_AWAYMODE_REQUIRED)` to prevent Modern Standby entry on power-button press.** Documented to keep the system out of S0ix while held, and it does work for *idle-driven* connected-standby entry. But power-button-driven entry on Modern Standby goes through a different kernel path that does not consult execution-state flags. The daemon still holds `ES_AWAYMODE_REQUIRED` because it costs nothing and prevents the idle-driven case, but it cannot save the power-button case on Modern Standby; that is what the `Do nothing` mapping handles instead.
- **Caching `OverlayForm` instances across arm cycles to save a few microseconds.** Originally `Show-Overlays` only added new forms for monitors not already covered, keyed by `Bounds.ToString()`. Broke as soon as the user docked or undocked: cached overlays sat at coordinates that no longer matched any current monitor, and the cached "already covered" check skipped the actually-present monitors. Switched to tearing down every existing overlay and re-enumerating `Screen.AllScreens` on every arm event. The cost is negligible (4 form constructions on a 4-monitor rig is sub-millisecond) and the correctness is unconditional.
- **Trusting USB selective suspend to leave docked USB-C devices alone.** On Modern Standby + USB-C dock setups, USB selective suspend tears down the dock's USB4/TB tunnel during S0ix transitions, and the tunnel does not always re-enumerate cleanly. The installer now disables USB selective suspend on the active scheme. Combined with `ES_AWAYMODE_REQUIRED` and the Modern Standby `Do nothing` power-button mapping, the dock stays enumerated for the daemon's whole lifetime.
- **Setting `WS_EX_LAYERED` in the overlay's `CreateParams` and assuming the form's `BackColor` would render.** Layered windows on Windows do not composite through the normal WinForms paint pipeline without an explicit alpha value: with `WS_EX_LAYERED` set but no call to `SetLayeredWindowAttributes` or `UpdateLayeredWindow`, the OS treats the window as fully transparent and the user sees through to the desktop. Symptom was perfectly-positioned, perfectly-sized, perfectly-topmost overlay forms that were completely invisible. The `Bounds`, `BackColor`, and ExStyle bits were all correct; the layered-attributes call was missing. Fixed by overriding `OnHandleCreated` on `OverlayForm` to call `SetLayeredWindowAttributes(handle, 0, 255, LWA_ALPHA)` immediately after the handle exists. Verified with `GetLayeredWindowAttributes`: all forms now report `alpha=255 flags=0x2`. The lesson: any time you set `WS_EX_LAYERED` you owe a layer-attributes or `UpdateLayeredWindow` call before the window will paint.
- **Trusting `Screen.AllScreens` to return raw pixel bounds without setting per-monitor DPI awareness on the process.** A DPI-unaware process gets DPI-virtualised values from `Screen.Bounds`: a 2560x1440 monitor at 125% scaling reports as 2048x1152, and any window painted to those bounds covers only the top-left ~64% of the physical display. After v1.4 made the layered windows actually opaque, the residual symptom was uncovered strips on the right and bottom of every monitor. Fixed by calling `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` before the first Form is created (the DPI context is locked in at first window creation, so it must be set early). Also added a belt `SetWindowPos` in `OnHandleCreated` so layered-window `CreateWindowEx` cannot drift the bounds out from under us.

## Why no admin?

Everything in this repo lives at user scope:

- `powercfg /setacvalueindex SCHEME_CURRENT ...` writes to the user's active power scheme. Allowed at user privilege.
- The Scheduled Task uses `New-ScheduledTaskPrincipal -RunLevel Limited`. Allowed without admin.
- The daemon writes to `%LOCALAPPDATA%`. Allowed at user privilege.
- `RegisterPowerSettingNotification` and `RegisterHotKey` are user-mode APIs. No elevation required.

The only thing that *would* require admin is changing the **system-wide default power scheme**. We don't do that. Each user gets their own behavior.

## Why a Scheduled Task instead of `Run` registry key?

`HKCU:\...\Run` runs your script after Explorer comes up but before the desktop is fully usable. The result is sometimes a daemon that starts before `Screen.AllScreens` is ready and ends up missing one monitor. Scheduled Task at logon waits past that point and is reliable.

The task is also visible in `Get-ScheduledTask`, which is a much more discoverable place to look for "what is this thing doing on my machine" than three different `Run` keys scattered across HKCU and HKLM.

## What if the user just wants the manual hotkey?

```powershell
.\INSTALL.ps1 -SkipPowerButton
```

Daemon installs, `Ctrl+Alt+Shift+B` works, but the power button keeps doing whatever it was doing before. Useful if you have a different muscle-memory trigger or if your enterprise GPO is opinionated about power button mapping.

## Source References

- INSTALL.ps1 / UNINSTALL.ps1 / BlackOverlay.ps1 in this repo.
- [Microsoft Learn — `RegisterPowerSettingNotification`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerpowersettingnotification)
- [Microsoft Learn — `WM_POWERBROADCAST`](https://learn.microsoft.com/en-us/windows/win32/power/wm-powerbroadcast)
- [Microsoft Learn — Power-setting GUIDs](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids)
- [Microsoft Learn — `RegisterHotKey`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)
- [Microsoft Learn — Extended Window Styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles)
