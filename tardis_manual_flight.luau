-- TARDIS FLIGHT 4.1 | Ultimate Build FIU
-- Standalone physics flight with a SMALL, STATIC destination/control GUI.
-- No per-frame GUI updates; never animates individual shell CFrames.
-- Requires the matching controller's unanchored welded exterior.
--
-- Input A: optional TRUE pulse to take off / drop.
-- Input B: optional Vector3, CFrame or "x,y,z" autopilot destination.
-- Input C: optional TRUE pulse to toggle autopilot.
-- Input D: optional number speed limit, 10-265.
-- Output A: active boolean. Output B: actual root world Vector3.
--
-- GUI: TAKEOFF / GO / HOVER / DROP / +/- speed, X Y Z target fields.
-- Keyboard W/S: thrust, A/D: steer, Q/E: up/down, Shift: boost,
-- Space: hover, +/-: speed, G: autopilot, V: camera, X: drop.
-- Box spins with gentle wobble independently of travel heading.
-- On DROP, propulsion turns off; gravity takes over, never anchors box.

local inputA, inputB, inputC, inputD = nil, nil, nil, nil
local outputA, outputB = nil, nil
pcall(function() inputA = script.inputs["a"] end)
pcall(function() inputB = script.inputs["b"] end)
pcall(function() inputC = script.inputs["c"] end)
pcall(function() inputD = script.inputs["d"] end)
pcall(function() outputA = script.outputs["a"] end)
pcall(function() outputB = script.outputs["b"] end)

local MIN_SPEED, MAX_SPEED, SPEED_STEP = 10, 265, 10
local ACCELERATION, BRAKING, ARRIVAL_RADIUS = 55, 105, 2.8
local SPIN_RATE, STEER_SPIN, TURN_RATE, WOBBLE = 0.9, 0.4, math.rad(70), 0.11
local UPDATE = 1 / 30
local NAV_GUI = "TardisNavigationGui"
local RunService, Players, UserInputService = nil, nil, nil
pcall(function() RunService = game:GetService("RunService") end)
pcall(function() Players = game:GetService("Players") end)
pcall(function() UserInputService = game:GetService("UserInputService") end)
local player = nil
if Players then pcall(function() player = Players.LocalPlayer end) end

local root, attachment, linear, angular = nil, nil, nil, nil
local flying, autopilot, velocityFallback = false, false, false
local cameraEnabled, savedCamera, cameraPose, cameraHeading = true, nil, nil, nil
local keyDown, target, speedLimit, desiredVelocity = {}, nil, 80, Vector3.zero
local travelHeading = Vector3.new(0, 0, -1)
local previousTarget, previousSpeed = nil, nil
local guiTargetLocked = false
local lastInputA, lastInputC = false, false
local lastTargetRead, lastPositionWrite, lastGuard, lastHeartbeat = 0, 0, 0, 0
local takeoffUntil, lastTick = 0, os.clock()
local motionStart, motionPosition, stalledChecks = 0, nil, 0
local heartbeatConnection, renderConnection = nil, nil
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
    for _, object in ipairs(workspace:GetDescendants()) do
        local part = basePart(object)
        if part and attr(part, "TardisRigRoot") == true then return part end
    end
    return nil
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

local function restoreCamera()
    if not savedCamera then return end
    local cam = camera()
    if cam then pcall(function()
        if savedCamera.subject then cam.CameraSubject = savedCamera.subject end
        if savedCamera.fov then cam.FieldOfView = savedCamera.fov end
        cam.CameraType = savedCamera.kind or Enum.CameraType.Custom
    end) end
    savedCamera, cameraPose = nil, nil
end

local function engageCamera()
    local cam = camera()
    if not cam then return end
    if not savedCamera then
        pcall(function()
            savedCamera = {
                kind = cam.CameraType,
                subject = cam.CameraSubject,
                fov = cam.FieldOfView,
            }
        end)
    end
    pcall(function()
        cam.CameraType = Enum.CameraType.Scriptable
        cam.FieldOfView = 70
    end)
end

