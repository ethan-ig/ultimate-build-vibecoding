# TARDIS Controller 2.1 + Navigation 2.0

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
| **Demat/remat button (NEW)** | Controller **Input G** | TRUE pulse for one full cycle at the current exterior location |

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

## NEW: One-press in-place dematerialization cycle (Input G)

Connect a momentary button's TRUE pulse directly to **Controller Input G**. Tap it once while the TARDIS is materialized:

1. Snapshot the exterior's **current CFrame**, not Navigation's last selected coordinate.
2. Play the usual dematerialization sound, lights and fading.
3. Move the invisible exterior through the usual hidden stage, then return it to that exact saved location.
4. Play the rematerialization sound and fade the exterior back in, automatically.

You do **not** have to hold the button or change Input A. Input D controls normal vs. quick timing for this cycle. Repeated pulses while a transition is active are ignored, protecting an already-running sequence. If the box is already hidden, G simply rematerializes it at the last visible location. A held-high input triggers only on its rising edge; release it before pressing again.

**Input F still performs destination travel.** Use G for the classic dematerialize/rematerialize effect without traveling. Navigation wiring A→C and B→F is unchanged.

The controller also retains quick recall (E), normal recall (J), optional player target B, fast mode D, exterior sound plus mirrored interior SoundBlock, roof-light pulse, translucent shell waveform, portal and independently animated interior time rotor.

## Exterior and safety behavior

The controller operates on separately anchored existing Ultimate Build exterior proxies. It verifies anchors before removing only previously generated `TardisRigidWeld_*` joints. It NEVER moves the map, never creates physics flight constraints and never touches the interior when moving the exterior. The last saved shell arrangement is captured as fixed offsets from one pivot. Partial teleport writes trigger a best-effort rollback.

The controller refuses to initialize if the saved exterior is incomplete or scattered. Restore a healthy backup before installing; no script can guess the original positions of scattered parts.

Normal materialization follows the audio when available, with a bounded wall-clock fallback. Quick transitions use separate quick sound profiles and a short end sting. The time rotor animates while the exterior is dematerialized or transitioning, then pauses.

## Expected startup messages

```text
TARDIS: CONTROLLER 2.1 / ... SHELL / ... MOVING / READY
NAVIGATION 2.0 / A -> CONTROLLER C, B -> CONTROLLER F
```

Check one full two-client travel before trusting the new version for normal use. A successful proxy assignment alone does not verify remote visibility. Nothing in this rewrite claims to provide manual physical flight or a real gravity drop.
