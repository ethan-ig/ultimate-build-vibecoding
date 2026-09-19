-- TARDIS controller
-- A: true=materialized, false=dematerialized
-- B: optional player name target (partial names accepted)
-- C: normal destination (Vector3/CFrame)
-- D: fast travel toggle (fast demat + fast remat)
-- E: quick recall to local player (fast demat + fast remat)
-- F: quick destination cycle (fast demat + B/C fast remat)
-- J: normal recall (demat, then remat on local player)
-- No Code outputs are required.

local inputA = script.inputs["a"]
local inputB = nil
pcall(function() inputB = script.inputs["b"] end)
local inputC = script.inputs["c"]
local inputD = nil
local inputE = nil
local inputF = nil
pcall(function() inputD = script.inputs["d"] end)
pcall(function() inputE = script.inputs["e"] end)
pcall(function() inputF = script.inputs["f"] end)
local inputJ = script.inputs["j"]

local SHELL_NAME = "Tardis"
local MAT_SOUND_NAME = "TardisMatSound"
local INTERIOR_MAT_SOUND_NAME = "InteriorTardisMatSound"
local LIGHT_NAME = "Tardislight"
local PORTAL_NAME = "tardisportal"

-- Audio is the master clock.
local VISUAL_START_TIME = 0.20
local SOUND_TAIL_TIME = 3
local AGGRESSIVE_PROGRESS_POWER = 0.62
local SHELL_WAVE_STRENGTH = 0.30
local WAVE_ATTACK = 0.78
local WAVE_RELEASE = 0.20
local WAVE_GAMMA = 0.55
local MIN_LOUDNESS_PEAK = 80
local SYNTH_WAVE_RATE_A = 18.0
local SYNTH_WAVE_RATE_B = 31.0
local FALLBACK_FADE_TIME = 14
local FALLBACK_TAIL_TIME = 3
local SOUND_START_TIMEOUT = 4
local MAIN_UPDATE_INTERVAL = 1 / 60
local MAX_FADE_WRITES_PER_SECOND = 2200

-- Roof lamp reacts harder than the shell.
local LIGHT_QUIET_VISIBILITY = 0.12
local LIGHT_QUIET_BRIGHTNESS = 0.15
local LIGHT_PEAK_BRIGHTNESS_MULT = 4.0

local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10
local SOUND_VOLUME = 1

-- One exterior SoundBlock + one mirrored interior SoundBlock are reused for every
-- transition. The controller swaps the asset and pitch immediately before playback.
local SOUND_PROFILES = {
    materialize_normal = { id = "142277519", pitch = 1.000 },
    materialize_quick = { id = "140477091", pitch = 0.735 },
    demat_normal = { id = "135858826", pitch = 0.633 },
    demat_quick = { id = "135858448", pitch = 1.000 },
    quick_end = { id = "134966578", pitch = 1.000 },
}

local QUICK_END_STING_SECONDS = 3

local FAST_FADE_TIME = 1.15 -- fallback only when the SoundBlock clock is unavailable
local FAST_TAIL_TIME = 0.15
local FAST_DEMAT_VISUAL_END_FRACTION = 0.70 -- fully gone/teleported by 70% of quick demat audio
local FAST_MAT_VISUAL_END_FRACTION = 0.90 -- fully solid by 90% of quick materialize audio
local FAST_DEMAT_PROGRESS_POWER = 0.34 -- demat gets aggressive much earlier
local FAST_MAT_PROGRESS_POWER = 0.42 -- remat keeps the current feel

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

local function setBlockValue(block, key, value)
    if not block then return false end

    local ok = pcall(function() block[key] = value end)
    if ok then return true end

    ok = pcall(function() block:SetAttribute(key, value) end)
    if ok then return true end

    ok = pcall(function() block.attributes[key] = value end)
    return ok
end

local function getDisplayName(part)
    local value = getBlockValue(part, "DisplayName")
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function getOptionalBoolInput(input)
    if not input then return false end
    local state = false
    pcall(function() state = input:GetState() == true end)
    return state
end

local function fastTravelEnabled()
    return getOptionalBoolInput(inputD)
end

local function findNamedBlock(name)
    for _, part in ipairs(workspace:GetDescendants(true)) do
        if part ~= script then
            local displayName = getDisplayName(part)
            if displayName and string.lower(displayName) == string.lower(name) then
                return part
            end
        end
    end
    return nil
end

local matSound = findNamedBlock(MAT_SOUND_NAME)
local interiorMatSound = findNamedBlock(INTERIOR_MAT_SOUND_NAME)
local tardisLight = findNamedBlock(LIGHT_NAME)

print(matSound and "FOUND: TardisMatSound" or "ERROR: missing TardisMatSound")
print(interiorMatSound and "FOUND: InteriorTardisMatSound" or "WARNING: missing InteriorTardisMatSound")
print(tardisLight and "FOUND: Tardislight" or "WARNING: missing Tardislight")

local function getSoundInput(block)
    if not block then return nil end

    for _, name in ipairs({"Input", "input", "Toggle", "toggle", "a", "A"}) do
        local ok, value = pcall(function() return block.inputs[name] end)
        if ok and value then return value end
    end

    local ok, inputTable = pcall(function() return block.inputs end)
    if ok and inputTable then
        local success, result = pcall(function()
            for _, value in pairs(inputTable) do return value end
        end)
        if success and result then return result end
    end

    return nil
end

local function setSoundPowered(block, state)
    if not block then return false end

    local input = getSoundInput(block)
    if input then
        local ok = pcall(function() input:Fire(state, true) end)
        if ok then return true end

        ok = pcall(function() input:SetState(state) end)
        if ok then return true end
    end

    for _, name in ipairs({"Input", "input", "Toggle", "toggle", "a"}) do
        local ok = pcall(function() block:FireInput(name, state) end)
        if ok then return true end
    end

    print("Could not control SoundBlock:", getDisplayName(block))
    return false
end

local function configureSound(block)
    if not block then return end
    setBlockValue(block, "Repeat", false)
    setBlockValue(block, "ResetTimePosition", false)
    setBlockValue(block, "Volume", SOUND_VOLUME)
    setBlockValue(block, "Effects", false)
end

configureSound(matSound)
configureSound(interiorMatSound)

local function getMirroredSound(block)
    if block == matSound then return interiorMatSound end
    if block == interiorMatSound then return matSound end
    return nil
end

local function stopSound(block)
    if not block then return end

    local mirror = getMirroredSound(block)

    setSoundPowered(block, false)
    if mirror then setSoundPowered(mirror, false) end

    task.wait()

    setBlockValue(block, "TimePosition", 0)
    if mirror then setBlockValue(mirror, "TimePosition", 0) end
