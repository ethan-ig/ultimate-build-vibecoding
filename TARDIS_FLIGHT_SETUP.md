# TARDIS Flight V8 | Ultimate Build FIU

**Restore a healthy saved TARDIS before installing.** V7 moved the root
without the rest of the exterior. No script can reconstruct the original
relative positions of parts already scattered by that failed flight.

Stop all old controller and flight Code Blocks. Replace the controller and
flight scripts **together**, then start only one controller followed by one
flight block. Navigation remains unchanged.

## Why V8 is different

The old chat-cube test proved that an anchored UB *part proxy* accepts
replicated CFrame edits. It did not prove that a client-created WeldConstraint
replicates. V7 anchored one root and moved it, leaving the exterior scattered
on other clients.

V8 removes only prior `TardisRigidWeld_*` constraints on the TARDIS root,
anchors each exterior UB block through the editable proxy, and drives **one
shared desired pivot**. At the network cadence, each block receives
`proxy.CFrame = pivot * originalRelativeOffset`. This preserves the whole
restored shape while each part is server-edited. The interior/time rotor are
independent. Flight does not use raw-part velocity, local root CFrame writes,
or a client weld graph.

The default cruise speed is 24 studs/sec; +/- changes it in 5-stud increments.
Updates are capped at 12 Hz and ~1,900 proxy edits/second. Camera smoothing
does not increase network edits. This architecture avoids physics fights and
catastrophic separation, but 155 independent server property writes are not
atomic: perfect spectator-side animation would require a documented native
server-side group-movement mechanism or a much smaller union-based exterior.

## Controller: tardis_controller.luau

Inputs are unchanged: A materialization state; B optional player target;
C destination; D fast travel; E quick recall; F quick destination; J normal
recall. The controller still handles audio, visual fades, portal, lamp,
time rotor and teleportation. Normal teleport movement also uses the UB
exterior part proxies, rather than the raw client root.

Required ready messages:

```text
TARDIS PROXY RIG READY: ... independent anchored exterior proxies; no welds
```

It sets `TardisRigMode = PROXY_V8`, `TardisRigReady`, and transition
attributes on the physical root for the flight block to read. Flight refuses
to engage if the controller is mismatched, a shell is too far from the
restored pivot, or an exterior anchor cannot be verified.

## Flight: tardis_manual_flight.luau

Input A (optional): pulse to take off or begin descent.
Input B: optional Vector3, CFrame or coordinate string.
Input C: optional autopilot pulse.
Input D: optional cruise speed (5-90).
Output A: powered-flight active.
Output B: desired world position.
Output C: full desired pivot CFrame.

The compact GUI has TAKEOFF, GO with X/Y/Z fields, HOVER/ABORT, DROP
and speed +/- buttons. Keyboard: W/S thrust, A/D steer, E/Q up/down,
Shift boost, Space brake, G autopilot, V switch camera, X begin descent.
The independent shell spins and gently wobbles around the shared pivot.
The FIU-compatible camera supports orbiting and zoom, independently of spin.

**DROP IS SCRIPTED, NOT REAL PHYSICS.** The entire independently anchored
exterior descends together using increasing vertical speed and an available
ground raycast, with fallback to the takeoff floor. It remains anchored when
landed. Unanchoring 155 separately replicated parts without server-authority
welds would scatter the box, as the previous experiment proved. Wait until
the panel reports LANDED before stopping the flight block.

## Navigation: tardis_navigation.luau

Unchanged. Output A -> controller input C; output B -> flight input C;
output C -> flight input B. Navigation input A opens/closes the map.

## Test in Ultimate Build

1. Restore the healthy saved build. Replace controller and flight as a set.
2. Start controller, confirm `TARDIS PROXY RIG READY` and correct shell count.
3. Start flight, confirm `TARDIS FLIGHT 8.0 READY`.
4. Click TAKEOFF, test W and E at the default speed, then GO with coordinates.
5. Have another client confirm that the entire exterior follows, not just
   a root or sound/light block.
6. Press DROP and allow the scripted descent to finish; test normal recall.

A successful proxy setter does not by itself prove two-client behavior. This
code is committed but still needs a live multiplayer runtime test.
