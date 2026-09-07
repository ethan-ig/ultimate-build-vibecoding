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
--   rising edge = demat, then remat on the local player
--
-- DISPLAY NAMES
--   Tardis             = every shell piece
--   TardisDematSound   = dematerialization SoundBlock
--   TardisMatSound     = materialization SoundBlock
--   Tardislight        = top lamp/light block
--
-- No outputs or sound wires are required.
-- The SoundBlocks are controlled directly by this Code block.
-- Sound TimePosition is the master transition clock.
-- PlaybackLoudness, when accessible, drives the violent shell/light pulses.

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
-- AUDIO / VISUAL SETTINGS
--------------------------------------------------

-- Intro before the shell starts changing.
local VISUAL_START_TIME = 0.20

-- Shell reaches its final transparency before the sound ends.
local SOUND_TAIL_TIME = 2.50

-- Only used if SoundBlock timing cannot be read.
local FALLBACK_FADE_TIME = 14
local FALLBACK_TAIL_TIME = 2.5
local SOUND_START_TIMEOUT = 4

-- 60 Hz makes the pulse feel much tighter to the audio envelope.
local UPDATE_INTERVAL = 1 / 60

-- Base progress curve. Less than 1 = changes happen harder/earlier.
local FADE_AGGRESSION = 0.42

-- How much PlaybackLoudness can punch transparency away from the base curve.
-- 0.90 is intentionally extreme.
local SHELL_WAVE_STRENGTH = 0.90

-- Attack transient multiplier. Makes individual loud attacks kick harder.
local TRANSIENT_BOOST = 2.75

-- Dynamic loudness normalization floor.
local LOUDNESS_PEAK_FLOOR = 45

-- Light pulse range.
local LIGHT_MIN_BRIGHTNESS = 0.05
local LIGHT_MAX_BRIGHTNESS = 14
local LIGHT_IDLE_BRIGHTNESS_DEFAULT = 2

-- Script-controlled SoundBlock settings.
local SOUND_VOLUME = 1
local SOUND_PITCH = 1

--------------------------------------------------
-- POSITIONING
--------------------------------------------------

local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10

--------------------------------------------------
-- SAFE UB VALUE ACCESS
--------------------------------------------------

local function getBlockValue(block, key)
    if not block then
        return nil
    end

    local ok, value

    ok, value = pcall(function()
        return block[key]
    end)

    if ok and value ~= nil then
        return value
    end

    ok, value = pcall(function()
        return block:GetAttribute(key)
    end)

    if ok and value ~= nil then
        return value
    end

    ok, value = pcall(function()
        return block.attributes[key]
    end)

    if ok then
        return value
    end

    return nil
end

local function setBlockValue(block, key, value)
    if not block then
        return false
    end

    local ok = pcall(function()
        block[key] = value
    end)

    if ok then
        return true
    end

    ok = pcall(function()
        block:SetAttribute(key, value)
    end)

    if ok then
        return true
    end

    ok = pcall(function()
        block.attributes[key] = value
    end)

    return ok
end

local function getDisplayName(part)
    local value = getBlockValue(part, "DisplayName")

    if type(value) == "string" and value ~= "" then
        return value
    end

    return nil
end

--------------------------------------------------
-- FIND BLOCKS
--------------------------------------------------

local function findNamedBlock(name)
    for _, part in ipairs(workspace:GetDescendants(true)) do
        if part ~= script then
            local displayName = getDisplayName(part)

            if displayName
            and string.lower(displayName) == string.lower(name) then
                return part
            end
        end
    end

    return nil
end

local dematSound = findNamedBlock(DEMAT_SOUND_NAME)
local matSound = findNamedBlock(MAT_SOUND_NAME)
local tardisLight = findNamedBlock(LIGHT_NAME)

print(dematSound and "FOUND TardisDematSound" or "ERROR: TardisDematSound missing")
print(matSound and "FOUND TardisMatSound" or "ERROR: TardisMatSound missing")
print(tardisLight and "FOUND Tardislight" or "WARNING: Tardislight missing")

