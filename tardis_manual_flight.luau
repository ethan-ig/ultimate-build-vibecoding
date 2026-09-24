-- TARDIS MANUAL FLIGHT / standalone Ultimate Build FIU Code Block
-- Input A: pulse TRUE to enter / leave flight mode.
-- Output A (optional): TRUE while manually flying, FALSE otherwise.
-- Output B (optional): live world Vector3 of the exterior pivot.
--
-- W/S        forward / reverse thrust
-- A/D        yaw left / right
-- Q/E        descend / ascend
-- Up/Down    pitch up / down
-- Z/C        manual roll left / right
-- Shift      boost
-- Space      airbrake / hover
-- V          switch chase / wide camera
-- X or Esc   disengage and restore camera
--
-- The original controller and navigation code do NOT need to be edited.
-- Keep the exterior materialized before engaging. Flight relinquishes the
-- exterior on sound playback, fade, hidden staging, external teleport, or
-- navigation GUI activation. It never moves the interior or time rotor.
-- Note: CFrame flight is kinematic; optional raycast only prevents direct
-- forward penetration, not full physical body collisions.

local toggleInput = script.inputs["a"]
local activeOutput, positionOutput = nil, nil
pcall(function() activeOutput = script.outputs["a"] end)
pcall(function() positionOutput = script.outputs["b"] end)

local SHELL_NAME = "tardis"
local PORTAL_NAME = "tardisportal"
local SOUND_NAME = "tardismatsound"
local LIGHT_NAME = "tardislight"
local NAV_GUI_NAME = "TardisNavigationGui"
local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local HIDDEN_RADIUS = 100

local TICK = 1 / 60
local ACCELERATION = 60
local VERTICAL_ACCELERATION = 48
local REVERSE_ACCELERATION = 37
local BOOST_MULTIPLIER = 2.3
local MAX_SPEED = 125
local MAX_BOOST_SPEED = 265
local DRAG = 0.85
local BRAKE_DRAG = 7.5
local TURN_RATE = math.rad(68)
local PITCH_RATE = math.rad(40)
local MAX_PITCH = math.rad(50)
local BANK_ANGLE = math.rad(18)
local ROLL_ANGLE = math.rad(22)
local VISUAL_SMOOTHNESS = 5
local CAMERA_SMOOTHNESS = 5.5
local COLLISION_MARGIN = 3

local Players = nil
local UserInputService = nil
local player = nil
pcall(function() Players = game:GetService("Players") end)
pcall(function() UserInputService = game:GetService("UserInputService") end)
if Players then pcall(function() player = Players.LocalPlayer end) end

local function getValue(block, key)
    if not block then return nil end
    local ok, value = pcall(function() return block[key] end)
    if ok and value ~= nil then return value end
    ok, value = pcall(function() return block:GetAttribute(key) end)
    if ok and value ~= nil then return value end
    ok, value = pcall(function() return block.attributes[key] end)
    if ok then return value end
    return nil
end

local function setValue(block, key, value)
    if not block then return false end
    local ok = pcall(function() block[key] = value end)
    if ok then return true end
    ok = pcall(function() block:SetAttribute(key, value) end)
    if ok then return true end
    ok = pcall(function() block.attributes[key] = value end)
    return ok
end

local function blockName(block)
    local name = getValue(block, "DisplayName")
    if type(name) == "string" and name ~= "" then return string.lower(name) end
    local raw = getValue(block, "Part")
    if raw then
        local rawName = nil
        pcall(function() rawName = raw.Name end)
        if type(rawName) == "string" then return string.lower(rawName) end
    end
    return ""
end

local function rawPart(block)
    if not block then return nil end
    local raw = nil
    pcall(function() raw = block.Part end)
    if raw then return raw end
    if typeof(block) == "Instance" then return block end
    return nil
end

local function getCF(block)
    if not block then return nil end
    local cf = nil
    pcall(function() cf = block.CFrame end)
    if cf then return cf end
    local raw = rawPart(block)
    if raw then pcall(function() cf = raw.CFrame end) end
    return cf
