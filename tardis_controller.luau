-- TARDIS controller
-- A: true=materialized, false=dematerialized
-- C: normal destination (Vector3/CFrame)
-- J: recall (demat, then remat on local player)
-- No Code outputs are required.

local inputA = script.inputs["a"]
local inputC = script.inputs["c"]
local inputJ = script.inputs["j"]

local SHELL_NAME = "Tardis"
local DEMAT_SOUND_NAME = "TardisDematSound"
local MAT_SOUND_NAME = "TardisMatSound"
local LIGHT_NAME = "Tardislight"

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
local SOUND_PITCH = 1

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

local dematSound = findNamedBlock(DEMAT_SOUND_NAME)
local matSound = findNamedBlock(MAT_SOUND_NAME)
local tardisLight = findNamedBlock(LIGHT_NAME)

print(dematSound and "FOUND: TardisDematSound" or "ERROR: missing TardisDematSound")
print(matSound and "FOUND: TardisMatSound" or "ERROR: missing TardisMatSound")
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
    setBlockValue(block, "Pitch", SOUND_PITCH)
    setBlockValue(block, "Effects", false)
end

configureSound(dematSound)
configureSound(matSound)

local function stopSound(block)
    if not block then return end
    setSoundPowered(block, false)
    task.wait()
    setBlockValue(block, "TimePosition", 0)
end

local function playSound(block, position)
    if not block then return false end
    setSoundPowered(block, false)
    task.wait()
    setBlockValue(block, "TimePosition", position or 0)
    setSoundPowered(block, true)
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

local dematSoundInstance = findActualSoundInstance(dematSound)
local matSoundInstance = findActualSoundInstance(matSound)

print(dematSoundInstance and "DEMAT PlaybackLoudness available" or "DEMAT loudness fallback enabled")
print(matSoundInstance and "MAT PlaybackLoudness available" or "MAT loudness fallback enabled")

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
-- moveParts include shell + sounds + roof light.
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

addPart(moveParts, dematSound)
addPart(moveParts, matSound)
addPart(moveParts, tardisLight)
addPart(fadeParts, dematSound)
addPart(fadeParts, matSound)

