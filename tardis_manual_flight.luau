-- TARDIS FLIGHT 6.1 | Ultimate Build FIU
-- Standalone physics flight with a SMALL, STATIC destination/control GUI.
-- No per-frame GUI updates. Replicated movement writes go to EVERY exterior
-- Ultimate Build part proxy using the same CFrame setter as the hovering cubes.
-- Local root prediction handles in-between frames and the camera.
-- Requires the matching controller's unanchored welded exterior.
--
-- Input A: optional TRUE pulse to take off / drop.
-- Input B: optional Vector3, CFrame or "x,y,z" autopilot destination.
-- Input C: optional TRUE pulse to toggle autopilot.
-- Input D: optional number speed limit, 10-265.
-- Output A: active boolean. Output B: world Vector3.
-- Output C (optional): desired flight CFrame for a native game mover if needed.
--
-- GUI: TAKEOFF / GO / HOVER / DROP / +/- speed, X Y Z target fields.
-- Native Roblox Custom camera: mouse orbit, scroll zoom, no scripted camera CFrame.
-- Keyboard W/S: thrust, A/D: steer, Q/E: up/down, Shift: boost,
-- Space: hover, +/-: speed, G: autopilot, V: camera, X: drop.
-- Box spins with gentle wobble independently of travel heading.
-- On DROP, propulsion turns off; gravity takes over, never anchors box.

local inputA, inputB, inputC, inputD = nil, nil, nil, nil
local outputA, outputB, outputC = nil, nil, nil
pcall(function() inputA = script.inputs["a"] end)
pcall(function() inputB = script.inputs["b"] end)
pcall(function() inputC = script.inputs["c"] end)
pcall(function() inputD = script.inputs["d"] end)
pcall(function() outputA = script.outputs["a"] end)
pcall(function() outputB = script.outputs["b"] end)
pcall(function() outputC = script.outputs["c"] end)

local MIN_SPEED, MAX_SPEED, SPEED_STEP = 10, 265, 10
local ACCELERATION, BRAKING, ARRIVAL_RADIUS = 55, 105, 2.8
local SPIN_RATE, STEER_SPIN, TURN_RATE, WOBBLE = 0.9, 0.4, math.rad(70), 0.11
local UPDATE = 1 / 30
local MAX_REPLICATION_RATE = 12 -- Upper bound, adjusted for shell count
local MAX_PROXY_WRITES_PER_SECOND = 2200
local REPLICATION_INTERVAL = 1 / MAX_REPLICATION_RATE
local NAV_GUI = "TardisNavigationGui"
local RunService, Players, UserInputService = nil, nil, nil
pcall(function() RunService = game:GetService("RunService") end)
pcall(function() Players = game:GetService("Players") end)
pcall(function() UserInputService = game:GetService("UserInputService") end)
local player = nil
if Players then pcall(function() player = Players.LocalPlayer end) end

local root, rootWrapper, attachment, linear, angular = nil, nil, nil, nil
local exteriorProxies, exteriorOffsets = {}, {}
local lastReplicationWrite, replicationWrites = 0, 0
local replicationWriteFailures, lastFailureLog = 0, 0
local lastSuccessfulWriteCount, lastProxySummary = 0, 0
local flying, autopilot, velocityFallback = false, false, false
local cameraEnabled, savedCamera, cameraTarget = true, nil, nil
local lastCameraCheck = 0
local cameraMode, nativeSubject = "OFF", nil
local orbitYaw, orbitPitch, orbitDistance = 0, math.rad(18), 30
local orbitDragging = false
local orbitFocus, orbitCameraPose = nil, nil
local cameraRenderConnection, lastOrbitRender = nil, 0
local cameraFailureLogged = false
local keyDown, target, speedLimit, desiredVelocity = {}, nil, 80, Vector3.zero
local travelHeading = Vector3.new(0, 0, -1)
local previousTarget, previousSpeed = nil, nil
local lastInputA, lastInputC = false, false
local lastTargetRead, lastPositionWrite, lastGuard, lastHeartbeat = 0, 0, 0, 0
local takeoffUntil, lastTick = 0, os.clock()
local motionStart, motionPosition, stalledChecks = 0, nil, 0
local kinematicFallback, kinematicPose = false, nil
local kinematicStallChecks = 0
local heartbeatConnection = nil
local updateCamera
local gui, statusLabel, speedLabel, coords = nil, nil, nil, {}
local lastGuiAttempt, lastGuiError = 0, nil
local statusMessage = "READY"

local function status(message)
    message = tostring(message)
    if statusMessage == message then return end
    statusMessage = message
    print("TARDIS FLIGHT:", message)
    if statusLabel then pcall(function() statusLabel.Text = message end) end
end

local function output(port, value)
    if port then pcall(function() port:SetState(value) end) end
end

local function attr(obj, name)
    if not obj then return nil end
    local ok, value = pcall(function() return obj:GetAttribute(name) end)
    return ok and value or nil
end

local function basePart(obj)
    if not obj then return nil end
    local raw = nil
    pcall(function() raw = obj.Part end)
    raw = raw or obj
    local ok, isPart = pcall(function() return raw:IsA("BasePart") end)
    return ok and isPart and raw or nil
end

local function camera()
    local result = nil
    pcall(function() result = workspace.CurrentCamera end)
    return result
end

local function navigationOpen()
    if not player then return false end
    local pg = nil
    pcall(function() pg = player:FindFirstChildOfClass("PlayerGui") end)
    return pg and pg:FindFirstChild(NAV_GUI) ~= nil
