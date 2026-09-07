-- SIMPLE TARDIS CONTROLLER
--
-- A = false -> dematerialize
-- A = true  -> materialize at Input C
-- C = destination Vector3 or CFrame
-- J = dematerialize, then materialize on local player
--
-- Every shell piece: Display name = Tardis
--
-- ALL MOVEMENT IS DONE WITH CFrame.

local inputA = inputs["a"]
local inputC = inputs["c"]
local inputJ = inputs["j"]

local TARGET_NAME = "Tardis"
local HIDDEN_CFRAME = CFrame.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10
local FADE_TIME = 14
local FADE_STEP = 0.18
local MOVE_BATCH_SIZE = 40

--------------------------------------------------
-- FIND SHELL
--------------------------------------------------

local tardisParts = {}

for _, part in ipairs(workspace:GetChildren(true)) do
    if part ~= script then
        local displayName = nil

        pcall(function()
            displayName = part.attributes["Display name"]
        end)

        if type(displayName) == "string"
        and string.lower(displayName) == string.lower(TARGET_NAME) then
            table.insert(tardisParts, part)
        end
    end
end

print("TARDIS parts found:", #tardisParts)

if #tardisParts == 0 then
    print("TARDIS ERROR: no parts named Tardis")
    return
end

--------------------------------------------------
-- LOCK SHELL
--------------------------------------------------

for index, part in ipairs(tardisParts) do
    part.Anchored = true
    part.CanCollide = true

    if index % MOVE_BATCH_SIZE == 0 then
        task.wait()
    end
end

--------------------------------------------------
-- PIVOT / OFFSETS
--------------------------------------------------

local startingPivot = tardisParts[1].CFrame
local startingRotation = startingPivot - startingPivot.Position
local relativeCFrames = {}

for _, part in ipairs(tardisParts) do
    relativeCFrames[part] = startingPivot:ToObjectSpace(part.CFrame)
end

--------------------------------------------------
-- BOTTOM OFFSET
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
-- CFRAME MOVEMENT
--------------------------------------------------

local function moveTardisToCFrame(targetCFrame)
    if typeof(targetCFrame) ~= "CFrame" then
        print("TARDIS MOVE ERROR: target is not CFrame")
        return false
    end

    for index, part in ipairs(tardisParts) do
        part.CFrame = targetCFrame * relativeCFrames[part]

        if index % MOVE_BATCH_SIZE == 0 then
            task.wait()
        end
    end

    return true
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
    local started = os.clock()

    while true do
        local progress = math.clamp(
            (os.clock() - started) / duration,
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

local function getInputCFrame()
    local value = inputC:GetState()

    if typeof(value) == "CFrame" then
        return value
    end

    if typeof(value) == "Vector3" then
        return CFrame.new(value) * startingRotation
    end

    print("INPUT C must be CFrame or Vector3")
    return startingPivot
end

--------------------------------------------------
-- PLAYER -> CFRAME
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

local function getCharacterCFrame()
    local root = getLocalPlayerRoot()

    if not root then
        print("J RECALL ERROR: HumanoidRootPart not found")
        return nil
    end

    local groundY = getPlayerGroundY(root)
    local pivotY =
        groundY
        - tardisBottomOffset
        + RECALL_GROUND_CLEARANCE

    return CFrame.new(
        root.Position.X,
        pivotY,
        root.Position.Z
    ) * startingRotation
end

--------------------------------------------------
-- MATERIALIZE / DEMATERIALIZE
--------------------------------------------------

local hiddenCFrame = HIDDEN_CFRAME * startingRotation
local hidden = false

local function dematerialize()
    if hidden then
        return
    end

    print("TARDIS DEMATERIALIZING")

    fadeTo(1)
    moveTardisToCFrame(hiddenCFrame)
    hidden = true

    print("TARDIS DEMATERIALIZED")
end

local function materializeAtCFrame(destinationCFrame)
    if typeof(destinationCFrame) ~= "CFrame" then
        return
    end

    print("TARDIS MATERIALIZING")

    setTransparency(1)
    moveTardisToCFrame(destinationCFrame)
    hidden = false
    fadeTo(0)

    print("TARDIS MATERIALIZED")
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
    moveTardisToCFrame(hiddenCFrame)
    hidden = true
end

print("SIMPLE CFRAME TARDIS READY")

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

        local destinationCFrame = getCharacterCFrame()

        if destinationCFrame then
            materializeAtCFrame(destinationCFrame)
        end

        lastAState = inputA:GetState() == true
        recallRunning = false
    end

    lastJState = jState

    if not recallRunning then
        local aState = inputA:GetState() == true

        if aState ~= lastAState then
            lastAState = aState

            if aState then
                materializeAtCFrame(getInputCFrame())
            else
                dematerialize()
            end
        end
    end

    task.wait(0.05)
end