end

local function getCamera()
    local camera = nil
    pcall(function() camera = workspace.CurrentCamera end)
    return camera
end

local shell, extras, offsets, rawSafeguards = {}, {}, {}, {}
local matSound, portal, roofLight = nil, nil, nil
local primary = nil
local pivot, baseRotation = nil, nil
local position = nil
local velocity = Vector3.new(0, 0, 0)
local yaw, pitch, visualRoll = 0, 0, 0
local flightActive, viewMode = false, "CHASE"
local savedCamera = nil
local deferredCameraRestore = false
local savedLampBrightness = nil
local lastVisualPosition = nil
local keyDown = {}
local lastToggle = false
local lastTick = os.clock()
local lastHudUpdate, lastPositionOutput = 0, 0
local collisionWarningUntil = 0
local fxAttachmentA, fxAttachmentB, fxTrail = nil, nil, nil

local gui, speedText, telemetryText, statusText = nil, nil, nil, nil
local boostBar, cameraText, controlText = nil, nil, nil

local function signalActive(value)
    if activeOutput then pcall(function() activeOutput:SetState(value) end) end
end

local function hasNavGui()
    if not player then return false end
    local found = nil
    pcall(function()
        local playerGui = player:FindFirstChildOfClass("PlayerGui")
        if playerGui then found = playerGui:FindFirstChild(NAV_GUI_NAME) end
    end)
    return found ~= nil
end

local function scanExterior()
    shell, extras, offsets, rawSafeguards = {}, {}, {}, {}
    matSound, portal, roofLight = nil, nil, nil
    primary = nil

    local descendants = workspace:GetDescendants(true)
    for _, block in ipairs(descendants) do
        if block ~= script then
            local name = blockName(block)
            if name == SHELL_NAME then
                if getCF(block) then table.insert(shell, block) end
            elseif name == SOUND_NAME and not matSound then
                matSound = block
            elseif name == LIGHT_NAME and not roofLight then
                roofLight = block
            elseif name == PORTAL_NAME and not portal then
                portal = block
            end
        end
    end

    primary = shell[1]
    if not primary then return false end

    pivot = getCF(primary)
    if not pivot then return false end

    for _, block in ipairs(shell) do table.insert(extras, block) end
    for _, block in ipairs({matSound, roofLight, portal}) do
        if block and getCF(block) then table.insert(extras, block) end
    end
    for _, block in ipairs(extras) do
        offsets[block] = pivot:ToObjectSpace(getCF(block))
    end

    -- Some FIU wrappers move their CFrame without moving the actual Sound
    -- emitter or portal Part. Mirror the controller's raw-Part safeguards.
    for _, block in ipairs({matSound, portal}) do
        local raw = rawPart(block)
        if raw and raw ~= block then
            local rawCF = nil
            pcall(function() rawCF = raw.CFrame end)
            if rawCF then
                table.insert(rawSafeguards, {
                    part = raw,
                    offset = pivot:ToObjectSpace(rawCF),
                })
            end
        end
    end

    return true
end

local function isHidden(cf)
    return not cf or (cf.Position - HIDDEN_POSITION).Magnitude < HIDDEN_RADIUS
end

local function transitionSoundPlaying()
    if not matSound then return false end
    local raw = rawPart(matSound)
    if raw then
        local sound = nil
        pcall(function() sound = raw:FindFirstChildWhichIsA("Sound", true) end)
        if sound then
            local playing = false
            pcall(function() playing = sound.IsPlaying == true end)
            return playing
        end
    end
    return getValue(matSound, "IsPlaying") == true
end

local function fullyMaterialized()
    local cf = getCF(primary)
    if isHidden(cf) then return false end
    if transitionSoundPlaying() then return false end
    for _, block in ipairs(shell) do
        local transparency = tonumber(getValue(block, "Transparency"))
        if transparency and transparency > 0.04 then return false end
    end
    return true
end

