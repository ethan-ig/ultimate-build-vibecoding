-- TARDIS FLIGHT 8.0 | Ultimate Build FIU
-- Standalone replicated UB-proxy flight with compact destination GUI.
-- Requires the matching V8 controller, which REMOVES client-only welds and
-- independently anchors each editable exterior part.
-- Every part receives one shared pivot and a fixed relative offset.
-- The original hovering-cube test proved these per-block proxy writes
-- replicate; unlike V7, there is no client weld graph to tear apart.
-- DROP uses scripted downward motion of the complete exterior. It does
-- NOT unanchor the pieces: real gravity would scatter them without
-- server-owned joints. The camera remains user-controlled.
--
-- Input A: optional TRUE pulse takeoff / scripted drop.
-- Input B: optional Vector3, CFrame or "x,y,z" destination.
-- Input C: optional TRUE pulse toggle autopilot.
-- Input D: optional number speed limit.
-- Output A: powered flight active. B: current target world Vector3.
-- Output C: desired pivot CFrame.
-- GUI: TAKEOFF / GO / HOVER / DROP / +/- speed, X Y Z.
-- Keyboard W/S thrust, A/D steer, Q/E up/down, Shift boost,
-- Space brake, +/- speed, G autopilot, V camera, X scripted drop.
-- Spin rotates a single desired pivot and maintains all relative offsets.

local inputA, inputB, inputC, inputD = nil, nil, nil, nil
local outputA, outputB, outputC = nil, nil, nil
pcall(function() inputA = script.inputs["a"] end)
pcall(function() inputB = script.inputs["b"] end)
pcall(function() inputC = script.inputs["c"] end)
pcall(function() inputD = script.inputs["d"] end)
pcall(function() outputA = script.outputs["a"] end)
pcall(function() outputB = script.outputs["b"] end)
pcall(function() outputC = script.outputs["c"] end)

local MIN_SPEED, MAX_SPEED, SPEED_STEP = 5, 90, 5
local ACCELERATION, BRAKING, ARRIVAL_RADIUS = 16, 28, 2.8
local SPIN_RATE, STEER_SPIN, TURN_RATE, WOBBLE = .60, .25, math.rad(55), .028
local UPDATE = 1 / 30
local MAX_REPLICATION_RATE = 12 -- 155 proxies ~= 1,860 edits/sec
local MAX_WRITES_PER_SECOND = 1900
local REPLICATION_INTERVAL = 1 / MAX_REPLICATION_RATE
local MAX_SHELL_RADIUS = 70
local DROP_ACCELERATION, MAX_DROP_SPEED = 65, 75
local NAV_GUI = "TardisNavigationGui"
local RunService, Players, UserInputService = nil, nil, nil
pcall(function() RunService = game:GetService("RunService") end)
pcall(function() Players = game:GetService("Players") end)
pcall(function() UserInputService = game:GetService("UserInputService") end)
local player = nil
if Players then pcall(function() player = Players.LocalPlayer end) end

local root, rootWrapper = nil, nil
local exteriorProxies, exteriorOffsets, exteriorRawParts = {}, {}, {}
local dropping, dropVelocity, dropGroundY, initialFloorY = false, 0, nil, nil
local writerBusy, writerFault, writerEpoch = false, nil, 0
local landingCommitInProgress = false
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
local keyDown, target, speedLimit, desiredVelocity = {}, nil, 24, Vector3.zero
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

-- The controller's shell/sound/light/portal blocks remain independent
-- anchored UB entities. Collect their editable proxies, NEVER raw BaseParts.
local function proxyDisplayName(object)
    if not object then return nil end
    local function readName(key)
        local ok, v = pcall(function() return object[key] end)
        if ok and type(v) == "string" and v ~= "" then return v end
        ok, v = pcall(function() return object:GetAttribute(key) end)
        if ok and type(v) == "string" and v ~= "" then return v end
        ok, v = pcall(function() return object.attributes[key] end)
        if ok and type(v) == "string" and v ~= "" then return v end
        return nil
    end
    return readName("DisplayName") or readName("Display name")
end

