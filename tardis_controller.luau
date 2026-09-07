-- TARDIS controller
--
-- INPUT A
--   true  = materialized
--   false = dematerialized
--
-- INPUT C
--   normal destination (Vector3 or CFrame)
--
-- INPUT J
--   rising edge = demat, then remat on local player
--
-- DISPLAY NAMES
--   Tardis             = every shell piece
--   TardisDematSound   = dematerialization SoundBlock
--   TardisMatSound     = materialization SoundBlock
--   Tardislight        = roof lamp
--
-- IMPORTANT:
-- This now copies the replication pattern from the old skyshow/orbit command
-- system: ALL networked BasePart properties are written ONLY through the UB
-- proxy with object[property] = value. We NEVER write CFrame/Transparency/
-- Anchored/CanCollide through .Part before the proxy write.
--
-- .Part is read-only here and is only used to read PlaybackLoudness from the
-- actual Roblox Sound instance.

local inputA = script.inputs["a"]
local inputC = script.inputs["c"]
local inputJ = script.inputs["j"]

--------------------------------------------------
-- NAMES
--------------------------------------------------

local SHELL_NAME = "Tardis"
local DEMAT_SOUND_NAME = "TardisDematSound"
local MAT_SOUND_NAME = "TardisMatSound"
local LIGHT_NAME = "Tardislight"

--------------------------------------------------
-- EFFECT SETTINGS
--------------------------------------------------

local VISUAL_START_TIME = 0.20
local SOUND_TAIL_TIME = 2.50
local FALLBACK_FADE_TIME = 14
local FALLBACK_TAIL_TIME = 2.50
local SOUND_START_TIMEOUT = 3
local LOOP_INTERVAL = 1 / 60

-- Very aggressive audio following.
local FADE_AGGRESSION = 0.32
local SHELL_WAVE_STRENGTH = 1.00
local LOUDNESS_GAMMA = 0.20
local LOUDNESS_PEAK_FLOOR = 35
local TRANSIENT_BOOST = 4.0
local ATTACK = 1.00
local RELEASE = 0.72

local LIGHT_MIN_BRIGHTNESS = 0.02
local LIGHT_MAX_BRIGHTNESS = 18
local LIGHT_IDLE_BRIGHTNESS_DEFAULT = 2

local SOUND_VOLUME = 1
local SOUND_PITCH = 1

--------------------------------------------------
-- REPLICATION BUDGET
--
-- UB historically documented a 2500/s property remote limit.
-- Keep shell writes well below that.
--------------------------------------------------

local FADE_WRITE_BUDGET = 1600
local FADE_MAX_HZ = 20
local FADE_MIN_HZ = 3
local LIGHT_HZ = 20
local MOVE_BATCH_SIZE = 40

--------------------------------------------------
-- POSITIONING
--------------------------------------------------

local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10

--------------------------------------------------
-- UB PROXY HELPERS
--------------------------------------------------

-- EXACTLY like the old skyshow/orbit command system.
-- This is for REAL PROPERTIES such as CFrame, Transparency, Anchored, etc.
-- NO ATTRIBUTE FALLBACK. If this fails, we want to know it failed.
local function setProperty(object, property, value)
    if not object then
        return false
    end

    local ok = pcall(function()
        object[property] = value
    end)

    return ok
end

local function getProperty(object, property)
    if not object then
        return nil
    end

    local ok, value = pcall(function()
        return object[property]
    end)

    if ok then
        return value
    end

    return nil
end

-- Settings/attributes are separate from BasePart properties.
local function getAttribute(object, name)
    if not object then
        return nil
    end

    local ok, value = pcall(function()
        return object.attributes[name]
    end)

    if ok and value ~= nil then
        return value
    end

    ok, value = pcall(function()
        return object:GetAttribute(name)
    end)

    if ok then
        return value
    end

    return nil
end

local function setAttribute(object, name, value)
    if not object then
        return false
    end

    local ok = pcall(function()
        object.attributes[name] = value
    end)

    if ok then
        return true
    end

    return pcall(function()
        object:SetAttribute(name, value)
    end)
end

-- Sound/light settings can be exposed either as proxy properties or attributes.
local function getSetting(object, name)
    local value = getProperty(object, name)
    if value ~= nil then
        return value
    end

    return getAttribute(object, name)