local function placeExterior(cf)
    for _, block in ipairs(extras) do
        local offset = offsets[block]
        if offset then pcall(function() block.CFrame = cf * offset end) end
    end
    for _, entry in ipairs(rawSafeguards) do
        pcall(function() entry.part.CFrame = cf * entry.offset end)
    end
    -- Flight must never expose the invisible teleport portal.
    if portal then
        setValue(portal, "Transparency", 1)
        local raw = rawPart(portal)
        if raw then pcall(function() raw.Transparency = 1 end) end
    end
end

local function restoreLamp()
    if roofLight and savedLampBrightness then
        setValue(roofLight, "Brightness", savedLampBrightness)
    end
    savedLampBrightness = nil
end

local function removeFX()
    for _, item in ipairs({fxTrail, fxAttachmentA, fxAttachmentB}) do
        if item then pcall(function() item:Destroy() end) end
    end
    fxTrail, fxAttachmentA, fxAttachmentB = nil, nil, nil
end

local function createFX()
    removeFX()
    local raw = rawPart(primary)
    if not raw then return end
    pcall(function()
        local size = raw.Size
        local a = Instance.new("Attachment")
        a.Name = "TardisFlightTrailLeft"
        a.Position = Vector3.new(-size.X * 0.35, -size.Y * 0.25, size.Z * 0.3)
        a.Parent = raw
        local b = Instance.new("Attachment")
        b.Name = "TardisFlightTrailRight"
        b.Position = Vector3.new(size.X * 0.35, -size.Y * 0.25, size.Z * 0.3)
        b.Parent = raw
        local trail = Instance.new("Trail")
        trail.Name = "TardisFlightBoostTrail"
        trail.Attachment0 = a
        trail.Attachment1 = b
        trail.Color = ColorSequence.new(
            Color3.fromRGB(70, 215, 255),
            Color3.fromRGB(116, 71, 255)
        )
        trail.LightEmission = 1
        trail.Lifetime = 0.34
        trail.MinLength = 0.1
        trail.Enabled = false
        trail.Parent = raw
        fxAttachmentA, fxAttachmentB, fxTrail = a, b, trail
    end)
end

local function roundCorner(parent, pixels)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, pixels)
    corner.Parent = parent
end

local function panel(parent, pos, size, anchor)
    local frame = Instance.new("Frame")
    frame.AnchorPoint = anchor or Vector2.new(0, 0)
    frame.Position = pos
    frame.Size = size
    frame.BackgroundColor3 = Color3.fromRGB(9, 17, 31)
    frame.BackgroundTransparency = 0.12
    frame.BorderSizePixel = 0
    frame.Parent = parent
    roundCorner(frame, 12)
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(45, 135, 186)
    stroke.Transparency = 0.22
    stroke.Thickness = 1
    stroke.Parent = frame
    return frame
end

local function label(parent, text, pos, size, fontSize, color, font)
    local item = Instance.new("TextLabel")
    item.BackgroundTransparency = 1
    item.Position = pos
    item.Size = size
    item.Font = font or Enum.Font.Code
    item.TextSize = fontSize
    item.TextColor3 = color or Color3.fromRGB(220, 240, 255)
    item.TextXAlignment = Enum.TextXAlignment.Left
    item.TextYAlignment = Enum.TextYAlignment.Center
    item.Text = text
    item.Parent = parent
    return item
end

local function destroyGUI()
    if gui then pcall(function() gui:Destroy() end) end
    gui, speedText, telemetryText, statusText = nil, nil, nil, nil
    boostBar, cameraText, controlText = nil, nil, nil
end

