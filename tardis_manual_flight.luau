-- TARDIS FLIGHT 4.0  |  Ultimate Build FIU
-- NO ScreenGui, NO per-part CFrame writes, NO Anchored=true on the exterior.
-- Requires the matching tardis_controller.luau to weld the exterior.
--
-- Input A: pulse TRUE to enter/exit flight (or press X to drop).
-- Input B: Vector3 / CFrame / "x,y,z" destination.
-- Input C: pulse TRUE to engage/abort autopilot.
-- Input D: optional numeric speed limit, 10..265 studs/sec.
-- Output A: flight engaged boolean. Output B: actual world position Vector3.
--
-- W/S thrust forward/back | A/D steer travel bearing | Q/E down/up
-- Shift boost | Space brake/hover | +/- adjust speed by 10
-- G autopilot start/abort | V chase camera on/off | X DROP
--
-- Doctor Who-inspired rotational flight: always spinning around Y with a
-- small wobble. Autopilot follows world coordinates, so spinning does not
-- interfere with a destination. When flight disengages, all motors turn off
-- and the heavy, unanchored assembly falls under normal Roblox gravity.
--
-- If the sandbox refuses the physical constraints/rig, this block prints a
-- specific error rather than silently reverting to the old laggy CFrame mode.

local inputA = script.inputs["a"]
local inputB, inputC, inputD = nil, nil, nil
local outputA, outputB = nil, nil
pcall(function() inputB = script.inputs["b"] end)
pcall(function() inputC = script.inputs["c"] end)
pcall(function() inputD = script.inputs["d"] end)
pcall(function() outputA = script.outputs["a"] end)
pcall(function() outputB = script.outputs["b"] end)

local MIN_SPEED, MAX_SPEED, SPEED_STEP = 10, 265, 10
local ACCELERATION, BRAKING = 55, 105
local ARRIVAL_RADIUS = 2.8
local NORMAL_SPIN = 0.90 -- radians/sec, about 1 revolution per 7 seconds
local STEER_SPIN = 0.40
local TURN_SPEED = math.rad(70)
local WOBBLE = 0.11
local UPDATE = 1 / 30
local NAV_GUI = "TardisNavigationGui"

local RunService, Players, UserInputService = nil, nil, nil
pcall(function() RunService = game:GetService("RunService") end)
pcall(function() Players = game:GetService("Players") end)
pcall(function() UserInputService = game:GetService("UserInputService") end)
local player = Players and Players.LocalPlayer or nil

local root, attachment, thrust, spin = nil, nil, nil, nil
local flying, autopilot, cameraEnabled = false, false, true
local speedLimit, target = 80, nil
local desiredVelocity = Vector3.zero
local flightHeading = Vector3.new(0, 0, -1)
local keyDown, lastA, lastC = {}, false, false
local previousB, previousD = nil, nil
local savedCamera, lastCameraFrame, cameraHeading = nil, nil, nil
local renderConnection, heartbeatConnection = nil, nil
local lastHeartBeat = 0
local lastTargetRead, lastOutput, lastSafety = 0, 0, 0
local lastTick = os.clock()
local takeoffUntil = 0

local function safeOutput(port, value)
    if port then pcall(function() port:SetState(value) end) end
end

local function getValue(block, property)
    if not block then return nil end
    local ok, value = pcall(function() return block[property] end)
    if ok and value ~= nil then return value end
    ok, value = pcall(function() return block:GetAttribute(property) end)
    if ok then return value end
    return nil
end

local function asPart(block)
    if not block then return nil end
    local raw = nil
    pcall(function() raw = block.Part end)
    if not raw then raw = block end
    local ok, isPart = pcall(function() return raw:IsA("BasePart") end)
    return ok and isPart and raw or nil
end

local function getCamera()
    local cam = nil
    pcall(function() cam = workspace.CurrentCamera end)
    return cam
end

local function hasNavigation()
    if not player then return false end
    local pg = nil
    pcall(function() pg = player:FindFirstChildOfClass("PlayerGui") end)
    return pg and pg:FindFirstChild(NAV_GUI) ~= nil
end

local function findRigRoot()
    local parts = workspace:GetDescendants()
    for _, object in ipairs(parts) do
        local physical = asPart(object)
        if physical then
            local ok, marker = pcall(function()
                return physical:GetAttribute("TardisRigRoot")
            end)
            if ok and marker == true then return physical end
        end
    end
    return nil
end

local function rigAvailable()
    if not root then return false, "controller rig missing" end
    local ready = getValue(root, "TardisRigReady")
    if ready ~= true then return false, "controller rig incomplete" end
    if getValue(root, "TardisTransitioning") == true then
        return false, "materialization/quick travel is active"
    end
    local anchored = nil
    pcall(function() anchored = root.Anchored end)
    if anchored ~= false then return false, "exterior root is anchored" end
    return true