local function prepareExteriorProxies(pivot)
    exteriorProxies, exteriorOffsets, exteriorRawParts = {}, {}, {}
    local seen = {}
    local shellCount, accessoryCount, unsafeCount = 0, 0, 0
    local function add(block, isShell)
        local ok, cf = pcall(function() return block.CFrame end)
        if not ok or typeof(cf) ~= "CFrame" then return end
        local raw = basePart(block) or block
        if seen[raw] then return end
        seen[raw] = true
        local anchoredOK, anchored = pcall(function() return block.Anchored end)
        if not anchoredOK or anchored ~= true then
            unsafeCount = unsafeCount + 1
            return
        end
        local offset = pivot:ToObjectSpace(cf)
        if isShell and offset.Position.Magnitude > MAX_SHELL_RADIUS then
            unsafeCount = unsafeCount + 1
            print("TARDIS V8: scattered shell at radius", offset.Position.Magnitude)
            return
        end
        table.insert(exteriorProxies, block)
        exteriorOffsets[block] = offset
        if raw then table.insert(exteriorRawParts, raw) end
        if isShell then shellCount = shellCount + 1
        else accessoryCount = accessoryCount + 1 end
    end
    -- Prefer the same editable objects used by the controller, not raw
    -- duplicates. A BasePart wrapper may otherwise be counted twice.
    local all = workspace:GetDescendants()
    for pass = 1, 2 do
        for _, block in ipairs(all) do
            local raw = basePart(block)
            local wrapper = raw and block ~= raw
            if (pass == 1 and wrapper) or (pass == 2 and not wrapper) then
                local name = proxyDisplayName(block)
                if type(name) == "string" then
                    name = string.lower(name:match("^%s*(.-)%s*$"))
                    if name == "tardis" then
                        add(block, true)
                    elseif name == "tardismatsound" or name == "tardislight"
                        or name == "tardisportal" then
                        add(block, false)
                    end
                end
            end
        end
    end
    local actualRate = math.min(MAX_REPLICATION_RATE, math.max(1,
        math.floor(MAX_WRITES_PER_SECOND / math.max(1, #exteriorProxies))))
    REPLICATION_INTERVAL = 1 / actualRate
    print("TARDIS V8 PROXY SCAN:", shellCount, "shell;",
        accessoryCount, "accessory;", unsafeCount, "unsafe;",
        #exteriorProxies, "total;", actualRate, "Hz")

    -- A partial shell is more dangerous than a flight that refuses to arm.
    if shellCount < 10 or unsafeCount > 0 then
        status("SHELL INCOMPLETE / RESTORE BUILD OR CHECK ANCHORS")
        return false
    end
    if not seen[root] then
        status("ROOT PROXY MISSING FROM V8 SHELL")
        return false
    end
    return true
end

-- Writes are sliced into short batches, rather than blocking one Heartbeat
-- with 155 proxy setter calls. Each burst uses ONE immutable pose snapshot;
-- the input/camera calculation keeps running while the edits are sent.
local function replicateExterior(pivot, now, force)
    if writerFault then return false end
    if not force and (writerBusy or now - lastReplicationWrite < REPLICATION_INTERVAL) then
        return true
    end
    if force and writerBusy then
        local waitStart = os.clock()
        while writerBusy and os.clock() - waitStart < 1.2 do
            task.wait(.02)
        end
        if writerBusy then
            writerFault = "prior network burst did not finish"
            return false
        end
    end
    lastReplicationWrite = now
    local epoch = writerEpoch
    local snapshot = pivot
    local function sendBurst()
        local wrote, failed, cancelled = 0, 0, false
        for i, proxy in ipairs(exteriorProxies) do
            if epoch ~= writerEpoch or attr(root, "TardisTransitioning") == true then
                cancelled = true
                break
            end
            local offset = exteriorOffsets[proxy]
            if offset then
                local ok, err = pcall(function()
                    proxy.CFrame = snapshot * offset
                end)
                if ok then
                    wrote = wrote + 1
                else
                    failed = failed + 1
                    if failed <= 3 and os.clock() - lastFailureLog > 1 then
                        lastFailureLog = os.clock()
                        print("TARDIS V8 PROXY WRITE ERROR:", tostring(err))
                    end
                end
            end
            -- Allow input, camera and the GUI to run between small chunks.
            if i % 24 == 0 then task.wait() end
        end
        if epoch ~= writerEpoch then
            -- Do not clear the busy flag of a NEW flight session.
            return
        end
        replicationWrites = replicationWrites + wrote
        replicationWriteFailures = replicationWriteFailures + failed
        lastSuccessfulWriteCount = wrote
        if failed > 0 or (not cancelled and wrote ~= #exteriorProxies) then
            writerFault = "only " .. tostring(wrote) .. "/"
                .. tostring(#exteriorProxies) .. " proxy edits accepted"
        end
        if os.clock() - lastProxySummary > 12 then
            lastProxySummary = os.clock()
            print("TARDIS V8 SYNC:", wrote, "/", #exteriorProxies,
                "writes; total errors", replicationWriteFailures)
        end
        writerBusy = false
    end
    writerBusy = true
    if force then
        sendBurst()
    else
        task.spawn(sendBurst)
    end
    return writerFault == nil
end

local function rigReady()
    if not root then return false, "controller rig not found" end
    if attr(root, "TardisRigMode") ~= "PROXY_V8" then
        return false, "matching V8 controller required; no client welds"
    end
    if attr(root, "TardisRigReady") ~= true then
        return false, tostring(attr(root, "TardisRigError") or "proxy rig incomplete")
    end
    if attr(root, "TardisTransitioning") == true then
        return false, "controller owns exterior during transition"
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

-- Find a safe scripted landing height. Raycasts exclude the entire exterior;
-- if the sandbox does not expose RaycastParams, fall back to the takeoff floor.
local function estimateGroundY(pose)
    local clearance = tonumber(attr(root, "TardisPilotGroundOffset")) or 7
    clearance = math.clamp(clearance - .8, 2, 24)
    local params = nil
    local setupOK = pcall(function()
        params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = exteriorRawParts
        params.IgnoreWater = true
    end)
    if setupOK and params then
        local hitOK, hit = pcall(function()
            return workspace:Raycast(
                pose.Position + Vector3.new(0, 25, 0),
                Vector3.new(0, -2000, 0), params
            )
        end)
        if hitOK and hit then
            local hitPosition = nil
            pcall(function() hitPosition = hit.Position end)
            if typeof(hitPosition) == "Vector3" then
                return math.min(pose.Position.Y,
                    hitPosition.Y + clearance)
            end
        end
    end
    return initialFloorY or pose.Position.Y
end

local function stopFlight(reason)
    -- Controller transitions and failed writes stop here. They do NOT
    -- unanchor or destroy any part of the restored exterior.
    flying, dropping, autopilot = false, false, false
    landingCommitInProgress = false
    writerEpoch = writerEpoch + 1
    desiredVelocity, keyDown = Vector3.zero, {}
    kinematicFallback, kinematicPose = false, nil
    output(outputA, false)
    if root then pcall(function() root:SetAttribute("TardisFlightActive", false) end) end
    restoreCamera()
    status(reason or "STOPPED / EXTERIOR HELD TOGETHER")
end

local function dropFlight(reason)
    if not flying and not dropping then return end
    if flying and (reason == "DROP / scripted descent" or reason == "TOGGLE DROP") then
        flying, dropping, autopilot = false, true, false
        desiredVelocity, keyDown = Vector3.zero, {}
        output(outputA, false)
        if root then pcall(function() root:SetAttribute("TardisFlightActive", false) end) end
        dropGroundY = estimateGroundY(kinematicPose)
        dropGroundY = math.min(dropGroundY, kinematicPose.Position.Y)
        dropVelocity = 0
        status("SCRIPTED GRAVITY DESCENT / SHELL STAYS TOGETHER")
        print("TARDIS V8 DESCENT TARGET:", dropGroundY)
    else
        stopFlight(reason)
    end
end

local function takeoff()
    if flying then return true end
    if dropping then status("WAIT FOR DESCENT TO FINISH"); return false end
    root, rootWrapper = findRoot()
    local ok, reason = rigReady()
    if not ok then status("CAN'T TAKE OFF: " .. tostring(reason)); return false end
    if not rootWrapper then status("NO EDITABLE UB ROOT PROXY"); return false end
    local readOK, initialPose = pcall(function() return rootWrapper.CFrame end)
    if not readOK or typeof(initialPose) ~= "CFrame" then
        status("ROOT PROXY CFRAME UNREADABLE")
        return false
    end
    if not prepareExteriorProxies(initialPose) then
        status("V8 EXTERIOR NOT SAFE / RESTORE BUILD")
        return false
    end
    -- Preflight uses the same replicated property path without moving anything.
    local writeOK, err = pcall(function() rootWrapper.CFrame = initialPose end)
    if not writeOK then
        status("UB ROOT WRITER FAILED: " .. tostring(err))
        return false
    end

    velocityFallback, kinematicFallback = false, true
    kinematicPose, kinematicStallChecks = initialPose, 0
    lastReplicationWrite, replicationWrites, replicationWriteFailures = 0, 0, 0
    lastSuccessfulWriteCount, lastProxySummary, lastFailureLog = 0, 0, 0
    writerFault, writerBusy, landingCommitInProgress = nil, false, false
    writerEpoch = writerEpoch + 1
    desiredVelocity = Vector3.zero
    initialFloorY = estimateGroundY(initialPose)
    local flat = Vector3.new(initialPose.LookVector.X, 0, initialPose.LookVector.Z)
    travelHeading = flat.Magnitude > .01 and flat.Unit or Vector3.new(0, 0, -1)
    lastCameraCheck = 0
    takeoffUntil = os.clock() + .9
    motionStart, motionPosition, stalledChecks = os.clock(), initialPose.Position, 0
    flying, autopilot, cameraEnabled = true, false, true
    pcall(function() root:SetAttribute("TardisFlightActive", true) end)
    engageCamera()
    output(outputA, true)
    print("TARDIS V8 ENGAGED:", #exteriorProxies,
        "independent replicated proxies / no physics welds")
    status("V8 FLIGHT / SHARED-PIVOT PROXY MOVEMENT")
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
            function() dropFlight("DROP / scripted descent") end)
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

local function typingIntoTextBox()
    if not UserInputService then return false end
    local ok, focused = pcall(function()
        return UserInputService:GetFocusedTextBox()
    end)
    return ok and focused ~= nil
end

local function held(key)
    if typingIntoTextBox() then return false end
    -- InputBegan may be marked processed by Roblox's normal character
    -- controls. Poll the physical key itself so W/S/Q/E still steer flight.
    if UserInputService then
        local ok, down = pcall(function()
            return UserInputService:IsKeyDown(key)
        end)
        if ok and type(down) == "boolean" then
            return down or keyDown[key] == true
        end
    end
    -- Older FIU versions might not expose IsKeyDown. The InputBegan/
    -- InputEnded fallback below still works even if processed is true.
    return keyDown[key] == true
end
local function approach(current, goal, maxStep)
    local diff = goal - current
    if diff.Magnitude <= maxStep then return goal end
    return current + diff.Unit * maxStep
end

-- Controlled fall: animated gravity, not Roblox physical gravity. Keeping
-- every block anchored is essential when the client welds do not replicate.
local function updateDrop(dt)
    if not dropping or not kinematicPose or landingCommitInProgress then return end
    if writerFault then stopFlight("DESCENT NETWORK ERROR: " .. writerFault); return end
    dt = math.clamp(dt or UPDATE, .002, .10)
    if attr(root, "TardisTransitioning") == true then
        stopFlight("CONTROLLER HANDOFF")
        return
    end
    local previousPose = kinematicPose
    local fromY = previousPose.Position.Y
    local landing = dropGroundY or initialFloorY or fromY
    dropVelocity = math.min(MAX_DROP_SPEED, dropVelocity + DROP_ACCELERATION * dt)
    local nextY = math.max(landing, fromY - dropVelocity * dt)
    local rotation = previousPose - previousPose.Position
    kinematicPose = CFrame.new(previousPose.Position.X, nextY,
        previousPose.Position.Z) * rotation
    local landingReached = nextY <= landing + 0.001
    if landingReached then landingCommitInProgress = true end
    if not replicateExterior(kinematicPose, os.clock(), landingReached) then
        stopFlight("DESCENT PROXY WRITE FAILED / HOLD")
        return
    end
    output(outputC, kinematicPose)
    if outputB then output(outputB, kinematicPose.Position) end
    if cameraEnabled then updateCamera() end
    if landingReached then
        -- Final synchronized position before ending the follow camera.
        dropping = false
        landingCommitInProgress = false
        status("LANDED / EXTERIOR SAFELY ANCHORED")
        restoreCamera()
        kinematicFallback, kinematicPose = false, nil
        print("TARDIS V8 LANDING: all", #exteriorProxies,
            "independent shell proxies remained intact")
    end
end

local function updatePhysics(dt)
    if dropping then
        updateDrop(dt)
        return
    end
    if not flying or not root then return end
    if writerFault then stopFlight("FLIGHT NETWORK ERROR: " .. writerFault); return end
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
    -- Integrate ONE commanded pose, then write all independent UB proxies
    -- from their saved offsets. There are no physical welds or raw CFrame
    -- preview writes to fight these authoritative edits.
    if not kinematicPose then
        stopFlight("MISSING FLIGHT POSE")
        return
    end
    local orientation = kinematicPose - kinematicPose.Position
    local yaw = CFrame.Angles(0, rotation.Y * dt, 0)
    local wobble = CFrame.Angles(rotation.X * dt, 0, rotation.Z * dt)
    orientation = yaw * orientation * wobble
    kinematicPose = CFrame.new(
        kinematicPose.Position + desiredVelocity * dt
    ) * orientation
    if attr(root, "TardisTransitioning") == true then
        stopFlight("CONTROLLER HANDOFF")
        return
    end
    if not replicateExterior(kinematicPose, now, false) then
        stopFlight("PARTIAL PROXY WRITE / HOLD EXTERIOR")
        return
    end
    output(outputC, kinematicPose)

    -- Actual editor writes are counted separately from local interpolation.
    if now - motionStart >= 10 then
        print("TARDIS V8 STATUS:",
            "parts", #exteriorProxies,
            "speed", math.floor(desiredVelocity.Magnitude + .5),
            "edits", replicationWrites,
            "errors", replicationWriteFailures)
        motionStart = now
    end
    if outputB and now - lastPositionWrite >= .12 then
        lastPositionWrite = now
        output(outputB, kinematicPose.Position)
    end

    -- Update the follow subject on the physics tick, independently from
    -- Roblox's native render-frame orbit and scroll-wheel zoom.
    if cameraEnabled then updateCamera() end
end

updateCamera = function(dt)
    if not (flying or dropping) or not cameraEnabled or not root then return end
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
        if not (flying or dropping) then return end
        local key = input.KeyCode
        -- Roblox may consume WASD for regular player movement and set
        -- processed=true. Keep those keys for the flight fallback unless
        -- the pilot is actually typing in a TextBox.
        if key == Enum.KeyCode.W or key == Enum.KeyCode.A
            or key == Enum.KeyCode.S or key == Enum.KeyCode.D
            or key == Enum.KeyCode.Q or key == Enum.KeyCode.E
            or key == Enum.KeyCode.Space or key == Enum.KeyCode.LeftShift
            or key == Enum.KeyCode.RightShift then
            if not typingIntoTextBox() then keyDown[key] = true end
            return
        end
        if processed then return end
        if key == Enum.KeyCode.X or key == Enum.KeyCode.Escape then
            dropFlight("DROP / scripted descent")
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
        if (flying or dropping) and cameraMode == "ORBIT" and not navigationOpen()
            and input.UserInputType == Enum.UserInputType.MouseButton2 then
            orbitDragging = true
        end
    end)
    UserInputService.InputChanged:Connect(function(input, processed)
        if not (flying or dropping) or not cameraEnabled or cameraMode ~= "ORBIT"
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

-- Best-effort emergency unanchor if FIU exposes the Destroying signal.
-- Still press DROP before manually stopping the Code Block.
pcall(function()
    script.Destroying:Connect(function()
        if flying or dropping then stopFlight("FLIGHT BLOCK DESTROYED") end
    end)
end)

output(outputA, false)
buildGUI()
print("TARDIS FLIGHT 8.0 READY / stable independent proxies / scripted descent")
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

    if (flying or dropping) and (not heartbeatConnection or now - lastHeartbeat > .6) then
        updatePhysics(dt)
    end
    -- Refresh proxy even if the FIU Heartbeat callback stalls; Roblox's
    -- default CameraModule handles every rendered camera frame itself.
    if (flying or dropping) and cameraEnabled and
        (cameraMode ~= "ORBIT" or now - lastOrbitRender > .15) then
        updateCamera(dt)
    end
    task.wait(UPDATE)
end