local function buildGUI()
    destroyGUI()
    if not player then return end
    local ok, err = pcall(function()
        local playerGui = player:FindFirstChildOfClass("PlayerGui")
            or player:FindFirstChild("PlayerGui")
        if not playerGui then return end

        local root = Instance.new("ScreenGui")
        root.Name = "TardisManualFlightGui"
        root.IgnoreGuiInset = true
        root.ResetOnSpawn = false
        root.DisplayOrder = 900
        root.Parent = playerGui
        gui = root

        local left = panel(root, UDim2.new(0, 22, 0, 22), UDim2.new(0, 325, 0, 193))
        label(left, "TYPE 40  /  MANUAL FLIGHT", UDim2.new(0, 16, 0, 10),
            UDim2.new(1, -32, 0, 25), 17, Color3.fromRGB(109, 231, 255), Enum.Font.GothamBold)
        label(left, "VELOCITY", UDim2.new(0, 16, 0, 40),
            UDim2.new(0, 150, 0, 20), 11, Color3.fromRGB(147, 174, 197))
        speedText = label(left, "000", UDim2.new(0, 16, 0, 55),
            UDim2.new(0, 175, 0, 58), 46, Color3.fromRGB(245, 252, 255), Enum.Font.GothamBold)
        label(left, "STUDS / SEC", UDim2.new(0, 179, 0, 75),
            UDim2.new(0, 130, 0, 20), 12, Color3.fromRGB(147, 174, 197))
        label(left, "THRUST / FIELD OUTPUT", UDim2.new(0, 16, 0, 118),
            UDim2.new(1, -32, 0, 17), 11, Color3.fromRGB(147, 174, 197))
        local track = Instance.new("Frame")
        track.Position = UDim2.new(0, 16, 0, 142)
        track.Size = UDim2.new(1, -32, 0, 9)
        track.BackgroundColor3 = Color3.fromRGB(32, 54, 79)
        track.BorderSizePixel = 0
        track.Parent = left
        roundCorner(track, 5)
        boostBar = Instance.new("Frame")
        boostBar.Size = UDim2.new(0, 0, 1, 0)
        boostBar.BackgroundColor3 = Color3.fromRGB(75, 227, 248)
        boostBar.BorderSizePixel = 0
        boostBar.Parent = track
        roundCorner(boostBar, 5)
        statusText = label(left, "●  READY", UDim2.new(0, 16, 0, 160),
            UDim2.new(1, -32, 0, 22), 13, Color3.fromRGB(121, 239, 205))

        local right = panel(root, UDim2.new(1, -22, 0, 22),
            UDim2.new(0, 305, 0, 170), Vector2.new(1, 0))
        label(right, "TELEMETRY  //  LIVE", UDim2.new(0, 16, 0, 10),
            UDim2.new(1, -32, 0, 27), 15, Color3.fromRGB(109, 231, 255), Enum.Font.GothamBold)
        telemetryText = label(right, "ACQUIRING POSITION", UDim2.new(0, 16, 0, 43),
            UDim2.new(1, -32, 0, 87), 14, Color3.fromRGB(215, 239, 255))
        telemetryText.TextYAlignment = Enum.TextYAlignment.Top
        cameraText = label(right, "CAM  /  CHASE", UDim2.new(0, 16, 0, 137),
            UDim2.new(1, -32, 0, 20), 12, Color3.fromRGB(125, 202, 225))

        local crossColor = Color3.fromRGB(120, 226, 251)
        for _, entry in ipairs({
            {UDim2.new(0.5, -1, 0.5, -23), UDim2.new(0, 2, 0, 12)},
            {UDim2.new(0.5, -1, 0.5, 11), UDim2.new(0, 2, 0, 12)},
            {UDim2.new(0.5, -23, 0.5, -1), UDim2.new(0, 12, 0, 2)},
            {UDim2.new(0.5, 11, 0.5, -1), UDim2.new(0, 12, 0, 2)},
        }) do
            local mark = Instance.new("Frame")
            mark.Position, mark.Size = entry[1], entry[2]
            mark.BorderSizePixel = 0
            mark.BackgroundColor3 = crossColor
            mark.BackgroundTransparency = 0.20
            mark.Parent = root
        end

        local footer = panel(root, UDim2.new(0.5, 0, 1, -24),
            UDim2.new(0, 750, 0, 66), Vector2.new(0.5, 1))
        controlText = label(footer,
            "W/S  THRUST    A/D  TURN    Q/E  LIFT    ↑/↓  PITCH    Z/C  ROLL",
            UDim2.new(0, 16, 0, 8), UDim2.new(1, -32, 0, 22),
            14, Color3.fromRGB(215, 239, 255))
        label(footer, "SHIFT  BOOST     SPACE  BRAKE     V  CAMERA     X / ESC  EXIT",
            UDim2.new(0, 16, 0, 33), UDim2.new(1, -32, 0, 23),
            13, Color3.fromRGB(116, 211, 235))
    end)
    if not ok then
        print("TARDIS FLIGHT HUD unavailable:", err)
        destroyGUI()
    end
