-- TARDIS EXTERIOR CONTROLLER - UNION VERSION
--
-- A false = dematerialize
-- A true  = materialize at Input C
-- C       = Vector3 or CFrame destination
-- J       = one-shot recall to your character
--
-- Give every TARDIS union/part the UB Display name: Tardis
--
-- Ultimate Build workspace scans return proxy tables. The proxy is used for
-- replicated writes; proxy.Part is used for reliable geometry reads.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local inputA = inputs["a"]
local inputC = inputs["c"]
local inputJ = inputs["j"]

local TARGET_NAME = "Tardis"
local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10
local FADE_TIME = 14

--------------------------------------------------
-- UB PROXY HELPERS
--------------------------------------------------

local function getRawPart(object)
    if not object then
        return nil
    end

    local raw = nil

    pcall(function()
        raw = object.Part
    end)

    if typeof(raw) == "Instance" then
        local ok, isBasePart = pcall(function()
            return raw:IsA("BasePart")
        end)

        if ok and isBasePart then
            return raw
        end
    end

    if typeof(object) == "Instance" then
        local ok, isBasePart = pcall(function()
            return object:IsA("BasePart")
        end)

        if ok and isBasePart then
            return object
        end
    end

    return nil
end

local function readDisplayName(object)
    local value = nil

    local ok = pcall(function()
        value = object.attributes["Display name"]
    end)

    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    ok = pcall(function()
        value = object:GetAttribute("Display name")
    end)

    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    ok = pcall(function()
        value = object["Display name"]
    end)

    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    local raw = getRawPart(object)
    if raw then
        ok = pcall(function()
            value = raw:GetAttribute("Display name")
        end)

        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end

    return nil
end

local function normalizeName(value)
    if type(value) ~= "string" then
        return nil
    end

    value = string.lower(value)
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    return value
end

local function isTardis(object)
    return normalizeName(readDisplayName(object)) == string.lower(TARGET_NAME)
end

local function setReplicated(entry, property, value)
    -- Skip the remote call when already correct.
    local current = nil
    local readable = pcall(function()
        current = entry.raw[property]
    end)

    if readable and current == value then
        return true
    end

    -- UB proxy assignment is the server-replicated path.
    local ok, err = pcall(function()
        entry.proxy[property] = value
    end)

    if ok then
        return true
    end

    print("TARDIS proxy write failed:", property, tostring(err))

    -- Raw fallback. This may only be local depending on ownership, but keeps
    -- the controller usable if UB exposes a real Instance instead of a proxy.
    ok, err = pcall(function()
        entry.raw[property] = value
    end)

    if not ok then
        print("TARDIS raw write failed:", property, tostring(err))
    end

    return ok
end

--------------------------------------------------
-- FIND TARDIS PARTS
--------------------------------------------------

local tardisParts = {}
local seen = {}

local function scan(label, objects)
    if type(objects) ~= "table" then
        return
    end

    print("TARDIS scan:", label, "objects:", #objects)

    for _, object in ipairs(objects) do
        if object ~= script and isTardis(object) then
            local raw = getRawPart(object)

            if raw and not seen[raw] then
                seen[raw] = true
                table.insert(tardisParts, {
                    proxy = object,
                    raw = raw,
                })
            end
        end
    end
end

local function tryScan(label, callback)
    local ok, result = pcall(callback)

    if ok then
        scan(label, result)
    else
        print("TARDIS scan error:", label, tostring(result))
    end
end

tryScan("GetChildren(true)", function()
    return workspace:GetChildren(true)
end)

if #tardisParts == 0 then
    tryScan("GetDescendants(true)", function()
        return workspace:GetDescendants(true)
    end)
end

if #tardisParts == 0 then
    tryScan("GetChildren()", function()
        return workspace:GetChildren()
    end)
end

if #tardisParts == 0 then
    tryScan("GetDescendants()", function()
        return workspace:GetDescendants()
    end)
end

print("TARDIS parts found:", #tardisParts)

if #tardisParts == 0 then
    print("TARDIS ERROR: no editable parts with Display name = Tardis")
    return
end

--------------------------------------------------
-- STARTUP PHYSICS
--------------------------------------------------

print("TARDIS stage: startup physics")

for _, entry in ipairs(tardisParts) do
    setReplicated(entry, "Anchored", true)
    setReplicated(entry, "CanCollide", true)
end

print("TARDIS stage: startup physics done")

--------------------------------------------------
-- PIVOT / RELATIVE CFRAMES
--------------------------------------------------

local startingPivot = tardisParts[1].raw.CFrame
local defaultRotation = startingPivot - startingPivot.Position
local relativeCFrames = {}

for _, entry in ipairs(tardisParts) do
    relativeCFrames[entry] = startingPivot:ToObjectSpace(entry.raw.CFrame)
end

--------------------------------------------------
-- ACTUAL BOTTOM OF TARDIS
--------------------------------------------------

local lowestBottom = math.huge

for _, entry in ipairs(tardisParts) do
    local cf = entry.raw.CFrame
    local size = entry.raw.Size

    local verticalHalfExtent =
        math.abs(cf.RightVector.Y) * (size.X / 2)
        + math.abs(cf.UpVector.Y) * (size.Y / 2)
        + math.abs(cf.LookVector.Y) * (size.Z / 2)

    local bottomY = cf.Position.Y - verticalHalfExtent

    if bottomY < lowestBottom then
        lowestBottom = bottomY
    end
end

local tardisBottomOffset = 0

if lowestBottom < math.huge then
    tardisBottomOffset = lowestBottom - startingPivot.Position.Y
end

--------------------------------------------------
-- MOVEMENT
--------------------------------------------------

local function moveTardis(targetPivot)
    for _, entry in ipairs(tardisParts) do
        setReplicated(entry, "CFrame", targetPivot * relativeCFrames[entry])
    end
end

--------------------------------------------------
-- TRANSPARENCY
--------------------------------------------------

local currentTransparency = tardisParts[1].raw.Transparency

local function setTransparency(value)
    value = math.clamp(value, 0, 1)
    currentTransparency = value

    for _, entry in ipairs(tardisParts) do
        setReplicated(entry, "Transparency", value)
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
    local elapsed = 0

    while elapsed < duration do
        local dt = RunService.Heartbeat:Wait()
        elapsed = elapsed + (dt or 0)

        local progress = math.clamp(elapsed / duration, 0, 1)
        local eased = smoothStep(progress)

        setTransparency(startValue + (target - startValue) * eased)
    end

    setTransparency(target)
end

--------------------------------------------------
-- INPUT C DESTINATION
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
-- PLAYER RECALL DESTINATION
--------------------------------------------------

local function getLocalPlayerRoot()
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
-- DEMATERIALIZE / MATERIALIZE
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

local function materializeAt(destination)
    if not destination then
        return
    end

    setTransparency(1)
    moveTardis(destination)
    hidden = false
    fadeTo(0)
end

--------------------------------------------------
-- INITIAL STATE
--------------------------------------------------

print("TARDIS stage: initial state")

local lastAState = inputA:GetState() == true
local lastJState = inputJ:GetState() == true
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
-- MAIN LOOP - NO task.wait(); UB/Fiu is happier on RunService
--------------------------------------------------

while true do
    RunService.Heartbeat:Wait()

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
end