end

local function clearOldMotors()
    for _, name in ipairs({"TardisFlightVelocity", "TardisFlightSpin", "TardisFlightAttachment"}) do
        local old = root:FindFirstChild(name)
        if old then pcall(function() old:Destroy() end) end
    end
end

local function buildMotors()
    local ok, err = pcall(function()
        clearOldMotors()
        attachment = Instance.new("Attachment")
        attachment.Name = "TardisFlightAttachment"
        attachment.Parent = root

        thrust = Instance.new("LinearVelocity")
        thrust.Name = "TardisFlightVelocity"
        thrust.Attachment0 = attachment
        thrust.RelativeTo = Enum.ActuatorRelativeTo.World
        thrust.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        thrust.ForceLimitsEnabled = false
        thrust.VectorVelocity = Vector3.zero
        thrust.Enabled = false
        thrust.Parent = root

        spin = Instance.new("AngularVelocity")
        spin.Name = "TardisFlightSpin"
        spin.Attachment0 = attachment
        spin.RelativeTo = Enum.ActuatorRelativeTo.World
        spin.MaxTorque = math.huge
        spin.AngularVelocity = Vector3.zero
        spin.Enabled = false
        spin.Parent = root
    end)
    if not ok then
        print("TARDIS FLIGHT ERROR: physics constraints unavailable:", err)
        for _, thing in ipairs({thrust, spin, attachment}) do
            if thing then pcall(function() thing:Destroy() end) end
        end
        thrust, spin, attachment = nil, nil, nil
        return false
    end
    return true
end

local function restoreCamera()
    if not savedCamera then return end
    local cam = getCamera()
    if cam then pcall(function()
        if savedCamera.subject then cam.CameraSubject = savedCamera.subject end
        if savedCamera.fov then cam.FieldOfView = savedCamera.fov end
        cam.CameraType = savedCamera.kind or Enum.CameraType.Custom
    end) end
    savedCamera = nil
    lastCameraFrame = nil
end

local function stopFlight(reason)
    if not flying then return end
    flying, autopilot = false, false
    desiredVelocity = Vector3.zero
    keyDown = {}
    if thrust then pcall(function() thrust.Enabled = false end) end
    if spin then pcall(function() spin.Enabled = false end) end
    -- An ordinary pilot drop retains a little momentum and then falls.
    -- During dematerialization the main controller owns the shell, so
    -- absolutely no residual spin/velocity is injected into its teleport.
    if root then pcall(function()
        if getValue(root, "TardisTransitioning") == true then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        else
            local v = root.AssemblyLinearVelocity
            root.AssemblyLinearVelocity = Vector3.new(v.X * 0.20, v.Y, v.Z * 0.20)
            root.AssemblyAngularVelocity = Vector3.new(0.08, 0.30, 0.05)
        end
    end) end
    safeOutput(outputA, false)
    restoreCamera()
    print("TARDIS FLIGHT: " .. tostring(reason or "DROP") .. " / physics released")
end

local function startFlight()
    if flying then return end
    root = findRigRoot()
    local ok, why = rigAvailable()
    if not ok then
        print("TARDIS FLIGHT: cannot engage; " .. why)
        return
    end
    if not thrust and not buildMotors() then return end
    local cam = getCamera()
    if cam then pcall(function()
        savedCamera = {
            kind = cam.CameraType, subject = cam.CameraSubject, fov = cam.FieldOfView
        }
        cam.CameraType = Enum.CameraType.Scriptable
        cam.FieldOfView = 70
    end) end
    desiredVelocity = Vector3.zero
    takeoffUntil = os.clock() + 0.8
    flying, autopilot, cameraEnabled = true, false, true
    lastCameraFrame = nil
    local look = root.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    flightHeading = flat.Magnitude > 0.05 and flat.Unit or Vector3.new(0, 0, -1)
    cameraHeading = flightHeading
    thrust.VectorVelocity = Vector3.zero
    spin.AngularVelocity = Vector3.new(0, NORMAL_SPIN, 0)
    thrust.Enabled, spin.Enabled = true, true
    safeOutput(outputA, true)
    print("TARDIS FLIGHT: ENGAGED / real physics / spinning / +/- cruise / G autopilot / X drop")
end

local function number3(a, b, c)
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if not a or not b or not c then return nil end
    if a ~= a or b ~= b or c ~= c then return nil end
    if math.max(math.abs(a), math.abs(b), math.abs(c)) > 10000000 then return nil end
    return Vector3.new(a, b, c)
