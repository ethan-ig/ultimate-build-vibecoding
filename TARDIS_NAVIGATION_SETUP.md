# TARDIS Controller + Navigation 2.0

**This is a matched two-Code-Block rewrite.** Stop both old Code Blocks, restore a healthy saved exterior if previous flight testing scattered it, then replace controller and navigation together. Manual flight remains removed. A backup of the previous three-file setup is on branch `tardis-pre-navigation-rewrite`.

## Exact wiring

| From | To | Signal |
| --- | --- | --- |
| Navigation **Output A** | Controller **Input C** | Chosen landing destination (Vector3) |
| Navigation **Output B** | Controller **Input F** | TRUE pulse to dematerialize, travel, rematerialize |
| Your existing NAV button/switch (optional) | Navigation **Input A** | TRUE pulse opens/closes the overhead map |
| Your existing materialization switch (optional) | Controller **Input A** | Boolean level: TRUE = show, FALSE = hide, changes only |
| Player target string (optional) | Controller **Input B** | Player name or prefix |
| Fast-mode switch (optional) | Controller **Input D** | Boolean: quick transition sounds/effects |
| Quick recall button (optional) | Controller **Input E** | TRUE pulse to recall to your character |
| Normal recall button (optional) | Controller **Input J** | TRUE pulse to recall to your character |

**NEW REQUIRED CONNECTION:** Navigation Output B to Controller Input F. Previously, navigation only loaded C and required separate travel input. The new map's CONFIRM TRAVEL button now sends C first, waits 0.18 seconds, then pulses F for 0.22 seconds to avoid input race conditions.

If you leave Navigation Output B disconnected, the map still loads Controller Input C, but you must pulse Controller Input F yourself to initiate travel.

Controller outputs are all optional: Output A = status text, Output B = transition-busy boolean, Output C = current exterior pivot CFrame. Navigation requires output A; output B is needed for automatic travel on confirmation.

## How to use

The navigation script creates its own persistent **NAV / MAP** GUI button, even without a wired navigation input A.

1. Open the map with NAV / MAP or input A.
2. Left-click a collidable surface to preview it. This does not travel yet.
3. Right-drag to pan, scroll to zoom; select a different location if necessary.
4. Press **CONFIRM TRAVEL**. The script sets destination C and triggers F automatically when wired.
5. The controller dematerializes, teleports the hidden exterior via its UB proxies, and rematerializes at the selected grounded coordinate.

The normal controller materialization switch still works. Changing controller input A to FALSE hides the exterior; TRUE shows it. A travel pulse works independently of the switch's previous value.

The controller also retains quick recall (E), normal recall (J), optional player target B, fast mode D, exterior sound plus mirrored interior SoundBlock, roof-light pulse, translucent shell waveform, portal and independently animated interior time rotor.

## Exterior and safety behavior

The controller operates on separately anchored existing Ultimate Build exterior proxies. It verifies anchors before removing only previously generated `TardisRigidWeld_*` joints. It NEVER moves the map, never creates physics flight constraints and never touches the interior when moving the exterior. The last saved shell arrangement is captured as fixed offsets from one pivot. Partial teleport writes trigger a best-effort rollback.

The controller refuses to initialize if the saved exterior is incomplete or scattered. Restore a healthy backup before installing; no script can guess the original positions of scattered parts.

Normal materialization follows the audio when available, with a bounded wall-clock fallback. Quick transitions use separate quick sound profiles and a short end sting. The time rotor animates while the exterior is dematerialized or transitioning, then pauses.

## Expected startup messages

```text
TARDIS: CONTROLLER 2.0 / ... SHELL / ... MOVING / READY
NAVIGATION 2.0 / A -> CONTROLLER C, B -> CONTROLLER F
```

Check one full two-client travel before trusting the new version for normal use. A successful proxy assignment alone does not verify remote visibility. Nothing in this rewrite claims to provide manual physical flight or a real gravity drop.

## Input reliability update

These scripts now resolve FIU socket names with lowercase or uppercase keys, read
socket state from `GetState()` (or `State`/`Value` when exposed), and accept
boolean, 0/1, or "on"/"off" switch values.

**Important: install both files together.** The controller does not act on the
initial materialization switch position anymore. Toggle A **after startup** to
show or hide the exterior. This prevents restarting the Code Block from launching
an unrequested transition. E, F, and J trigger on the rising edge and should be
released between activations. If FIU delivers `StateChanged` or `Changed`
events, short pulses are captured by the event handlers as well as the polling
fallback. If FIU exposes neither event, pulses must remain active for at least
one controller poll (1/30 second plus scheduler delays).