end

local function restoreCamera()
    if not savedCamera then return end
    local camera = getCamera()
    if camera then
        local old = savedCamera
        pcall(function()
            if old.cf then camera.CFrame = old.cf end
            if old.subject then camera.CameraSubject = old.subject end
            if old.fov then camera.FieldOfView = old.fov end
            camera.CameraType = old.kind or Enum.CameraType.Custom
        end)
    end
    savedCamera = nil
    deferredCameraRestore = false
end

local function stopFlight(reason, deferCamera, controllerOwnsLamp)
    if not flightActive then return end
    flightActive = false
    keyDown = {}
    signalActive(false)
    if fxTrail then pcall(function() fxTrail.Enabled = false end) end
    removeFX()
    destroyGUI()
    if controllerOwnsLamp then
        savedLampBrightness = nil
    else
        restoreLamp()
    end
    if deferCamera then
        -- Navigation has already captured our flight camera; let it finish,
        -- then restore the original camera after its GUI disappears.
        deferredCameraRestore = true
    else
        restoreCamera()
    end
    print("TARDIS FLIGHT:", reason or "DISENGAGED")
end

local function startFlight()
    if flightActive then return end
    if deferredCameraRestore or hasNavGui() then
        print("TARDIS FLIGHT: navigation owns the camera")
        return
    end
    if not scanExterior() then
        print("TARDIS FLIGHT: no named exterior Tardis parts found")
        return
    end
    if not fullyMaterialized() then
        print("TARDIS FLIGHT: materialize exterior and finish audio first")
        return
    end

    local camera = getCamera()
    if not camera then
        print("TARDIS FLIGHT: camera unavailable")
        return
    end
    savedCamera = {}
    pcall(function()
        savedCamera.kind = camera.CameraType
        savedCamera.cf = camera.CFrame
        savedCamera.subject = camera.CameraSubject
        savedCamera.fov = camera.FieldOfView
        camera.CameraType = Enum.CameraType.Scriptable
        camera.FieldOfView = 68
    end)

    position = pivot.Position
    baseRotation = pivot - pivot.Position
    velocity = Vector3.new(0, 0, 0)
    yaw, pitch, visualRoll = 0, 0, 0
    lastVisualPosition = position
    viewMode = "CHASE"
    savedLampBrightness = tonumber(getValue(roofLight, "Brightness"))
    keyDown = {}
    flightActive = true
    signalActive(true)
    createFX()
    buildGUI()
    print("TARDIS FLIGHT: ENGAGED // W/S thrust, A/D yaw, Q/E lift, arrows pitch")
end

local function pressed(key)
    return keyDown[key] == true
end

local function updateHUD(now, speed, maxSpeed, boosting, grounded, heading)
    if now - lastHudUpdate < 0.075 then return end
    lastHudUpdate = now
    local p = position
    local compass = (math.deg(math.atan2(-heading.LookVector.X, -heading.LookVector.Z)) + 360) % 360
    pcall(function()
        if speedText then speedText.Text = string.format("%03d", math.floor(speed + 0.5)) end
        if boostBar then boostBar.Size = UDim2.new(math.clamp(speed / maxSpeed, 0, 1), 0, 1, 0) end
        if telemetryText then
            telemetryText.Text = string.format(
                "X  %9.1f\nY  %9.1f\nZ  %9.1f\nHDG  %03.0f°   PITCH %+03.0f°",
                p.X, p.Y, p.Z, compass, math.deg(pitch)
            )
        end
        if statusText then
            if grounded then
                statusText.Text = "●  PROXIMITY ALERT / BRAKING"
                statusText.TextColor3 = Color3.fromRGB(255, 187, 101)
            elseif boosting then
                statusText.Text = "●  VORTEX BOOST ACTIVE"
                statusText.TextColor3 = Color3.fromRGB(185, 138, 255)
            else
                statusText.Text = "●  MANUAL CONTROL ONLINE"
                statusText.TextColor3 = Color3.fromRGB(121, 239, 205)
            end
        end
        if cameraText then cameraText.Text = "CAM  /  " .. viewMode end
    end)
