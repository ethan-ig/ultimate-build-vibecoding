-- TARDIS navigation selector
-- Input A: pulse true to open/cancel navigation mode
-- Output A: ground-biased destination; connect to controller input C.
-- Output B (optional): pulse TRUE to start the flight block's autopilot.
-- Output C (optional): flight root pivot above clicked ground; connect to flight input B.
-- Wire navigation output B -> flight input C. Keep normal teleport wiring.
--
-- Controls while navigation mode is open:
--   Left click  = choose destination
--   Right drag  = pan
--   Mouse wheel = zoom
--   Escape      = cancel

local inputA = script.inputs["a"]
local outputA = script.outputs["a"]
local outputB, outputC = nil, nil
pcall(function() outputB = script.outputs["b"] end)
pcall(function() outputC = script.outputs["c"] end)

local NAV_START_HEIGHT = 450
local NAV_MIN_HEIGHT = 80
local NAV_MAX_HEIGHT = 1800
local NAV_ZOOM_STEP = 70
local NAV_CAMERA_SMOOTHNESS = 12
local UPDATE_INTERVAL = 1 / 60
local LAND_UPDATE_INTERVAL = 0.08
local MAX_RAY_DISTANCE = 20000

-- The main controller scans for coordinate floors up to hintY + 8. Navigation
-- already knows the exact ground surface, so send a Y hint 7 studs below it.
-- That makes the controller scan only about 1 stud above the clicked ground and
-- prevents roofs, props, or the current TARDIS from becoming the landing floor.
local CONTROLLER_COORDINATE_CEILING_PAD = 8
local NAV_GROUND_SCAN_HEADROOM = 1
local NAV_OUTPUT_Y_BIAS = CONTROLLER_COORDINATE_CEILING_PAD - NAV_GROUND_SCAN_HEADROOM

-- Matches the hidden exterior staging point in the main controller. We only use
-- this to avoid centering the nav camera there while the TARDIS is dematerialized.
local HIDDEN_TARDIS_POSITION = Vector3.new(-2000, 1, 2772)
local HIDDEN_POSITION_RADIUS = 100

local Players = nil
local UserInputService = nil
local player = nil
local mouse = nil

pcall(function() Players = game:GetService("Players") end)
pcall(function() UserInputService = game:GetService("UserInputService") end)
if Players then pcall(function() player = Players.LocalPlayer end) end
if player then pcall(function() mouse = player:GetMouse() end) end

local navigationActive = false
local navigationHeight = NAV_START_HEIGHT
local navigationTargetHeight = NAV_START_HEIGHT
local navigationCenter = Vector3.new(0, 0, 0)
local navigationTargetCenter = Vector3.new(0, 0, 0)
local rightDragging = false
local rightButtonWasDown = false
local lastCursorPosition = nil
local lastSelectedDestination = nil
local lastKnownExteriorPosition = nil
local hoverDestination = nil
local lastLandUpdate = 0
local lastSelectTime = 0
local lastZoomTime = 0
local lastLoopTime = os.clock()

local savedCameraType = nil
local savedCameraCFrame = nil
local savedCameraSubject = nil
local savedFieldOfView = nil

local navGui = nil
local navCoordinateLabel = nil
local navStatusLabel = nil

local landCandidates = {}
local ignoredInstances = {}
local navRaycastParams = nil

local function getBlockValue(block, key)
    if not block then return nil end

    local ok, value = pcall(function() return block[key] end)
    if ok and value ~= nil then return value end

    ok, value = pcall(function() return block:GetAttribute(key) end)
    if ok and value ~= nil then return value end

    ok, value = pcall(function() return block.attributes[key] end)
    if ok then return value end

    return nil
end

local function getDisplayName(block)
    local value = getBlockValue(block, "DisplayName")
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function getRawPart(block)
    if not block then return nil end

    local raw = nil
    pcall(function() raw = block.Part end)
    if raw then return raw end

    if typeof(block) == "Instance" then return block end
    return nil
end

local function getBlockCFrame(block)
    if not block then return nil end

    local cf = nil
    pcall(function() cf = block.CFrame end)
    if cf then return cf end

    local raw = getRawPart(block)
    if raw then pcall(function() cf = raw.CFrame end) end
    return cf
end

