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