The navigation panel now listens for the native GUI button events **and** checks
pointer coordinates against button bounds. This fallback allows NAV / MAP,
CONFIRM TRAVEL, CANCEL / ESC, RECENTER, and CLEAR PIN to respond on FIU
environments that render a button but do not dispatch its click events.

### Checks after installation

1. Ensure the controller reports `INPUTS ARMED` and does **not** immediately
   show/hide the box on startup. If it reports `shell not found`, `scattered
   shell`, or `anchors unconfirmed`, fix the saved exterior or proxy access
   first: input processing cannot start until rig validation succeeds.
2. Flip controller input A OFF then ON. Confirm each state change produces one
   transition, rather than a transition at startup.
3. Trigger E, F, and J individually with distinct TRUE/FALSE pulses and check
   the controller status output A. Recall relies on a readable local player
   root. Coordinate travel requires a grounded destination through input C.
4. Press NAV / MAP, select terrain, use RECENTER and CLEAR PIN, select
   again, then press CONFIRM TRAVEL. With navigation B wired to controller F,
   confirm destination C reaches the controller before the travel pulse.
5. Verify behavior with two clients before trusting exterior replication.

The event subscriptions and coordinate fallback are defensive integrations for
FIU. Roblox or game-side proxy APIs may vary; these changes have not been
validated in a live Ultimate Build session.

## NAV A first-pulse troubleshooting

The 2.0 input-compatibility update accidentally discarded the first TRUE
navigation pulse whenever the startup socket state was unreadable (`nil`).
The latest navigation fix treats an unknown initial NAV A level as FALSE,
so the first received TRUE opens the map instead of merely arming its latch.

Navigation A is **edge triggered**: supply FALSE, then TRUE, then FALSE.
A continuous TRUE signal opens only once; send FALSE before the next press.
A very short pulse still may be missed when FIU exposes only polling
(no input change events). For diagnosis, keep TRUE high for 0.2 seconds.

### Watch the Navigation Code Block console

On startup look for `TARDIS NAV START:` followed by:

- `INPUT A FOUND` versus `INPUT A NOT FOUND`: whether the script
  resolved the input socket.
- `local player=<name>` versus `NO LOCAL PLAYER`: whether the
  script has the player context needed for an on-screen GUI.
- `CAMERA FOUND` versus `NO CAMERA`: whether a usable camera is present.

On each recognized level change look for `TARDIS NAV INPUT A: TRUE` or
`FALSE`. When a TRUE arrives but no local player is present, the script
prints `MAP CANNOT OPEN` rather than silently ignoring the pulse.
Navigation **Output C**, when offered by the Code Block, also sends
these diagnostic messages as text to an external display.

**Architecture limitation:** Roblox only defines `Players.LocalPlayer`
inside client-side scripts. If Ultimate Build's Code Block executes on
the server, simply wiring an input cannot make this script's
`PlayerGui`, `UserInputService`, and local camera navigation work.
The GUI must then run in an authorized client-side context, or the
navigation controls must be redesigned for server-side/world-space use.
Do not assume a connected wire proves that the GUI can render.

## Opening the navigation map again after travel

Navigation Input A is an edge-triggered button input. After a successful
travel the map closes but the Code Block keeps running. For each new
navigation request, send **FALSE -> TRUE -> FALSE**. A held TRUE is not
another button press.

Some Ultimate Build input/pulse blocks deliver repeated TRUE **events**
without ever exposing the intervening FALSE state through `GetState()`.
The navigation script now accepts a new TRUE input **event** after a
0.30-second debounce, even if its last readable level stayed TRUE.
Polling by itself will never repeatedly toggle on a constantly held
TRUE, because that would open and close the map in an endless loop.

Console messages now distinguish the possible cases:
- `TARDIS NAV ACCEPTED A PULSE: ... map was CLOSED`: the reopen was
  recognized and the script attempted to open the map
- `TARDIS NAV INPUT A: FALSE / rearmed`: an explicit release was seen
- `TARDIS NAV INPUT A: repeat TRUE event / no FALSE observed`:
  a fresh button event arrived after a prior unreleased pulse
- `TARDIS NAV INPUT A STUCK TRUE`: the Code Block still sees a high
  level and cannot distinguish another press from a held switch

