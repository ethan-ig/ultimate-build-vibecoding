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

A compact, static coordinate-and-controls GUI replaces the old animated HUD.
Its TAKEOFF button works without any input-A wiring; GO uses three editable
world-coordinate fields. Flight V5.0 bypasses the ineffective local velocity
path. It predicts movement on the client for responsive piloting and requests
the same CFrame through Ultimate Build's exposed block wrapper at 20 Hz,
rather than relying on the raw BasePart's client-only CFrame. The exterior
remains one heavy unanchored welded assembly; stopping flight stops motion
writes so it can fall. Whether the FIU wrapper assignment reaches the server
must be confirmed from another player/client, including that **every shell
part** follows, not just the root. If it does not, this game must provide a
server-authorized movement block or server-side script. The optional flight
output C publishes the desired CFrame for a native mover that accepts it. The exterior constantly spins
with a slight wobble while flight is active. Flight V5.1 tries Roblox's
native `CameraType.Custom` camera with a real underlying BasePart as the follow
subject. In this FIU environment, CameraSubject sometimes rejects its
table-based proxies. When that happens, the script switches ONCE to a
Scriptable orbit camera with right-mouse drag and scroll-wheel zoom instead
of repeatedly submitting the invalid table. Press V to switch between the
player and TARDIS views. The camera uses the commanded flight position so
stale root reads do not leave it behind. The camera proxy is independent
from the welded rig.

| Port | Meaning |
|---|---|
| Input A | Pulse TRUE to engage or drop |
| Input B | Vector3 / CFrame / string `x, y, z` target |
| Input C | Pulse TRUE to toggle autopilot |
| Input D | Optional numeric speed limit (10–265) |
| Output A | Flight active boolean |
| Output B | Desired exterior position Vector3 |
| Output C | Optional desired full CFrame, connect only to a native movement block with a documented CFrame input |

Keyboard: W/S forward/back; A/D steer travel independently of the spin;
Q/E descend/ascend; Shift boost; Space brake/hover; + and - adjust speed by 10;
G toggles autopilot; V toggles camera; X or Escape drops out of flight.

The GUI is visible even when flight is off. Click TAKEOFF, type X/Y/Z, click GO;
use HOVER/ABORT or DROP at any time. The status line reports rig failures and
whether physical motors, direct assembly velocity or network authority may be
preventing movement.

With autopilot active, normal steering thrust or Space cancels autopilot.
The target stays set until a new one is supplied. When the ship arrives, the
flight constraint holds a hover until X/input A releases it.

**Drop** disables both movers, leaves the exterior unanchored, and lets
Roblox gravity act on the heavy physical assembly. Greater density increases
mass and collision inertia, not gravity's acceleration. It does not make
the box fall faster in a vacuum. The hidden stage is the only special support.

## 3. Navigation: `tardis_navigation.luau`

The overhead map remains separate from the compact flight control panel.

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
3. Engage flight using GUI TAKEOFF (no input A required), verify motion and controls.
4. Enter GUI coordinates, e.g. `500, 150, 500`, click GO and check braking/hover. Input B/C remain optional for map wiring.
5. Use map destination; verify output C is ground-adjusted and output A is ground-biased.
6. Test with a second client. Confirm **the whole exterior** moves, not only the root, and check movement after reconnecting. Then press X to verify the box can fall.
7. Dematerialize while flying; flight motors should disarm immediately.
8. Ensure no two old/new controller copies are running simultaneously.

These scripts have static checks and GitHub content verification, but require
a real Ultimate Build runtime test for engine permissions and network ownership.
