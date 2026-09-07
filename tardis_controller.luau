-- SIMPLE TARDIS CONTROLLER
--
-- A false = dematerialize
-- A true  = materialize at Input C
-- C       = Vector3 or CFrame destination
-- J       = one-shot recall to your character
--
-- Every shell piece needs Display name = Tardis
--
-- No sounds. No lights. No outputs.

local inputA = inputs["a"]
local inputC = inputs["c"]
local inputJ = inputs["j"]

local TARGET_NAME = "Tardis"
local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10
local FADE_TIME = 14
local FADE_STEP = 0.18
local MOVE_BATCH_SIZE = 40

--------------------------------------------------
-- DISPLAY NAME
--------------------------------------------------

local function getDisplayName(part)
    local value = nil

    local ok = pcall(function()
        value = part.attributes["Display name"]
    end)

    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    ok = pcall(function()
        value = part:GetAttribute("Display name")
    end)

    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    ok = pcall(function()
        value = part.DisplayName
    end)

    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    return nil
end

local function isTardis(part)
    local displayName = getDisplayName(part)

    if type(displayName) ~= "string" then
        return false
    end

    displayName = string.lower(displayName)
    displayName = string.gsub(displayName, "^%s+", "")
    displayName = string.gsub(displayName, "%s+$", "")

    return displayName == string.lower(TARGET_NAME)
end

--------------------------------------------------
-- FIND TARDIS PARTS
--
-- Try the cheap/known scan first. If this UB build returns
-- nothing useful, fall back to the documented descendant scan.
--------------------------------------------------

local tardisParts = {}
local seen = {}

local function scan(list)
    if not list then
        return
    end

    for _, part in ipairs(list) do
        if part ~= script and not seen[part] and isTardis(part) then
            local hasCFrame = false

            pcall(function()
                hasCFrame = typeof(part.CFrame) == "CFrame"
            end)

            if hasCFrame then
                seen[part] = true
                table.insert(tardisParts, part)
            end
        end
    end
end

local function safeList(callback)
    local ok, result = pcall(callback)

    if ok then
        return result
    end

    return nil
end

scan(safeList(function()
    return workspace:GetChildren(true)
end))

if #tardisParts == 0 then
    scan(safeList(function()
        return workspace:GetDescendants(true)
    end))
end

if #tardisParts == 0 then
    scan(safeList(function()
        return workspace:GetChildren()
    end))
end

if #tardisParts == 0 then
    scan(safeList(function()
        return workspace:GetDescendants()
    end))
end