end

local function makeCollisionParams()
    local params = nil
    pcall(function()
        params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        pcall(function() params.RespectCanCollide = true end)
        local exclude = {}
        local seen = {}
        for _, block in ipairs(extras) do
            local raw = rawPart(block)
            if raw and not seen[raw] then
                seen[raw] = true
                table.insert(exclude, raw)
            end
        end
        if player then
            local character = player.Character
            if character then table.insert(exclude, character) end
        end
        params.FilterDescendantsInstances = exclude
    end)
    return params
end

local collisionParams = nil

local function updateCamera(cf, speed, boosting, dt)
    local camera = getCamera()
    if not camera then return end
    local forward, up = cf.LookVector, cf.UpVector
    local wide = viewMode == "WIDE"
    local distance = wide and 35 or 19
    local height = wide and 15 or 8
    local target = cf.Position + forward * (wide and 11 or 6) + Vector3.new(0, 2, 0)
    local desiredPosition = cf.Position - forward * distance
        + up * height - velocity * (wide and 0.075 or 0.035)
    local desired = CFrame.lookAt(desiredPosition, target)
        * CFrame.Angles(0, 0, -visualRoll * 0.20)
    local alpha = 1 - math.exp(-CAMERA_SMOOTHNESS * dt)
    local desiredFOV = (wide and 62 or 69)
        + 12 * math.clamp(speed / MAX_BOOST_SPEED, 0, 1)
        + (boosting and 5 or 0)
    pcall(function()
        camera.CameraType = Enum.CameraType.Scriptable
        camera.CFrame = camera.CFrame:Lerp(desired, alpha)
        camera.FieldOfView = camera.FieldOfView
            + (desiredFOV - camera.FieldOfView) * alpha
    end)
end