end

local function playSound(block, position)
    if not block then return false end

    local mirror = getMirroredSound(block)
    local startPosition = position or 0

    setSoundPowered(block, false)
    if mirror then setSoundPowered(mirror, false) end

    task.wait()

    setBlockValue(block, "TimePosition", startPosition)
    if mirror then setBlockValue(mirror, "TimePosition", startPosition) end

    setSoundPowered(block, true)
    if mirror then setSoundPowered(mirror, true) end

    return true
end

-- Try to reach the real Roblox Sound so PlaybackLoudness can drive the effect.
local function findActualSoundInstance(block)
    if not block then return nil end

    local rawPart = nil
    pcall(function() rawPart = block.Part end)
    if not rawPart then return nil end

    local found = nil
    pcall(function() found = rawPart:FindFirstChildWhichIsA("Sound", true) end)
    if found then return found end

    local descendants = nil
    pcall(function() descendants = rawPart:GetDescendants() end)
    if descendants then
        for _, child in ipairs(descendants) do
            local isSound = false
            pcall(function() isSound = child:IsA("Sound") end)
            if isSound then return child end
        end
    end

    return nil
end

local matSoundInstance = findActualSoundInstance(matSound)
local interiorMatSoundInstance = findActualSoundInstance(interiorMatSound)

print(matSoundInstance and "TARDIS transition PlaybackLoudness available" or "TARDIS transition loudness fallback enabled")

local function getPlaybackLoudness(block, actualSound)
    if actualSound then
        local ok, value = pcall(function() return actualSound.PlaybackLoudness end)
        if ok and type(value) == "number" then return value, true end
    end

    local value = getBlockValue(block, "PlaybackLoudness")
    if type(value) == "number" then return value, true end
    return 0, false
end

-- shellParts determine ground height.
-- moveParts include shell + sounds + roof light + portal.
-- fadeParts include shell + sounds. Roof light gets a stronger custom effect.
local shellParts = {}
local moveParts = {}
local fadeParts = {}
local relativeCFrames = {}

local function contains(list, part)
    for _, existing in ipairs(list) do
        if existing == part then return true end
    end
    return false
end

local function addPart(list, part)
    if not part or contains(list, part) then return end
    local ok = pcall(function() return part.CFrame end)
    if ok then table.insert(list, part) end
end

for _, part in ipairs(workspace:GetDescendants(true)) do
    if part ~= script then
        local displayName = getDisplayName(part)
        if displayName and string.lower(displayName) == string.lower(SHELL_NAME) then
            local ok = pcall(function() return part.CFrame end)
            if ok then
                table.insert(shellParts, part)
                addPart(moveParts, part)
                addPart(fadeParts, part)
            end
        end
    end
end

addPart(moveParts, matSound)
addPart(moveParts, tardisLight)
addPart(fadeParts, matSound)

local function getRawPart(block)
    if not block then return nil end

    local raw = nil
    pcall(function() raw = block.Part end)
    if raw then return raw end

    if typeof(block) == "Instance" then return block end
    return nil
end

local function blockNameMatches(block, name)
    if not block then return false end
    local wanted = string.lower(name)

    local displayName = getDisplayName(block)
    if type(displayName) == "string" and string.lower(displayName) == wanted then
        return true
    end

    local objectName = getBlockValue(block, "Name")
    if type(objectName) == "string" and string.lower(objectName) == wanted then
        return true
    end

    local raw = getRawPart(block)
    if raw then
        local rawName = nil
        pcall(function() rawName = raw.Name end)
        if type(rawName) == "string" and string.lower(rawName) == wanted then
            return true
        end
    end

    return false
end

local function findBlockFlexible(name)
    for _, block in ipairs(workspace:GetDescendants(true)) do
        if block ~= script and blockNameMatches(block, name) then
            return block
        end
    end
    return nil
end

-- Replace the old click-to-enter system with a portal that physically follows
-- the exterior TARDIS. The portal is never included in fadeParts.
local tardisPortal = findBlockFlexible(PORTAL_NAME)
local tardisPortalRaw = getRawPart(tardisPortal)
local tardisPortalMoveTarget = nil

if tardisPortal then
    local cf = nil
    pcall(function() cf = tardisPortal.CFrame end)
    if cf then
        tardisPortalMoveTarget = tardisPortal
    elseif tardisPortalRaw then
        pcall(function() cf = tardisPortalRaw.CFrame end)
        if cf then tardisPortalMoveTarget = tardisPortalRaw end
    end
end

addPart(moveParts, tardisPortalMoveTarget)

local function forcePortalTransparent()
    if tardisPortal then
        setBlockValue(tardisPortal, "Transparency", 1)
    end
    if tardisPortalRaw then
        pcall(function() tardisPortalRaw.Transparency = 1 end)
    end
end

forcePortalTransparent()

-- Clean up ClickDetectors created by older versions of this controller.
for _, part in ipairs(shellParts) do
    local raw = getRawPart(part)
    if raw then
        local detector = nil
        pcall(function() detector = raw:FindFirstChild("TardisEnterClick") end)
        if detector then pcall(function() detector:Destroy() end) end
    end
end

local oldInteriorTarget = findBlockFlexible("interiortardisteleportspot")
local oldInteriorRaw = getRawPart(oldInteriorTarget)
if oldInteriorRaw then
    local detector = nil
    pcall(function() detector = oldInteriorRaw:FindFirstChild("TardisExitClick") end)
    if detector then pcall(function() detector:Destroy() end) end
end