local function dropFlight(reason)
    if not flying then return end
    flying, autopilot = false, false
    desiredVelocity, keyDown = Vector3.zero, {}
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
    root = findRoot()
    local ok, reason = rigReady()
    if not ok then
        status("CAN'T TAKE OFF: " .. tostring(reason))
        return false
    end

    velocityFallback = not buildMotors()
    desiredVelocity = Vector3.zero
    local look = root.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    travelHeading = flat.Magnitude > .01 and flat.Unit or Vector3.new(0, 0, -1)
    cameraHeading = travelHeading
    takeoffUntil = os.clock() + .8
    motionStart, motionPosition, stalledChecks = os.clock(), root.Position, 0
    flying, autopilot, cameraEnabled = true, false, true
    pcall(function() root:SetAttribute("TardisFlightActive", true) end)
    engageCamera()
    if not velocityFallback then
        local enabled, err = pcall(function()
            linear.VectorVelocity = Vector3.new(0, 20, 0)
            angular.AngularVelocity = Vector3.new(0, SPIN_RATE, 0)
            linear.Enabled = true
            angular.Enabled = true
        end)
        if not enabled then
            print("TARDIS MOTOR ENABLE FAILED:", tostring(err))
            velocityFallback = true
            disableMotors()
        end
    end
    output(outputA, true)
    print("TARDIS PHYSICS START:", "mass", tostring(root.AssemblyMass),
        "anchored", tostring(root.Anchored),
        "mode", velocityFallback and "direct velocity" or "constraints")
    status("ENGAGED / " .. (velocityFallback and "velocity" or "motors"))
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
            previousTarget = p
            if not guiTargetLocked then target = p end
            guiTargetLocked = false
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
    guiTargetLocked = true
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
        local delta = target - root.Position
        local distance = delta.Magnitude
        if distance < ARRIVAL_RADIUS and root.AssemblyLinearVelocity.Magnitude < 4 then
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
    if not velocityFallback then
        local ok, err = pcall(function()
            linear.VectorVelocity = desiredVelocity
            angular.AngularVelocity = rotation
        end)
        if not ok then
            print("TARDIS MOTOR UPDATE ERROR:", tostring(err))
            disableMotors()
            velocityFallback = true
            status("MOTOR UPDATE FAILED / direct velocity")
        end
    end
    if velocityFallback then
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

    -- Do not confuse successfully setting a motor with actually moving.
    if now - motionStart >= 1.3 and motionPosition then
        local actualDistance = (root.Position - motionPosition).Magnitude
        if desiredVelocity.Magnitude > 8 and actualDistance < .35 then
            stalledChecks = stalledChecks + 1
            if not velocityFallback then
                velocityFallback = true
                disableMotors()
                status("CONSTRAINTS STALLED / trying direct velocity")
            elseif stalledChecks >= 2 then
                status("NOT MOVING / joints or physics authority")
            end
        else
            stalledChecks = 0
        end
        print("TARDIS MOTION CHECK:", "moved", actualDistance,
            "requested", desiredVelocity.Magnitude,
            "actual", root.AssemblyLinearVelocity.Magnitude,
            "mass", tostring(root.AssemblyMass),
            "direct", tostring(velocityFallback))
        motionStart, motionPosition = now, root.Position
    end
    if outputB and now - lastPositionWrite >= .1 then
        lastPositionWrite = now
        output(outputB, root.Position)
    end
end

local function updateCamera(dt)
    if not flying or not cameraEnabled or navigationOpen() then return end
    local cam = camera()
    if not cam or not root then return end
    local cf = root.CFrame
    local velocity = root.AssemblyLinearVelocity
    if not cameraHeading then cameraHeading = cf.LookVector end
    if velocity.Magnitude > 8 then
        local v = cameraHeading:Lerp(velocity.Unit,
            1 - math.exp(-3 * math.clamp(dt or UPDATE, 0, .1)))
        if v.Magnitude > .01 then cameraHeading = v.Unit end
    end
    local desired = CFrame.lookAt(
        cf.Position - cameraHeading * 24 + Vector3.new(0, 11, 0),
        cf.Position + Vector3.new(0, 2, 0)
    )
    local alpha = 1 - math.exp(-8 * math.clamp(dt or UPDATE, 0, .1))
    cameraPose = cameraPose and cameraPose:Lerp(desired, alpha) or desired
    pcall(function()
        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame = cameraPose
        cam.FieldOfView = 70 + math.min(12, velocity.Magnitude / 22)
    end)
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
            updateCamera(dt)
        end)
    end)
    if renderOK then renderConnection = renderConn end
end

output(outputA, false)
buildGUI()
print("TARDIS FLIGHT 4.1 READY / compact coordinate GUI / actual motion diagnostics")
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
    if flying and not renderConnection then updateCamera(dt) end
    task.wait(UPDATE)
end