For initial testing, use a variable or switch to send FALSE for
0.3 seconds, TRUE for 0.3 seconds, then FALSE. Repeat that sequence
after confirming travel. Test NAV / MAP on-screen as an independent
path. If neither method reopens the map, inspect the navigation
Code Block logs to find whether it is still running.

## Navigation Input A: readback versus actual button press

The startup line `initial=false` reports **one startup sample**. A later
`GetState()==true` does not establish that the physical button is held;
the socket readback may keep its last value after a short pulse.

The navigation script now prefers meaningful `Pressed`, `Released` and
`StateChanged` events, when those events exist and dispatch in Ultimate
Build. The generic `Changed` notification is **not** a new press event.
After the first real input event is seen, polling no longer treats a
latched TRUE readback as a fresh press; polling still detects FALSE to
rearm. Environments without working input events keep the edge-detected
polling fallback.

Observe these lines in the Navigation Code Block's output:
- `TARDIS NAV INPUT A EVENT: PRESSED ...` or
  `STATECHANGED value=true` means a press was delivered to the script.
- `TARDIS NAV INPUT A EVENT: RELEASED ...` or
  `STATECHANGED value=false` means a release was delivered.
- `TARDIS NAV A GetState CHANGED: ...` records changes in the socket's
  **readback**, which may lag behind or differ from received events.
- `TARDIS NAV A READBACK REMAINS TRUE` means exactly that. It is not
  a claim about the physical button.

To isolate input wiring from camera and travel, press the on-screen
`NAV / MAP` button twice. Then press the wired control twice and
compare the event and readback messages. If no release **event** and no
FALSE readback is ever delivered, the script cannot distinguish the
next press from a switch continuously held TRUE; the source must send a
release or a distinct new press event.

These changes have not been exercised inside a live Ultimate Build
session. No HTTP loader or dynamic string execution is involved.

## FIU pulse release is `nil`, not always `false`

Observed navigation socket diagnostics in-game:
`GetState CHANGED: nil -> true -> nil -> true -> nil`.

This means the Code Block sees a momentary `true` followed by an
**empty (`nil`) socket**, not an explicit boolean `false`. This was
why a working pulse source appeared "stuck": the script previously
ignored `nil` and never cleared its `lastA` latch.

Navigation now treats an observed input `nil` **after an accepted
TRUE** as release/rearm. It accepts a new `nil -> true` as the next
press. An explicit `false` also rearms. It does **not** treat a
continuously held TRUE as repeated presses.

Expected diagnostics on each normal momentary press:

```text
TARDIS NAV A GetState CHANGED: nil -> true
TARDIS NAV ACCEPTED A PULSE: POLL map was CLOSED
TARDIS NAV A GetState CHANGED: true -> nil
TARDIS NAV INPUT A: NIL / rearmed after pulse
```

The order of the lines can differ when an input event arrives before
the polling loop. On the next press the accepted pulse should say
`map was OPEN` if the first press has not already been confirmed/
closed by navigation actions, or `map was CLOSED` after travel.

If `true -> nil` happens but no accepted pulse appears, check
whether the script is still running and whether GUI/camera operations
logged failures. Live FIU testing is still required.

## Controller buttons E/F/J: repeatable FIU pulses

The same `true -> nil` issue also affected Controller inputs **E**, **F**,
and **J**. A first pulse was accepted, but the code previously skipped a
`nil` readback without rearming its edge detector, so the next press
was ignored. Controller pulse inputs now interpret `nil` as **not
asserted** (the equivalent of a release), just like an explicit
`false`. A short 0.25-second duplicate-event guard prevents one
button action from double-firing across multiple socket callbacks.

Level-controlled inputs **A** (materialization) and **D** (fast mode)
keep their level semantics. An unconnected/`nil` value must **not**
instruct the TARDIS to dematerialize.

After installing **both updated Code Blocks**, press an E/F/J button,
let go, and press again. Watch the controller log for
`TARDIS INPUT E/F/J PULSE ACCEPTED` and
`TARDIS INPUT E/F/J PULSE REARMED (NIL)` (or `(FALSE)`).
Navigation Input A now prints `NIL / rearmed after pulse`
when its readback returns to nil.

The input behavior was inferred from live in-game screenshots of
`nil -> true -> nil`. Roblox FIU runtime verification is required
after installation; code/asset structure checks are not a substitute
for trying the physical controls.
