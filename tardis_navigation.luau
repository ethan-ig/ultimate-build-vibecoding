-- TARDIS navigation selector
-- Input A: pulse true to open/cancel navigation mode
-- Output A: selected world Vector3; connect this to TARDIS controller input C
--
-- Controls while navigation mode is open:
--   Left click  = choose destination
--   Right drag  = pan
--   Mouse wheel = zoom
--   Escape      = cancel

local inputA = script.inputs["a"]
local outputA = script.outputs["a"]

local NAV_START_HEIGHT = 450
local NAV_MIN_HEIGHT = 80
local NAV_MAX_HEIGHT = 1800
local NAV_ZOOM_STEP = 70
local NAV_PAN_SCALE = 0.0022
local UPDATE_INTERVAL = 1 / 60

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
local navigationCenter = Vector3.new(0, 0, 0)
local rightDragging = false
local lastSelectedDestination = nil

local savedCameraType = nil
local savedCameraCFrame = nil
local savedCameraSubject = nil
local savedFieldOfView = nil

local navGui = nil
local navCoordinateLabel = nil
local navStatusLabel = nil

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

local function getBlockCFrame(block)
    if not block then return nil end

    local cf = nil
    pcall(function() cf = block.CFrame end)
    if cf then return cf end

    local raw = nil
    pcall(function() raw = block.Part end)
    if raw then pcall(function() cf = raw.CFrame end) end
    return cf
end

local function findExteriorTardisPosition()
    for _, block in ipairs(workspace:GetDescendants(true)) do
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

local function getFallbackCenter()
    if lastSelectedDestination then
        return lastSelectedDestination
    end

    local root = nil
    if player then
        pcall(function()
            local character = player.Character
            if character then root = character:FindFirstChild("HumanoidRootPart") end
        end)
    end

    if root then return root.Position end
    return Vector3.new(0, 0, 0)
end

local function getCamera()
    local camera = nil
    pcall(function() camera = workspace.CurrentCamera end)
    return camera
end

local function updateCamera()
    if not navigationActive then return end

    local camera = getCamera()
    if not camera then return end

    local cameraPosition = Vector3.new(
        navigationCenter.X,
        navigationCenter.Y + navigationHeight,
        navigationCenter.Z
    )

    -- Looking straight down. This avoids a lookAt singularity at exactly +/-Y.
    local cf = CFrame.new(cameraPosition) * CFrame.Angles(-math.pi / 2, 0, 0)
    pcall(function() camera.CFrame = cf end)
end

local function destroyNavigationGui()
    if navGui then
        pcall(function() navGui:Destroy() end)
    end
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
        panel.Name = "Panel"
        panel.AnchorPoint = Vector2.new(0.5, 0)
        panel.Position = UDim2.new(0.5, 0, 0, 18)
        panel.Size = UDim2.new(0, 520, 0, 82)
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
        coords.Text = "MOVE MOUSE OVER THE MAP"
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
    restoreCamera()
    destroyNavigationGui()

    if reason then print("TARDIS NAV:", reason) end
end

local function openNavigation()
    if navigationActive then return end
    if not player or not mouse then
        print("TARDIS NAV: LocalPlayer/mouse unavailable")
        return
    end

    local camera = getCamera()
    if not camera then
        print("TARDIS NAV: camera unavailable")
        return
    end

    local center = findExteriorTardisPosition()
    if not center then center = getFallbackCenter() end

    navigationCenter = center
    navigationHeight = NAV_START_HEIGHT

    pcall(function() savedCameraType = camera.CameraType end)
    pcall(function() savedCameraCFrame = camera.CFrame end)
    pcall(function() savedCameraSubject = camera.CameraSubject end)
    pcall(function() savedFieldOfView = camera.FieldOfView end)

    navigationActive = true

    pcall(function()
        camera.CameraType = Enum.CameraType.Scriptable
        camera.FieldOfView = 55
    end)

    makeNavigationGui()
    updateCamera()
    print("TARDIS NAV: OPEN")
end

local function toggleNavigation()
    if navigationActive then
        closeNavigation("CANCELLED")
    else
        openNavigation()
    end
end

local function getMouseWorldPosition()
    if not navigationActive or not mouse then return nil end

    local hit = nil
    pcall(function() hit = mouse.Hit end)
    if not hit then return nil end

    local position = nil
    pcall(function() position = hit.Position end)
    return position
end

local function selectMouseDestination()
    local position = getMouseWorldPosition()
    if not position then
        print("TARDIS NAV: no map point under cursor")
        return
    end

    lastSelectedDestination = Vector3.new(position.X, position.Y, position.Z)

    pcall(function()
        outputA:SetState(lastSelectedDestination)
    end)

    print(
        "TARDIS NAV DESTINATION:",
        math.floor(position.X * 10 + 0.5) / 10,
        math.floor(position.Y * 10 + 0.5) / 10,
        math.floor(position.Z * 10 + 0.5) / 10
    )

    closeNavigation("DESTINATION SET")
end

if mouse then
    pcall(function()
        mouse.Button1Down:Connect(function()
            if navigationActive and not rightDragging then
                selectMouseDestination()
            end
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

            if input.UserInputType == Enum.UserInputType.MouseButton2 then
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
                local wheel = input.Position.Z
                navigationHeight = math.clamp(
                    navigationHeight - wheel * NAV_ZOOM_STEP,
                    NAV_MIN_HEIGHT,
                    NAV_MAX_HEIGHT
                )
                updateCamera()
                return
            end

            if rightDragging
            and input.UserInputType == Enum.UserInputType.MouseMovement then
                local scale = math.max(0.08, navigationHeight * NAV_PAN_SCALE)
                navigationCenter = navigationCenter + Vector3.new(
                    -input.Delta.X * scale,
                    0,
                    input.Delta.Y * scale
                )
                updateCamera()
            end
        end)
    end)
end

local lastInputState = false

print("TARDIS navigation ready")
print("Wire navigation output A -> TARDIS controller input C")

while true do
    local state = false
    pcall(function() state = inputA:GetState() == true end)

    if state and not lastInputState then
        toggleNavigation()
    end
    lastInputState = state

    if navigationActive then
        updateCamera()

        local position = getMouseWorldPosition()
        if position and navCoordinateLabel then
            local x = math.floor(position.X * 10 + 0.5) / 10
            local y = math.floor(position.Y * 10 + 0.5) / 10
            local z = math.floor(position.Z * 10 + 0.5) / 10
            pcall(function()
                navCoordinateLabel.Text = string.format(
                    "X %.1f    Y %.1f    Z %.1f    |    HEIGHT %.0f",
                    x, y, z, navigationHeight
                )
            end)
        end
    end

    task.wait(UPDATE_INTERVAL)
end
