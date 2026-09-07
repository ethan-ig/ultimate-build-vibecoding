-- SIMPLE TARDIS CONTROLLER
--
-- A false = dematerialize
-- A true  = materialize at Input C
-- C       = Vector3 or CFrame destination
-- J       = one-shot recall to your character
--
-- Every shell piece needs Display name = Tardis
--
-- IMPORTANT: Ultimate Build workspace scans return basePart proxy tables.
-- We keep the proxy for replicated property writes and use proxy.Part for
-- real Roblox geometry/CFrame reads.

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
-- ULTIMATE BUILD PROXY HELPERS
--------------------------------------------------

local function resolveRawPart(object)
    if not object then
        return nil
    end

    local rawPart = nil

    pcall(function()
        rawPart = object.Part
    end)

    if typeof(rawPart) == "Instance" then
        local isBasePart = false
        pcall(function()
            isBasePart = rawPart:IsA("BasePart")
        end)

        if isBasePart then
            return rawPart
        end
    end

    if typeof(object) == "Instance" then
        local isBasePart = false
        pcall(function()
            isBasePart = object:IsA("BasePart")
        end)

        if isBasePart then
            return object
        end
    end

    return nil
end

local function readObjectProperty(entry, property)
    local value = nil
    local gotValue = false

    if entry.proxy then
        local ok = pcall(function()
            value = entry.proxy[property]
        end)

        if ok and value ~= nil then
            gotValue = true
        end
    end

    if not gotValue and entry.raw then
        local ok = pcall(function()
            value = entry.raw[property]
        end)

        if ok and value ~= nil then
            gotValue = true
        end
    end

    if gotValue then
        return value
    end

    return nil
end

local function writeObjectProperty(entry, property, value)
    -- UB proxy writes are the important path: these are what Ultimate Build
    -- can replicate through its own property system.
    if entry.proxy then
        local ok = pcall(function()
            entry.proxy[property] = value
        end)

        if ok then
            return true
        end
    end

    -- Fallback for a raw Roblox BasePart. Useful if UB handed us a real part.
    if entry.raw then
        return pcall(function()
            entry.raw[property] = value
        end)
    end

    return false
end

--------------------------------------------------
-- DISPLAY NAME
--------------------------------------------------