--------------------------------------------------
-- RAW INSTANCE HELPERS
-- Used only for PlaybackLoudness / actual Light instance.
--------------------------------------------------

local function getRawPart(block)
    if not block then
        return nil
    end

    local ok, raw = pcall(function()
        return block.Part
    end)

    if ok and raw then
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

local function findRawLight(block)
    local rawPart = getRawPart(block)

    if not rawPart then
        return nil
    end

    for _, className in ipairs({ "PointLight", "SpotLight", "SurfaceLight" }) do
        local ok, light = pcall(function()
            return rawPart:FindFirstChildWhichIsA(className, true)
        end)

        if ok and light then
            return light
        end
    end

    return nil
end

local rawDematSound = findRawSound(dematSound)
local rawMatSound = findRawSound(matSound)
local rawTopLight = findRawLight(tardisLight)

--------------------------------------------------
-- DIRECT SOUNDBLOCK CONTROL
--------------------------------------------------

local function getSoundInput(block)
    if not block then
        return nil
    end

    for _, name in ipairs({ "Input", "input", "Toggle", "toggle", "a", "A" }) do
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

        if success and result then
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

    for _, inputName in ipairs({ "Input", "input", "Toggle", "toggle", "a" }) do
        local ok = pcall(function()
            block:FireInput(inputName, state)
        end)

        if ok then
            return true
        end
    end

    print("Could not control SoundBlock:", getDisplayName(block))
    return false
end

local function configureSound(block)
    if not block then
        return
    end

    setBlockValue(block, "Repeat", false)
    setBlockValue(block, "ResetTimePosition", false)
    setBlockValue(block, "Volume", SOUND_VOLUME)
    setBlockValue(block, "Pitch", SOUND_PITCH)
    setBlockValue(block, "Effects", false)
end

configureSound(dematSound)
configureSound(matSound)

local function stopSound(block)
    if not block then
        return
    end

    setSoundPowered(block, false)
    task.wait()
    setBlockValue(block, "TimePosition", 0)
end

local function pauseSound(block)
    if not block then
        return
    end

    local position = tonumber(getBlockValue(block, "TimePosition")) or 0
    setSoundPowered(block, false)
    task.wait()
    setBlockValue(block, "TimePosition", position)
end

local function resumeSound(block)
    if block then
        setSoundPowered(block, true)
    end
end

local function playSound(block, position)
    if not block then
        return false
    end

    setSoundPowered(block, false)
    task.wait()
    setBlockValue(block, "TimePosition", position or 0)
    setSoundPowered(block, true)
    return true
end

--------------------------------------------------
-- PART GROUPS
--------------------------------------------------

local shellParts = {}
local moveParts = {}
local fadeParts = {}
local relativeCFrames = {}

local function listContains(list, part)
    for _, existing in ipairs(list) do
        if existing == part then
            return true
        end
    end

    return false
end

local function addPart(list, part)
    if not part or listContains(list, part) then
        return
    end

    local ok = pcall(function()
        return part.CFrame
    end)

    if ok then
        table.insert(list, part)
    end
end

for _, part in ipairs(workspace:GetDescendants(true)) do
    if part ~= script then
        local displayName = getDisplayName(part)

        if displayName
        and string.lower(displayName) == string.lower(SHELL_NAME) then
            local ok = pcall(function()
                return part.CFrame
            end)

            if ok then
                table.insert(shellParts, part)
                addPart(moveParts, part)
                addPart(fadeParts, part)
            end
        end
    end
end

-- SoundBlocks physically travel with the shell and visually fade with it.
addPart(moveParts, dematSound)
addPart(moveParts, matSound)
addPart(fadeParts, dematSound)
addPart(fadeParts, matSound)

-- Top lamp travels with the shell, but gets its own audio-reactive transparency.
addPart(moveParts, tardisLight)