local function findExteriorTardisPosition()
    for _, block in ipairs(workspace:GetDescendants()) do
        if block ~= script then
            local displayName = getDisplayName(block)
            if type(displayName) == "string"
            and string.lower(displayName) == "tardis" then
                local cf = getBlockCFrame(block)
                if cf then return cf.Position end
            end
        end
    end
    return nil
end

local function isHiddenExteriorPosition(position)
    if not position then return true end
    return (position - HIDDEN_TARDIS_POSITION).Magnitude <= HIDDEN_POSITION_RADIUS
end

local function refreshLastKnownExteriorPosition()
    local position = findExteriorTardisPosition()
    if position and not isHiddenExteriorPosition(position) then
        lastKnownExteriorPosition = position
    end
end

local function getPlayerRootPosition()
    local root = nil
    if player then
        pcall(function()
            local character = player.Character
            if character then root = character:FindFirstChild("HumanoidRootPart") end
        end)
    end
    if root then return root.Position end
    return nil
end

local function getNavigationCenter()
    if lastSelectedDestination then return lastSelectedDestination end
    if lastKnownExteriorPosition then return lastKnownExteriorPosition end

    refreshLastKnownExteriorPosition()
    if lastKnownExteriorPosition then return lastKnownExteriorPosition end

    return getPlayerRootPosition() or Vector3.new(0, 0, 0)
end

local function getCamera()
    local camera = nil
    pcall(function() camera = workspace.CurrentCamera end)
    return camera
end

local function writeCameraCFrame()
    if not navigationActive then return end

    local camera = getCamera()
    if not camera then return end

    local cameraPosition = Vector3.new(
        navigationCenter.X,
        navigationCenter.Y + navigationHeight,
        navigationCenter.Z
    )

    local cf = CFrame.new(cameraPosition) * CFrame.Angles(-math.pi / 2, 0, 0)
    pcall(function() camera.CFrame = cf end)
end

local function updateSmoothCamera(dt)
    if not navigationActive then return end

    dt = math.clamp(dt or UPDATE_INTERVAL, 0, 0.1)
    local alpha = 1 - math.exp(-NAV_CAMERA_SMOOTHNESS * dt)

    navigationCenter = navigationCenter
        + (navigationTargetCenter - navigationCenter) * alpha
    navigationHeight = navigationHeight
        + (navigationTargetHeight - navigationHeight) * alpha

    writeCameraCFrame()
end

local function snapCameraToTarget()
    navigationCenter = navigationTargetCenter
    navigationHeight = navigationTargetHeight
    writeCameraCFrame()
end

local function getCursorPosition()
    local position = nil

    if UserInputService then
        pcall(function() position = UserInputService:GetMouseLocation() end)
    end

    if not position and mouse then
        local x, y = nil, nil
        pcall(function()
            x = mouse.X
            y = mouse.Y
        end)
        if type(x) == "number" and type(y) == "number" then
            position = Vector2.new(x, y)
        end
    end

    return position
end

local function getCameraRay()
    if not navigationActive then return nil, nil end

    local camera = getCamera()
    local cursor = getCursorPosition()
    if not camera or not cursor then return nil, nil end

    local ray = nil
    pcall(function() ray = camera:ScreenPointToRay(cursor.X, cursor.Y) end)
    if not ray then
        pcall(function() ray = camera:ViewportPointToRay(cursor.X, cursor.Y) end)
    end
    if not ray and mouse then
        pcall(function() ray = mouse.UnitRay end)
    end
    if not ray then return nil, nil end

    local origin, direction = nil, nil
    pcall(function()
        origin = ray.Origin
        direction = ray.Direction
    end)
    if not origin or not direction or direction.Magnitude <= 0.0001 then
        return nil, nil
    end

    direction = direction.Unit
    return origin, direction
end

local function nameShouldBeIgnored(block)
    local displayName = getDisplayName(block)
    if type(displayName) ~= "string" then return false end

    local name = string.lower(displayName)
    return name == "tardis"
        or name == "tardisportal"
        or name == "tardisdematsound"
        or name == "tardismatsound"
        or name == "interiortardisdematsound"
        or name == "interiortardismatsound"
end

local function isPlayerCharacterPart(instance)
    if not instance or not player then return false end

    local character = nil
    pcall(function() character = player.Character end)
    if not character then return false end

    local result = false
    pcall(function() result = instance:IsDescendantOf(character) end)
    return result
end

