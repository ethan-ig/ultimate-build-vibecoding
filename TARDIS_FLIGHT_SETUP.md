# TARDIS physics-flight rebuild (FIU code blocks)

Install all three matching files **as a set**. The main controller creates the
physical rig; flight will not run against the older per-part CFrame controller.
Stop the old running blocks before replacing their code, then start the
controller first, flight second, navigation third.

## 1. Controller: `tardis_controller.luau`

Existing inputs are preserved:

| Input | Meaning |
|---|---|
| A | TRUE materialized / FALSE dematerialized |
| B | Optional player target |
| C | Normal teleport destination (Vector3 or CFrame) |
| D | Fast travel |
| E | Quick recall |
| F | Quick destination |
| J | Normal recall |

The controller retains the sound-synced fades, roof lamp, exterior portal,
floor placement, quick travel and interior time rotor. It creates a heavy
unanchored `WeldConstraint` assembly, an invisible support at the hidden
staging location, and two root attributes:

- `TardisRigReady`: TRUE only if assembly construction succeeded.
- `TardisTransitioning`: TRUE during transitions and while hidden.

Exterior parts and accessories must expose real Roblox `BasePart` instances
through `.Part` or directly, so WeldConstraints can operate. If the sandbox
denies this, the controller logs `TARDIS RIG INCOMPLETE` and flight refuses
to run instead of silently reverting to jerky individual CFrame movement.

## 2. Flight: `tardis_manual_flight.luau`

No HUD or ScreenGui. A single `LinearVelocity` and `AngularVelocity`
move the entire unanchored welded assembly. The exterior constantly spins
with a slight wobble while flight is active. The camera holds a stable viewing
direction rather than circling with the spinning box.

| Port | Meaning |
|---|---|
| Input A | Pulse TRUE to engage or drop |
| Input B | Vector3 / CFrame / string `x, y, z` target |
| Input C | Pulse TRUE to toggle autopilot |
| Input D | Optional numeric speed limit (10–265) |
| Output A | Flight active boolean |
| Output B | Live actual exterior position Vector3 |

Keyboard: W/S forward/back; A/D adjust spin; Q/E descend/ascend; Shift boost;
Space brake/hover; + and - adjust speed by 10; G toggle autopilot; V camera;
X or Escape drop out of flight.

With autopilot active, normal steering thrust or Space cancels autopilot.
The target stays set until a new one is supplied. When the ship arrives, the
flight constraint holds a hover until X/input A releases it.

**Drop** disables both movers, leaves the exterior unanchored, and lets
Roblox gravity act on the heavy physical assembly. Greater density increases
mass and collision inertia, not gravity's acceleration. It does not make
the box fall faster in a vacuum. The hidden stage is the only special support.

## 3. Navigation: `tardis_navigation.luau`

The overhead map is separate; only the flight GUI was removed.

| Output | Wire to |
|---|---|
| A | Controller input C (normal teleport landing hint) |
| B | Flight input C (autopilot pulse) |
| C | Flight input B (root target at ground + measured box clearance) |

Navigation input A opens/closes the overhead selector. Click the destination.
If flight is running, it holds while navigation owns the camera and follows
the selected destination when navigation closes. If flight is off, the
destination is still available to the normal teleport controller.

## Tests to run in Ultimate Build

1. On starting the controller, find `TARDIS RIG READY` in logs and verify
   `AssemblyMass` is finite. If `RIG INCOMPLETE` appears, do not test flight.
2. Check materialize, demat, quick travel, portal, roof light and time rotor.
3. Engage flight with A, verify physical rotation and W/S/Q/E.
4. Enter input B as e.g. `500, 150, 500`, pulse C, check braking and hover.
5. Use map destination; verify output C is ground-adjusted and output A is ground-biased.
6. Press X while airborne; verify the box tumbles/falls and rests on terrain.
7. Dematerialize while flying; flight motors should disarm immediately.
8. Ensure no two old/new controller copies are running simultaneously.

These scripts have static checks and GitHub content verification, but require
a real Ultimate Build runtime test for engine permissions and network ownership.