print("TARDIS shell blocks:", #shellParts)
print("TARDIS moving blocks:", #moveParts)
print("TARDIS regular fading blocks:", #fadeParts)

--------------------------------------------------
-- FORCE THE WHOLE TARDIS ASSEMBLY ANCHORED + COLLIDABLE
-- This happens immediately on script startup.
--------------------------------------------------

local function lockTardisAssembly()
    for _, part in ipairs(moveParts) do
        pcall(function()
            part.Anchored = true
        end)

        pcall(function()
            part.CanCollide = true
        end)
    end
end

lockTardisAssembly()
print("TARDIS startup lock: all moving pieces anchored + CanCollide=true")

--------------------------------------------------
-- STARTING PIVOT / OFFSETS
--------------------------------------------------

local startingPivot = nil

if #shellParts > 0 then
    startingPivot = shellParts[1].CFrame
end

if startingPivot then
    for _, part in ipairs(moveParts) do
        relativeCFrames[part] = startingPivot:ToObjectSpace(part.CFrame)
    end
end

local defaultRotation =
    startingPivot
    and (startingPivot - startingPivot.Position)
    or CFrame.identity

--------------------------------------------------
-- FIND ACTUAL BOTTOM OF SHELL
--------------------------------------------------

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

            if bottom < lowestBottom then
                lowestBottom = bottom
            end
        end)
    end

    if lowestBottom < math.huge then
        tardisBottomOffset = lowestBottom - startingPivot.Position.Y
    end
end

print("TARDIS bottom offset:", tardisBottomOffset)

--------------------------------------------------
-- MOVE WHOLE TARDIS
--------------------------------------------------

local function moveTardis(pivot)
    -- Reassert these because another block/tool could have changed them.
    lockTardisAssembly()

    for _, part in ipairs(moveParts) do
        local offset = relativeCFrames[part]

        if offset then
            pcall(function()
                part.CFrame = pivot * offset
            end)
        end
    end
end

--------------------------------------------------
-- SHELL TRANSPARENCY
--------------------------------------------------

local function setShellTransparency(value)
    value = math.clamp(value, 0, 1)

    for _, part in ipairs(fadeParts) do
        pcall(function()
            part.Transparency = value
        end)
    end
end

--------------------------------------------------
-- TOP LIGHT CONTROL
--------------------------------------------------

local lightIdleBrightness =
    tonumber(getBlockValue(tardisLight, "Brightness"))
    or LIGHT_IDLE_BRIGHTNESS_DEFAULT

local lightIdleTransparency = 0

if tardisLight then
    local ok, value = pcall(function()
        return tardisLight.Transparency
    end)

    if ok and type(value) == "number" then
        lightIdleTransparency = value
    end
end

local function setTopLight(brightness, transparency)
    if not tardisLight then
        return
    end

    brightness = math.max(0, brightness or 0)
    transparency = math.clamp(transparency or 0, 0, 1)

    setBlockValue(tardisLight, "Brightness", brightness)

    pcall(function()
        tardisLight.Transparency = transparency
    end)

    if rawTopLight then
        pcall(function()
            rawTopLight.Brightness = brightness
            rawTopLight.Enabled = brightness > 0.01
        end)
    end
end

local function setIdleLight(hidden)
    if hidden then
        setTopLight(0, 1)
    else
        setTopLight(lightIdleBrightness, lightIdleTransparency)
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

    local position = Vector3.new(
        root.Position.X,
        pivotY,
        root.Position.Z
    )

    print("J RECALL destination:", position)
    return CFrame.new(position) * defaultRotation
end

local hiddenPivot = CFrame.new(HIDDEN_POSITION) * defaultRotation

--------------------------------------------------
-- SOUND TIMING / LOUDNESS
--------------------------------------------------

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

local function getRawSoundForBlock(block)
    if block == dematSound then
        return rawDematSound
    elseif block == matSound then
        return rawMatSound
    end

    return findRawSound(block)
end

local function readPlaybackLoudness(block)
    local rawSound = getRawSoundForBlock(block)

    if rawSound then
        local ok, loudness = pcall(function()
            return rawSound.PlaybackLoudness
        end)

        if ok and type(loudness) == "number" then
            return loudness, true
        end
    end

    -- Some UB wrappers may expose it directly/through an attribute.
    local loudness = tonumber(getBlockValue(block, "PlaybackLoudness"))

    if loudness then
        return loudness, true
    end

    return 0, false
end

--------------------------------------------------
-- AUDIO ENVELOPE
--------------------------------------------------

local loudnessPeak = LOUDNESS_PEAK_FLOOR
local loudnessEnvelope = 0
local previousEnvelope = 0
local warnedNoLoudness = false

local function resetAudioEnvelope()
    loudnessPeak = LOUDNESS_PEAK_FLOOR
    loudnessEnvelope = 0
    previousEnvelope = 0
end

local function getAudioPulse(soundBlock, soundTime)
    local loudness, hasRealLoudness = readPlaybackLoudness(soundBlock)

    if hasRealLoudness then
        -- Fast peak acquisition; slow release keeps normalization useful
        -- through quiet/loud sections of the clip.
        if loudness > loudnessPeak then
            loudnessPeak = loudness
        else
            loudnessPeak = math.max(
                LOUDNESS_PEAK_FLOOR,
                loudnessPeak * 0.992
            )
        end

        local normalized = math.clamp(loudness / math.max(loudnessPeak, 1), 0, 1)

        -- Brutal shaping: even medium audio becomes a strong pulse.
        local shaped = normalized ^ 0.28

        -- Almost no smoothing on attack; quick but visible release.
        if shaped > loudnessEnvelope then
            loudnessEnvelope = loudnessEnvelope + (shaped - loudnessEnvelope) * 0.98
        else
            loudnessEnvelope = loudnessEnvelope + (shaped - loudnessEnvelope) * 0.58
        end

        local transient = math.max(0, loudnessEnvelope - previousEnvelope)
        previousEnvelope = loudnessEnvelope

        local pulse = math.clamp(
            loudnessEnvelope + transient * TRANSIENT_BOOST,
            0,
            1
        )

        return pulse, true
    end

    -- Fallback only if PlaybackLoudness is unavailable. It is intentionally
    -- violent and TimePosition-locked, but it is NOT the actual audio waveform.
    if not warnedNoLoudness then
        warnedNoLoudness = true
        print("PlaybackLoudness unavailable; using TimePosition pulse fallback")
    end

    local t = soundTime or 0
    local wave =
        0.52
        + 0.24 * math.sin(t * 11.8)
        + 0.14 * math.sin(t * 23.6 + 1.2)
        + 0.10 * math.sin(t * 37.1 + 0.4)

    wave = math.clamp(wave, 0, 1)
    wave = wave ^ 0.42

    previousEnvelope = loudnessEnvelope
    loudnessEnvelope = wave

    return wave, false
end

--------------------------------------------------
-- AGGRESSIVE AUDIO-REACTIVE VISUAL
--------------------------------------------------

local function applyAudioVisual(transition, visualProgress, soundTime)
    visualProgress = math.clamp(visualProgress, 0, 1)

    -- Stronger-than-linear base progression.
    local aggressiveProgress = visualProgress ^ FADE_AGGRESSION

    local pulse = select(1, getAudioPulse(transition.sound, soundTime))

    local transparency

    if transition.targetFade >= 1 then
        -- DEMAT:
        -- loud peaks punch the shell HARD toward invisible.
        local base = aggressiveProgress
        transparency = base + pulse * SHELL_WAVE_STRENGTH * (1 - base)
    else
        -- MATERIALIZE:
        -- loud peaks punch the shell HARD toward visible.
        local base = 1 - aggressiveProgress
        transparency = base - pulse * SHELL_WAVE_STRENGTH * base
    end

    transparency = math.clamp(transparency, 0, 1)
    setShellTransparency(transparency)

    -- Keep currentFade as the base transition state so reversals remain sane.
    if transition.targetFade >= 1 then
        transition.baseFade = aggressiveProgress
    else
        transition.baseFade = 1 - aggressiveProgress
    end

    -- Top lamp follows the audio envelope even harder than the shell.
    -- Quiet sections almost extinguish it; peaks slam it bright/opaque.
    local lampPulse = pulse ^ 0.18
    local brightness =
        LIGHT_MIN_BRIGHTNESS
        + (LIGHT_MAX_BRIGHTNESS - LIGHT_MIN_BRIGHTNESS) * lampPulse

    local lampTransparency = math.clamp(1 - lampPulse * 1.12, 0, 1)

    -- Give attacks an extra visible kick.
    if pulse > 0.82 then
        brightness = LIGHT_MAX_BRIGHTNESS
        lampTransparency = 0
    end

    setTopLight(brightness, lampTransparency)
end

--------------------------------------------------
-- STATE
--------------------------------------------------

local inputState = inputA:GetState() == true

-- Logical/base fade state. 0 = materialized, 1 = dematerialized.
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
    setShellTransparency(0)
    setIdleLight(false)
else
    setShellTransparency(1)
    setIdleLight(true)
    moveTardis(hiddenPivot)
end

--------------------------------------------------
-- PREPARE MATERIALIZATION LOCATION
--------------------------------------------------

local function prepareMaterialization(kind)
    if not hidden then
        return true
    end

    setShellTransparency(1)
    setTopLight(0, 1)

    local destination

    if kind == "auto_materialize" then
        destination = getCharacterDestination()
    else
        destination = getInputDestination()
    end

    if not destination then
        return false
    end

    -- Shell, sounds, and top light all move before the arrival sound starts.
    moveTardis(destination)

    hidden = false
    currentFade = 1
    return true
end

--------------------------------------------------
-- START TRANSITION
--------------------------------------------------

local function startTransition(kind, targetFade, sound)
    if not sound then
        print("Cannot start TARDIS transition: required SoundBlock missing")
        return
    end

    if activeTransition and activeTransition.sound then
        stopSound(activeTransition.sound)
    end

    activeTransition = nil

    if targetFade <= 0 then
        if not prepareMaterialization(kind) then
            print("Materialization destination unavailable")
            return
        end
    end

    if sound == dematSound then
        stopSound(matSound)
    else
        stopSound(dematSound)
    end

    resetAudioEnvelope()

    local visualEnd = getVisualEndTime(sound)

    -- Reverse transitions seek into the new sound so the visual doesn't jump
    -- all the way back to the beginning.
    local completedProgress

    if targetFade >= 1 then
        completedProgress = currentFade
    else
        completedProgress = 1 - currentFade
    end

    completedProgress = math.clamp(completedProgress, 0, 1)

    local seekPosition = 0

    if completedProgress > 0.01 then
        seekPosition =
            VISUAL_START_TIME
            + completedProgress * (visualEnd - VISUAL_START_TIME)
    end

    playSound(sound, seekPosition)

    activeTransition = {
        kind = kind,
        targetFade = targetFade,
        sound = sound,
        visualEnd = visualEnd,
        requestTime = os.clock(),
        maxSoundTime = seekPosition,
        visualComplete = false,
        fallback = false,
        fallbackStart = 0,
        fallbackTailStart = nil,
        baseFade = currentFade,
    }
end

local function requestDemat(kind)
    startTransition(kind, 1, dematSound)
end

local function requestMaterialize(kind)
    startTransition(kind, 0, matSound)
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
        setShellTransparency(1)
        setIdleLight(true)

        -- Leave the sound at the departure point until the clip is finished,
        -- then park everything together.
        moveTardis(hiddenPivot)
        hidden = true

        if transition.kind == "auto_demat" then
            requestMaterialize("auto_materialize")
        end
    else
        currentFade = 0
        setShellTransparency(0)
        hidden = false
        setIdleLight(false)

        if transition.kind == "auto_materialize" then
            autoSequence = false
            lastInputState = inputA:GetState() == true
            print("J RECALL COMPLETE")
        end
    end
end

--------------------------------------------------
-- UPDATE SOUND-CLOCKED TRANSITION
--------------------------------------------------

local function updateTransition()
    local transition = activeTransition

    if not transition then
        return
    end

    local now = os.clock()
    local sound = transition.sound

    local soundTime = tonumber(getBlockValue(sound, "TimePosition"))
    local timeLength = getSoundLength(sound)
    local isPlaying = getBlockValue(sound, "IsPlaying") == true

    if not transition.fallback and soundTime then
        if soundTime > transition.maxSoundTime then
            transition.maxSoundTime = soundTime
        end

        if timeLength > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
            transition.visualEnd = timeLength - SOUND_TAIL_TIME
        end

        if not transition.visualComplete
        and soundTime >= VISUAL_START_TIME then
            local denominator = math.max(
                0.05,
                transition.visualEnd - VISUAL_START_TIME
            )

            local visualProgress = math.clamp(
                (soundTime - VISUAL_START_TIME) / denominator,
                0,
                1
            )

            applyAudioVisual(transition, visualProgress, soundTime)

            if transition.targetFade >= 1 then
                currentFade = math.clamp(visualProgress ^ FADE_AGGRESSION, 0, 1)
            else
                currentFade = math.clamp(1 - (visualProgress ^ FADE_AGGRESSION), 0, 1)
            end

            if visualProgress >= 1 then
                transition.visualComplete = true
                currentFade = transition.targetFade
                setShellTransparency(transition.targetFade)
                setTopLight(0, 1)
                print("Visual complete; sound tail still playing")
            end
        end

        local soundFinished = false

        if transition.visualComplete then
            if timeLength > 0
            and transition.maxSoundTime >= timeLength - 0.08 then
                soundFinished = true
            end

            if not isPlaying
            and transition.maxSoundTime > VISUAL_START_TIME then
                soundFinished = true
            end
        end

        if soundFinished then
            finishTransition(transition)
            return
        end

        if (now - transition.requestTime) >= SOUND_START_TIMEOUT
        and transition.maxSoundTime <= 0.01 then
            print("Audio clock unavailable; using fallback transition clock")
            transition.fallback = true
            transition.fallbackStart = now
            resetAudioEnvelope()
        end
    elseif not transition.fallback then
        if (now - transition.requestTime) >= SOUND_START_TIMEOUT then
            transition.fallback = true
            transition.fallbackStart = now
            resetAudioEnvelope()
        end
    end

    --------------------------------------------------
    -- FALLBACK
    --------------------------------------------------

    if transition.fallback then
        local elapsed = now - transition.fallbackStart

        if elapsed <= FALLBACK_FADE_TIME then
            local progress = math.clamp(elapsed / FALLBACK_FADE_TIME, 0, 1)

            -- Even fallback remains aggressive and pulsy, but its pulse is
            -- time-generated because real PlaybackLoudness was unavailable.
            applyAudioVisual(transition, progress, elapsed)

            if transition.targetFade >= 1 then
                currentFade = progress ^ FADE_AGGRESSION
            else
                currentFade = 1 - (progress ^ FADE_AGGRESSION)
            end
        elseif not transition.visualComplete then
            transition.visualComplete = true
            currentFade = transition.targetFade
            setShellTransparency(transition.targetFade)
            setTopLight(0, 1)
            transition.fallbackTailStart = now
        elseif transition.fallbackTailStart
        and (now - transition.fallbackTailStart) >= FALLBACK_TAIL_TIME then
            finishTransition(transition)
        end
    end
end

--------------------------------------------------
-- J RECALL
--------------------------------------------------

local function startAutoRecall()
    print("J RECALL START")
    autoSequence = true

    if hidden or currentFade >= 1 then
        setShellTransparency(1)
        setTopLight(0, 1)
        hidden = true
        requestMaterialize("auto_materialize")
    else
        requestDemat("auto_demat")
    end
end

--------------------------------------------------
-- MAIN LOOP
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
    task.wait(UPDATE_INTERVAL)
end
