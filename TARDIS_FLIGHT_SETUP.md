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

A compact coordinate-and-controls GUI provides TAKEOFF, GO, speed +/-,
HOVER and DROP. The controller still constructs a heavy welded assembly with
its root normally unanchored.

**Powered-flight tradeoff (V7.0):** The pilot temporarily anchors just the
root *through the editable UB proxy*, then updates only its CFrame at up to
30 Hz. Roblox's weld behavior is designed to carry the connected parts
together. This removes V6's roughly 155 independent proxy writes per tick.
When you press DROP or initiate controller travel, the root is unanchored
again so normal gravity can act. The root is therefore NOT always unanchored
while flight is active. Press DROP **before stopping the flight Code Block**;
abruptly killing a running block may prevent cleanup.

The old cloned-cube test established that an anchored UB proxy could move on
another client. It did not prove that the entire controller-created welded
assembly follows one anchored root on other clients. Test this with a second
client, checking the entire shell, light, portal and sound block. If only the
root moves, the engine's client-created welds may not be server-authoritative.
Do not reactivate the 155-write backend: it was visibly unsmooth.

Camera: try the native Custom orbit camera first, then FIU-compatible right-
mouse drag and wheel zoom if CameraSubject rejects the proxy table. Camera
position follows the calculated flight position rather than inheriting the
exterior spin. Input B and the GUI use world X/Y/Z coordinates. Output C
optionally publishes the desired full CFrame.

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
whether the powered-flight root and CFrame writes are available.

With autopilot active, normal steering thrust or Space cancels autopilot.
The target stays set until a new one is supplied. When the ship arrives, the powered root remains at its final CFrame until DROP.

**Drop** unanchors the replicated UB root and lets Roblox gravity act on the
heavy physical assembly. If the unanchor write fails, the script reports a
release error rather than claiming success. Greater density increases
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
7. Dematerialize while flying; the controller should release the flight anchor before travel.
8. Press DROP before stopping the flight Code Block. Ensure no two pilot/controller copies are running.

These scripts have static checks and GitHub content verification, but require
a real Ultimate Build runtime test for engine permissions and network ownership.
