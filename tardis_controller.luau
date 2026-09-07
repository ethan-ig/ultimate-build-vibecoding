-- SIMPLE TARDIS CONTROLLER
--
-- INPUT A
--   false = dematerialize
--   true  = materialize at Input C
--
-- INPUT C
--   Vector3 or CFrame destination
--
-- INPUT J
--   one-shot recall:
--   dematerialize, then materialize on your character
--
-- Every TARDIS shell piece must have:
--   Display name = Tardis
--
-- No sounds. No light logic. No outputs. No waveform stuff.

local inputA = inputs["a"]
local inputC = inputs["c"]
local inputJ = inputs["j"]

local TARGET_NAME = "Tardis"

local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10

-- Full visible <-> invisible transition time.
local FADE_TIME = 14

-- 357 pieces at ~5.5 writes/sec stays below UB's old 2500/s remote limit.
local FADE_STEP = 0.18

local MOVE_BATCH_SIZE = 40

--------------------------------------------------
-- FIND TARDIS SHELL
--------------------------------------------------

local tardisParts = {}

for _, part in ipairs(workspace:GetChildren(true)) do
    if part ~= script then
        local displayName = nil

        local ok = pcall(function()
            displayName = part.attributes["Display name"]
        end)

        if ok
        and type(displayName) == "string"
        and string.lower(displayName) == string.lower(TARGET_NAME) then
            table.insert(tardisParts, part)
        end
    end
end

print("TARDIS parts found:", #tardisParts)

if #tardisParts == 0 then
    print("TARDIS ERROR: no parts with Display name = Tardis")
    return
end

--------------------------------------------------
-- FORCE SHELL ANCHORED + COLLIDABLE
--------------------------------------------------

for index, part in ipairs(tardisParts) do
    part.Anchored = true
    part.CanCollide = true

    if index % MOVE_BATCH_SIZE == 0 then
        task.wait()
    end
end

--------------------------------------------------
-- PIVOT + OFFSETS
--------------------------------------------------

local startingPivot = tardisParts[1].CFrame
local defaultRotation = startingPivot - startingPivot.Position

local relativeCFrames = {}

for _, part in ipairs(tardisParts) do
    relativeCFrames[part] = startingPivot:ToObjectSpace(part.CFrame)
end

--------------------------------------------------
-- FIND TRUE BOTTOM OF TARDIS
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
-- MOVE WHOLE TARDIS
--------------------------------------------------

local function moveTardis(pivot)
    for index, part in ipairs(tardisParts) do
        part.CFrame = pivot * relativeCFrames[part]

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

    -- Reversing halfway only takes the remaining fraction of 14 seconds.
    local duration = FADE_TIME * distance
    local startClock = os.clock()

    while true do
        local progress = math.clamp(
            (os.clock() - startClock) / duration,
            0,
            1
        )

        local eased = smoothStep(progress)
        local value = startValue + (target - startValue) * eased

        setTransparency(value)

        if progress >= 1 then
            break
        end

        task.wait(FADE_STEP)
    end

    setTransparency(target)
end

--------------------------------------------------
-- DESTINATION FROM INPUT C
--------------------------------------------------

local function getInputDestination()
    local value = inputC:GetState()

    if typeof(value) == "Vector3" then
        return CFrame.new(value) * defaultRotation
    end

    if typeof(value) == "CFrame" then
        return value
    end

    print("INPUT C must be Vector3 or CFrame")
    return startingPivot
end

--------------------------------------------------
-- LOCAL PLAYER DESTINATION
--------------------------------------------------

local function getLocalPlayerRoot()
    local Players = game:GetService("Players")
    local player = Players.LocalPlayer

    if not player then
        return nil
    end

    local character = player.Character

    if not character then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
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
            groundY =
                root.Position.Y
                - (rootHeight / 2)
                - hipHeight
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

    local pivotY =
        groundY
        - tardisBottomOffset
        + RECALL_GROUND_CLEARANCE

    return CFrame.new(
        root.Position.X,
        pivotY,
        root.Position.Z
    ) * defaultRotation
end

--------------------------------------------------
-- MATERIALIZE / DEMATERIALIZE
--------------------------------------------------

local hiddenPivot = CFrame.new(HIDDEN_POSITION) * defaultRotation
local hidden = false

local function dematerialize()
    if hidden then
        return
    end

    print("TARDIS DEMATERIALIZING")

    fadeTo(1)
    moveTardis(hiddenPivot)

    hidden = true

    print("TARDIS DEMATERIALIZED")
end

local function materializeAt(destination)
    if not destination then
        return
    end

    print("TARDIS MATERIALIZING")

    -- Move while invisible, then fade in.
    setTransparency(1)
    moveTardis(destination)

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
    currentTransparency = 0
    setTransparency(0)
    hidden = false
else
    currentTransparency = 1
    setTransparency(1)
    moveTardis(hiddenPivot)
    hidden = true
end

print("SIMPLE TARDIS READY")

--------------------------------------------------
-- MAIN LOOP
--------------------------------------------------

while true do
    --------------------------------------------------
    -- J RECALL
    --------------------------------------------------

    local jState = inputJ:GetState() == true

    if jState and not lastJState and not recallRunning then
        recallRunning = true

        print("J RECALL START")

        -- If visible, disappear first.
        if not hidden then
            dematerialize()
        end

        -- Sample your position immediately before materializing.
        local destination = getCharacterDestination()

        if destination then
            materializeAt(destination)
        end

        -- Resync A so J does not immediately trigger an opposite transition.
        lastAState = inputA:GetState() == true
        recallRunning = false

        print("J RECALL COMPLETE")
    end

    lastJState = jState

    --------------------------------------------------
    -- NORMAL A CONTROL
    --------------------------------------------------

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