local function updateFlight(now, dt)
    if hasNavGui() then
        stopFlight("NAVIGATION HANDOFF", true, false)
        return
    end
    if not fullyMaterialized() then
        stopFlight("CONTROLLER / TRANSITION HANDOFF", false, true)
        return
    end

    local actual = getCF(primary)
    if not actual or (actual.Position - lastVisualPosition).Magnitude > 8 then
        stopFlight("EXTERIOR MOVED BY ANOTHER CONTROLLER", false, true)
        return
    end

    local forwardInput = (pressed(Enum.KeyCode.W) and 1 or 0)
        - (pressed(Enum.KeyCode.S) and 1 or 0)
    local turnInput = (pressed(Enum.KeyCode.D) and 1 or 0)
        - (pressed(Enum.KeyCode.A) and 1 or 0)
    local liftInput = (pressed(Enum.KeyCode.E) and 1 or 0)
        - (pressed(Enum.KeyCode.Q) and 1 or 0)
    local pitchInput = (pressed(Enum.KeyCode.Up) and 1 or 0)
        - (pressed(Enum.KeyCode.Down) and 1 or 0)
    local rollInput = (pressed(Enum.KeyCode.C) and 1 or 0)
        - (pressed(Enum.KeyCode.Z) and 1 or 0)
    local boosting = pressed(Enum.KeyCode.LeftShift) or pressed(Enum.KeyCode.RightShift)
    local braking = pressed(Enum.KeyCode.Space)

    yaw = yaw - turnInput * TURN_RATE * dt
    pitch = math.clamp(pitch + pitchInput * PITCH_RATE * dt, -MAX_PITCH, MAX_PITCH)
    local targetRoll = -turnInput * BANK_ANGLE + rollInput * ROLL_ANGLE
    visualRoll = visualRoll + (targetRoll - visualRoll)
        * (1 - math.exp(-VISUAL_SMOOTHNESS * dt))

    local heading = CFrame.Angles(0, yaw, 0) * baseRotation
        * CFrame.Angles(pitch, 0, 0)
    local multiplier = boosting and BOOST_MULTIPLIER or 1
    local thrust = forwardInput >= 0 and ACCELERATION or REVERSE_ACCELERATION

    velocity = velocity + (
        heading.LookVector * (forwardInput * thrust * multiplier)
        + Vector3.new(0, liftInput * VERTICAL_ACCELERATION * multiplier, 0)
    ) * dt
    velocity = velocity * math.exp(-(braking and BRAKE_DRAG or DRAG) * dt)
    local maxSpeed = boosting and MAX_BOOST_SPEED or MAX_SPEED
    if velocity.Magnitude > maxSpeed then velocity = velocity.Unit * maxSpeed end
    if braking and velocity.Magnitude < 0.4 then velocity = Vector3.new(0, 0, 0) end

    local step = velocity * dt
    if step.Magnitude > 0.0001 and collisionParams then
        local hit = nil
        pcall(function()
            hit = workspace:Raycast(
                position, step.Unit * (step.Magnitude + COLLISION_MARGIN),
                collisionParams
            )
        end)
        if hit then
            local allowed = math.max(0, hit.Distance - COLLISION_MARGIN)
            if allowed < step.Magnitude then
                step = step.Unit * allowed
                velocity = Vector3.new(0, 0, 0)
                collisionWarningUntil = now + 0.65
            end
        end
    end
    position = position + step

    local speed = velocity.Magnitude
    local bob = math.sin(now * 2.4) * (0.12 + 0.10 * speed / MAX_BOOST_SPEED)
    local cf = CFrame.new(position + Vector3.new(0, bob, 0))
        * heading * CFrame.Angles(0, 0, visualRoll)
    placeExterior(cf)
    lastVisualPosition = cf.Position

    if roofLight and savedLampBrightness then
        local pulse = 0.5 + 0.5 * math.sin(now * (boosting and 19 or 9))
        local gain = 1.0 + pulse * (boosting and 3.5 or 1.15)
        setValue(roofLight, "Brightness", savedLampBrightness * gain)
    end
    if fxTrail then
        pcall(function() fxTrail.Enabled = boosting and speed > 25 end)
    end

    updateCamera(cf, speed, boosting, dt)
    updateHUD(now, speed, maxSpeed, boosting, now < collisionWarningUntil, heading)

    if positionOutput and now - lastPositionOutput >= 0.12 then
        lastPositionOutput = now
        pcall(function() positionOutput:SetState(position) end)
    end
end

if UserInputService then
    pcall(function()
        UserInputService.InputBegan:Connect(function(input, processed)
            if not flightActive or processed then return end
            local key = input.KeyCode
            if key == Enum.KeyCode.Escape or key == Enum.KeyCode.X then
                stopFlight("PILOT DISENGAGED", false, false)
                return
            elseif key == Enum.KeyCode.V then
                viewMode = viewMode == "CHASE" and "WIDE" or "CHASE"
                return
            end
            keyDown[key] = true
        end)
        UserInputService.InputEnded:Connect(function(input)
            keyDown[input.KeyCode] = nil
        end)
    end)
end

signalActive(false)
print("TARDIS MANUAL FLIGHT READY / Pulse input A to toggle / No controller edits")
while true do
    local now = os.clock()
    local dt = math.clamp(now - lastTick, 0, 0.08)
    lastTick = now

    local toggle = false
    pcall(function() toggle = toggleInput:GetState() == true end)
    if toggle and not lastToggle then
        if flightActive then
            stopFlight("PILOT DISENGAGED", false, false)
        else
            startFlight()
            if flightActive then collisionParams = makeCollisionParams() end
        end
    end
    lastToggle = toggle

    if deferredCameraRestore and not hasNavGui() then
        restoreCamera()
    end
    if flightActive then updateFlight(now, dt) end
    task.wait(TICK)
end