end

local function setSetting(object, name, value)
    if setProperty(object, name, value) then
        return true
    end

    return setAttribute(object, name, value)
end

--------------------------------------------------
-- DISPLAY NAME
--------------------------------------------------

local function getDisplayName(object)
    if not object then
        return nil
    end

    local value = getProperty(object, "DisplayName")
    if type(value) == "string" and value ~= "" then
        return value
    end

    for _, key in ipairs({"Display name", "DisplayName"}) do
        value = getAttribute(object, key)
        if type(value) == "string" and value ~= "" then
            return value
        end
    end

    value = getProperty(object, "Name")
    if type(value) == "string" and value ~= "" then
        return value
    end

    return nil
end

--------------------------------------------------
-- FIND OWNED UB BLOCKS
--------------------------------------------------

local ownedParts = workspace:GetDescendants(true)

local function findNamedBlock(name)
    for _, object in ipairs(ownedParts) do
        if object ~= script then
            local displayName = getDisplayName(object)

            if displayName
            and string.lower(displayName) == string.lower(name) then
                return object
            end
        end
    end

    return nil
end

local dematSound = findNamedBlock(DEMAT_SOUND_NAME)
local matSound = findNamedBlock(MAT_SOUND_NAME)
local tardisLight = findNamedBlock(LIGHT_NAME)

print(dematSound and "FOUND TardisDematSound" or "WARNING: TardisDematSound missing")
print(matSound and "FOUND TardisMatSound" or "WARNING: TardisMatSound missing")
print(tardisLight and "FOUND Tardislight" or "WARNING: Tardislight missing")

--------------------------------------------------
-- RAW READ-ONLY SOUND ACCESS
--------------------------------------------------

local function getRawPart(block)
    if not block then
        return nil
    end

    local ok, raw = pcall(function()
        return block.Part
    end)

    if ok then
        return raw
    end

    return nil
end

local function findRawSound(block)
    local rawPart = getRawPart(block)
    if not rawPart then
        return nil
    end

    local ok, sound = pcall(function()
        return rawPart:FindFirstChildWhichIsA("Sound", true)
    end)

    if ok then
        return sound
    end

    return nil
end

local rawDematSound = findRawSound(dematSound)
local rawMatSound = findRawSound(matSound)

--------------------------------------------------
-- DIRECT SOUNDBLOCK CONTROL
--------------------------------------------------

local function getSoundInput(block)
    if not block then
        return nil
    end

    for _, name in ipairs({"Input", "input", "Toggle", "toggle", "a", "A"}) do
        local ok, value = pcall(function()
            return block.inputs[name]
        end)

        if ok and value then
            return value
        end
    end

    local ok, inputTable = pcall(function()
        return block.inputs
    end)

    if ok and inputTable then
        local success, result = pcall(function()
            for _, value in pairs(inputTable) do
                return value
            end
        end)

        if success then
            return result
        end
    end

    return nil
end

local function setSoundPowered(block, state)
    if not block then
        return false
    end

    local input = getSoundInput(block)

    if input then
        local ok = pcall(function()
            input:Fire(state, true)
        end)

        if ok then
            return true
        end

        ok = pcall(function()
            input:SetState(state)
        end)

        if ok then
            return true
        end
    end

    for _, name in ipairs({"Input", "input", "Toggle", "toggle", "a"}) do
        local ok = pcall(function()
            block:FireInput(name, state)
        end)

        if ok then
            return true
        end
    end

    return false
end

local function configureSound(block)
    if not block then
        return
    end

    setSetting(block, "Repeat", false)
    setSetting(block, "ResetTimePosition", false)
    setSetting(block, "Volume", SOUND_VOLUME)
    setSetting(block, "Pitch", SOUND_PITCH)
    setSetting(block, "Effects", false)
end

configureSound(dematSound)
configureSound(matSound)

local function stopSound(block)
    if not block then
        return
    end

    setSoundPowered(block, false)
    task.wait()
    setSetting(block, "TimePosition", 0)
end

local function playSound(block, position)
    if not block then
        return false
    end

    setSoundPowered(block, false)
    task.wait()
    setSetting(block, "TimePosition", position or 0)
    return setSoundPowered(block, true)