local function getGeometryTarget(block)
    if not block then return nil end

    local raw = getRawPart(block)
    if raw then
        local cf, size = nil, nil
        pcall(function()
            cf = raw.CFrame
            size = raw.Size
        end)
        if cf and size then return raw end
    end

    local cf, size = nil, nil
    pcall(function()
        cf = block.CFrame
        size = block.Size
    end)
    if cf and size then return block end

    return nil
end

local function targetCanCollide(target, wrapper)
    local canCollide = getBlockValue(wrapper, "CanCollide")
    if canCollide == nil then
        pcall(function() canCollide = target.CanCollide end)
    end
    return canCollide ~= false
end

local function rebuildLandCandidates()
    landCandidates = {}
    ignoredInstances = {}
    navRaycastParams = nil

    local descendants = workspace:GetDescendants()

    for _, block in ipairs(descendants) do
        if block ~= script and nameShouldBeIgnored(block) then
            local target = getGeometryTarget(block)
            if target then ignoredInstances[target] = true end
        end
    end

    local seen = {}
    for _, block in ipairs(descendants) do
        if block ~= script then
            local target = getGeometryTarget(block)
            if target
            and not seen[target]
            and not ignoredInstances[target]
            and not isPlayerCharacterPart(target)
            and targetCanCollide(target, block) then
                seen[target] = true
                table.insert(landCandidates, target)
            end
        end
    end

    pcall(function()
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude

        local exclude = {}
        local character = player and player.Character or nil
        if character then table.insert(exclude, character) end
        for instance, _ in pairs(ignoredInstances) do
            table.insert(exclude, instance)
        end

        params.FilterDescendantsInstances = exclude
        pcall(function() params.RespectCanCollide = true end)
        navRaycastParams = params
    end)

    print("TARDIS NAV land candidates:", #landCandidates)
end

local function updateSlab(originCoord, directionCoord, minCoord, maxCoord, tMin, tMax)
    local epsilon = 0.000001

    if math.abs(directionCoord) <= epsilon then
        if originCoord < minCoord or originCoord > maxCoord then
            return tMin, tMax, false
        end
        return tMin, tMax, true
    end

    local t1 = (minCoord - originCoord) / directionCoord
    local t2 = (maxCoord - originCoord) / directionCoord
    if t1 > t2 then
        local swap = t1
        t1 = t2
        t2 = swap
    end

    if t1 > tMin then tMin = t1 end
    if t2 < tMax then tMax = t2 end
    return tMin, tMax, tMin <= tMax
end

local function rayBoxDistance(target, worldOrigin, worldDirection)
    local cf, size = nil, nil
    local ok = pcall(function()
        cf = target.CFrame
        size = target.Size
    end)
    if not ok or not cf or not size then return nil end

    local localOrigin, localDirection = nil, nil
    ok = pcall(function()
        localOrigin = cf:PointToObjectSpace(worldOrigin)
        localDirection = cf:VectorToObjectSpace(worldDirection)
    end)
    if not ok or not localOrigin or not localDirection then return nil end

    local tMin = 0
    local tMax = MAX_RAY_DISTANCE
    local hit = true

    tMin, tMax, hit = updateSlab(
        localOrigin.X, localDirection.X,
        -size.X / 2, size.X / 2,
        tMin, tMax
    )
    if not hit then return nil end

    tMin, tMax, hit = updateSlab(
        localOrigin.Y, localDirection.Y,
        -size.Y / 2, size.Y / 2,
        tMin, tMax
    )
    if not hit then return nil end

    tMin, tMax, hit = updateSlab(
        localOrigin.Z, localDirection.Z,
        -size.Z / 2, size.Z / 2,
        tMin, tMax
    )
    if not hit or tMin < 0 or tMin > MAX_RAY_DISTANCE then return nil end

    return tMin
end

local function getCursorLandPosition()
    local origin, direction = getCameraRay()
    if not origin or not direction then return nil end

    if navRaycastParams then
        local result = nil
        local ok = pcall(function()
            result = workspace:Raycast(
                origin,
                direction * MAX_RAY_DISTANCE,
                navRaycastParams
            )
        end)
        if ok and result then
            local position = nil
            pcall(function() position = result.Position end)
            if position then return position end
        end
    end

    local bestDistance = nil
    for _, target in ipairs(landCandidates) do
        local distance = rayBoxDistance(target, origin, direction)
        if distance and (bestDistance == nil or distance < bestDistance) then
            bestDistance = distance
        end
    end

    if bestDistance then
        return origin + direction * bestDistance
    end

    return nil
end

local function destroyNavigationGui()
    if navGui then pcall(function() navGui:Destroy() end) end
    navGui = nil
    navCoordinateLabel = nil
    navStatusLabel = nil
end

local function makeNavigationGui()
    destroyNavigationGui()
    if not player then return end

    pcall(function()
        local playerGui = player:FindFirstChildOfClass("PlayerGui")
            or player:FindFirstChild("PlayerGui")
        if not playerGui then return end

        local gui = Instance.new("ScreenGui")
        gui.Name = "TardisNavigationGui"
        gui.ResetOnSpawn = false
        gui.IgnoreGuiInset = true
        gui.DisplayOrder = 1000

        local panel = Instance.new("Frame")
        panel.AnchorPoint = Vector2.new(0.5, 0)
        panel.Position = UDim2.new(0.5, 0, 0, 18)
        panel.Size = UDim2.new(0, 560, 0, 82)
        panel.BackgroundColor3 = Color3.fromRGB(10, 14, 20)
        panel.BackgroundTransparency = 0.15
        panel.BorderSizePixel = 0
        panel.Parent = gui

        local title = Instance.new("TextLabel")
        title.BackgroundTransparency = 1
        title.Position = UDim2.new(0, 12, 0, 5)
        title.Size = UDim2.new(1, -24, 0, 22)
        title.Font = Enum.Font.GothamBold
        title.TextSize = 16
        title.TextColor3 = Color3.fromRGB(235, 240, 255)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Text = "TARDIS NAVIGATION"
        title.Parent = panel

        local coords = Instance.new("TextLabel")
        coords.BackgroundTransparency = 1
        coords.Position = UDim2.new(0, 12, 0, 28)
        coords.Size = UDim2.new(1, -24, 0, 22)
        coords.Font = Enum.Font.Code
        coords.TextSize = 15
        coords.TextColor3 = Color3.fromRGB(180, 220, 255)
        coords.TextXAlignment = Enum.TextXAlignment.Left
        coords.Text = "SCANNING LAND..."
        coords.Parent = panel

        local status = Instance.new("TextLabel")
        status.BackgroundTransparency = 1
        status.Position = UDim2.new(0, 12, 0, 52)
        status.Size = UDim2.new(1, -24, 0, 20)
        status.Font = Enum.Font.Gotham
        status.TextSize = 12
        status.TextColor3 = Color3.fromRGB(190, 195, 205)
        status.TextXAlignment = Enum.TextXAlignment.Left
        status.Text = "LEFT CLICK: SELECT   |   RIGHT DRAG: PAN   |   WHEEL: ZOOM   |   ESC: CANCEL"
        status.Parent = panel

        gui.Parent = playerGui
        navGui = gui
        navCoordinateLabel = coords
        navStatusLabel = status
    end)
end

local function restoreCamera()
    local camera = getCamera()
    if camera then
        if savedCameraCFrame then pcall(function() camera.CFrame = savedCameraCFrame end) end
        if savedCameraSubject then pcall(function() camera.CameraSubject = savedCameraSubject end) end
        if savedFieldOfView then pcall(function() camera.FieldOfView = savedFieldOfView end) end
        if savedCameraType then pcall(function() camera.CameraType = savedCameraType end) end
    end

    savedCameraType = nil
    savedCameraCFrame = nil
    savedCameraSubject = nil
    savedFieldOfView = nil
end

local function closeNavigation(reason)
    if not navigationActive then return end

    navigationActive = false
    rightDragging = false
    rightButtonWasDown = false
    lastCursorPosition = nil
    hoverDestination = nil
    restoreCamera()
    destroyNavigationGui()

    if reason then print("TARDIS NAV:", reason) end
end

local function openNavigation()
    if navigationActive then return end
    if not player then
        print("TARDIS NAV: LocalPlayer unavailable")
        return
    end

    local camera = getCamera()
    if not camera then
        print("TARDIS NAV: camera unavailable")
        return
    end

    refreshLastKnownExteriorPosition()
    local center = getNavigationCenter()
    navigationCenter = center
    navigationTargetCenter = center
    navigationHeight = NAV_START_HEIGHT
    navigationTargetHeight = NAV_START_HEIGHT

    pcall(function() savedCameraType = camera.CameraType end)
    pcall(function() savedCameraCFrame = camera.CFrame end)
    pcall(function() savedCameraSubject = camera.CameraSubject end)
    pcall(function() savedFieldOfView = camera.FieldOfView end)

    navigationActive = true

    pcall(function()
        camera.CameraType = Enum.CameraType.Scriptable
        camera.FieldOfView = 55
    end)

    rebuildLandCandidates()
    makeNavigationGui()
    snapCameraToTarget()
    lastCursorPosition = getCursorPosition()
    lastLandUpdate = 0
    lastLoopTime = os.clock()
    print("TARDIS NAV: OPEN")
end

local function toggleNavigation()
    if navigationActive then
        closeNavigation("CANCELLED")
    else
        openNavigation()
    end
end

local function applyZoom(direction)
    local now = os.clock()
    if now - lastZoomTime < 0.025 then return end
    lastZoomTime = now

    navigationTargetHeight = math.clamp(
        navigationTargetHeight - direction * NAV_ZOOM_STEP,
        NAV_MIN_HEIGHT,
        NAV_MAX_HEIGHT
    )
end

local function getRightButtonDown()
    local pressed = rightDragging

    if UserInputService then
        local value = nil
        pcall(function()
            value = UserInputService:IsMouseButtonPressed(
                Enum.UserInputType.MouseButton2
            )
        end)
        if type(value) == "boolean" then pressed = value end
    end

    return pressed
end

local function updatePanInput()
    if not navigationActive then return end

    local cursor = getCursorPosition()
    if not cursor then return end

    local pressed = getRightButtonDown()
    if not pressed then
        rightButtonWasDown = false
        lastCursorPosition = cursor
        return
    end

    if not rightButtonWasDown or not lastCursorPosition then
        rightButtonWasDown = true
        lastCursorPosition = cursor
        return
    end

    local delta = cursor - lastCursorPosition
    lastCursorPosition = cursor

    if math.abs(delta.X) < 0.01 and math.abs(delta.Y) < 0.01 then return end

    local camera = getCamera()
    if not camera then return end

    local fov = 55
    local viewportY = 720
    pcall(function() fov = camera.FieldOfView end)
    pcall(function() viewportY = math.max(camera.ViewportSize.Y, 1) end)

    local worldPerPixel =
        (2 * navigationHeight * math.tan(math.rad(fov) / 2)) / viewportY

    local right = camera.CFrame.RightVector
    local up = camera.CFrame.UpVector
    local rightXZ = Vector3.new(right.X, 0, right.Z)
    local upXZ = Vector3.new(up.X, 0, up.Z)

    if rightXZ.Magnitude > 0.001 then rightXZ = rightXZ.Unit end
    if upXZ.Magnitude > 0.001 then upXZ = upXZ.Unit end

    navigationTargetCenter = navigationTargetCenter
        - rightXZ * delta.X * worldPerPixel
        + upXZ * delta.Y * worldPerPixel
end

local function pilotGroundOffset()
    -- Convert the map's ground hit into the elevation of the physical
    -- exterior root. The controller has already measured its lowest shell.
    for _, object in ipairs(workspace:GetDescendants()) do
        local raw = getRawPart(object)
        if raw then
            local marker, offset = nil, nil
            pcall(function()
                marker = raw:GetAttribute("TardisRigRoot")
                offset = raw:GetAttribute("TardisPilotGroundOffset")
            end)
            if marker == true and type(offset) == "number" then return offset end
        end
    end
    return 8 -- Only used if the controller has not initialized its rig.
end

local function selectMouseDestination()
    if not navigationActive or getRightButtonDown() then return end

    local now = os.clock()
    if now - lastSelectTime < 0.12 then return end
    lastSelectTime = now

    local position = getCursorLandPosition() or hoverDestination
    if not position then
        print("TARDIS NAV: no collidable land under cursor")
        if navCoordinateLabel then
            pcall(function()
                navCoordinateLabel.Text = "NO COLLIDABLE LAND UNDER CURSOR"
            end)
        end
        return
    end

    -- Keep the real clicked ground for navigation recentering, but send a lower
    -- Y hint to C. The main controller then finds the actual surface itself with
    -- a ceiling only ~1 stud above this exact ground point.
    lastSelectedDestination = Vector3.new(position.X, position.Y, position.Z)
    local controllerDestination = Vector3.new(
        position.X,
        position.Y - NAV_OUTPUT_Y_BIAS,
        position.Z
    )

    pcall(function() outputA:SetState(controllerDestination) end)
    -- The pilot's root must hover ABOVE the ground by the measured bottom
    -- offset; otherwise a root-centered autopilot tries to bury the box.
    -- The normal controller still gets its original lowered Y scan hint.
    if outputC then pcall(function()
        local groundOffset = pilotGroundOffset()
        outputC:SetState(Vector3.new(
            position.X, position.Y + groundOffset, position.Z
        ))
    end) end

    print(
        "TARDIS NAV DESTINATION:",
        math.floor(position.X * 10 + 0.5) / 10,
        math.floor(position.Y * 10 + 0.5) / 10,
        math.floor(position.Z * 10 + 0.5) / 10
    )

    closeNavigation("DESTINATION SET")
    -- Close the map camera before pulsing the flight block. A 0.20 s
    -- pulse can be read by a 30 Hz FIU code block without timing races.
    if outputB then
        pcall(function() outputB:SetState(true) end)
        task.wait(0.20)
        pcall(function() outputB:SetState(false) end)
    end
end

if mouse then
    pcall(function()
        mouse.Button1Down:Connect(function()
            if navigationActive then selectMouseDestination() end
        end)
    end)

    pcall(function()
        mouse.Button2Down:Connect(function()
            if navigationActive then rightDragging = true end
        end)
    end)

    pcall(function()
        mouse.Button2Up:Connect(function()
            rightDragging = false
        end)
    end)

    pcall(function()
        mouse.WheelForward:Connect(function()
            if navigationActive then applyZoom(1) end
        end)
    end)

    pcall(function()
        mouse.WheelBackward:Connect(function()
            if navigationActive then applyZoom(-1) end
        end)
    end)
end

if UserInputService then
    pcall(function()
        UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if not navigationActive then return end

            if input.KeyCode == Enum.KeyCode.Escape then
                closeNavigation("CANCELLED")
                return
            end

            if input.UserInputType == Enum.UserInputType.MouseButton1
            and not gameProcessed then
                selectMouseDestination()
            elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
                rightDragging = true
            end
        end)
    end)

    pcall(function()
        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                rightDragging = false
            end
        end)
    end)

    pcall(function()
        UserInputService.InputChanged:Connect(function(input)
            if not navigationActive then return end
            if input.UserInputType == Enum.UserInputType.MouseWheel then
                applyZoom(input.Position.Z)
            end
        end)
    end)