print("TARDIS shell blocks:", #shellParts)
print("TARDIS moving blocks:", #moveParts)
print("TARDIS wave-fading blocks:", #fadeParts)

-- Click-to-enter is deliberately isolated from all TARDIS movement/fade lists.
local ENTER_TARGET_NAME = "interiortardisteleportspot"

local function getClickRawPart(block)
    if not block then return nil end

    local raw = nil
    pcall(function() raw = block.Part end)
    if raw then return raw end

    if typeof(block) == "Instance" then return block end
    return nil
end

local function findEnterTarget()
    local wanted = string.lower(ENTER_TARGET_NAME)

    for _, block in ipairs(workspace:GetDescendants(true)) do
        if block ~= script then
            local displayName = getDisplayName(block)
            if displayName and string.lower(displayName) == wanted then
                return block
            end

            local objectName = getBlockValue(block, "Name")
            if type(objectName) == "string" and string.lower(objectName) == wanted then
                return block
            end

            local raw = getClickRawPart(block)
            if raw then
                local rawName = nil
                pcall(function() rawName = raw.Name end)
                if type(rawName) == "string" and string.lower(rawName) == wanted then
                    return block
                end
            end
        end
    end

    return nil
end

local enterTarget = findEnterTarget()

local function getEnterTargetCFrame()
    if not enterTarget then
        enterTarget = findEnterTarget()
    end
    if not enterTarget then return nil end

    local cf = nil
    pcall(function() cf = enterTarget.CFrame end)
    if cf then return cf end

    local raw = getClickRawPart(enterTarget)
    if raw then
        pcall(function() cf = raw.CFrame end)
    end

    return cf
end

local clickableCount = 0

for _, part in ipairs(shellParts) do
    local raw = getClickRawPart(part)
    if raw then
        local detector = nil
        pcall(function() detector = raw:FindFirstChildOfClass("ClickDetector") end)

        if not detector then
            pcall(function()
                detector = Instance.new("ClickDetector")
                detector.Name = "TardisEnterClick"
                detector.MaxActivationDistance = 18
                detector.Parent = raw
            end)
        end

        if detector then
            local connected = pcall(function()
                detector.MouseClick:Connect(function(player)
                    if not player then return end

                    local targetCFrame = getEnterTargetCFrame()
                    if not targetCFrame then return end

                    local character = player.Character
                    if not character then return end

                    local root = character:FindFirstChild("HumanoidRootPart")
                    if root then
                        root.CFrame = targetCFrame * CFrame.new(0, 3, 0)
                    end
                end)
            end)

            if connected then
                clickableCount = clickableCount + 1
            end
        end
    end
end

print("TARDIS clickable blocks:", clickableCount)

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

local function getInputDestination()
    local value = inputC:GetState()
    if typeof(value) == "Vector3" then return CFrame.new(value) * defaultRotation end
    if typeof(value) == "CFrame" then return value end
    print("Input C must be Vector3 or CFrame. Got:", typeof(value))
    return startingPivot
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

local function findFloorY(x, z, maxY)
    local bestY = nil

    for _, part in ipairs(workspace:GetDescendants(true)) do
        local hitY = floorHitY(part, x, z, maxY)
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

local hiddenPivot = CFrame.new(HIDDEN_POSITION) * defaultRotation

local function getSoundLength(block)
    return tonumber(getBlockValue(block, "TimeLength")) or 0
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
    if kind == "auto_materialize" then
        destination = getCharacterDestination()
    else
        destination = getInputDestination()
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

local function startTransition(kind, targetFade, sound, actualSound)
    if activeTransition and activeTransition.sound then
        stopSound(activeTransition.sound)
    end
    activeTransition = nil

    if targetFade <= 0 and not prepareMaterialization(kind) then
        print("Materialization destination unavailable")
        return
    end

    if sound == dematSound then stopSound(matSound) else stopSound(dematSound) end

    local visualEnd = getVisualEndTime(sound)
    local visualProgress = targetFade >= 1 and currentFade or (1 - currentFade)
    visualProgress = math.clamp(visualProgress, 0, 1)

    -- Undo the aggressive curve when mapping current transparency back to audio time.
    local linearProgress = math.pow(visualProgress, 1 / AGGRESSIVE_PROGRESS_POWER)
    local seekPosition = 0
    if visualProgress > 0.01 then
        seekPosition = VISUAL_START_TIME + linearProgress * (visualEnd - VISUAL_START_TIME)
    end

    playSound(sound, seekPosition)

    activeTransition = {
        kind = kind,
        targetFade = targetFade,
        sound = sound,
        actualSound = actualSound,
        visualEnd = visualEnd,
        requestTime = os.clock(),
        maxSoundTime = seekPosition,
        visualComplete = false,
        fallback = false,
        fallbackStart = 0,
        fallbackTailStart = nil,
        waveEnvelope = 0,
        loudnessPeak = MIN_LOUDNESS_PEAK,
    }
end

local function requestDemat(kind)
    startTransition(kind, 1, dematSound, dematSoundInstance)
end

local function requestMaterialize(kind)
    startTransition(kind, 0, matSound, matSoundInstance)
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
        end
    end
end

local function updateTransition()
    local transition = activeTransition
    if not transition then return end

    local now = os.clock()
    local sound = transition.sound
    local soundTime = tonumber(getBlockValue(sound, "TimePosition"))
    local isPlaying = getBlockValue(sound, "IsPlaying") == true
    local timeLength = getSoundLength(sound)

    if not transition.fallback and soundTime then
        if soundTime > transition.maxSoundTime then transition.maxSoundTime = soundTime end

        if timeLength > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
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
            if timeLength > 0 and transition.maxSoundTime >= timeLength - 0.08 then
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

while true do
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
    task.wait(MAIN_UPDATE_INTERVAL)
end