end

--------------------------------------------------
-- PART GROUPS
--------------------------------------------------

local shellParts = {}
local moveParts = {}
local fadeParts = {}
local relativeCFrames = {}

local function contains(list, object)
    for _, existing in ipairs(list) do
        if existing == object then
            return true
        end
    end

    return false
end

local function addMovable(list, object)
    if not object or contains(list, object) then
        return
    end

    if typeof(getProperty(object, "CFrame")) == "CFrame" then
        table.insert(list, object)
    end
end

for _, object in ipairs(ownedParts) do
    if object ~= script then
        local displayName = getDisplayName(object)

        if displayName
        and string.lower(displayName) == string.lower(SHELL_NAME)
        and typeof(getProperty(object, "CFrame")) == "CFrame" then
            table.insert(shellParts, object)
            addMovable(moveParts, object)
            addMovable(fadeParts, object)
        end
    end
end

-- SoundBlocks move + fade with shell.
addMovable(moveParts, dematSound)
addMovable(moveParts, matSound)
addMovable(fadeParts, dematSound)
addMovable(fadeParts, matSound)

-- Roof light moves, but gets separate waveform transparency.
addMovable(moveParts, tardisLight)

print("TARDIS shell blocks:", #shellParts)
print("TARDIS moving blocks:", #moveParts)
print("TARDIS fading blocks:", #fadeParts)

--------------------------------------------------
-- STARTUP ANCHOR / COLLISION
--
-- Proxy ONLY, exactly like the preplaced command cubes.
--------------------------------------------------

local function lockTardisAssembly()
    local anchorFailures = 0
    local collideFailures = 0

    for index, object in ipairs(moveParts) do
        if not setProperty(object, "Anchored", true) then
            anchorFailures = anchorFailures + 1
        end

        if not setProperty(object, "CanCollide", true) then
            collideFailures = collideFailures + 1
        end

        if index % MOVE_BATCH_SIZE == 0 then
            task.wait()
        end
    end

    print(
        "TARDIS startup lock complete. Anchor failures:",
        anchorFailures,
        "Collision failures:",
        collideFailures
    )
end

lockTardisAssembly()

--------------------------------------------------
-- PIVOT / OFFSETS
--------------------------------------------------

local startingPivot = nil

if #shellParts > 0 then
    startingPivot = getProperty(shellParts[1], "CFrame")
end

if startingPivot then
    for _, object in ipairs(moveParts) do
        local cf = getProperty(object, "CFrame")
        if typeof(cf) == "CFrame" then
            relativeCFrames[object] = startingPivot:ToObjectSpace(cf)
        end
    end
end

local defaultRotation =
    startingPivot
    and (startingPivot - startingPivot.Position)
    or CFrame.identity

--------------------------------------------------
-- FIND ACTUAL SHELL BOTTOM
--------------------------------------------------

local tardisBottomOffset = 0

if startingPivot then
    local lowestBottom = math.huge

    for _, object in ipairs(shellParts) do
        local cf = getProperty(object, "CFrame")
        local size = getProperty(object, "Size")

        if typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
            local halfHeight =
                math.abs(cf.RightVector.Y) * (size.X / 2)
                + math.abs(cf.UpVector.Y) * (size.Y / 2)
                + math.abs(cf.LookVector.Y) * (size.Z / 2)

            local bottom = cf.Position.Y - halfHeight
            if bottom < lowestBottom then
                lowestBottom = bottom
            end
        end
    end

    if lowestBottom < math.huge then
        tardisBottomOffset = lowestBottom - startingPivot.Position.Y
    end
end

--------------------------------------------------
-- SERVER-REPLICATED MOVEMENT
--
-- NO .Part writes. This mirrors skyshow exactly.
--------------------------------------------------

local function moveTardis(pivot)
    if not pivot then
        return false
    end

    local failures = 0

    for index, object in ipairs(moveParts) do
        local offset = relativeCFrames[object]

        if offset then
            if not setProperty(object, "CFrame", pivot * offset) then
                failures = failures + 1
            end
        end

        if index % MOVE_BATCH_SIZE == 0 then
            task.wait()
        end
    end

    if failures > 0 then
        print("TARDIS CFrame proxy write failures:", failures)
    else
        print("TARDIS server move sent:", pivot.Position)
    end

    return failures == 0
end

--------------------------------------------------
-- SERVER-REPLICATED TRANSPARENCY
--------------------------------------------------

local fadeCount = math.max(#fadeParts, 1)
local fadeHz = math.floor(FADE_WRITE_BUDGET / fadeCount)
fadeHz = math.clamp(fadeHz, FADE_MIN_HZ, FADE_MAX_HZ)
local fadeInterval = 1 / fadeHz
local lastFadeWrite = -math.huge
local lastFadeValue = nil

print("TARDIS replicated fade rate:", fadeHz, "Hz")

local function setShellTransparency(value, force)
    value = math.clamp(value, 0, 1)
    local now = os.clock()

    if not force then
        if now - lastFadeWrite < fadeInterval then
            return
        end

        if lastFadeValue ~= nil
        and math.abs(value - lastFadeValue) < 0.01 then
            return
        end
    end

    lastFadeWrite = now
    lastFadeValue = value

    for _, object in ipairs(fadeParts) do
        setProperty(object, "Transparency", value)
    end
end

--------------------------------------------------
-- ROOF LIGHT
--------------------------------------------------

local lightIdleBrightness =
    tonumber(getSetting(tardisLight, "Brightness"))
    or LIGHT_IDLE_BRIGHTNESS_DEFAULT

local lightIdleTransparency =
    tonumber(getProperty(tardisLight, "Transparency"))
    or 0

local lightInterval = 1 / LIGHT_HZ
local lastLightWrite = -math.huge

local function setTopLight(brightness, transparency, force)
    if not tardisLight then
        return
    end

    local now = os.clock()
    if not force and now - lastLightWrite < lightInterval then
        return
    end

    lastLightWrite = now

    brightness = math.max(0, brightness or 0)
    transparency = math.clamp(transparency or 0, 0, 1)

    setProperty(tardisLight, "Transparency", transparency)
    setSetting(tardisLight, "Brightness", brightness)
end

local function setIdleLight(isHidden)
    if isHidden then
        setTopLight(0, 1, true)
    else
        setTopLight(lightIdleBrightness, lightIdleTransparency, true)
    end
end

--------------------------------------------------
-- DESTINATIONS
--------------------------------------------------

local function getInputDestination()
    local value = inputC:GetState()

    if typeof(value) == "Vector3" then
        return CFrame.new(value) * defaultRotation
    end

    if typeof(value) == "CFrame" then
        return value
    end

    print("Input C must be Vector3 or CFrame. Got:", typeof(value))
    return startingPivot
end

local function getLocalPlayerRoot()
    local Players = nil

    pcall(function()
        Players = game:GetService("Players")
    end)

    if not Players then
        return nil
    end

    local player = nil
    pcall(function()
        player = Players.LocalPlayer
    end)

    if not player then
        return nil
    end

    local character = nil
    pcall(function()
        character = player.Character
    end)

    if not character then
        return nil
    end

    local root = nil
    pcall(function()
        root = character:FindFirstChild("HumanoidRootPart")
    end)

    return root
end

local function getPlayerGroundY(root)
    local groundY = root.Position.Y - 3
    local character = root.Parent

    if not character then
        return groundY
    end

    local humanoid = nil
    pcall(function()
        humanoid = character:FindFirstChildOfClass("Humanoid")
    end)

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
        print("J RECALL: player root not found")
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

local hiddenPivot = CFrame.new(HIDDEN_POSITION) * defaultRotation

--------------------------------------------------
-- AUDIO CLOCK / WAVEFORM
--------------------------------------------------

local function getSoundLength(block)
    return tonumber(getSetting(block, "TimeLength")) or 0
end

local function getSoundTime(block)
    return tonumber(getSetting(block, "TimePosition"))
end

local function getIsPlaying(block)
    return getSetting(block, "IsPlaying") == true
end

local function readPlaybackLoudness(block)
    local rawSound = nil

    if block == dematSound then
        rawSound = rawDematSound
    elseif block == matSound then
        rawSound = rawMatSound
    end

    if rawSound then
        local ok, value = pcall(function()
            return rawSound.PlaybackLoudness
        end)

        if ok and type(value) == "number" then
            return value, true
        end
    end

    local value = tonumber(getSetting(block, "PlaybackLoudness"))
    if value then
        return value, true
    end

    return 0, false
end

local function getVisualEndTime(block)
    local length = getSoundLength(block)

    if length > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
        return length - SOUND_TAIL_TIME
    end

    return VISUAL_START_TIME + FALLBACK_FADE_TIME
end

local function syntheticPulse(t)
    local wave =
        0.48
        + 0.26 * math.sin(t * 12.2)
        + 0.16 * math.sin(t * 25.1 + 1.1)
        + 0.10 * math.sin(t * 41.3 + 0.3)

    return math.clamp(wave, 0, 1) ^ 0.35
end

local function updateAudioPulse(transition, soundTime)
    local loudness, hasReal = readPlaybackLoudness(transition.sound)

    if not hasReal then
        transition.lastPulse = syntheticPulse(soundTime or 0)
        return transition.lastPulse
    end

    if loudness > transition.peak then
        transition.peak = loudness
    else
        transition.peak = math.max(
            LOUDNESS_PEAK_FLOOR,
            transition.peak * 0.993
        )
    end

    local normalized = math.clamp(
        loudness / math.max(transition.peak, 1),
        0,
        1
    )

    local shaped = normalized ^ LOUDNESS_GAMMA
    local alpha = shaped > transition.envelope and ATTACK or RELEASE

    transition.envelope =
        transition.envelope
        + (shaped - transition.envelope) * alpha

    local transient = math.max(
        0,
        transition.envelope - transition.previousEnvelope
    )

    transition.previousEnvelope = transition.envelope

    transition.lastPulse = math.clamp(
        transition.envelope + transient * TRANSIENT_BOOST,
        0,
        1
    )

    return transition.lastPulse
end

--------------------------------------------------
-- AUDIO -> VISUAL
--------------------------------------------------

local function getWaveTransparency(targetFade, progress, pulse)
    progress = math.clamp(progress, 0, 1)
    pulse = math.clamp(pulse or 0, 0, 1)

    local aggressive = progress ^ FADE_AGGRESSION

    if targetFade >= 1 then
        local base = aggressive
        return math.clamp(
            base + pulse * SHELL_WAVE_STRENGTH * (1 - base),
            0,
            1
        )
    end

    local base = 1 - aggressive
    return math.clamp(
        base - pulse * SHELL_WAVE_STRENGTH * base,
        0,
        1
    )
end

local function updateReplicatedVisual(transition, progress, pulse, force)
    local transparency = getWaveTransparency(
        transition.targetFade,
        progress,
        pulse
    )

    setShellTransparency(transparency, force == true)

    -- Lamp follows the waveform even harder than the shell.
    local lampPulse = math.clamp(pulse or 0, 0, 1) ^ 0.12
    local brightness =
        LIGHT_MIN_BRIGHTNESS
        + (LIGHT_MAX_BRIGHTNESS - LIGHT_MIN_BRIGHTNESS) * lampPulse

    local lampTransparency = math.clamp(1 - lampPulse * 1.2, 0, 1)

    if pulse >= 0.72 then
        brightness = LIGHT_MAX_BRIGHTNESS
        lampTransparency = 0
    end

    setTopLight(brightness, lampTransparency, force == true)
end

--------------------------------------------------
-- STATE
--------------------------------------------------

local inputState = inputA:GetState() == true
local currentFade = inputState and 0 or 1
local hidden = not inputState
local lastInputState = inputState
local lastJState = false
local activeTransition = nil
local autoSequence = false

--------------------------------------------------
-- INITIAL STATE
--------------------------------------------------

if inputState then
    setShellTransparency(0, true)
    setIdleLight(false)
else
    setShellTransparency(1, true)
    setIdleLight(true)
    moveTardis(hiddenPivot)
end

--------------------------------------------------
-- MATERIALIZATION LOCATION
--------------------------------------------------

local function prepareMaterialization(kind)
    if not hidden then
        return true
    end

    setShellTransparency(1, true)
    setTopLight(0, 1, true)

    local destination

    if kind == "auto_materialize" then
        destination = getCharacterDestination()
    else
        destination = getInputDestination()
    end

    if not destination then
        return false
    end

    -- Server-replicated proxy move happens while shell is invisible.
    moveTardis(destination)

    hidden = false
    currentFade = 1
    return true
end

--------------------------------------------------
-- TRANSITIONS
--------------------------------------------------

local function startTransition(kind, targetFade, sound)
    if activeTransition and activeTransition.sound then
        stopSound(activeTransition.sound)
    end

    activeTransition = nil

    if targetFade <= 0 then
        if not prepareMaterialization(kind) then
            print("TARDIS: materialization destination unavailable")
            return false
        end
    end

    if sound == dematSound then
        stopSound(matSound)
    else
        stopSound(dematSound)
    end

    local visualEnd = getVisualEndTime(sound)

    local completedProgress
    if targetFade >= 1 then
        completedProgress = currentFade
    else
        completedProgress = 1 - currentFade
    end

    completedProgress = math.clamp(completedProgress, 0, 1)

    -- currentFade stores aggressive/base progress; invert curve to seek audio.
    local linearCompleted = 0
    if completedProgress > 0 then
        linearCompleted = completedProgress ^ (1 / FADE_AGGRESSION)
    end

    local seekPosition = 0
    if completedProgress > 0.01 then
        seekPosition =
            VISUAL_START_TIME
            + linearCompleted * (visualEnd - VISUAL_START_TIME)
    end

    local soundStarted = false
    if sound then
        soundStarted = playSound(sound, seekPosition)
    end

    local now = os.clock()

    activeTransition = {
        kind = kind,
        targetFade = targetFade,
        sound = sound,
        visualEnd = visualEnd,
        requestTime = now,
        maxSoundTime = seekPosition,
        soundAdvanced = false,
        visualComplete = false,
        visualCompleteAt = nil,

        fallback = not soundStarted,
        fallbackStart = now,
        fallbackStartProgress = linearCompleted,
        fallbackDuration = math.max(
            0.05,
            FALLBACK_FADE_TIME * (1 - linearCompleted)
        ),

        peak = LOUDNESS_PEAK_FLOOR,
        envelope = 0,
        previousEnvelope = 0,
        lastPulse = 0,
    }

    if not soundStarted then
        print("TARDIS: sound unavailable; using fallback clock")
    end

    return true
end

local function requestDemat(kind)
    return startTransition(kind, 1, dematSound)
end

local function requestMaterialize(kind)
    return startTransition(kind, 0, matSound)
end

--------------------------------------------------
-- FINISH TRANSITION
--------------------------------------------------

local function finishTransition(transition)
    if activeTransition ~= transition then
        return
    end

    activeTransition = nil
    stopSound(transition.sound)

    if transition.targetFade >= 1 then
        currentFade = 1
        setShellTransparency(1, true)
        setIdleLight(true)

        -- Leave the sound at the departure point until it is finished.
        -- Then move the whole invisible TARDIS to parking.
        moveTardis(hiddenPivot)
        hidden = true

        if transition.kind == "auto_demat" and autoSequence then
            requestMaterialize("auto_materialize")
        end
    else
        currentFade = 0
        setShellTransparency(0, true)
        setIdleLight(false)
        hidden = false

        if transition.kind == "auto_materialize" then
            autoSequence = false
            lastInputState = inputA:GetState() == true
            print("J RECALL COMPLETE")
        end
    end
end

--------------------------------------------------
-- UPDATE TRANSITION
--------------------------------------------------

local function updateTransition()
    local transition = activeTransition
    if not transition then
        return
    end

    local now = os.clock()
    local progress = nil
    local soundTime = nil
    local pulseTime = 0

    --------------------------------------------------
    -- SOUND-CLOCKED MODE
    --------------------------------------------------

    if not transition.fallback and transition.sound then
        soundTime = getSoundTime(transition.sound)
        pulseTime = soundTime or 0

        if soundTime then
            if soundTime > transition.maxSoundTime + 0.005 then
                transition.soundAdvanced = true
            end

            transition.maxSoundTime = math.max(
                transition.maxSoundTime,
                soundTime
            )

            local length = getSoundLength(transition.sound)
            if length > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
                transition.visualEnd = length - SOUND_TAIL_TIME
            end

            if soundTime >= VISUAL_START_TIME then
                progress = math.clamp(
                    (soundTime - VISUAL_START_TIME)
                    / math.max(0.05, transition.visualEnd - VISUAL_START_TIME),
                    0,
                    1
                )
            else
                progress = 0
            end
        end

        if now - transition.requestTime >= SOUND_START_TIMEOUT
        and not transition.soundAdvanced then
            transition.fallback = true
            transition.fallbackStart = now
            transition.fallbackStartProgress = 0
            transition.fallbackDuration = FALLBACK_FADE_TIME
            print("TARDIS: Sound TimePosition stalled; using fallback clock")
        end
    end

    --------------------------------------------------
    -- FALLBACK MODE
    --------------------------------------------------

    if transition.fallback then
        local elapsed = now - transition.fallbackStart
        pulseTime = elapsed

        local localProgress = math.clamp(
            elapsed / transition.fallbackDuration,
            0,
            1
        )

        progress =
            transition.fallbackStartProgress
            + (1 - transition.fallbackStartProgress) * localProgress
    end

    if progress == nil then
        return
    end

    local pulse = updateAudioPulse(transition, pulseTime)

    --------------------------------------------------
    -- VISUAL PHASE
    --------------------------------------------------

    if progress < 1 then
        if transition.targetFade >= 1 then
            currentFade = progress ^ FADE_AGGRESSION
        else
            currentFade = 1 - (progress ^ FADE_AGGRESSION)
        end

        updateReplicatedVisual(transition, progress, pulse, false)
        return
    end

    --------------------------------------------------
    -- VISUAL COMPLETE; AUDIO TAIL STILL RUNS
    --------------------------------------------------

    if not transition.visualComplete then
        transition.visualComplete = true
        transition.visualCompleteAt = now
        currentFade = transition.targetFade
        setShellTransparency(transition.targetFade, true)
    end

    -- Keep roof lamp following waveform during audio tail.
    updateReplicatedVisual(transition, 1, pulse, false)
    setShellTransparency(transition.targetFade, false)

    --------------------------------------------------
    -- FINISH WHEN AUDIO FINISHES
    --------------------------------------------------

    if not transition.fallback and transition.sound then
        local length = getSoundLength(transition.sound)
        local isPlaying = getIsPlaying(transition.sound)

        local finished = false

        if length > 0
        and transition.maxSoundTime >= length - 0.08 then
            finished = true
        end

        if transition.soundAdvanced
        and not isPlaying then
            finished = true
        end

        -- Safety for SoundBlocks that never report their end correctly.
        if not finished
        and transition.visualCompleteAt
        and now - transition.visualCompleteAt >= SOUND_TAIL_TIME + 1.0
        and length <= 0 then
            finished = true
        end

        if finished then
            finishTransition(transition)
        end

        return
    end

    --------------------------------------------------
    -- FALLBACK TAIL
    --------------------------------------------------

    if transition.visualCompleteAt
    and now - transition.visualCompleteAt >= FALLBACK_TAIL_TIME then
        finishTransition(transition)
    end
end

--------------------------------------------------
-- J RECALL
--------------------------------------------------

local function startAutoRecall()
    print("J RECALL START")
    autoSequence = true

    if hidden or currentFade >= 1 then
        currentFade = 1
        setShellTransparency(1, true)
        setTopLight(0, 1, true)
        hidden = true
        requestMaterialize("auto_materialize")
    else
        requestDemat("auto_demat")
    end
end

--------------------------------------------------
-- MAIN LOOP
--
-- J is rising-edge one-shot. While J recall is active, A is ignored.
--------------------------------------------------

while true do
    local jState = inputJ:GetState() == true

    if jState
    and not lastJState
    and not autoSequence then
        startAutoRecall()
    end

    lastJState = jState

    if not autoSequence then
        local newAState = inputA:GetState() == true

        if newAState ~= lastInputState then
            lastInputState = newAState

            print(
                "INPUT A:",
                newAState and "MATERIALIZE" or "DEMATERIALIZE"
            )

            if newAState then
                requestMaterialize("manual_materialize")
            else
                requestDemat("manual_demat")
            end
        end
    end

    updateTransition()
    task.wait(LOOP_INTERVAL)
end