end

local function findRoot()
    local selectedRoot, selectedWrapper = nil, nil
    for _, object in ipairs(workspace:GetDescendants()) do
        local part = basePart(object)
        if part and attr(part, "TardisRigRoot") == true then
            selectedRoot = part
            -- An ordinary raw BasePart write is client-local here. We need
            -- the Ultimate Build exposed block whose .Part points at it.
            -- The original controller moved these same block.CFrame values.
            if object ~= part then
                local readOK, wrapperCF = pcall(function() return object.CFrame end)
                if readOK and typeof(wrapperCF) == "CFrame" then
                    selectedWrapper = object
                    break
                end
            end
        end
    end
    return selectedRoot, selectedWrapper
end

-- Matches the original admin cubes' proxy movement path. The controller
-- uses the same DisplayName matching for its 155 exterior parts. We do not
-- clone or destroy the build: drive the EXISTING editable UB block proxies.
local function proxyDisplayName(object)
    if not object then return nil end
    -- Match the EXISTING controller's getBlockValue(block, "DisplayName")
    -- exactly, before trying the unrelated "Display name" metadata key.
    -- That difference made V6 find only the root even though the controller
    -- successfully found all of the shell union proxies.
    local function readKey(key)
        local ok, value = pcall(function() return object[key] end)
        if ok and type(value) == "string" and value ~= "" then return value end
        ok, value = pcall(function() return object:GetAttribute(key) end)
        if ok and type(value) == "string" and value ~= "" then return value end
        ok, value = pcall(function() return object.attributes[key] end)
        if ok and type(value) == "string" and value ~= "" then return value end
        return nil
    end
    return readKey("DisplayName") or readKey("Display name")
end

