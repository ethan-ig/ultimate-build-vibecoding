# TARDIS Controller + Navigation | Ultimate Build FIU

Manual flight is paused. The manual flight code block was removed from this branch. The navigation selector now sends destinations **only** to the normal controller. There are no manual-flight or autopilot outputs to wire.

## Files

- `tardis_controller.luau`: exterior, materialization/dematerialization, travel, sound, lights, portal, and time rotor.
- `tardis_navigation.luau`: overhead destination map and mouse-controlled location selection.

## Wiring

| Connection | Purpose |
| --- | --- |
| Navigation input A | Pulse TRUE to open/cancel the destination map |
| Navigation output A -> controller input C | Send the chosen destination as a Vector3 |
| Controller input A | TRUE = materialized; FALSE = dematerialized |
| Controller input B (optional) | Player-name target |
| Controller input D (optional) | Fast travel toggle |
| Controller input E (optional) | Quick recall to the local player |
| Controller input F (optional) | Quick destination cycle |
| Controller input J | Normal recall |

The navigation map chooses a coordinate but **does not independently start a teleport**. Use the controller's existing materialization/dematerialization controls or quick destination input after selecting a destination. The lowered Y value is intentional: the controller resolves the actual ground height.

## Navigation controls

Left click chooses land; right-mouse drag pans; mouse wheel zooms; Escape cancels. Input A toggles the map. The navigation script restores the ordinary camera after selection or cancellation.

## Installation

1. Restore a healthy saved TARDIS build if a previous flight test scattered parts.
2. Stop and remove the old manual flight Code Block; deleting the GitHub file does not stop a script already running in Roblox.
3. Run one copy of the controller and one copy of navigation.
4. Wire navigation output A to controller input C. Disconnect obsolete flight wiring.
5. Select a destination, then initiate travel through the controller.

The controller is currently based on the independently anchored proxy exterior from V8, which avoids the client-only weld behavior that scattered the old build. Its existing materialization and destination systems remain; physical/manual flight and gravity-drop are not part of this focused setup.