end

local function parseDestination(value)
    if typeof(value) == "Vector3" then return value end
    if typeof(value) == "CFrame" then return value.Position end
    if type(value) ~= "string" then return nil end
    local components = {}
    for token in string.gmatch(value, "[^,%s]+") do
        table.insert(components, token)
    end
    if #components == 3 then
        return number3(components[1], components[2], components[3])
    end
    return nil
end

local function updateWiredInputs(now)
    if now - lastTargetRead < 0.10 then return end
    lastTargetRead = now
    if inputB then
        local value = nil
        pcall(function() value = inputB:GetState() end)
        local parsed = parseDestination(value)
        if parsed and (not previousB or (parsed - previousB).Magnitude > 0.01) then
            previousB = parsed
            target = parsed
            print("TARDIS FLIGHT: target", target)
        end
    end
    if inputD then
        local n = nil
        pcall(function() n = tonumber(inputD:GetState()) end)
        if n and n == n and n ~= previousD then
            previousD = n
            speedLimit = math.clamp(n, MIN_SPEED, MAX_SPEED)
            print("TARDIS FLIGHT: cruise speed", speedLimit)
        end
    end
end

local function toggleAutopilot()
    if not flying then return end
    if autopilot then
        autopilot = false
        print("TARDIS AUTOPILOT: cancelled, manual hover")
        return
    end
    lastTargetRead = 0
    updateWiredInputs(os.clock())
    if not target then
        print("TARDIS AUTOPILOT: no target on input B")
        return
    end
    autopilot = true
    print("TARDIS AUTOPILOT: heading to", target)
end

local function held(key)
    return keyDown[key] == true
end

local function approach(current, goal, maxChange)
    local diff = goal - current
    local distance = diff.Magnitude
    if distance <= maxChange then return goal end
    return current + diff.Unit * maxChange
end

local function updatePhysics(dt)
    if not flying or not root or not thrust or not spin then return end
    dt = math.clamp(dt or UPDATE, 0.002, 0.10)
    local now = os.clock()
    -- Interlock is cheap. No repeated workspace scans or property GUI writes.
    if now - lastSafety >= 0.1 then
        lastSafety = now
        local valid, reason = rigAvailable()
        if not valid then stopFlight("controller handoff: " .. reason); return end
    end
    updateWiredInputs(now)

    local go = (held(Enum.KeyCode.W) and 1 or 0)
        - (held(Enum.KeyCode.S) and 1 or 0)
    local lift = (held(Enum.KeyCode.E) and 1 or 0)
        - (held(Enum.KeyCode.Q) and 1 or 0)
    local steer = (held(Enum.KeyCode.D) and 1 or 0)
        - (held(Enum.KeyCode.A) and 1 or 0)
    local braking = held(Enum.KeyCode.Space)
    local boosting = held(Enum.KeyCode.LeftShift) or held(Enum.KeyCode.RightShift)
    -- A/D steer the travel bearing independently of the visually spinning
    -- box. Holding W therefore flies straight instead of tracing a tiny circle.
    if steer ~= 0 then
        local turn = CFrame.Angles(0, -steer * TURN_SPEED * dt, 0)
        flightHeading = turn:VectorToWorldSpace(flightHeading)
    end

    if autopilot and (go ~= 0 or lift ~= 0 or braking) then
        autopilot = false
        print("TARDIS AUTOPILOT: manual override")
    end

    local top = speedLimit
    if boosting and not autopilot then top = math.min(MAX_SPEED, top * 1.7) end
    local requested = Vector3.zero
    if autopilot and target then
        local delta = target - root.Position
        local distance = delta.Magnitude
        if distance < ARRIVAL_RADIUS and root.AssemblyLinearVelocity.Magnitude < 4 then
            autopilot = false
            print("TARDIS AUTOPILOT: arrived / holding position")
        elseif distance > 0.001 then
            local safeSpeed = math.min(top,
                math.sqrt(2 * BRAKING * math.max(0, distance - ARRIVAL_RADIUS)))
            requested = delta.Unit * safeSpeed
        end
    else
        -- Visual spin is independent of the direction of travel.
        requested = flightHeading * (go * top)
            + Vector3.new(0, lift * top * 0.70, 0)
        if requested.Magnitude > top then requested = requested.Unit * top end
        -- Clear the ground before starting the cinematic spin. No teleport:
        -- the physics motor performs a short, gentle vertical takeoff.
        if now < takeoffUntil and lift == 0 and go == 0 then
            requested = Vector3.new(0, 20, 0)
        end
    end
    if braking then requested = Vector3.zero end

    desiredVelocity = approach(desiredVelocity, requested,
        (requested.Magnitude < desiredVelocity.Magnitude and BRAKING or ACCELERATION) * dt)
    thrust.VectorVelocity = desiredVelocity
    spin.AngularVelocity = Vector3.new(
        WOBBLE * math.sin(now * 0.8),
        NORMAL_SPIN + steer * STEER_SPIN,
        WOBBLE * math.cos(now * 0.65)
    )

    if outputB and now - lastOutput >= 0.1 then
        lastOutput = now
        safeOutput(outputB, root.Position)
    end