print("TARDIS parts found:", #tardisParts)

if #tardisParts == 0 then
    print("TARDIS ERROR: no parts with Display name = Tardis")
    return
end

--------------------------------------------------
-- STARTUP PHYSICS
--------------------------------------------------

for index, part in ipairs(tardisParts) do
    part.Anchored = true
    part.CanCollide = true

    if index % MOVE_BATCH_SIZE == 0 then
        task.wait()
    end
end

--------------------------------------------------
-- PIVOT / RELATIVE CFRAMES
--------------------------------------------------

local startingPivot = tardisParts[1].CFrame
local defaultRotation = startingPivot - startingPivot.Position
local relativeCFrames = {}

for _, part in ipairs(tardisParts) do
    relativeCFrames[part] = startingPivot:ToObjectSpace(part.CFrame)
end

--------------------------------------------------
-- ACTUAL BOTTOM OF TARDIS
--------------------------------------------------

local tardisBottomOffset = 0
local lowestBottom = math.huge

for _, part in ipairs(tardisParts) do
    local cf = part.CFrame
    local size = part.Size

    local verticalHalfExtent =
        math.abs(cf.RightVector.Y) * (size.X / 2)
        + math.abs(cf.UpVector.Y) * (size.Y / 2)
        + math.abs(cf.LookVector.Y) * (size.Z / 2)

    local bottomY = cf.Position.Y - verticalHalfExtent

    if bottomY < lowestBottom then
        lowestBottom = bottomY
    end
end

if lowestBottom < math.huge then
    tardisBottomOffset = lowestBottom - startingPivot.Position.Y
end

--------------------------------------------------
-- CFRAME MOVEMENT ONLY
--------------------------------------------------

local function moveTardis(targetCFrame)
    for index, part in ipairs(tardisParts) do
        part.CFrame = targetCFrame * relativeCFrames[part]

        if index % MOVE_BATCH_SIZE == 0 then
            task.wait()
        end
    end
end

--------------------------------------------------
-- TRANSPARENCY
--------------------------------------------------

local currentTransparency = 0

local function setTransparency(value)
    value = math.clamp(value, 0, 1)
    currentTransparency = value

    for _, part in ipairs(tardisParts) do
        part.Transparency = value
    end
end

local function smoothStep(t)
    t = math.clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

local function fadeTo(target)
    target = math.clamp(target, 0, 1)

    local startValue = currentTransparency
    local distance = math.abs(target - startValue)

    if distance <= 0.001 then
        setTransparency(target)
        return
    end

    local duration = FADE_TIME * distance
    local startClock = os.clock()

    while true do
        local progress = math.clamp(
            (os.clock() - startClock) / duration,
            0,
            1
        )

        local eased = smoothStep(progress)
        setTransparency(startValue + (target - startValue) * eased)

        if progress >= 1 then
            break
        end

        task.wait(FADE_STEP)
    end

    setTransparency(target)
end

--------------------------------------------------
-- INPUT C -> CFRAME
--------------------------------------------------

local function getInputDestination()
    local value = inputC:GetState()

    if typeof(value) == "CFrame" then
        return value
    end

    if typeof(value) == "Vector3" then
        return CFrame.new(value) * defaultRotation
    end

    print("INPUT C must be CFrame or Vector3")
    return startingPivot
end

--------------------------------------------------
-- PLAYER DESTINATION -> CFRAME
--------------------------------------------------

local function getLocalPlayerRoot()
    local Players = game:GetService("Players")
    local player = Players.LocalPlayer

    if not player or not player.Character then
        return nil
    end

    return player.Character:FindFirstChild("HumanoidRootPart")
end

local function getPlayerGroundY(root)
    local groundY = root.Position.Y - 3
    local character = root.Parent

    if not character then
        return groundY
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")

    if humanoid then
        local hipHeight = humanoid.HipHeight
        local rootHeight = root.Size.Y

        if hipHeight and hipHeight > 0.5 then
            groundY = root.Position.Y - (rootHeight / 2) - hipHeight
        end
    end

    return groundY
end

local function getCharacterDestination()
    local root = getLocalPlayerRoot()

    if not root then
        print("J RECALL ERROR: HumanoidRootPart not found")
        return nil
    end

    local groundY = getPlayerGroundY(root)
    local pivotY = groundY - tardisBottomOffset + RECALL_GROUND_CLEARANCE

    return CFrame.new(
        root.Position.X,
        pivotY,
        root.Position.Z
    ) * defaultRotation
end

--------------------------------------------------
-- DEMAT / MAT
--------------------------------------------------

local hiddenPivot = CFrame.new(HIDDEN_POSITION) * defaultRotation
local hidden = false

local function dematerialize()
    if hidden then
        return
    end

    fadeTo(1)
    moveTardis(hiddenPivot)
    hidden = true
end

local function materializeAt(destinationCFrame)
    if not destinationCFrame then
        return
    end

    setTransparency(1)
    moveTardis(destinationCFrame)
    hidden = false
    fadeTo(0)
end

--------------------------------------------------
-- INITIAL STATE
--------------------------------------------------

local lastAState = inputA:GetState() == true
local lastJState = false
local recallRunning = false

if lastAState then
    setTransparency(0)
    hidden = false
else
    setTransparency(1)
    moveTardis(hiddenPivot)
    hidden = true
end

print("SIMPLE TARDIS READY")

--------------------------------------------------
-- MAIN LOOP
--------------------------------------------------

while true do
    local jState = inputJ:GetState() == true

    if jState and not lastJState and not recallRunning then
        recallRunning = true

        if not hidden then
            dematerialize()
        end

        materializeAt(getCharacterDestination())

        lastAState = inputA:GetState() == true
        recallRunning = false
    end

    lastJState = jState

    if not recallRunning then
        local aState = inputA:GetState() == true

        if aState ~= lastAState then
            lastAState = aState

            if aState then
                materializeAt(getInputDestination())
            else
                dematerialize()
            end
        end
    end

    task.wait(0.05)
end
