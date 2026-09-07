-- TARDIS controller - Code block safe version
--
-- INPUT A: true = materialized, false = dematerialized
-- INPUT C: Vector3/CFrame normal destination
-- INPUT J: rising edge = recall to local player
--
-- DISPLAY NAMES:
--   Tardis
--   TardisDematSound
--   TardisMatSound
--   Tardislight
--
-- IMPORTANT:
-- BasePart movement/transparency writes go through the UB proxy only.
-- .Part is READ ONLY and is used only to read Roblox Sound.PlaybackLoudness.

local inputA = inputs["a"]
local inputC = inputs["c"]
local inputJ = inputs["j"]

local SHELL_NAME = "Tardis"
local DEMAT_SOUND_NAME = "TardisDematSound"
local MAT_SOUND_NAME = "TardisMatSound"
local LIGHT_NAME = "Tardislight"

local VISUAL_START_TIME = 0.20
local SOUND_TAIL_TIME = 2.50
local FALLBACK_FADE_TIME = 14
local FALLBACK_TAIL_TIME = 2.50
local SOUND_START_TIMEOUT = 3
local LOOP_INTERVAL = 1 / 60

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

local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10

local FADE_WRITE_BUDGET = 1500
local FADE_MAX_HZ = 20
local FADE_MIN_HZ = 4
local LIGHT_HZ = 20

--------------------------------------------------
-- BASIC UB PROXY HELPERS
--------------------------------------------------

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

local function readAttribute(object, name)
    if not object then
        return nil
    end

    local value = nil

    pcall(function()
        value = object.attributes[name]
    end)

    if value ~= nil then
        return value
    end

    pcall(function()
        value = object:GetAttribute(name)
    end)

    return value
end

local function writeAttribute(object, name, value)
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

--------------------------------------------------
-- DISPLAY NAME
--
-- DO NOT probe object.DisplayName. The old working
-- command system reads the UB "Display name" attribute.
--------------------------------------------------

local function readDisplayName(object)
    local value = readAttribute(object, "Display name")

    if type(value) == "string" and value ~= "" then
        return value
    end

    value = readAttribute(object, "DisplayName")

    if type(value) == "string" and value ~= "" then
        return value
    end

    value = getProperty(object, "Name")

    if type(value) == "string" then
        return value
    end

    return nil
end

--------------------------------------------------
-- FIND OWNED PARTS
--
-- GetChildren is enough for normal UB builds and is
-- less invasive than recursively walking the whole plot.
--------------------------------------------------

local ownedParts = workspace:GetChildren(true)

local shellParts = {}
local moveParts = {}
local fadeParts = {}
local relativeCFrames = {}

local dematSound = nil
local matSound = nil
local tardisLight = nil

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

    local cf = getProperty(object, "CFrame")

    if typeof(cf) == "CFrame" then
        table.insert(list, object)
    end
end

for _, object in ipairs(ownedParts) do
    if object ~= script then
        local displayName = readDisplayName(object)

        if displayName then
            local lower = string.lower(displayName)

            if lower == string.lower(SHELL_NAME) then
                table.insert(shellParts, object)
                addMovable(moveParts, object)
                addMovable(fadeParts, object)

            elseif lower == string.lower(DEMAT_SOUND_NAME) then
                dematSound = object

            elseif lower == string.lower(MAT_SOUND_NAME) then
                matSound = object

            elseif lower == string.lower(LIGHT_NAME) then
                tardisLight = object
            end
        end
    end
end

addMovable(moveParts, dematSound)
addMovable(moveParts, matSound)
addMovable(fadeParts, dematSound)
addMovable(fadeParts, matSound)
addMovable(moveParts, tardisLight)