end

local function updateCamera(dt)
    if not flying or not cameraEnabled or hasNavigation() then return end
    local cam = getCamera()
    if not cam or not root then return end
    local cf = root.CFrame
    local actualVelocity = root.AssemblyLinearVelocity
    local speed = actualVelocity.Magnitude
    local alpha = 1 - math.exp(-8 * math.clamp(dt or UPDATE, 0, 0.1))
    -- Let the POLICE BOX spin in the shot. Do not orbit the camera with
    -- its rotating LookVector, which makes the whole world appear to spin.
    if not cameraHeading then cameraHeading = cf.LookVector end
    if speed > 8 then
        local mixed = cameraHeading:Lerp(actualVelocity.Unit,
            1 - math.exp(-3 * math.clamp(dt or UPDATE, 0, 0.1)))
        if mixed.Magnitude > 0.01 then cameraHeading = mixed.Unit end
    end
    local desired = CFrame.lookAt(
        cf.Position - cameraHeading * 24 + Vector3.new(0, 11, 0),
        cf.Position + Vector3.new(0, 2, 0)
    )
    lastCameraFrame = lastCameraFrame and lastCameraFrame:Lerp(desired, alpha) or desired
    pcall(function()
        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame = lastCameraFrame
        cam.FieldOfView = 70 + math.min(12, speed / 22)
    end)
end

if UserInputService then pcall(function()
    UserInputService.InputBegan:Connect(function(input, processed)
        if not flying or processed then return end
        local key = input.KeyCode
        if key == Enum.KeyCode.X or key == Enum.KeyCode.Escape then
            stopFlight("PILOT DROP")
        elseif key == Enum.KeyCode.G then
            toggleAutopilot()
        elseif key == Enum.KeyCode.V then
            cameraEnabled = not cameraEnabled
            if not cameraEnabled then restoreCamera() else
                local cam = getCamera()
                if cam then pcall(function()
                    savedCamera = {
                        kind = cam.CameraType, subject = cam.CameraSubject, fov = cam.FieldOfView
                    }
                    cam.CameraType = Enum.CameraType.Scriptable
                end) end
            end
        elseif key == Enum.KeyCode.Equals or key == Enum.KeyCode.KeypadPlus then
            speedLimit = math.min(MAX_SPEED, speedLimit + SPEED_STEP)
            print("TARDIS SPEED:", speedLimit)
        elseif key == Enum.KeyCode.Minus or key == Enum.KeyCode.KeypadMinus then
            speedLimit = math.max(MIN_SPEED, speedLimit - SPEED_STEP)
            print("TARDIS SPEED:", speedLimit)
        else
            keyDown[key] = true
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        keyDown[input.KeyCode] = nil
    end)
end) end

if RunService then
    local ok, conn = pcall(function()
        return RunService.Heartbeat:Connect(function(dt)
            lastHeartBeat = os.clock()
            updatePhysics(dt)
        end)
    end)
    if ok then heartbeatConnection = conn end
    local renderOK, renderConn = pcall(function()
        return RunService.RenderStepped:Connect(function(dt)
            updateCamera(dt)
        end)
    end)
    if renderOK then renderConnection = renderConn end
end

safeOutput(outputA, false)
print("TARDIS FLIGHT 4.0 READY / no HUD / physical assembly required")
while true do
    local now = os.clock()
    local dt = math.clamp(now - lastTick, 0.002, 0.1)
    lastTick = now

    local a = false
    pcall(function() a = inputA:GetState() == true end)
    if a and not lastA then
        if flying then stopFlight("TOGGLE DROP") else startFlight() end
    end
    lastA = a

    local c = false
    if inputC then pcall(function() c = inputC:GetState() == true end) end
    if c and not lastC then toggleAutopilot() end
    lastC = c

    -- When FIU disallows Heartbeat, do not freeze. This task fallback still
    -- only writes TWO constraint velocities, never dozens of CFrames.
    if flying and (not heartbeatConnection or now - lastHeartBeat > 0.6) then
        updatePhysics(dt)
    end
    if flying and not renderConnection then updateCamera(dt) end
    task.wait(UPDATE)
end