print("TARDIS shell blocks:", #shellParts)
print("TARDIS moving blocks:", #moveParts)
print("TARDIS wave-fading blocks:", #fadeParts)
print("TARDIS portal found:", tardisPortal ~= nil)

local lightOriginalTransparency = 0
local lightOriginalBrightness = 2

if tardisLight then
    local t = tonumber(getBlockValue(tardisLight, "Transparency"))
    if t then lightOriginalTransparency = math.clamp(t, 0, 1) end

    local b = tonumber(getBlockValue(tardisLight, "Brightness"))
    if b then lightOriginalBrightness = b end
end

local startingPivot = nil
if #shellParts > 0 then startingPivot = shellParts[1].CFrame end

if startingPivot then
    for _, part in ipairs(moveParts) do
        relativeCFrames[part] = startingPivot:ToObjectSpace(part.CFrame)
    end
end

local matSoundRaw = nil
local matSoundRawOffset = nil
if startingPivot and matSound then
    pcall(function() matSoundRaw = matSound.Part end)
    if matSoundRaw then
        pcall(function()
            matSoundRawOffset = startingPivot:ToObjectSpace(matSoundRaw.CFrame)
        end)
    end
end

local tardisPortalRawOffset = nil
if startingPivot and tardisPortalRaw then
    pcall(function()
        tardisPortalRawOffset = startingPivot:ToObjectSpace(tardisPortalRaw.CFrame)
    end)
end

local defaultRotation = startingPivot
    and (startingPivot - startingPivot.Position)
    or CFrame.identity

local tardisBottomOffset = 0
if startingPivot then
    local lowestBottom = math.huge

    for _, part in ipairs(shellParts) do
        pcall(function()
            local cf = part.CFrame
            local size = part.Size
            local halfHeight =
                math.abs(cf.RightVector.Y) * (size.X / 2)
                + math.abs(cf.UpVector.Y) * (size.Y / 2)
                + math.abs(cf.LookVector.Y) * (size.Z / 2)

            local bottom = cf.Position.Y - halfHeight
            if bottom < lowestBottom then lowestBottom = bottom end
        end)
    end

    if lowestBottom < math.huge then
        tardisBottomOffset = lowestBottom - startingPivot.Position.Y
    end
end

local function moveTardis(pivot)
    for _, part in ipairs(moveParts) do
        local offset = relativeCFrames[part]
        if offset then
            pcall(function() part.CFrame = pivot * offset end)
        end
    end

    -- Keep the exterior materialization SoundBlock's actual raw Part glued to
    -- the box too. Its wrapper can report a moved CFrame while the emitter Part
    -- stays behind in Ultimate Build, so enforce the stored TARDIS-relative pose.
    if matSoundRaw and matSoundRawOffset then
        pcall(function()
            matSoundRaw.CFrame = pivot * matSoundRawOffset
        end)
    end

    -- Same raw-Part safeguard for the portal so it cannot get left behind by
    -- a wrapper that reports its own CFrame.
    if tardisPortalRaw and tardisPortalRawOffset then
        pcall(function()
            tardisPortalRaw.CFrame = pivot * tardisPortalRawOffset
        end)
    end

    forcePortalTransparent()
end

local function setFadePartsTransparency(value)
    value = math.clamp(value, 0, 1)
    for _, part in ipairs(fadeParts) do
        pcall(function() part.Transparency = value end)
    end
end

local function setLightEffect(baseFade, wave, active)
    if not tardisLight then return end

    baseFade = math.clamp(baseFade, 0, 1)
    wave = math.clamp(wave or 0, 0, 1)

    if not active then
        if baseFade >= 0.999 then
            pcall(function() tardisLight.Transparency = 1 end)
            setBlockValue(tardisLight, "Brightness", 0)
        else
            pcall(function() tardisLight.Transparency = lightOriginalTransparency end)
            setBlockValue(tardisLight, "Brightness", lightOriginalBrightness)
        end
        return
    end

    local shellVisibility = 1 - baseFade
    local wavePunch = math.pow(wave, 0.45)

    -- Lamp glass flashes with peaks.
    local pulseVisibility =
        LIGHT_QUIET_VISIBILITY
        + (1 - LIGHT_QUIET_VISIBILITY) * wavePunch
    local finalVisibility = shellVisibility * pulseVisibility
    local finalTransparency = 1 - finalVisibility * (1 - lightOriginalTransparency)

    pcall(function()
        tardisLight.Transparency = math.clamp(finalTransparency, 0, 1)
    end)

    -- Emitted light also follows the waveform, much harder.
    local brightnessFactor =
        LIGHT_QUIET_BRIGHTNESS
        + (LIGHT_PEAK_BRIGHTNESS_MULT - LIGHT_QUIET_BRIGHTNESS) * wavePunch
    local brightness = lightOriginalBrightness * shellVisibility * brightnessFactor
    setBlockValue(tardisLight, "Brightness", math.max(0, brightness))
end

local function getAggressiveProgress(progress)
    return math.pow(math.clamp(progress, 0, 1), AGGRESSIVE_PROGRESS_POWER)
end

local function getWaveDrivenFade(targetFade, baseFade, wave)
    baseFade = math.clamp(baseFade, 0, 1)
    wave = math.clamp(wave or 0, 0, 1)

    local punch = math.pow(wave, WAVE_GAMMA) * SHELL_WAVE_STRENGTH

    if targetFade >= 1 then
        -- Demat: sound peaks punch it further invisible.
        return math.clamp(baseFade + punch * (1 - baseFade), 0, 1)
    else
        -- Materialize: sound peaks punch it further visible.
        return math.clamp(baseFade - punch * baseFade, 0, 1)
    end
end

local fadePartCount = math.max(#fadeParts, 1)
local fadeUpdateRate = math.floor(MAX_FADE_WRITES_PER_SECOND / fadePartCount)
fadeUpdateRate = math.clamp(fadeUpdateRate, 15, 60)
local fadeUpdateInterval = 1 / fadeUpdateRate
local lastFadeWrite = 0
print("TARDIS fade refresh:", fadeUpdateRate, "Hz")

local findFloorY
local findFloorNearY

local function getInputDestination()
    local value = inputC:GetState()
    local requested = nil

    if typeof(value) == "Vector3" then
        requested = CFrame.new(value) * defaultRotation
    elseif typeof(value) == "CFrame" then
        requested = value
    else
        print("Input C must be Vector3 or CFrame. Got:", typeof(value))
        requested = startingPivot
    end

    if not requested then return nil end

    local position = requested.Position
    local groundY = findFloorNearY(position.X, position.Z, position.Y)
    if groundY == nil then
        return requested
    end

    local rotation = requested - position
    local pivotY = groundY - tardisBottomOffset + RECALL_GROUND_CLEARANCE
    print("C LANDING:", "hintY", position.Y, "groundY", groundY, "pivotY", pivotY)
    return CFrame.new(position.X, pivotY, position.Z) * rotation
end

local function getLocalPlayerRoot()
    local Players = nil
    pcall(function() Players = game:GetService("Players") end)
    if not Players then return nil end

    local player = nil
    pcall(function() player = Players.LocalPlayer end)
    if not player then return nil end

    local character = nil
    pcall(function() character = player.Character end)
    if not character then return nil end

    local root = nil
    pcall(function() root = character:FindFirstChild("HumanoidRootPart") end)
    return root
end

local function getPlayerGroundY(root)
    local groundY = root.Position.Y - 3
    local character = root.Parent
    if not character then return groundY end

    local humanoid = nil
    pcall(function() humanoid = character:FindFirstChildOfClass("Humanoid") end)

    if humanoid then
        local hipHeight = humanoid.HipHeight
        local rootHeight = root.Size.Y
        if hipHeight and hipHeight > 0.5 then
            groundY = root.Position.Y - (rootHeight / 2) - hipHeight
        end
    end

    return groundY
end

-- Find the highest collidable surface directly below the player without using
-- Roblox raycast APIs that Ultimate Build may wrap differently. This only runs
-- when calculating a recall destination; the rest of the controller is unchanged.
local function updateFloorSlab(originCoord, directionCoord, minCoord, maxCoord, tMin, tMax)
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

local function floorHitY(part, x, z, maxY)
    if not part or part == script or contains(moveParts, part) then return nil end

    local cf = nil
    local size = nil
    local rawPart = nil

    pcall(function() rawPart = part.Part end)

    local ok = pcall(function()
        cf = part.CFrame
        size = part.Size
    end)

    if (not ok or not cf or not size) and rawPart then
        ok = pcall(function()
            cf = rawPart.CFrame
            size = rawPart.Size
        end)
    end

    if not ok or not cf or not size then return nil end

    local canCollide = getBlockValue(part, "CanCollide")
    if canCollide == nil and rawPart then
        pcall(function() canCollide = rawPart.CanCollide end)
    end
    if canCollide == false then return nil end

    local startY = maxY + 2
    local distance = 20000
    local worldOrigin = Vector3.new(x, startY, z)
    local worldEnd = Vector3.new(x, startY - distance, z)

    local localOrigin = nil
    local localEnd = nil
    ok = pcall(function()
        localOrigin = cf:PointToObjectSpace(worldOrigin)
        localEnd = cf:PointToObjectSpace(worldEnd)
    end)
    if not ok or not localOrigin or not localEnd then return nil end

    local direction = localEnd - localOrigin
    local tMin = 0
    local tMax = 1
    local hit = true

    tMin, tMax, hit = updateFloorSlab(localOrigin.X, direction.X, -size.X / 2, size.X / 2, tMin, tMax)
    if not hit then return nil end
    tMin, tMax, hit = updateFloorSlab(localOrigin.Y, direction.Y, -size.Y / 2, size.Y / 2, tMin, tMax)
    if not hit then return nil end
    tMin, tMax, hit = updateFloorSlab(localOrigin.Z, direction.Z, -size.Z / 2, size.Z / 2, tMin, tMax)
    if not hit or tMin < 0 or tMin > 1 then return nil end

    local hitY = startY - distance * tMin
    if hitY > maxY + 0.5 then return nil end
    return hitY
end

findFloorY = function(x, z, maxY)
    local bestY = nil

    for _, part in ipairs(workspace:GetDescendants(true)) do
        local hitY = floorHitY(part, x, z, maxY)
        if hitY and (bestY == nil or hitY > bestY) then
            bestY = hitY
        end
    end

    return bestY
end

local function raycastCoordinateGroundY(x, z, preferredCeiling)
    local params = nil

    pcall(function()
        params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude

        local exclude = {}

        for _, part in ipairs(moveParts) do
            local raw = getRawPart(part)
            if raw and typeof(raw) == "Instance" then
                table.insert(exclude, raw)
            end
            if typeof(part) == "Instance" then
                table.insert(exclude, part)
            end
        end

        local Players = game:GetService("Players")
        for _, player in ipairs(Players:GetPlayers()) do
            if player.Character then
                table.insert(exclude, player.Character)
            end
        end

        params.FilterDescendantsInstances = exclude
        pcall(function() params.RespectCanCollide = true end)
    end)

    local result = nil
    local origin = Vector3.new(x, preferredCeiling + 2, z)
    local direction = Vector3.new(0, -20000, 0)

    local ok = pcall(function()
        result = workspace:Raycast(origin, direction, params)
    end)

    if ok and result then
        local position = nil
        pcall(function() position = result.Position end)
        if position then
            return position.Y
        end
    end

    return nil
end

-- Coordinate destinations use Y as a rough ceiling hint. Prefer a real Roblox
-- downward ray so unions/terrain use their actual visible surface; only fall
-- back to the older wrapper-box scan if raycasting is unavailable in Fiu.
findFloorNearY = function(x, z, hintY)
    local preferredCeiling = hintY + 8

    local rayY = raycastCoordinateGroundY(x, z, preferredCeiling)
    if rayY ~= nil then
        return rayY
    end

    local bestY = nil
    for _, part in ipairs(workspace:GetDescendants(true)) do
        local hitY = floorHitY(part, x, z, preferredCeiling)
        if hitY and (bestY == nil or hitY > bestY) then
            bestY = hitY
        end
    end

    return bestY
end

local function getCharacterDestination()
    local root = getLocalPlayerRoot()
    if not root then
        print("J RECALL: player root not found")
        return nil
    end

    local groundY = findFloorY(root.Position.X, root.Position.Z, root.Position.Y + 1)
    if groundY == nil then
        groundY = getPlayerGroundY(root)
    end

    local pivotY = groundY - tardisBottomOffset + RECALL_GROUND_CLEARANCE
    return CFrame.new(root.Position.X, pivotY, root.Position.Z) * defaultRotation
end

local function getPlayerQuery()
    if not inputB then return nil end

    local value = nil
    pcall(function() value = inputB:GetState() end)
    if type(value) ~= "string" then return nil end

    local query = string.match(value, "^%s*(.-)%s*$")
    if not query or query == "" then return nil end
    return string.lower(query)
end

local function resolvePlayerByQuery(query)
    if not query then return nil end

    local Players = nil
    pcall(function() Players = game:GetService("Players") end)
    if not Players then return nil end

    local players = nil
    pcall(function() players = Players:GetPlayers() end)
    if not players then return nil end

    local exactDisplay = nil
    local prefixUser = nil
    local prefixDisplay = nil

    for _, player in ipairs(players) do
        local username = string.lower(player.Name or "")
        local displayName = string.lower(player.DisplayName or "")

        if username == query then
            return player
        end
        if displayName == query and not exactDisplay then
            exactDisplay = player
        end
        if string.sub(username, 1, #query) == query and not prefixUser then
            prefixUser = player
        end
        if string.sub(displayName, 1, #query) == query and not prefixDisplay then
            prefixDisplay = player
        end
    end

    return exactDisplay or prefixUser or prefixDisplay
end

local function getPlayerInputDestination()
    local query = getPlayerQuery()
    if not query then return nil end

    local player = resolvePlayerByQuery(query)
    if not player then
        print("B TARGET NOT FOUND:", query)
        return nil
    end

    local character = nil
    pcall(function() character = player.Character end)
    if not character then return nil end

    local root = nil
    pcall(function() root = character:FindFirstChild("HumanoidRootPart") end)
    if not root then return nil end

    local groundY = findFloorY(root.Position.X, root.Position.Z, root.Position.Y + 1)
    if groundY == nil then
        groundY = getPlayerGroundY(root)
    end

    print("B TARGET:", player.Name)

    local pivotY = groundY - tardisBottomOffset + RECALL_GROUND_CLEARANCE
    return CFrame.new(root.Position.X, pivotY, root.Position.Z) * defaultRotation
end

local hiddenPivot = CFrame.new(HIDDEN_POSITION) * defaultRotation

local function setActualSoundProfile(actualSound, assetId, pitch)
    if not actualSound then return end
    pcall(function() actualSound.SoundId = "rbxassetid://" .. tostring(assetId) end)
    pcall(function() actualSound.PlaybackSpeed = pitch end)
end

local function applySoundProfile(profile)
    if not profile then return end

    local assetId = tostring(profile.id)
    local soundId = "rbxassetid://" .. assetId
    local pitch = tonumber(profile.pitch) or 1

    for _, block in ipairs({ matSound, interiorMatSound }) do
        if block then
            -- SoundBlock builds have used both numeric-looking and Roblox-style IDs;
            -- setting SoundId to the canonical Roblox string covers the normal property.
            setBlockValue(block, "SoundId", soundId)
            setBlockValue(block, "Pitch", pitch)
        end
    end

    setActualSoundProfile(matSoundInstance, assetId, pitch)
    setActualSoundProfile(interiorMatSoundInstance, assetId, pitch)

    print("TARDIS SOUND:", assetId, "pitch", pitch)
end

local function getTransitionSoundProfile(targetFade, quick)
    if targetFade >= 1 then
        return quick and SOUND_PROFILES.demat_quick or SOUND_PROFILES.demat_normal
    end
    return quick and SOUND_PROFILES.materialize_quick or SOUND_PROFILES.materialize_normal
end

local function getSoundLength(block)
    return tonumber(getBlockValue(block, "TimeLength")) or 0
end

local function soundIdMatches(soundId, assetId)
    if type(soundId) ~= "string" or not assetId then return false end
    return string.find(soundId, tostring(assetId), 1, true) ~= nil
end

-- Every transition must follow the sound that is actually playing, not a stale
-- Ultimate Build wrapper clock left over from the previous SoundId.
local function getTransitionSoundClock(block, actualSound, expectedAssetId)
    if actualSound then
        local actualId = nil
        local actualTime = nil
        local actualLength = nil
        local actualPlaying = nil

        pcall(function() actualId = actualSound.SoundId end)
        pcall(function() actualTime = actualSound.TimePosition end)
        pcall(function() actualLength = actualSound.TimeLength end)
        pcall(function() actualPlaying = actualSound.IsPlaying end)

        if soundIdMatches(actualId, expectedAssetId)
        and type(actualTime) == "number"
        and type(actualLength) == "number"
        and actualLength > 0 then
            return actualTime, actualLength, actualPlaying == true, "actual"
        end
    end

    local wrapperTime = tonumber(getBlockValue(block, "TimePosition"))
    local wrapperLength = tonumber(getBlockValue(block, "TimeLength"))
    local wrapperPlaying = getBlockValue(block, "IsPlaying") == true

    if wrapperTime ~= nil
    and wrapperLength ~= nil
    and wrapperLength > 0 then
        return wrapperTime, wrapperLength, wrapperPlaying, "wrapper"
    end

    return nil, nil, false, "wall"
end

local function getVisualEndTime(block)
    local length = getSoundLength(block)
    if length > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
        return length - SOUND_TAIL_TIME
    end
    return VISUAL_START_TIME + FALLBACK_FADE_TIME
end

local inputState = inputA:GetState() == true
local currentFade = inputState and 0 or 1
local hidden = not inputState
local lastInputState = inputState
local lastJState = false
local lastEState = false
local lastFState = false
local activeTransition = nil
local autoSequence = false

if inputState then
    setFadePartsTransparency(0)
    setLightEffect(0, 0, false)
else
    setFadePartsTransparency(1)
    setLightEffect(1, 0, false)
    moveTardis(hiddenPivot)
end

local function prepareMaterialization(kind)
    if not hidden then return true end

    setFadePartsTransparency(1)
    setLightEffect(1, 0, false)

    local destination
    if kind == "auto_materialize"
    or kind == "quick_recall_materialize" then
        destination = getCharacterDestination()
    else
        destination = getPlayerInputDestination()
        if not destination then
            destination = getInputDestination()
        end
    end

    if not destination then return false end

    moveTardis(destination)
    hidden = false
    currentFade = 1
    return true
end

local function syntheticWave(soundTime)
    local a = 0.5 + 0.5 * math.sin(soundTime * SYNTH_WAVE_RATE_A)
    local b = 0.5 + 0.5 * math.sin(soundTime * SYNTH_WAVE_RATE_B + 1.7)
    return math.clamp(a * 0.68 + b * 0.32, 0, 1)
end

local function updateWaveEnvelope(transition, soundTime)
    local raw, available = getPlaybackLoudness(transition.sound, transition.actualSound)
    local normalized

    if available then
        transition.loudnessPeak = math.max(
            MIN_LOUDNESS_PEAK,
            transition.loudnessPeak * 0.995,
            raw
        )
        normalized = math.clamp(raw / transition.loudnessPeak, 0, 1)
        normalized = math.pow(normalized, WAVE_GAMMA)
    else
        normalized = syntheticWave(soundTime or 0)
    end

    local envelope = transition.waveEnvelope or 0
    local alpha = normalized > envelope and WAVE_ATTACK or WAVE_RELEASE
    envelope = envelope + (normalized - envelope) * alpha
    transition.waveEnvelope = math.clamp(envelope, 0, 1)
    return transition.waveEnvelope
end

local function startTransition(kind, targetFade, fast)
    if activeTransition and activeTransition.sound then
        stopSound(activeTransition.sound)
    end
    activeTransition = nil

    if targetFade <= 0 and not prepareMaterialization(kind) then
        print("Materialization destination unavailable")
        return
    end

    local useFast = fast == true
    local profile = getTransitionSoundProfile(targetFade, useFast)
    applySoundProfile(profile)

    -- Let the SoundBlock/underlying Sound accept the new asset before playback.
    task.wait()

    local sound = matSound
    local actualSound = matSoundInstance
    local visualEnd = getVisualEndTime(sound)
    local visualProgress = targetFade >= 1 and currentFade or (1 - currentFade)
    visualProgress = math.clamp(visualProgress, 0, 1)

    -- Normal reversals can resume partway through their selected source. Quick
    -- transitions always start their dedicated quick asset from the beginning.
    local linearProgress = math.pow(visualProgress, 1 / AGGRESSIVE_PROGRESS_POWER)
    local seekPosition = 0
    if not useFast and visualProgress > 0.01 then
        seekPosition = VISUAL_START_TIME + linearProgress * (visualEnd - VISUAL_START_TIME)
    end

    playSound(sound, seekPosition)

    activeTransition = {
        kind = kind,
        targetFade = targetFade,
        sound = sound,
        actualSound = actualSound,
        soundPitch = tonumber(profile.pitch) or 1,
        soundId = profile.id,
        visualEnd = visualEnd,
        requestTime = os.clock(),
        startFade = currentFade,
        fast = useFast,
        fastSawPlaying = false,
        fastEndpointApplied = false,
        fastClockLogged = false,
        quickEndStingActive = false,
        quickEndStingStart = nil,
        quickEndStingSawPlaying = false,
        quickEndStingMaxTime = 0,
        maxSoundTime = seekPosition,
        visualComplete = false,
        fallback = false,
        fallbackStart = 0,
        fallbackTailStart = nil,
        waveEnvelope = 0,
        loudnessPeak = MIN_LOUDNESS_PEAK,
    }
end

local function requestDemat(kind, forceFast)
    local useFast = forceFast == true or fastTravelEnabled()
    startTransition(kind, 1, useFast)
end

local function requestMaterialize(kind, forceFast)
    local useFast = forceFast == true or fastTravelEnabled()
    startTransition(kind, 0, useFast)
end

local function finishTransition(transition)
    if activeTransition ~= transition then return end

    activeTransition = nil
    stopSound(transition.sound)

    if transition.targetFade >= 1 then
        currentFade = 1
        setFadePartsTransparency(1)
        setLightEffect(1, 0, false)
        moveTardis(hiddenPivot)
        hidden = true

        if transition.kind == "auto_demat" then
            requestMaterialize("auto_materialize")
        elseif transition.kind == "quick_recall_demat" then
            requestMaterialize("quick_recall_materialize", true)
        elseif transition.kind == "quick_destination_demat" then
            requestMaterialize("quick_destination_materialize", true)
        end
    else
        currentFade = 0
        setFadePartsTransparency(0)
        setLightEffect(0, 0, false)
        hidden = false

        if transition.kind == "auto_materialize" then
            autoSequence = false
            lastInputState = inputA:GetState() == true
            print("J RECALL COMPLETE")
        elseif transition.kind == "quick_recall_materialize" then
            autoSequence = false
            lastInputState = inputA:GetState() == true
            print("E QUICK RECALL COMPLETE")
        elseif transition.kind == "quick_destination_materialize" then
            autoSequence = false
            lastInputState = inputA:GetState() == true
            print("F QUICK DESTINATION COMPLETE")
        end
    end
end

local function startQuickEndSting(transition)
    if transition.quickEndStingActive then return end

    -- Keep the exterior pinned at its completed quick-travel state while the
    -- three-second end sting plays.
    currentFade = transition.targetFade
    setFadePartsTransparency(transition.targetFade)
    setLightEffect(transition.targetFade, 0, false)

    stopSound(transition.sound)
    applySoundProfile(SOUND_PROFILES.quick_end)
    task.wait()
    playSound(transition.sound, 0)

    transition.quickEndStingActive = true
    transition.quickEndStingStart = os.clock()
    transition.quickEndStingSawPlaying = false
    transition.quickEndStingMaxTime = 0

    print("QUICK END STING:", SOUND_PROFILES.quick_end.id, "first", QUICK_END_STING_SECONDS, "seconds")
end

local function updateQuickEndSting(transition, now)
    if not transition.quickEndStingActive then return false end

    local elapsed = now - (transition.quickEndStingStart or now)
    local soundTime, _, isPlaying =
        getTransitionSoundClock(
            transition.sound,
            transition.actualSound,
            SOUND_PROFILES.quick_end.id
        )

    if isPlaying then
        transition.quickEndStingSawPlaying = true
    end

    if soundTime and soundTime > transition.quickEndStingMaxTime then
        transition.quickEndStingMaxTime = soundTime
    end

    local finished = false

    -- Preferred path: stop at exactly the first three seconds of the real Sound.
    if soundTime and soundTime >= QUICK_END_STING_SECONDS then
        finished = true
    end

    -- If the sting itself is shorter than three seconds, do not hang the travel.
    if transition.quickEndStingSawPlaying
    and not isPlaying
    and transition.quickEndStingMaxTime > 0.01 then
        finished = true
    end

    -- Safety fallback if the engine does not expose this replacement asset's clock.
    if not soundTime and elapsed >= QUICK_END_STING_SECONDS then
        finished = true
    end

    if finished then
        finishTransition(transition)
        return true
    end

    return true
end

local function updateTransition()
    local transition = activeTransition
    if not transition then return end

    local now = os.clock()

    if transition.fast then
        if transition.quickEndStingActive then
            updateQuickEndSting(transition, now)
            return
        end

        local elapsed = now - transition.requestTime
        local soundTime, timeLength, isPlaying, clockSource =
            getTransitionSoundClock(
                transition.sound,
                transition.actualSound,
                transition.soundId
            )

        if not transition.fastClockLogged then
            if clockSource == "actual"
            or clockSource == "wrapper"
            or elapsed >= 0.25 then
                transition.fastClockLogged = true
                print(
                    "FAST SOUND CLOCK:",
                    clockSource,
                    "id", transition.soundId,
                    "time", soundTime,
                    "length", timeLength,
                    "pitch", transition.soundPitch
                )
            end
        end

        if isPlaying then
            transition.fastSawPlaying = true
        end
        if soundTime and soundTime > transition.maxSoundTime then
            transition.maxSoundTime = soundTime
        end

        -- The quick assets have their own requested pitch. Use the complete
        -- pitched playback duration as the wall-clock fallback if the SoundBlock
        -- does not expose a reliable IsPlaying/TimePosition clock.
        local pitchedSoundDuration = nil
        local soundPitch = math.max(transition.soundPitch or 1, 0.01)
        if timeLength and timeLength > 0 then
            pitchedSoundDuration = timeLength / soundPitch
        end

        local startFade = transition.startFade or currentFade
        local fadeDistance = math.abs(transition.targetFade - startFade)

        -- Drive quick visuals from the sound itself. Prefer the SoundBlock source
        -- timeline (TimePosition / TimeLength); only use wall-clock math if that
        -- clock is unavailable. Full visual completion happens near the end.
        local audioProgress = nil
        if timeLength and timeLength > 0 and soundTime and soundTime >= 0 then
            audioProgress = math.clamp(soundTime / timeLength, 0, 1)
        elseif pitchedSoundDuration then
            audioProgress = math.clamp(elapsed / pitchedSoundDuration, 0, 1)
        else
            audioProgress = math.clamp(elapsed / FAST_FADE_TIME, 0, 1)
        end

        local visualEndFraction
        local progressPower
        if transition.targetFade >= 1 then
            visualEndFraction = FAST_DEMAT_VISUAL_END_FRACTION
            progressPower = FAST_DEMAT_PROGRESS_POWER
        else
            visualEndFraction = FAST_MAT_VISUAL_END_FRACTION
            progressPower = FAST_MAT_PROGRESS_POWER
        end

        local linearProgress = math.clamp(
            audioProgress / visualEndFraction,
            0,
            1
        )
        local progress = math.pow(linearProgress, progressPower)
        local baseFade = startFade
            + (transition.targetFade - startFade) * progress
        currentFade = baseFade

        local waveTime = soundTime or (elapsed * (transition.soundPitch or 1))
        local wave = updateWaveEnvelope(transition, waveTime)
        local waveFade = getWaveDrivenFade(transition.targetFade, baseFade, wave)

        if linearProgress >= 1 then
            -- Once quick travel reaches its endpoint, pin it there. Do not let
            -- waveform modulation make the box look partly present again.
            waveFade = transition.targetFade
            currentFade = transition.targetFade
        end

        setLightEffect(waveFade, wave, true)

        if now - lastFadeWrite >= fadeUpdateInterval then
            lastFadeWrite = now
            setFadePartsTransparency(waveFade)
        end

        if linearProgress >= 1 and not transition.visualComplete then
            transition.visualComplete = true
            currentFade = transition.targetFade
            setFadePartsTransparency(transition.targetFade)
            setLightEffect(transition.targetFade, wave, true)

            -- For a quick demat, teleport the exterior away as soon as it is fully
            -- invisible near the end of the sound. The final audio tail can then
            -- finish naturally before any chained rematerialization begins.
            if transition.targetFade >= 1
            and not transition.fastEndpointApplied then
                transition.fastEndpointApplied = true
                moveTardis(hiddenPivot)
                hidden = true
            end
        end

        local soundFinished = false

        -- Best signal: the source timeline actually reached the end.
        if timeLength
        and timeLength > 0
        and transition.maxSoundTime >= timeLength - 0.05 then
            soundFinished = true
        end

        -- If the block exposes IsPlaying reliably, accept a completed stop only
        -- after we have observed it playing at least once.
        if transition.fastSawPlaying
        and not isPlaying
        and transition.maxSoundTime > 0.01 then
            soundFinished = true
        end

        -- Ultimate Build sometimes fails to expose IsPlaying/TimePosition. In that
        -- case wait the full mathematically sped-up duration before stopping it.
        if pitchedSoundDuration
        and elapsed >= pitchedSoundDuration + 0.05 then
            soundFinished = true
        end

        -- Last-resort fallback when no SoundBlock length/clock is available.
        if not pitchedSoundDuration
        and not transition.fastSawPlaying
        and elapsed >= FAST_FADE_TIME + FAST_TAIL_TIME then
            soundFinished = true
        end

        if transition.visualComplete and soundFinished then
            startQuickEndSting(transition)
        end
        return
    end

    local sound = transition.sound
    local soundTime, timeLength, isPlaying, clockSource =
        getTransitionSoundClock(
            transition.sound,
            transition.actualSound,
            transition.soundId
        )

    if not transition.fastClockLogged then
        if clockSource == "actual"
        or clockSource == "wrapper"
        or now - transition.requestTime >= 0.25 then
            transition.fastClockLogged = true
            print(
                "SOUND CLOCK:",
                clockSource,
                "id", transition.soundId,
                "time", soundTime,
                "length", timeLength,
                "pitch", transition.soundPitch
            )
        end
    end

    if not transition.fallback and soundTime then
        if soundTime > transition.maxSoundTime then transition.maxSoundTime = soundTime end

        if timeLength
        and timeLength > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
            transition.visualEnd = timeLength - SOUND_TAIL_TIME
        end

        local wave = updateWaveEnvelope(transition, soundTime)
        setLightEffect(currentFade, wave, true)

        if not transition.visualComplete and soundTime >= VISUAL_START_TIME then
            local linearProgress = math.clamp(
                (soundTime - VISUAL_START_TIME)
                / math.max(transition.visualEnd - VISUAL_START_TIME, 0.01),
                0,
                1
            )

            local progress = getAggressiveProgress(linearProgress)
            local baseFade = transition.targetFade >= 1 and progress or (1 - progress)
            currentFade = baseFade

            local waveFade = getWaveDrivenFade(transition.targetFade, baseFade, wave)
            setLightEffect(waveFade, wave, true)

            if now - lastFadeWrite >= fadeUpdateInterval then
                lastFadeWrite = now
                setFadePartsTransparency(waveFade)
            end

            if linearProgress >= 1 then
                transition.visualComplete = true
                currentFade = transition.targetFade
                setFadePartsTransparency(transition.targetFade)
                setLightEffect(transition.targetFade, wave, true)
            end
        end

        local soundFinished = false
        if transition.visualComplete then
            if timeLength
            and timeLength > 0
            and transition.maxSoundTime >= timeLength - 0.08 then
                soundFinished = true
            end
            if not isPlaying and transition.maxSoundTime > VISUAL_START_TIME then
                soundFinished = true
            end
        end

        if soundFinished then
            finishTransition(transition)
            return
        end

        if now - transition.requestTime >= SOUND_START_TIMEOUT
        and transition.maxSoundTime <= 0.01 then
            print("Audio clock unavailable; using fallback")
            transition.fallback = true
            transition.fallbackStart = now
        end

    elseif not transition.fallback then
        if now - transition.requestTime >= SOUND_START_TIMEOUT then
            transition.fallback = true
            transition.fallbackStart = now
        end
    end

    if transition.fallback then
        local elapsed = now - transition.fallbackStart
        local wave = updateWaveEnvelope(transition, elapsed)

        if elapsed <= FALLBACK_FADE_TIME then
            local linearProgress = math.clamp(elapsed / FALLBACK_FADE_TIME, 0, 1)
            local progress = getAggressiveProgress(linearProgress)
            local baseFade = transition.targetFade >= 1 and progress or (1 - progress)
            currentFade = baseFade

            local waveFade = getWaveDrivenFade(transition.targetFade, baseFade, wave)
            setLightEffect(waveFade, wave, true)

            if now - lastFadeWrite >= fadeUpdateInterval then
                lastFadeWrite = now
                setFadePartsTransparency(waveFade)
            end
        elseif not transition.visualComplete then
            transition.visualComplete = true
            currentFade = transition.targetFade
            setFadePartsTransparency(transition.targetFade)
            setLightEffect(transition.targetFade, wave, true)
            transition.fallbackTailStart = now
        elseif transition.fallbackTailStart
        and now - transition.fallbackTailStart >= FALLBACK_TAIL_TIME then
            finishTransition(transition)
        else
            setLightEffect(currentFade, wave, true)
        end
    end
end

local function startAutoRecall()
    print("J RECALL START")
    autoSequence = true

    if hidden or currentFade >= 1 then
        currentFade = 1
        setFadePartsTransparency(1)
        setLightEffect(1, 0, false)
        hidden = true
        requestMaterialize("auto_materialize")
    else
        requestDemat("auto_demat")
    end
end

local function startQuickRecall()
    print("E QUICK RECALL START")
    autoSequence = true

    if hidden or currentFade >= 1 then
        currentFade = 1
        setFadePartsTransparency(1)
        setLightEffect(1, 0, false)
        hidden = true
        requestMaterialize("quick_recall_materialize", true)
    else
        requestDemat("quick_recall_demat", true)
    end
end

local function startQuickDestination()
    print("F QUICK DESTINATION START")
    autoSequence = true

    if hidden or currentFade >= 1 then
        currentFade = 1
        setFadePartsTransparency(1)
        setLightEffect(1, 0, false)
        hidden = true
        requestMaterialize("quick_destination_materialize", true)
    else
        requestDemat("quick_destination_demat", true)
    end
end

print("TARDIS fast controls: D=quick-sound demat+remat, E=quick recall, F=quick B/C cycle")
print("TARDIS audio: one exterior + one mirrored interior SoundBlock")

-- Interior time rotor animation. It runs while dematting, fully dematerialized,
-- and rematerializing. Once the exterior is fully solid again it pauses exactly
-- where it is until the next dematerialization cycle.
local TIME_ROTOR_NAME = "timerotor"
local TIME_ROTOR_TRAVEL = 6
local TIME_ROTOR_TWEEN_TIME = 1.4 -- seconds from bottom to top
local timeRotorParts = {}
local timeRotorTweens = {}
local timeRotorFallbackBases = {}
local timeRotorFallbackStartTime = os.clock()
local TweenService = nil

pcall(function() TweenService = game:GetService("TweenService") end)

local function rotorNameMatches(block)
    local wanted = string.lower(TIME_ROTOR_NAME)

    local displayName = getDisplayName(block)
    if type(displayName) == "string" and string.lower(displayName) == wanted then
        return true
    end

    local objectName = getBlockValue(block, "Name")
    if type(objectName) == "string" and string.lower(objectName) == wanted then
        return true
    end

    local raw = nil
    pcall(function() raw = block.Part end)
    if raw then
        local rawName = nil
        pcall(function() rawName = raw.Name end)
        if type(rawName) == "string" and string.lower(rawName) == wanted then
            return true
        end
    end

    return false
end

for _, block in ipairs(workspace:GetDescendants(true)) do
    if block ~= script and rotorNameMatches(block) then
        local target = nil
        local cf = nil
        local raw = nil

        pcall(function() raw = block.Part end)
        if raw then
            pcall(function() cf = raw.CFrame end)
            if cf then target = raw end
        end

        if not target then
            pcall(function() cf = block.CFrame end)
            if cf then target = block end
        end

        if target and cf and not contains(timeRotorParts, target) then
            table.insert(timeRotorParts, target)
            timeRotorFallbackBases[target] = cf
            pcall(function() target.Anchored = true end)
        end
    end
end

local timeRotorTweening = false

if TweenService and #timeRotorParts > 0 then
    local tweenInfo = nil
    local infoOk = pcall(function()
        tweenInfo = TweenInfo.new(
            TIME_ROTOR_TWEEN_TIME,
            Enum.EasingStyle.Sine,
            Enum.EasingDirection.InOut,
            -1,
            true,
            0
        )
    end)

    if infoOk and tweenInfo then
        local created = 0

        for _, part in ipairs(timeRotorParts) do
            local base = timeRotorFallbackBases[part]
            if base then
                local tween = nil
                local ok = pcall(function()
                    tween = TweenService:Create(part, tweenInfo, {
                        CFrame = base + Vector3.new(0, TIME_ROTOR_TRAVEL, 0)
                    })
                end)

                if ok and tween then
                    table.insert(timeRotorTweens, tween)
                    created = created + 1
                end
            end
        end

        timeRotorTweening = created == #timeRotorParts and created > 0
    end
end

local timeRotorRunning = false

local function setTimeRotorRunning(shouldRun)
    if shouldRun == timeRotorRunning then return end
    timeRotorRunning = shouldRun

    if timeRotorTweening then
        for _, tween in ipairs(timeRotorTweens) do
            pcall(function()
                if shouldRun then
                    tween:Play()
                else
                    tween:Pause()
                end
            end)
        end
    elseif shouldRun then
        timeRotorFallbackStartTime = os.clock()
    end
end

local function shouldRunTimeRotor()
    if hidden then return true end
    if activeTransition then return true end
    return currentFade > 0.001
end

print("TARDIS time rotor blocks:", #timeRotorParts)
print("TARDIS time rotor tweening:", timeRotorTweening)

-- Safety fallback only if TweenService is unavailable in the UB/Fiu sandbox.
local function updateTimeRotorFallback()
    if timeRotorTweening or not timeRotorRunning or #timeRotorParts == 0 then return end

    local elapsed = os.clock() - timeRotorFallbackStartTime
    local cycleSeconds = TIME_ROTOR_TWEEN_TIME * 2
    local offsetY = (0.5 + 0.5 * math.sin(
        elapsed * math.pi * 2 / cycleSeconds - math.pi / 2
    )) * TIME_ROTOR_TRAVEL

    for _, part in ipairs(timeRotorParts) do
        local base = timeRotorFallbackBases[part]
        if base then
            pcall(function()
                part.CFrame = base + Vector3.new(0, offsetY, 0)
            end)
        end
    end
end

while true do
    local eState = getOptionalBoolInput(inputE)
    if eState and not lastEState and not autoSequence then
        startQuickRecall()
    end
    lastEState = eState

    local fState = getOptionalBoolInput(inputF)
    if fState and not lastFState and not autoSequence then
        startQuickDestination()
    end
    lastFState = fState

    local jState = inputJ:GetState() == true
    if jState and not lastJState and not autoSequence then
        startAutoRecall()
    end
    lastJState = jState

    if not autoSequence then
        local newState = inputA:GetState() == true
        if newState ~= lastInputState then
            lastInputState = newState
            if newState then
                requestMaterialize("manual_materialize")
            else
                requestDemat("manual_demat")
            end
        end
    end

    updateTransition()
    setTimeRotorRunning(shouldRunTimeRotor())
    updateTimeRotorFallback()
    task.wait(MAIN_UPDATE_INTERVAL)
end