end

local lastInputState = false
local lastExteriorRefresh = 0

print("TARDIS navigation ready")
print("NAV WIRING: A -> controller C; C -> flight B; B -> flight C")

while true do
    local now = os.clock()
    local dt = math.clamp(now - lastLoopTime, 0, 0.1)
    lastLoopTime = now

    if not navigationActive and now - lastExteriorRefresh >= 0.5 then
        lastExteriorRefresh = now
        refreshLastKnownExteriorPosition()
    end

    local state = false
    pcall(function() state = inputA:GetState() == true end)

    if state and not lastInputState then
        toggleNavigation()
    end
    lastInputState = state

    if navigationActive then
        updatePanInput()
        updateSmoothCamera(dt)

        if now - lastLandUpdate >= LAND_UPDATE_INTERVAL then
            lastLandUpdate = now
            hoverDestination = getCursorLandPosition()

            if navCoordinateLabel then
                if hoverDestination then
                    local x = math.floor(hoverDestination.X * 10 + 0.5) / 10
                    local y = math.floor(hoverDestination.Y * 10 + 0.5) / 10
                    local z = math.floor(hoverDestination.Z * 10 + 0.5) / 10
                    pcall(function()
                        navCoordinateLabel.Text = string.format(
                            "LAND: X %.1f    Y %.1f    Z %.1f    |    HEIGHT %.0f",
                            x, y, z, navigationHeight
                        )
                    end)
                else
                    pcall(function()
                        navCoordinateLabel.Text = string.format(
                            "NO LAND UNDER CURSOR    |    HEIGHT %.0f",
                            navigationHeight
                        )
                    end)
                end
            end
        end
    end

    task.wait(UPDATE_INTERVAL)
end