local function prepareExteriorProxies(pivot)
    exteriorProxies, exteriorOffsets = {}, {}
    local seenRaw = {}
    local function add(object)
        if not object or object == script then return end
        local readOK, cf = pcall(function() return object.CFrame end)
        if not readOK or typeof(cf) ~= "CFrame" then return end
        local raw = basePart(object) or object
        if seenRaw[raw] then return end
        seenRaw[raw] = true
        table.insert(exteriorProxies, object)
        exteriorOffsets[object] = pivot:ToObjectSpace(cf)
    end

    add(rootWrapper)
    local shellCount, accessoryCount, namedCount, readableCount = 0, 0, 0, 0
    local descendants = workspace:GetDescendants()
    local function addNamed(block, kind)
        local previous = #exteriorProxies
        add(block)
        if #exteriorProxies > previous then
            if kind == "shell" then shellCount = shellCount + 1
            else accessoryCount = accessoryCount + 1 end
        end
    end
    -- Prefer FIU wrappers to their raw BaseParts so CFrame assignments
    -- follow the same replicated proxy path as our successful chat cubes.
    -- The controller uses these same workspace descendants.
    for pass = 1, 2 do
        for _, block in ipairs(descendants) do
            local raw = basePart(block)
            local isWrapper = raw and block ~= raw
            if (pass == 1 and isWrapper) or (pass == 2 and not isWrapper) then
                local name = proxyDisplayName(block)
                if type(name) == "string" then
                    namedCount = namedCount + 1
                    name = string.lower(name:match("^%s*(.-)%s*$"))
                    if name == "tardis" then
                        addNamed(block, "shell")
                    elseif name == "tardismatsound" or name == "tardislight"
                        or name == "tardisportal" then
                        addNamed(block, "accessory")
                    end
                end
                local readable = pcall(function() return block.CFrame end)
                if readable then readableCount = readableCount + 1 end
            end
        end
    end
    print("TARDIS PROXY DISCOVERY:", #descendants, "descendants;",
        readableCount, "CFrame-readable;", namedCount, "named;",
        shellCount, "shells;", accessoryCount, "accessories;",
        #exteriorProxies, "distinct proxies total")

    if #exteriorProxies < 2 or shellCount < 1 then
        print("TARDIS PROXY SCAN INCOMPLETE: controller and flight must",
            "resolve the same DisplayName. Refusing root-only local flight.")
        return false
    end
    local actualRate = math.min(MAX_REPLICATION_RATE,
        math.max(1, math.floor(MAX_PROXY_WRITES_PER_SECOND / #exteriorProxies)))
    REPLICATION_INTERVAL = 1 / actualRate
    print("TARDIS PROXY SCAN:", #exteriorProxies, "distinct blocks;",
        shellCount, "shell matches;", accessoryCount, "accessories;",
        actualRate, "replication Hz")
    return true
end

local function replicateExterior(pivot, now)
    if now - lastReplicationWrite < REPLICATION_INTERVAL then return true end
    lastReplicationWrite = now
    local failed, wrote = 0, 0
    for _, proxy in ipairs(exteriorProxies) do
        local offset = exteriorOffsets[proxy]
        if offset then
            -- Exact setter from the replicated chat cubes: proxy.CFrame = ...
            local ok, err = pcall(function() proxy.CFrame = pivot * offset end)
            if ok then
                wrote = wrote + 1
            else
                failed = failed + 1
                if failed <= 3 and now - lastFailureLog > 2 then
                    print("TARDIS PROXY WRITE REJECTED:", tostring(err))
                    lastFailureLog = now
                end
            end
        end
    end
    replicationWrites = replicationWrites + wrote
    replicationWriteFailures = replicationWriteFailures + failed
    lastSuccessfulWriteCount = wrote
    if now - lastProxySummary > 5 then
        lastProxySummary = now
        print("TARDIS PROXY MOVEMENT:", wrote, "/", #exteriorProxies,
            "wrote this tick; total failures", replicationWriteFailures)
    end
    -- If more than 20% of the exterior cannot be moved, stop. Never claim
    -- that moving one root represents successful flight of the whole build.
    return failed <= math.floor(#exteriorProxies * .2)
end

local function rigReady()
    if not root then return false, "controller rig not found" end
    if attr(root, "TardisRigReady") ~= true then
        return false, tostring(attr(root, "TardisRigError") or "controller rig incomplete")
    end
    if attr(root, "TardisTransitioning") == true then
        return false, "controller is materializing/dematerializing"
    end
    local anchored = nil
    pcall(function() anchored = root.Anchored end)
    if anchored ~= false then return false, "root is anchored" end
    local mass = nil
    pcall(function() mass = root.AssemblyMass end)
    if type(mass) ~= "number" or mass == math.huge or mass ~= mass or mass <= 0 then
        return false, "invalid assembly mass: " .. tostring(mass)
    end
    return true
end

local function disableMotors()
    if linear then pcall(function() linear.Enabled = false end) end
    if angular then pcall(function() angular.Enabled = false end) end
end

local function clearMotors()
    if not root then return end
    for _, name in ipairs({
        "TardisFlightVelocity", "TardisFlightSpin", "TardisFlightAttachment"
    }) do
        local old = root:FindFirstChild(name)
        if old then pcall(function() old:Destroy() end) end
    end
end

local function buildMotors()
    local ok, err = pcall(function()
        clearMotors()
        attachment = Instance.new("Attachment")
        attachment.Name = "TardisFlightAttachment"
        attachment.Parent = root

        linear = Instance.new("LinearVelocity")
        linear.Name = "TardisFlightVelocity"
        linear.Attachment0 = attachment
        linear.RelativeTo = Enum.ActuatorRelativeTo.World
        linear.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        linear.ForceLimitsEnabled = false
        linear.VectorVelocity = Vector3.zero
        linear.Enabled = false
        linear.Parent = root

        angular = Instance.new("AngularVelocity")
        angular.Name = "TardisFlightSpin"
        angular.Attachment0 = attachment
        angular.RelativeTo = Enum.ActuatorRelativeTo.World
        angular.MaxTorque = 1e12
        angular.AngularVelocity = Vector3.zero
        angular.Enabled = false
        angular.Parent = root
    end)
    if not ok then
        print("TARDIS MOTOR CREATION FAILED:", tostring(err))
        disableMotors()
        for _, obj in ipairs({linear, angular, attachment}) do
            if obj then pcall(function() obj:Destroy() end) end
        end
        linear, angular, attachment = nil, nil, nil
        return false
    end
    return true
end

local function playerCameraSubject()
    if not player then return nil end
    local found = nil
    pcall(function()
        local character = player.Character
        if character then
            found = character:FindFirstChildOfClass("Humanoid")
                or character:FindFirstChild("HumanoidRootPart")
        end
    end)
    return found
end

local function cameraFocusPosition()
    local pose = (kinematicFallback and kinematicPose) or (root and root.CFrame)
    return pose and (pose.Position + Vector3.new(0, 2, 0)) or nil
end

local function restoreCamera()
    cameraMode, nativeSubject, orbitDragging = "OFF", nil, false
    local cam = camera()
    if cam and savedCamera then
        local previous = savedCamera
        -- Do not submit FIU tables to CameraSubject. Only an actual valid
        -- Instance can be a subject; failed assignments are handled once.
        local subjects = {}
        if previous.subject then table.insert(subjects, previous.subject) end
        local characterSubject = playerCameraSubject()
        if characterSubject then table.insert(subjects, characterSubject) end
        local restored = false
        for _, subject in ipairs(subjects) do
            if subject then
                local ok = pcall(function() cam.CameraSubject = subject end)
                if ok then restored = true; break end
                local inner = nil
                pcall(function() inner = subject.Part end)
                if inner then
                    ok = pcall(function() cam.CameraSubject = inner end)
                    if ok then restored = true; break end
                end
            end
        end
        pcall(function()
            if previous.fov then cam.FieldOfView = previous.fov end
            cam.CameraType = previous.kind == Enum.CameraType.Scriptable
                and Enum.CameraType.Custom or (previous.kind or Enum.CameraType.Custom)
        end)
        if not restored then
            print("TARDIS CAMERA: FIU did not expose a restorable subject")
        end
    end
    savedCamera = nil
    orbitFocus, orbitCameraPose = nil, nil
    if cameraTarget then
        pcall(function() cameraTarget:Destroy() end)
        cameraTarget = nil
    end
end

local function configureOrbitFromCurrentView(cam, focus)
    orbitFocus, orbitCameraPose = focus, nil
    local offset = Vector3.new(0, 12, 28)
    pcall(function() offset = cam.CFrame.Position - focus end)
    if offset.Magnitude < 1 then offset = Vector3.new(0, 12, 28) end
    orbitDistance = math.clamp(offset.Magnitude, 8, 120)
    orbitYaw = math.atan2(offset.X, offset.Z)
    orbitPitch = math.clamp(math.asin(
        math.clamp(offset.Y / offset.Magnitude, -1, 1)),
        math.rad(-78), math.rad(78))
end

local function engageCamera()
    local cam = camera()
    if not cam or not root then
        status("CAMERA UNAVAILABLE / check CurrentCamera")
        return
    end
    if not savedCamera then
        pcall(function()
            savedCamera = {
                kind = cam.CameraType,
                subject = cam.CameraSubject,
                fov = cam.FieldOfView,
            }
        end)
    end

    local followPosition = cameraFocusPosition()
    if not followPosition then return end
    if not cameraTarget then
        -- This FIU may return a table proxy rather than a Roblox Instance.
        -- Native CameraSubject gets only ONE guarded attempt per candidate.
        local created, err = pcall(function()
            local old = workspace:FindFirstChild("TardisFlightCameraTarget")
            if old then old:Destroy() end
            local part = Instance.new("Part")
            part.Name = "TardisFlightCameraTarget"
            part.Size = Vector3.new(.2, .2, .2)
            part.Transparency = 1
            part.Anchored = true
            part.CanCollide = false
            pcall(function() part.CanTouch = false end)
            pcall(function() part.CanQuery = false end)
            part.CFrame = CFrame.new(followPosition)
            part.Parent = workspace
            cameraTarget = part
        end)
        if not created then print("TARDIS CAMERA PROXY:", tostring(err)) end
    end

    nativeSubject = nil
    local rawTarget = nil
    if cameraTarget then pcall(function() rawTarget = cameraTarget.Part end) end
    -- Try native Roblox subject first; FIU sometimes provides a real .Part.
    -- Do not retry a rejected table on every tick.
    local candidates = {}
    if rawTarget then table.insert(candidates, rawTarget) end
    if cameraTarget then table.insert(candidates, cameraTarget) end
    if root then table.insert(candidates, root) end
    for _, candidate in ipairs(candidates) do
        if candidate then
            local ok = pcall(function()
                cam.CameraSubject = candidate
                cam.CameraType = Enum.CameraType.Custom
            end)
            if ok then
                nativeSubject = candidate
                cameraMode = "NATIVE"
                break
            end
        end
    end

    if nativeSubject then
        print("TARDIS CAMERA: native Roblox orbit enabled")
    else
        -- CameraSubject rejects FIU table proxies. Preserve mouse orbit/zoom
        -- without relying on that property at all.
        if not cameraFailureLogged then
            print("TARDIS CAMERA: FIU CameraSubject requires Instance, got proxy; using mouse orbit")
            cameraFailureLogged = true
        end
        cameraMode = "ORBIT"
        configureOrbitFromCurrentView(cam, followPosition)
        local ok, err = pcall(function() cam.CameraType = Enum.CameraType.Scriptable end)
        if not ok then status("CAMERA ORBIT UNAVAILABLE: " .. tostring(err)) end
    end
    lastCameraCheck = os.clock()
end

local function dropFlight(reason)
    if not flying then return end
    -- Commit the exact last visual pose before releasing the physical shell.
    -- Otherwise the remote box can be one network tick behind the pilot.
    if kinematicPose and #exteriorProxies > 1
        and attr(root, "TardisTransitioning") ~= true then
        replicateExterior(kinematicPose, os.clock() + REPLICATION_INTERVAL)
    end
    flying, autopilot = false, false
    desiredVelocity, keyDown = Vector3.zero, {}
    kinematicFallback, kinematicPose = false, nil
    disableMotors()
    if root then
        pcall(function() root:SetAttribute("TardisFlightActive", false) end)
        pcall(function()
            if attr(root, "TardisTransitioning") == true then
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            else
                local v = root.AssemblyLinearVelocity
                root.AssemblyLinearVelocity = Vector3.new(v.X * .2, v.Y, v.Z * .2)
                root.AssemblyAngularVelocity = Vector3.new(.08, .30, .05)
            end
        end)
    end
    output(outputA, false)
    restoreCamera()
    status(reason or "DROP / gravity released")
end

local function takeoff()
    if flying then return true end
    root, rootWrapper = findRoot()
    local ok, reason = rigReady()
    if not ok then
        status("CAN'T TAKE OFF: " .. tostring(reason))
        return false
    end
    if not rootWrapper then
        status("NO FIU ROOT WRAPPER")
        return false
    end

    local wrapperOK, initialPose = pcall(function() return rootWrapper.CFrame end)
    if not wrapperOK or typeof(initialPose) ~= "CFrame" then
        status("FIU ROOT CFRAME UNREADABLE")
        return false
    end
    local testOK, testErr = pcall(function() rootWrapper.CFrame = initialPose end)
    if not testOK then
        status("FIU ROOT CFRAME WRITE REJECTED: " .. tostring(testErr))
        return false
    end

    -- A single raw/root wrapper moved only locally in earlier builds.
    -- Capture every named exterior proxy and its exact pivot-relative pose.
    if not prepareExteriorProxies(initialPose) then
        status("EXTERIOR PROXY SCAN FAILED / no root-only fallback")
        return false
    end
    clearMotors()
    velocityFallback, kinematicFallback = true, true
    kinematicPose, kinematicStallChecks = initialPose, 0
    lastReplicationWrite, replicationWrites, replicationWriteFailures = 0, 0, 0
    lastSuccessfulWriteCount, lastProxySummary, lastFailureLog = 0, 0, 0
    desiredVelocity = Vector3.zero
    local look = initialPose.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    travelHeading = flat.Magnitude > .01 and flat.Unit or Vector3.new(0, 0, -1)
    lastCameraCheck = 0
    takeoffUntil = os.clock() + .8
    motionStart, motionPosition, stalledChecks = os.clock(), root.Position, 0
    flying, autopilot, cameraEnabled = true, false, true
    pcall(function() root:SetAttribute("TardisFlightActive", true) end)
    engageCamera()
    output(outputA, true)
    print("TARDIS REPLICATION: matching hovering cubes, all exterior proxy CFrames")
    print("TARDIS PHYSICS START:", "mass", tostring(root.AssemblyMass),
        "anchored", tostring(root.Anchored), "mode", "FULL EXTERIOR PROXIES")
    local ownerOK, owner = pcall(function() return root:GetNetworkOwner() end)
    print("TARDIS NETWORK OWNER:", ownerOK and
        (owner and tostring(owner.Name) or "server") or "unavailable to FIU")
    status("FULL EXTERIOR PROXY FLIGHT")
    return true
end

local function parse3(a, b, c)
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if not a or not b or not c or a ~= a or b ~= b or c ~= c then return nil end
    if math.max(math.abs(a), math.abs(b), math.abs(c)) > 1e7 then return nil end
    return Vector3.new(a, b, c)
end

local function parseTarget(value)
    if typeof(value) == "Vector3" then return value end
    if typeof(value) == "CFrame" then return value.Position end
    if type(value) ~= "string" then return nil end
    local parts = {}
    for item in string.gmatch(value, "[^,%s]+") do table.insert(parts, item) end
    if #parts == 3 then return parse3(parts[1], parts[2], parts[3]) end
    return nil
end

local function readWiredInputs(now)
    if now - lastTargetRead < .12 then return end
    lastTargetRead = now
    if inputB then
        local v = nil
        pcall(function() v = inputB:GetState() end)
        local p = parseTarget(v)
        if p and (not previousTarget or (p - previousTarget).Magnitude > .01) then
            previousTarget, target = p, p
            if coords[1] then
                for i, n in ipairs({p.X, p.Y, p.Z}) do
                    local field = coords[i]
                    local focused = false
                    pcall(function() focused = field:IsFocused() end)
                    if not focused then field.Text = string.format("%.1f", n) end
                end
            end
            status("TARGET LOADED")
        end
    end
    if inputD then
        local v = nil
        pcall(function() v = tonumber(inputD:GetState()) end)
        if v and v == v and v ~= previousSpeed then
            previousSpeed = v
            speedLimit = math.clamp(v, MIN_SPEED, MAX_SPEED)
            if speedLabel then speedLabel.Text = tostring(speedLimit) end
        end
    end
end

local function startAuto()
    if not target then
        status("ENTER X / Y / Z FIRST")
        return
    end
    if not flying and not takeoff() then return end
    autopilot = true
    status("AUTOPILOT / " .. tostring(target))
end

local function toggleAuto()
    if autopilot then
        autopilot = false
        status("AUTOPILOT OFF / hover")
    else
        lastTargetRead = 0
        readWiredInputs(os.clock())
        startAuto()
    end
end

local function changeSpeed(amount)
    speedLimit = math.clamp(speedLimit + amount, MIN_SPEED, MAX_SPEED)
    if speedLabel then speedLabel.Text = tostring(speedLimit) end
    status("SPEED LIMIT: " .. tostring(speedLimit))
end

-- GUI is created ONCE. No continuously changing telemetry or animated bars.
-- The small panel remains available when dropped so TAKEOFF needs no input A.
local function rounded(parent, radius)
    pcall(function()
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, radius)
        corner.Parent = parent
    end)
end

local function offsetUDim(x, y)
    return UDim2.new(0, x, 0, y)
end

local function uiText(parent, text, pos, size, textSize, tint, strong)
    local element = Instance.new("TextLabel")
    element.BackgroundTransparency = 1
    element.Position, element.Size = pos, size
    element.Text = text
    element.TextColor3 = tint or Color3.fromRGB(218, 238, 250)
    element.TextSize = textSize
    element.Font = strong and Enum.Font.GothamBold or Enum.Font.Code
    element.TextXAlignment = Enum.TextXAlignment.Left
    element.TextWrapped = true
    element.Parent = parent
    return element
end

local function uiButton(parent, text, x, y, width, action)
    local button = Instance.new("TextButton")
    button.Size, button.Position = offsetUDim(width, 32), offsetUDim(x, y)
    button.BackgroundColor3 = Color3.fromRGB(28, 75, 106)
    button.BorderSizePixel = 0
    button.TextColor3 = Color3.fromRGB(235, 250, 255)
    button.TextSize = 13
    button.Text = text
    button.Font = Enum.Font.GothamBold
    button.Parent = parent
    rounded(button, 6)
    local activated = pcall(function() button.Activated:Connect(action) end)
    if not activated then
        button.MouseButton1Click:Connect(action)
    end
    return button
end

local function readGUI()
    if not coords[1] or not coords[2] or not coords[3] then return nil end
    return parse3(coords[1].Text, coords[2].Text, coords[3].Text)
end

local function goFromGUI()
    local p = readGUI()
    if not p then status("INVALID X / Y / Z"); return end
    -- Snapshot any existing wired target so an old input-B value does not
    -- immediately overwrite the coordinates the pilot just typed.
    if inputB then
        local wired = nil
        pcall(function() wired = inputB:GetState() end)
        previousTarget = parseTarget(wired) or previousTarget
    end
    target = p
    startAuto()
end

local function buildGUI()
    if gui then return true end
    if not player then return false end
    local ok, err = pcall(function()
        local pg = player:FindFirstChildOfClass("PlayerGui")
            or player:FindFirstChild("PlayerGui")
        if not pg then error("PlayerGui unavailable") end
        local old = pg:FindFirstChild("TardisFlightControls")
        if old then old:Destroy() end

        local screen = Instance.new("ScreenGui")
        screen.Name = "TardisFlightControls"
        screen.ResetOnSpawn = false
        screen.IgnoreGuiInset = true
        screen.DisplayOrder = 950
        screen.Parent = pg
        gui = screen

        local frame = Instance.new("Frame")
        frame.Position = UDim2.new(1, -358, 0, 18)
        frame.Size = offsetUDim(340, 239)
        frame.BackgroundColor3 = Color3.fromRGB(9, 20, 35)
        frame.BackgroundTransparency = .10
        frame.BorderSizePixel = 0
        frame.Parent = screen
        rounded(frame, 9)
        pcall(function()
            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(55, 168, 207)
            stroke.Thickness = 1
            stroke.Transparency = .25
            stroke.Parent = frame
        end)

        uiText(frame, "TYPE 40  /  FLIGHT", offsetUDim(12, 7),
            offsetUDim(310, 25), 16, Color3.fromRGB(110, 225, 250), true)
        uiText(frame, "DESTINATION (WORLD X / Y / Z)", offsetUDim(12, 39),
            offsetUDim(311, 18), 11)
        for i, name in ipairs({"X", "Y", "Z"}) do
            local field = Instance.new("TextBox")
            field.Position = offsetUDim(12 + (i - 1) * 107, 62)
            field.Size = offsetUDim(100, 29)
            field.BackgroundColor3 = Color3.fromRGB(22, 44, 66)
            field.BorderSizePixel = 0
            field.Font = Enum.Font.Code
            field.TextSize = 14
            field.TextColor3 = Color3.fromRGB(241, 250, 255)
            field.PlaceholderText = name
            field.Text = ""
            field.ClearTextOnFocus = false
            field.Parent = frame
            rounded(field, 5)
            coords[i] = field
            field.FocusLost:Connect(function(enter)
                if enter then goFromGUI() end
            end)
        end
        uiButton(frame, "TAKEOFF", 12, 102, 101, function() takeoff() end)
        uiButton(frame, "GO", 119, 102, 102, goFromGUI)
        uiButton(frame, "DROP", 227, 102, 100,
            function() dropFlight("DROP / gravity released") end)
        uiText(frame, "CRUISE SPEED", offsetUDim(12, 148),
            offsetUDim(145, 22), 12)
        speedLabel = uiText(frame, tostring(speedLimit), offsetUDim(180, 146),
            offsetUDim(47, 24), 18, Color3.fromRGB(110, 225, 250), true)
        uiButton(frame, "-", 231, 144, 42, function() changeSpeed(-SPEED_STEP) end)
        uiButton(frame, "+", 281, 144, 42, function() changeSpeed(SPEED_STEP) end)
        uiButton(frame, "HOVER / ABORT", 12, 185, 126, function()
            autopilot = false
            desiredVelocity = Vector3.zero
            status("HOVER / autopilot off")
        end)
        statusLabel = uiText(frame, statusMessage, offsetUDim(147, 185),
            offsetUDim(181, 48), 11, Color3.fromRGB(140, 230, 196))
    end)
    if not ok then
        print("TARDIS FLIGHT GUI ERROR:", tostring(err))
        if gui then pcall(function() gui:Destroy() end) end
        gui, statusLabel, speedLabel, coords = nil, nil, nil, {}
        return false
    end
    print("TARDIS FLIGHT: compact destination GUI ready")
    return true
end

local function held(key) return keyDown[key] == true end
local function approach(current, goal, maxStep)
    local diff = goal - current
    if diff.Magnitude <= maxStep then return goal end
    return current + diff.Unit * maxStep
end

local function updatePhysics(dt)
    if not flying or not root then return end
    dt = math.clamp(dt or UPDATE, .002, .10)
    local now = os.clock()

    if now - lastGuard >= .12 then
        lastGuard = now
        local valid, why = rigReady()
        if not valid then dropFlight("CONTROLLER HANDOFF: " .. tostring(why)); return end
    end
    readWiredInputs(now)

    local go = (held(Enum.KeyCode.W) and 1 or 0)
        - (held(Enum.KeyCode.S) and 1 or 0)
    local lift = (held(Enum.KeyCode.E) and 1 or 0)
        - (held(Enum.KeyCode.Q) and 1 or 0)
    local steer = (held(Enum.KeyCode.D) and 1 or 0)
        - (held(Enum.KeyCode.A) and 1 or 0)
    local brake = held(Enum.KeyCode.Space)
    local boost = held(Enum.KeyCode.LeftShift) or held(Enum.KeyCode.RightShift)

    if steer ~= 0 then
        local bearingTurn = CFrame.Angles(0, -steer * TURN_RATE * dt)
        travelHeading = bearingTurn:VectorToWorldSpace(travelHeading)
    end
    if autopilot and (go ~= 0 or lift ~= 0 or brake) then
        autopilot = false
        status("MANUAL OVERRIDE")
    end

    local top = speedLimit
    if boost and not autopilot then top = math.min(MAX_SPEED, top * 1.7) end
    local wanted = Vector3.zero
    if autopilot and target then
        -- Raw root.Position can be stale under FIU CFrame flight.
        local delta = target - kinematicPose.Position
        local distance = delta.Magnitude
        if distance < ARRIVAL_RADIUS and desiredVelocity.Magnitude < 4 then
            autopilot = false
            status("ARRIVED / HOVER")
        elseif distance > .001 then
            local remaining = math.max(0, distance - ARRIVAL_RADIUS)
            wanted = delta.Unit * math.min(top, math.sqrt(2 * BRAKING * remaining))
        end
    else
        wanted = travelHeading * go * top + Vector3.new(0, lift * top * .7, 0)
        if wanted.Magnitude > top then wanted = wanted.Unit * top end
        if now < takeoffUntil and go == 0 and lift == 0 then
            wanted = Vector3.new(0, 20, 0)
        end
    end
    if brake then wanted = Vector3.zero end

    desiredVelocity = approach(desiredVelocity, wanted,
        (wanted.Magnitude < desiredVelocity.Magnitude and BRAKING or ACCELERATION) * dt)
    local rotation = Vector3.new(
        WOBBLE * math.sin(now * .8),
        SPIN_RATE + steer * STEER_SPIN,
        WOBBLE * math.cos(now * .65)
    )
    if kinematicFallback then
        -- In some FIU environments velocity *properties* update but their
        -- physics owner never integrates a change in position. Move the ONE
        -- welded root instead, never all 155 separate shell pieces. It stays
        -- unanchored: dropping flight simply stops all kinematic writes.
        -- This can be client-local if the server does not grant ownership.
        if not kinematicPose then kinematicPose = root.CFrame end
        local orientation = kinematicPose - kinematicPose.Position
        local yaw = CFrame.Angles(0, rotation.Y * dt, 0)
        local wobble = CFrame.Angles(rotation.X * dt, 0, rotation.Z * dt)
        orientation = yaw * orientation * wobble
        kinematicPose = CFrame.new(kinematicPose.Position + desiredVelocity * dt)
            * orientation
        -- Local prediction preserves pilot/camera responsiveness, while
        -- the FIU block wrapper is the requested replicated movement path.
        local previewOK, previewErr = pcall(function()
            root.CFrame = kinematicPose
        end)
        if not previewOK then
            print("TARDIS LOCAL PREVIEW FAILED:", tostring(previewErr))
        end

        if not replicateExterior(kinematicPose, now) then
            dropFlight("EXTERIOR PROXY WRITES REJECTED")
            return
        end
        -- Optional native movement block bridge.
        output(outputC, kinematicPose)
    elseif velocityFallback then
        local ok, err = pcall(function()
            root.AssemblyLinearVelocity = desiredVelocity
            root.AssemblyAngularVelocity = rotation
        end)
        if not ok then
            print("TARDIS VELOCITY ERROR:", tostring(err))
            dropFlight("PHYSICS WRITE BLOCKED")
            return
        end
    end

    -- Client raw-part reads may remain stale even when UB proxy movement is
    -- accepted, so report it as LOCAL raw-root displacement, not server proof.
    if now - motionStart >= 1.3 and motionPosition then
        local actualDistance = (root.Position - motionPosition).Magnitude
        if desiredVelocity.Magnitude > 8 and actualDistance < .35 then
            stalledChecks = stalledChecks + 1
            if not velocityFallback then
                velocityFallback = true
                disableMotors()
                status("CONSTRAINTS STALLED / trying direct velocity")
            elseif not kinematicFallback then
                -- Repeated zero displacement with a finite mass and a
                -- nonzero AssemblyLinearVelocity is not successful flight.
                -- Stop relying on the velocity setter and try one root CFrame.
                kinematicFallback = true
                kinematicPose = root.CFrame
                kinematicStallChecks = 0
                disableMotors()
                print("TARDIS FALLBACK: single-root CFrame flight; physics velocity not advancing position")
                status("PHYSICS NOT ADVANCING / UB PROXY FLIGHT")
            else
                kinematicStallChecks = kinematicStallChecks + 1
                if kinematicStallChecks >= 2 then
                    status("RAW ROOT READ STALE / CHECK EXTERIOR ON SECOND CLIENT")
                    print("TARDIS PROXY STATUS: raw Position unchanged; use spectator and proxy count to verify movement")
                end
            end
        else
            stalledChecks = 0
            kinematicStallChecks = 0
            if kinematicFallback and lastSuccessfulWriteCount == #exteriorProxies then
                status("EXTERIOR PROXIES MOVING / CHECK SECOND CLIENT")
            end
        end
        print("TARDIS MOTION CHECK:", "local root moved", actualDistance,
            "requested", desiredVelocity.Magnitude,
            "proxy count", #exteriorProxies,
            "last proxy writes", lastSuccessfulWriteCount,
            "total writes", replicationWrites,
            "write errors", replicationWriteFailures)
        motionStart, motionPosition = now, root.Position
    end
    if outputB and now - lastPositionWrite >= .1 then
        lastPositionWrite = now
        output(outputB, kinematicFallback and kinematicPose.Position or root.Position)
    end
    -- Update the follow subject on the physics tick, independently from
    -- Roblox's native render-frame orbit and scroll-wheel zoom.
    if cameraEnabled then updateCamera() end
end

updateCamera = function(dt)
    if not flying or not cameraEnabled or not root then return end
    local focus = cameraFocusPosition()
    if not focus then return end
    local cam = camera()
    if not cam then return end

    if cameraMode == "NATIVE" then
        if cameraTarget then
            pcall(function() cameraTarget.CFrame = CFrame.new(focus) end)
        end
        -- The exterior's spin is not inherited by the invisible subject.
        -- Navigation takes over temporarily. Do not fight it.
        local now = os.clock()
        if not navigationOpen() and now - lastCameraCheck > .5 then
            lastCameraCheck = now
            local ok, subject = pcall(function() return cam.CameraSubject end)
            if ok and subject ~= nativeSubject then
                local changed = pcall(function()
                    cam.CameraSubject = nativeSubject
                    cam.CameraType = Enum.CameraType.Custom
                end)
                if not changed then
                    cameraMode = "ORBIT"
                    configureOrbitFromCurrentView(cam, focus)
                    pcall(function() cam.CameraType = Enum.CameraType.Scriptable end)
                    status("NATIVE SUBJECT LOST / MOUSE ORBIT")
                end
            end
        end
    elseif cameraMode == "ORBIT" and not navigationOpen() then
        dt = math.clamp(dt or UPDATE, .001, .10)
        local alpha = 1 - math.exp(-16 * dt)
        orbitFocus = orbitFocus and orbitFocus:Lerp(focus, alpha) or focus
        local c, si = math.cos(orbitPitch), math.sin(orbitPitch)
        local offset = Vector3.new(
            math.sin(orbitYaw) * c * orbitDistance,
            si * orbitDistance,
            math.cos(orbitYaw) * c * orbitDistance
        )
        local desired = CFrame.lookAt(orbitFocus + offset, orbitFocus)
        orbitCameraPose = orbitCameraPose
            and orbitCameraPose:Lerp(desired, alpha) or desired
        local ok, err = pcall(function()
            cam.CameraType = Enum.CameraType.Scriptable
            cam.CFrame = orbitCameraPose
        end)
        -- Focus is optional in some FIU camera proxies; do not let rejection
        -- of this nonessential property block the actual orbit movement.
        pcall(function() cam.Focus = CFrame.new(orbitFocus) end)
        if not ok then
            status("MOUSE ORBIT WRITE FAILED: " .. tostring(err))
        end
    end
end

if UserInputService then pcall(function()
    UserInputService.InputBegan:Connect(function(input, processed)
        if not flying or processed then return end
        local key = input.KeyCode
        if key == Enum.KeyCode.X or key == Enum.KeyCode.Escape then
            dropFlight("DROP / gravity released")
        elseif key == Enum.KeyCode.G then
            toggleAuto()
        elseif key == Enum.KeyCode.V then
            cameraEnabled = not cameraEnabled
            if cameraEnabled then engageCamera() else restoreCamera() end
        elseif key == Enum.KeyCode.Equals or key == Enum.KeyCode.KeypadPlus then
            changeSpeed(SPEED_STEP)
        elseif key == Enum.KeyCode.Minus or key == Enum.KeyCode.KeypadMinus then
            changeSpeed(-SPEED_STEP)
        else
            keyDown[key] = true
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        keyDown[input.KeyCode] = nil
        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            orbitDragging = false
        end
    end)
    UserInputService.InputBegan:Connect(function(input, processed)
        if flying and cameraMode == "ORBIT" and not navigationOpen()
            and input.UserInputType == Enum.UserInputType.MouseButton2 then
            orbitDragging = true
        end
    end)
    UserInputService.InputChanged:Connect(function(input, processed)
        if not flying or not cameraEnabled or cameraMode ~= "ORBIT"
            or navigationOpen() or processed then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            and orbitDragging then
            local d = input.Delta
            orbitYaw = orbitYaw - d.X * .004
            orbitPitch = math.clamp(orbitPitch + d.Y * .004,
                math.rad(-78), math.rad(78))
        elseif input.UserInputType == Enum.UserInputType.MouseWheel then
            orbitDistance = math.clamp(
                orbitDistance - input.Position.Z * 4, 8, 120
            )
        end
    end)
end) end

if RunService then
    local ok, conn = pcall(function()
        return RunService.Heartbeat:Connect(function(dt)
            lastHeartbeat = os.clock()
            updatePhysics(dt)
        end)
    end)
    if ok then heartbeatConnection = conn end
    local renderOK, renderConn = pcall(function()
        return RunService.RenderStepped:Connect(function(dt)
            lastOrbitRender = os.clock()
            if cameraMode == "ORBIT" then updateCamera(dt) end
        end)
    end)
    if renderOK then cameraRenderConnection = renderConn end
end

output(outputA, false)
buildGUI()
print("TARDIS FLIGHT 6.1 READY / controller-matched proxy scan / coordinate GUI")
while true do
    local now = os.clock()
    local dt = math.clamp(now - lastTick, .002, .1)
    lastTick = now

    if not gui and now - lastGuiAttempt > 5 then
        lastGuiAttempt = now
        buildGUI()
    end

    local a = false
    if inputA then pcall(function() a = inputA:GetState() == true end) end
    if a and not lastInputA then
        if flying then dropFlight("TOGGLE DROP") else takeoff() end
    end
    lastInputA = a

    local c = false
    if inputC then pcall(function() c = inputC:GetState() == true end) end
    if c and not lastInputC then toggleAuto() end
    lastInputC = c

    if flying and (not heartbeatConnection or now - lastHeartbeat > .6) then
        updatePhysics(dt)
    end
    -- Refresh proxy even if the FIU Heartbeat callback stalls; Roblox's
    -- default CameraModule handles every rendered camera frame itself.
    if flying and cameraEnabled and
        (cameraMode ~= "ORBIT" or now - lastOrbitRender > .15) then
        updateCamera(dt)
    end
    task.wait(UPDATE)
end