local function getDisplayName(object)
    local value = nil

    -- UB proxy attribute table.
    for _, key in ipairs({
        "Display name",
        "Display Name",
        "Display",
        "DisplayName",
    }) do
        local ok = pcall(function()
            value = object.attributes[key]
        end)

        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end

    -- UB proxy GetAttribute support.
    for _, key in ipairs({
        "Display name",
        "Display Name",
        "Display",
        "DisplayName",
    }) do
        local ok = pcall(function()
            value = object:GetAttribute(key)
        end)

        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end

    -- Some proxy implementations expose the display value directly.
    for _, key in ipairs({
        "Display name",
        "Display Name",
        "Display",
        "DisplayName",
    }) do
        local ok = pcall(function()
            value = object[key]
        end)

        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end

    -- Last-resort raw-part attributes.
    local rawPart = resolveRawPart(object)
    if rawPart then
        for _, key in ipairs({
            "Display name",
            "Display Name",
            "Display",
            "DisplayName",
        }) do
            local ok = pcall(function()
                value = rawPart:GetAttribute(key)
            end)

            if ok and type(value) == "string" and value ~= "" then
                return value
            end
        end
    end

    -- Name is only a fallback. UB's visible Display name is preferred.
    local ok = pcall(function()
        value = object.Name
    end)

    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    if rawPart then
        ok = pcall(function()
            value = rawPart.Name
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
    return normalizeName(getDisplayName(object)) == string.lower(TARGET_NAME)
end

--------------------------------------------------
-- FIND TARDIS PARTS
--
-- Ultimate Build's workspace:GetChildren/GetDescendants return editable
-- basePart proxies. proxy.Part is the real BasePart.
--------------------------------------------------

local tardisParts = {}
local seen = {}

local function scan(label, list)
    if type(list) ~= "table" then
        print("TARDIS scan failed:", label, "did not return a table")
        return
    end

    print("TARDIS scan:", label, "objects:", #list)

    for _, object in ipairs(list) do
        if object ~= script and isTardis(object) then
            local rawPart = resolveRawPart(object)

            if rawPart then
                local identity = rawPart

                if not seen[identity] then
                    seen[identity] = true
                    table.insert(tardisParts, {
                        proxy = object,
                        raw = rawPart,
                    })
                end
            else
                print("TARDIS matched Display name but .Part was unavailable")
            end
        end
    end
end

local function safeList(label, callback)
    local ok, result = pcall(callback)

    if not ok then
        print("TARDIS scan error:", label, tostring(result))
        return nil
    end

    return result
end

-- true = parts owned by this player. Try that first because it is cheaper.
scan("GetChildren(true)", safeList("GetChildren(true)", function()
    return workspace:GetChildren(true)
end))

if #tardisParts == 0 then
    scan("GetDescendants(true)", safeList("GetDescendants(true)", function()
        return workspace:GetDescendants(true)
    end))
end

-- Then allow every part editable by the player.
if #tardisParts == 0 then
    scan("GetChildren()", safeList("GetChildren()", function()
        return workspace:GetChildren()
    end))
end

if #tardisParts == 0 then
    scan("GetDescendants()", safeList("GetDescendants()", function()
        return workspace:GetDescendants()
    end))
end

print("TARDIS parts found:", #tardisParts)

if #tardisParts == 0 then
    print("TARDIS ERROR: no editable parts with Display name = Tardis")
    return
end

--------------------------------------------------
-- STARTUP PHYSICS
--------------------------------------------------

for index, entry in ipairs(tardisParts) do
    writeObjectProperty(entry, "Anchored", true)
    writeObjectProperty(entry, "CanCollide", true)

    if index % MOVE_BATCH_SIZE == 0 then
        task.wait()
    end
end

--------------------------------------------------
-- PIVOT / RELATIVE CFRAMES
--------------------------------------------------

local startingPivot = readObjectProperty(tardisParts[1], "CFrame")

if typeof(startingPivot) ~= "CFrame" then
    print("TARDIS ERROR: first matched part has no readable CFrame")
    return
end

local defaultRotation = startingPivot - startingPivot.Position
local relativeCFrames = {}

for _, entry in ipairs(tardisParts) do
    local partCFrame = readObjectProperty(entry, "CFrame")

    if typeof(partCFrame) == "CFrame" then
        relativeCFrames[entry] = startingPivot:ToObjectSpace(partCFrame)
    else
        print("TARDIS WARNING: matched part has no readable CFrame")
    end
end

--------------------------------------------------
-- ACTUAL BOTTOM OF TARDIS
--------------------------------------------------

local tardisBottomOffset = 0
local lowestBottom = math.huge

for _, entry in ipairs(tardisParts) do
    local cf = readObjectProperty(entry, "CFrame")
    local size = readObjectProperty(entry, "Size")

    if typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
        local verticalHalfExtent =
            math.abs(cf.RightVector.Y) * (size.X / 2)
            + math.abs(cf.UpVector.Y) * (size.Y / 2)
            + math.abs(cf.LookVector.Y) * (size.Z / 2)

        local bottomY = cf.Position.Y - verticalHalfExtent

        if bottomY < lowestBottom then
            lowestBottom = bottomY
        end
    end
end

if lowestBottom < math.huge then
    tardisBottomOffset = lowestBottom - startingPivot.Position.Y
end

--------------------------------------------------
-- CFRAME MOVEMENT ONLY
--------------------------------------------------

local function moveTardis(targetCFrame)
    for index, entry in ipairs(tardisParts) do
        local relative = relativeCFrames[entry]

        if relative then
            writeObjectProperty(entry, "CFrame", targetCFrame * relative)
        end

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

    for _, entry in ipairs(tardisParts) do
        writeObjectProperty(entry, "Transparency", value)
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
