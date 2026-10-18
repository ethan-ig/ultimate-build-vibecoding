# TARDIS Repair Bucket List

Working branch: `fix/tardis-stability-2026-10-02`. Base: `main`.
This list distinguishes source fixes from checks that require an actual Ultimate Build FIU session.

## Completed in this branch
- [x] Replace unreliable sound `Fire` / `FireInput` calls with `SetState` and report missing sound inputs.
- [x] Restore the exterior portal's original transparency after materialization.
- [x] Ignore named sound, lamp, or portal blocks located far from the saved exterior pivot.
- [x] On failed hide movement, restore exterior visibility and stop stale audio.
- [x] Report failed travel movement without silently announcing successful arrival.
- [x] Avoid materializing at the off-map staging point when starting hidden and no destination is supplied.
- [x] Lock navigation CONFIRM during the travel pulse so double clicks cannot fire overlapping requests.
- [x] Ignore map selection clicks falling within navigation controls.

## P0: Make the existing TARDIS work
- [ ] Restore a **known intact saved exterior** before installing. Scripts cannot infer the original arrangement of scattered or missing parts.
- [ ] Stop *all* old Code Blocks, including any old flight version. Install matching controller and navigation from the **same branch**.
- [ ] Confirm required wiring: navigation Output A -> controller Input C; navigation Output B -> controller Input F. Optional: navigation Input A from your NAV switch.
- [ ] Check controller startup log for READY. If incomplete/scattered/anchor errors appear, do not run travel.
- [ ] Test controller Input A false then true, and NAV button opening/closing the map without wiring.
- [ ] Preview a surface, cancel, select again, and confirm travel. Check exact landing position, intact shell arrangement, and portal/lamp restoration.
- [ ] Verify the exterior and *mirrored interior* materialization audio, quick end sting, and rotor across normal/quick transitions.
- [ ] Test short, long, elevated, and sloped landing locations; reject missing ground rather than teleporting into the void.
- [ ] Test failed movement recovery and ensure the shell doesn't remain invisible or claim a successful teleport.
- [ ] Test quick recall Input E, normal recall Input J, player-name target Input B, and fast-mode Input D.
- [ ] Test with **two Roblox clients**, verifying remote visibility of all exterior pieces and sound behavior. A successful local CFrame write does **not** establish server replication.

## P1: Reliability and safety
- [ ] Confirm SoundBlock supports `SetState` in *your* FIU runtime; if not, document the real supported input API and replace the audio adapter.
- [ ] Confirm moving proxies support CFrame writes and that all associated physical pieces replicate together.
- [ ] Add a deliberate travel acknowledgment / timeout handshake between navigation and controller; currently the output pulse only requests travel.
- [ ] Add post-movement position verification with retry or structured failure status. `pcall` means a write did not throw, **not** that the server moved the object.
- [ ] Avoid destructive cross-boundary joint cleanup without a known saved build and explicit in-game verification.
- [ ] Add a second-client smoke-test checklist and rollback instructions for failed installs.
- [ ] Ensure camera state is restored on all cancel/failure paths, including GUI initialization failure and respawn.
- [ ] Stress-test repeated travel and inputs arriving during materialization; define queue policy rather than allowing last-command wins.

## P2: Later features, separate from this navigation repair
- [ ] Decide whether to restore manual flight. The current 2.0 branch is **navigation-only** and intentionally removed physical flight.
- [ ] If flight returns, build and validate it as a separate system with an explicit controller handoff and real server ownership/replication tests.
- [ ] If desired, add saved destinations, named locations, landing preview marker, and collision clearance checks.

## Deploy / rollback

Use the controller and navigation files from this branch **together** and use the setup guide on main for the existing port wiring. This change does not resurrect manual flight. The backup `tardis-pre-navigation-rewrite` keeps the old three-block setup if you need to compare designs. Do not run old and new controllers at the same time.