print("TARDIS shell:", #shellParts)
print("TARDIS movers:", #moveParts)
print(dematSound and "FOUND demat sound" or "MISSING demat sound")
print(matSound and "FOUND mat sound" or "MISSING mat sound")
print(tardisLight and "FOUND Tardislight" or "MISSING Tardislight")

--------------------------------------------------
-- STARTUP LOCK
--
-- Only structural Tardis pieces are forced anchored/
-- collidable. Do not ask specialty Sound/Light blocks
-- for unsupported physics settings during startup.
--------------------------------------------------

for _, object in ipairs(shellParts) do
    setProperty(object, "Anchored", true)
    setProperty(object, "CanCollide", true)
end

print("TARDIS shell Anchored=true CanCollide=true")

--------------------------------------------------
-- SOUND BLOCK SETTINGS / CONTROL
--------------------------------------------------

local function configureSound(block)
    if not block then
        return
    end

    -- SoundBlock settings are UB block attributes.
    writeAttribute(block, "Repeat", false)
    writeAttribute(block, "ResetTimePosition", false)
    writeAttribute(block, "Volume", 1)
    writeAttribute(block, "Pitch", 1)
    writeAttribute(block, "Effects", false)
end

configureSound(dematSound)
configureSound(matSound)

local function readSoundValue(block, name)
    return readAttribute(block, name)
end

local function writeSoundValue(block, name, value)
    return writeAttribute(block, name, value)
end

local function setSoundPowered(block, state)
    if not block then
        return false
    end

    local ok = pcall(function()
        block.inputs["Input"]:Fire(state, true)
    end)

    if ok then
        return true
    end

    ok = pcall(function()
        block:FireInput("Input", state)
    end)

    return ok
end

local function stopSound(block)
    if not block then
        return
    end

    setSoundPowered(block, false)
    writeSoundValue(block, "TimePosition", 0)
end

local function playSound(block, position)
    if not block then
        return false
    end

    setSoundPowered(block, false)
    writeSoundValue(block, "TimePosition", position or 0)
    return setSoundPowered(block, true)
end

--------------------------------------------------
-- RAW SOUND LOUDNESS - READ ONLY
--------------------------------------------------

local function getRawSound(block)
    if not block then
        return nil
    end

    local raw = nil

    pcall(function()
        raw = block.Part
    end)

    if not raw then
        return nil
    end

    local sound = nil

    pcall(function()
        sound = raw:FindFirstChildWhichIsA("Sound", true)
    end)

    return sound
end

local rawDematSound = getRawSound(dematSound)
local rawMatSound = getRawSound(matSound)

--------------------------------------------------
-- PIVOT / OFFSETS
--------------------------------------------------

local startingPivot = nil

if #shellParts > 0 then
    startingPivot = getProperty(shellParts[1], "CFrame")
end

if not startingPivot then
    error("TARDIS: no shell pieces named Tardis were found")
end

for _, object in ipairs(moveParts) do
    local cf = getProperty(object, "CFrame")

    if typeof(cf) == "CFrame" then
        relativeCFrames[object] = startingPivot:ToObjectSpace(cf)
    end
end

local defaultRotation = startingPivot - startingPivot.Position

--------------------------------------------------
-- ACTUAL SHELL BOTTOM
--------------------------------------------------

local tardisBottomOffset = 0
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

--------------------------------------------------
-- SERVER REPLICATED MOVEMENT
--------------------------------------------------

local function moveTardis(pivot)
    if not pivot then
        return false
    end

    local failures = 0

    for _, object in ipairs(moveParts) do
        local offset = relativeCFrames[object]

        if offset then
            if not setProperty(object, "CFrame", pivot * offset) then
                failures = failures + 1
            end
        end
    end

    print("TARDIS MOVE ->", pivot.Position, "failures:", failures)
    return failures == 0
end

--------------------------------------------------
-- REPLICATED TRANSPARENCY
--------------------------------------------------

local fadeCount = math.max(#fadeParts, 1)
local fadeHz = math.floor(FADE_WRITE_BUDGET / fadeCount)
fadeHz = math.clamp(fadeHz, FADE_MIN_HZ, FADE_MAX_HZ)
local fadeInterval = 1 / fadeHz
local lastFadeAt = -math.huge
local lastFadeValue = nil

print("TARDIS replicated fade:", fadeHz, "Hz")

local function setShellTransparency(value, force)
    value = math.clamp(value, 0, 1)

    local now = os.clock()

    if not force then
        if now - lastFadeAt < fadeInterval then
            return
        end

        if lastFadeValue ~= nil
        and math.abs(value - lastFadeValue) < 0.01 then
            return
        end
    end

    lastFadeAt = now
    lastFadeValue = value

    for _, object in ipairs(fadeParts) do
        setProperty(object, "Transparency", value)
    end
end

--------------------------------------------------
-- TOP LIGHT
--------------------------------------------------

local lightIdleBrightness =
    tonumber(readAttribute(tardisLight, "Brightness"))
    or LIGHT_IDLE_BRIGHTNESS_DEFAULT

local lightIdleTransparency =
    tonumber(getProperty(tardisLight, "Transparency"))
    or 0

local lightInterval = 1 / LIGHT_HZ
local lastLightAt = -math.huge

local function setTopLight(brightness, transparency, force)
    if not tardisLight then
        return
    end

    local now = os.clock()

    if not force and now - lastLightAt < lightInterval then
        return
    end

    lastLightAt = now

    brightness = math.max(0, brightness or 0)
    transparency = math.clamp(transparency or 0, 0, 1)

    setProperty(tardisLight, "Transparency", transparency)
    writeAttribute(tardisLight, "Brightness", brightness)
end

local function setIdleLight(hidden)
    if hidden then
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
        print("J RECALL: HumanoidRootPart missing")
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
-- AUDIO CLOCK
--------------------------------------------------

local function getSoundTime(block)
    return tonumber(readSoundValue(block, "TimePosition"))
end

local function getSoundLength(block)
    return tonumber(readSoundValue(block, "TimeLength")) or 0
end

local function isSoundPlaying(block)
    return readSoundValue(block, "IsPlaying") == true
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

local function readLoudness(block)
    local raw = nil

    if block == dematSound then
        raw = rawDematSound
    elseif block == matSound then
        raw = rawMatSound
    end

    if raw then
        local value = nil

        pcall(function()
            value = raw.PlaybackLoudness
        end)

        if type(value) == "number" then
            return value, true
        end
    end

    return 0, false
end

local function getPulse(transition, soundTime)
    local loudness, hasReal = readLoudness(transition.sound)

    if not hasReal then
        return syntheticPulse(soundTime or 0)
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

    return math.clamp(
        transition.envelope + transient * TRANSIENT_BOOST,
        0,
        1
    )
end

local function waveTransparency(targetFade, progress, pulse)
    progress = math.clamp(progress, 0, 1)
    pulse = math.clamp(pulse or 0, 0, 1)

    local aggressive = progress ^ FADE_AGGRESSION

    if targetFade >= 1 then
        return math.clamp(
            aggressive + pulse * SHELL_WAVE_STRENGTH * (1 - aggressive),
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

local function applyVisual(transition, progress, pulse, force)
    setShellTransparency(
        waveTransparency(transition.targetFade, progress, pulse),
        force
    )

    local lampPulse = math.clamp(pulse or 0, 0, 1) ^ 0.12

    local brightness =
        LIGHT_MIN_BRIGHTNESS
        + (LIGHT_MAX_BRIGHTNESS - LIGHT_MIN_BRIGHTNESS) * lampPulse

    local lampTransparency = math.clamp(1 - lampPulse * 1.2, 0, 1)

    if pulse >= 0.72 then
        brightness = LIGHT_MAX_BRIGHTNESS
        lampTransparency = 0
    end

    setTopLight(brightness, lampTransparency, force)
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

if inputState then
    setShellTransparency(0, true)
    setIdleLight(false)
else
    setShellTransparency(1, true)
    setIdleLight(true)
    moveTardis(hiddenPivot)
end

--------------------------------------------------
-- MATERIALIZATION PREP
--------------------------------------------------

local function prepareMaterialization(kind)
    if not hidden then
        return true
    end

    setShellTransparency(1, true)
    setTopLight(0, 1, true)

    local destination = nil

    if kind == "auto_materialize" then
        destination = getCharacterDestination()
    else
        destination = getInputDestination()
    end

    if not destination then
        return false
    end

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
            return false
        end
    end

    if sound == dematSound then
        stopSound(matSound)
    else
        stopSound(dematSound)
    end

    local visualEnd = getVisualEndTime(sound)

    local completed = targetFade >= 1 and currentFade or (1 - currentFade)
    completed = math.clamp(completed, 0, 1)

    local linearCompleted = 0

    if completed > 0 then
        linearCompleted = completed ^ (1 / FADE_AGGRESSION)
    end

    local seek = 0

    if completed > 0.01 then
        seek = VISUAL_START_TIME
            + linearCompleted * (visualEnd - VISUAL_START_TIME)
    end

    local soundStarted = sound and playSound(sound, seek) or false
    local now = os.clock()

    activeTransition = {
        kind = kind,
        targetFade = targetFade,
        sound = sound,
        visualEnd = visualEnd,
        requestTime = now,
        maxSoundTime = seek,
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
    }

    return true
end

local function requestDemat(kind)
    return startTransition(kind, 1, dematSound)
end

local function requestMaterialize(kind)
    return startTransition(kind, 0, matSound)
end

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

local function updateTransition()
    local transition = activeTransition

    if not transition then
        return
    end

    local now = os.clock()
    local progress = nil
    local pulseTime = 0

    if not transition.fallback and transition.sound then
        local soundTime = getSoundTime(transition.sound)
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

            progress = math.clamp(
                (soundTime - VISUAL_START_TIME)
                / math.max(0.05, transition.visualEnd - VISUAL_START_TIME),
                0,
                1
            )
        end

        if now - transition.requestTime >= SOUND_START_TIMEOUT
        and not transition.soundAdvanced then
            transition.fallback = true
            transition.fallbackStart = now
            transition.fallbackStartProgress = 0
            transition.fallbackDuration = FALLBACK_FADE_TIME
            print("TARDIS: sound clock stalled, fallback")
        end
    end

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

    local pulse = getPulse(transition, pulseTime)

    if progress < 1 then
        if transition.targetFade >= 1 then
            currentFade = progress ^ FADE_AGGRESSION
        else
            currentFade = 1 - (progress ^ FADE_AGGRESSION)
        end

        applyVisual(transition, progress, pulse, false)
        return
    end

    if not transition.visualComplete then
        transition.visualComplete = true
        transition.visualCompleteAt = now
        currentFade = transition.targetFade
        setShellTransparency(transition.targetFade, true)
    end

    -- Lamp can keep pulsing during sound tail.
    local lampPulse = math.clamp(pulse, 0, 1) ^ 0.12
    setTopLight(
        LIGHT_MIN_BRIGHTNESS
            + (LIGHT_MAX_BRIGHTNESS - LIGHT_MIN_BRIGHTNESS) * lampPulse,
        math.clamp(1 - lampPulse * 1.2, 0, 1),
        false
    )

    if not transition.fallback and transition.sound then
        local length = getSoundLength(transition.sound)
        local finished = false

        if length > 0
        and transition.maxSoundTime >= length - 0.08 then
            finished = true
        end

        if transition.soundAdvanced
        and not isSoundPlaying(transition.sound) then
            finished = true
        end

        if finished then
            finishTransition(transition)
        end

        return
    end

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
