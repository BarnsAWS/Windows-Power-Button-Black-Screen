# Investigation 2026-05-29: session still locks after power-button press

End-of-day investigation that drove v1.1 and v1.2 of this repo. Two
related-but-distinct root causes; both are fixed in v1.2.

## Symptom

Press the laptop power button. Display blanks correctly. The black overlay
arms correctly (one click-through window per monitor, daemon log shows
`GUID_CONSOLE_DISPLAY_STATE: Off (0). Arming overlays.`). User walks away,
comes back ~15 minutes later. Session is **locked**, overnight automation
runs underneath the lock have failed.

A second symptom appeared during the v1.2 test cycle: pressing the power
button caused the laptop to *sleep* (Modern Standby), not just blank the
display. The daemon's overlay never painted because the message pump was
parked in S0ix.

## Round 1: stale screen-saver values from sibling repo (v1.1, partial fix)

Found `HKCU:\Control Panel\Desktop\ScreenSaverIsSecure = 1` and
`ScreenSaveActive = 1` with a 180-second timeout. Hypothesised this was
left over from a prior install of the sibling
[Windows-Power-Button-Lock-Without-Sleep](https://github.com/BarnsAWS/Windows-Power-Button-Lock-Without-Sleep)
repo, which deliberately sets those values.

Patched `INSTALL.ps1` v1.1 to clear `ScreenSaverIsSecure`, `ScreenSaveActive`,
and `EnableGoodbye` (Dynamic Lock) at install time. New `-SkipLockGuard`
switch lets the user opt out. Verification block in INSTALL.ps1 reports the
post-install state. README and CHANGELOG updated.

This made the locks stop briefly. They came back.

## Round 2: GPO-enforced policy path (v1.2, the real fix)

Walked the user through a power-button cycle, then ran a deep diagnostic
script. Key findings:

```
=== HKCU:\Control Panel\Desktop (live, post-fix) ===
ScreenSaveActive    : 0
ScreenSaverIsSecure : 0          <-- v1.1 lock-guard held here
ScreenSaveTimeOut   : 180

=== GPO/MDM-managed policy paths ===
[HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop]
    ScreenSaverIsSecure = 1      <-- but this is what Windows actually obeys
    ScreenSaveActive    = 1
    ScreenSaveTimeOut   = 900    <-- 15 minutes. Matches the observed lock timing.

=== Corporate endpoint agents ===
CSFalconContainer (CrowdStrike)  -- multiple PIDs
CSFalconService
```

The `\Software\Policies\` path is the GPO/MDM-managed copy of the same
settings. Windows reads policy paths first and falls back to the user paths
only when policy is absent. The corporate Intune / GPO machinery on this
Amazon-managed laptop pushes `ScreenSaverIsSecure=1` with `ScreenSaveTimeOut=900`,
re-applies it on every policy refresh (typically every 90 minutes plus
random jitter), and there is nothing user-mode can do about that registry
value durably.

### Fix shipped in v1.2

Operate one layer above the registry. Windows decides whether to launch the
screen saver by checking whether any thread is holding `ES_DISPLAY_REQUIRED`
via `SetThreadExecutionState`. The daemon now holds:

```
ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED
```

continuously for its entire lifetime. The flag set is `0x80000043`. With
this held, the screen saver does not fire regardless of what the registry
or policy engine says, because the activation predicate fails before the
saver process is spawned.

The daemon also tries `SystemParametersInfo(SPI_SETSCREENSAVEACTIVE, FALSE)`
at startup and every 60 seconds. On unmanaged boxes that succeeds and is a
belt-and-suspenders win. On GPO-locked boxes it fails with
`Win32Error=0x4ec` (`ERROR_NOT_FOR_YOU_TO_PROCESS`); the daemon logs the
denial and the `ES_*` keepalive does the actual work.

### Verification of v1.2 GPO bypass

Lock-prevention test (`_test_lock_prevention.ps1`, deleted after run):
sends `WM_SYSCOMMAND SC_SCREENSAVE` to broadcast, which is the same
mechanism Windows uses internally when the screen-saver idle timer
expires. With the keepalive flags held, Windows refuses to launch
`scrnsave.scr` and the session stays Active. Test passes both
immediately after install and 70+ seconds later (after the keepalive
re-apply timer ticks).

The 20-minute real-world test (waiting through the 15-minute GPO timer)
is left to the user since it cannot be automated end-to-end.

## Round 3: Modern Standby caused power-button sleep (v1.2, second fix)

After deploying v1.2, the user reported "i just power button and it
slept. make it run the script instead which was good". Diagnostic showed:

- `powercfg /a` reports **only** `Standby (S0 Low Power Idle) Network
  Connected` is available. S1, S2, S3 all explicitly disabled by
  firmware. This is a Modern Standby capable laptop.
- System events showed Kernel-Power 506 (enter S0 low-power state) at
  the power-press timestamp, then Kernel-Power 507 (resume) about
  2 minutes later when the user wiggled the mouse.
- Daemon log confirmed `GUID_CONSOLE_DISPLAY_STATE: Off (0)` only fired
  *during the wake transition*, by which time the screen was about to
  light up.

On Modern Standby hardware, mapping the power button to "Turn off the
display" causes the firmware to hand the action to the connected-standby
path, parking the entire user-mode session. `ES_AWAYMODE_REQUIRED` blocks
*idle-driven* connected-standby entry, but power-button-driven entry goes
through a different kernel path that does not consult execution-state flags.

### Fix shipped in v1.2

Detect Modern Standby in `INSTALL.ps1` via `powercfg /a` regex against
"Standby (S0 Low Power Idle)". On Modern Standby hardware:

- Power button is mapped to `Do nothing` instead of "Turn off the display".
- Verification block prints `Modern Standby: present` and points the
  user to the hotkeys.
- Smoke-test text adapts.

The hotkey arm path (`Win+Shift+L`, `Ctrl+Alt+Shift+L`,
`Ctrl+Alt+Shift+B`) was already implemented in v1.0 and is fully reliable
on Modern Standby because the daemon paints the overlay synchronously
in its own message pump, before any firmware-blank request goes out.

The cleaner alternative would be to disable Connected Standby system-wide
via `HKLM:\System\CurrentControlSet\Control\Power\CsEnabled = 0`, but
that requires admin and a reboot, which is out of scope for a per-user
daemon.

### Verification of v1.2 Modern Standby fix

```
[2/5] Modern Standby (S0ix) detected.
       Mapping power button -> Do nothing (firmware would otherwise drop the system into S0ix).
       Use Win+Shift+L or Ctrl+Alt+Shift+B to arm the overlay.
...
Verification:
  Power button (AC):     00000000  (Do nothing)
  Power button (DC):     00000000  (Do nothing)
  Modern Standby:        present (S0 Low Power Idle); power button mapped to 'Do nothing'
                         to keep the daemon alive. Use Win+Shift+L or Ctrl+Alt+Shift+B.
```

## Round 4: open question - power button on Modern Standby

The user asked for the muscle-memory power-button gesture to keep working
on Modern Standby hardware. With the OS power button mapped to `Do nothing`
the system no longer enters S0ix, but the kernel also does not surface
the press to user-mode (firmware swallows it). Investigation paths
considered for a future v1.3:

- **WMI permanent event subscription on Kernel-Power button events.** The
  kernel may emit an event log entry distinguishable from idle-resume
  even when the OS action is `Do nothing`. Worth probing under live
  conditions on the target hardware.
- **Disabling Connected Standby (`CsEnabled=0`) and using "Turn off the
  display" as before.** Requires admin + reboot. Could be a separate
  `INSTALL-Admin.ps1` for users who can elevate.
- **A scheduled task with an event-log trigger** wired to whichever
  Kernel-Power ID fires on power-button on this hardware. Would call
  back into the daemon via a named pipe or named event to arm the
  overlay.

Out of scope for v1.2. v1.2 ships with hotkey-only arming on Modern
Standby and clear documentation about why.

## Files changed in v1.1

- `INSTALL.ps1` - added step 3 lock-guard, `-SkipLockGuard` switch,
  expanded verification block. Now 5 numbered steps.
- `README.md` - new "Why the lock-guard?" subsection, updated "What the
  script changes" table, updated "does not touch" list, corrected
  cross-repo install order.
- `CHANGELOG.md` - v1.1 entry describing the fix.
- `UNINSTALL.ps1` - small doc-block tidy.

## Files changed in v1.2

- `BlackOverlay.ps1`:
  - Added PInvoke surface for `SystemParametersInfo` (with explicit
    `EntryPoint = "SystemParametersInfoW"` to support both `IntPtr` and
    `ref bool` overloads), `SetThreadExecutionState`, and the
    `EXECUTION_STATE` enum.
  - Added `Suppress-ScreenSaver`, `Get-ScreenSaverActive`,
    `Hold-IdleKeepalive`, `Release-IdleKeepalive` helpers.
  - Daemon now calls `Hold-IdleKeepalive` at startup (not just on overlay
    arm) and `Release-IdleKeepalive` only at shutdown. The flag set is
    held continuously.
  - 60-second `keepaliveTimer` re-applies the keepalive flags and
    retries the SPI suppression. Logs only when state changes.
  - GPO probe at startup logs the live values of the policy registry
    path so future investigations have evidence.
  - On overlay arm, also synchronously re-suppresses the screen saver
    in case the timer just ticked.
- `INSTALL.ps1`:
  - Probes `powercfg /a` for "S0 Low Power Idle" and on Modern Standby
    hardware maps the power button to `Do nothing` instead of
    "Turn off the display". The detection result is stored in
    `$isModernStandby` for the verification block to print.
  - Verification block now reports the resolved button action by name
    (Do nothing / Sleep / Hibernate / Shut down / Turn off the display)
    on both AC and DC, and surfaces Modern Standby presence/absence.
  - Smoke-test text adapts to Modern Standby.
- `README.md` - new "GPO bypass" section, new "Modern Standby (S0ix)
  hardware" section, updated "What the script changes" table to include
  the running-session SPI call and the held ES flags.
- `ABOUT.md` - extended "What was tried that didn't work" with two new
  bullets for the GPO and Modern Standby paths.
- `CHANGELOG.md` - v1.2 entry with detailed root-cause description.

## Diagnostic snippets to keep handy

Reproduce the exact scan that found the policy hit:

```powershell
# Live user setting (what v1.1 controls)
Get-ItemProperty 'HKCU:\Control Panel\Desktop' |
    Select ScreenSaveActive, ScreenSaverIsSecure, ScreenSaveTimeOut, 'SCRNSAVE.EXE'

# Policy-managed setting (what GPO/MDM controls; v1.2 bypasses via ES flags)
Get-ItemProperty 'HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop' -EA SilentlyContinue

# Running-session screen-saver state. v1.2 daemon either sets this to FALSE
# or the policy engine denies the call (see daemon log).
Add-Type -Namespace S -Name P -MemberDefinition @'
[DllImport("user32.dll", EntryPoint="SystemParametersInfoW")] public static extern bool SystemParametersInfo(
    uint a, uint b, ref bool c, uint d);
'@
$on = $false
[S.P]::SystemParametersInfo(0x0010, 0, [ref]$on, 0) | Out-Null
"Running screen-saver active: $on"

# Daemon log. The v1.2 daemon emits 'Idle keepalive ON', 'GPO policy path
# present:', and 'SPI_SETSCREENSAVEACTIVE blocked at startup' lines that
# diagnose the GPO state at install time.
Get-Content "$env:LOCALAPPDATA\BlackOverlay\BlackOverlay.log" -Tail 30

# Modern Standby capability check
powercfg /a
```

## Decision log

- Chose `SetThreadExecutionState(ES_DISPLAY_REQUIRED)` over a `.scr`
  process watchdog. The watchdog races against the lock and is
  whack-a-mole across `.scr` variants. The ES flag short-circuits at
  the activation predicate, one level up.
- Chose to hold `ES_*` for the *entire daemon lifetime*, not just while
  the overlay is armed. The contract of the daemon is "session never
  auto-locks while I am running"; that contract has to hold whether
  the overlay is currently up or down.
- Did **not** attempt to write to the policy registry path. That would
  require admin and would be reverted on the next gpupdate. Wrong layer.
- Did **not** switch the daemon to a service. User scope is correct;
  the daemon must paint windows on the interactive desktop, which a
  SYSTEM service cannot do without session-1 hand-holding.
- Did **not** disable Connected Standby system-wide (`CsEnabled=0`).
  Requires admin + reboot, both out of scope. Future `INSTALL-Admin.ps1`
  could.
- Chose to map the power button to `Do nothing` on Modern Standby
  rather than fight the firmware. Hotkeys are reliable; pretending
  power button works on this hardware would be lying.
