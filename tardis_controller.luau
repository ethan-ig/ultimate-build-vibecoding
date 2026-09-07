-- TARDIS controller - Fiu-safe direct discovery version
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
-- Structural properties are written through UB proxies so they replicate.
-- SoundBlocks are controlled ONLY through FireInput. We do not write their
-- attributes because those writes were causing Fiu's asynchronous Promise
-- rejection. TimePosition/TimeLength/IsPlaying are read-only here and drive
-- the visual effect.
--
-- Discovery intentionally matches the old working skyshow command system:
-- Workspace:GetChildren() with NO true parameter and NO GetDescendants().

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

local FADE_AGGRESSION = 0.27
local WAVE_STRENGTH = 0.92

local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10

local FADE_WRITE_BUDGET = 1500
local FADE_MAX_HZ = 20
local FADE_MIN_HZ = 4
local LIGHT_HZ = 20

--------------------------------------------------
-- UB PROXY ACCESS
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

    local ok, value = pcall(function()
        return object.attributes[name]
    end)

    if ok then
        return value
    end

    return nil
end

local function readDisplayName(object)
    local value = readAttribute(object, "Display name")

    if type(value) == "string" and value ~= "" then
        return value
    end

    value = getProperty(object, "Name")

    if type(value) == "string" and value ~= "" then
        return value
    end

    return nil
end

--------------------------------------------------
-- DISCOVERY
--------------------------------------------------

print("TARDIS SAFE INIT 1: skyshow-style GetChildren scan")

-- IMPORTANT: this intentionally matches the old working command system.
-- No true flag and no recursive descendant call.
local ownedParts = workspace:GetChildren()

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

            elseif string.find(lower, "tardis", 1, true) then
                print("TARDIS other named block:", displayName)
            end
        end
    end
end

addMovable(moveParts, dematSound)
addMovable(moveParts, matSound)
addMovable(moveParts, tardisLight)

addMovable(fadeParts, dematSound)
addMovable(fadeParts, matSound)

print("TARDIS scanned children:", #ownedParts)
print("TARDIS shell:", #shellParts)
print("TARDIS movers:", #moveParts)
print(dematSound and "FOUND demat sound" or "MISSING demat sound")
print(matSound and "FOUND mat sound" or "MISSING mat sound")
print(tardisLight and "FOUND Tardislight" or "MISSING Tardislight")

--------------------------------------------------
-- STARTUP LOCK
--------------------------------------------------

for _, object in ipairs(shellParts) do
    setProperty(object, "Anchored", true)
    setProperty(object, "CanCollide", true)
end

print("TARDIS SAFE INIT 2: shell anchored/collidable")

--------------------------------------------------
-- SOUNDBLOCK CONTROL
--
-- DO NOT write Repeat/ResetTimePosition/TimePosition from Code.
-- Fiu was rejecting those writes asynchronously.
--
-- Set BOTH SoundBlocks manually:
--   Repeat = false
--   ResetTimePosition = true
--------------------------------------------------

local function setSoundPowered(block, state)
    if not block then
        return false
    end

    local ok = pcall(function()
        block:FireInput("Input", state)
    end)

    return ok
end

local function stopSound(block)
    if block then
        setSoundPowered(block, false)
    end
end

local function playSound(block)
    if not block then
        return false
    end

    -- ResetTimePosition=true means this false edge rewinds it.
    setSoundPowered(block, false)
    return setSoundPowered(block, true)
end

local function getSoundTime(block)
    return tonumber(readAttribute(block, "TimePosition"))
end

local function getSoundLength(block)
    return tonumber(readAttribute(block, "TimeLength")) or 0
end

local function isSoundPlaying(block)
    return readAttribute(block, "IsPlaying") == true
end

print("TARDIS SAFE INIT 3: SoundBlocks untouched; FireInput ready")

--------------------------------------------------
-- PIVOT / OFFSETS
--------------------------------------------------

local startingPivot = nil

if #shellParts > 0 then
    startingPivot = getProperty(shellParts[1], "CFrame")
end

if not startingPivot then
    print("TARDIS FATAL: no shell pieces named Tardis")

    while true do
        task.wait(1)
    end
end

for _, object in ipairs(moveParts) do
    local cf = getProperty(object, "CFrame")

    if typeof(cf) == "CFrame" then
        relativeCFrames[object] = startingPivot:ToObjectSpace(cf)
    end
end

local defaultRotation = startingPivot - startingPivot.Position

--------------------------------------------------
-- SHELL BOTTOM
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

print("TARDIS SAFE INIT 4: pivot/offsets ready")

--------------------------------------------------
-- SERVER-REPLICATED MOVEMENT
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
        and math.abs(value - lastFadeValue) < 0.008 then
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
-- TOP LAMP
--------------------------------------------------

local lightInterval = 1 / LIGHT_HZ
local lastLightAt = -math.huge

local function setTopLightTransparency(value, force)
    if not tardisLight then
        return
    end

    local now = os.clock()

    if not force and now - lastLightAt < lightInterval then
        return
    end

    lastLightAt = now
    setProperty(tardisLight, "Transparency", math.clamp(value, 0, 1))
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

    local ok = pcall(function()
        Players = game:GetService("Players")
    end)

    if not ok or not Players then
        return nil
    end

    local player = nil

    ok = pcall(function()
        player = Players.LocalPlayer
    end)

    if not ok or not player then
        return nil
    end

    local character = nil

    ok = pcall(function()
        character = player.Character
    end)

    if not ok or not character then
        return nil
    end

    local root = nil

    pcall(function()
        root = character.HumanoidRootPart
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
        humanoid = character.Humanoid
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
-- SOUND-TIME PULSE
--------------------------------------------------

local function soundPulse(t)
    t = t or 0

    local a = math.abs(math.sin(t * 5.7))
    local b = math.abs(math.sin(t * 11.9 + 0.7))
    local c = math.abs(math.sin(t * 23.4 + 1.8))
    local d = math.abs(math.sin(t * 37.1 + 0.2))

    local pulse =
        a * 0.38
        + b * 0.28
        + c * 0.20
        + d * 0.14

    return math.clamp(pulse, 0, 1) ^ 0.32
end

local function getVisualEndTime(sound)
    local length = getSoundLength(sound)

    if length > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
        return length - SOUND_TAIL_TIME
    end

    return VISUAL_START_TIME + FALLBACK_FADE_TIME
end

local function getWaveTransparency(targetFade, progress, pulse)
    progress = math.clamp(progress, 0, 1)
    pulse = math.clamp(pulse or 0, 0, 1)

    local aggressive = progress ^ FADE_AGGRESSION

    if targetFade >= 1 then
        return math.clamp(
            aggressive + pulse * WAVE_STRENGTH * (1 - aggressive),
            0,
            1
        )
    end

    local base = 1 - aggressive

    return math.clamp(
        base - pulse * WAVE_STRENGTH * base,
        0,
        1
    )
end

local function applyVisual(transition, progress, pulse, force)
    local transparency = getWaveTransparency(
        transition.targetFade,
        progress,
        pulse
    )

    setShellTransparency(transparency, force == true)

    local lampPulse = math.clamp(pulse, 0, 1) ^ 0.16
    setTopLightTransparency(1 - lampPulse, force == true)
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
    setTopLightTransparency(0, true)
else
    setShellTransparency(1, true)
    setTopLightTransparency(1, true)
    moveTardis(hiddenPivot)
end

print("TARDIS SAFE INIT 5: initial state applied")
print("TARDIS SAFE INIT COMPLETE")

--------------------------------------------------
-- MATERIALIZATION PREP
--------------------------------------------------

local function prepareMaterialization(kind)
    if not hidden then
        return true
    end

    setShellTransparency(1, true)
    setTopLightTransparency(1, true)

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

    local completed

    if targetFade >= 1 then
        completed = currentFade
    else
        completed = 1 - currentFade
    end

    completed = math.clamp(completed, 0, 1)

    local soundStarted = playSound(sound)
    local now = os.clock()

    activeTransition = {
        kind = kind,
        targetFade = targetFade,
        sound = sound,
        visualEnd = visualEnd,
        requestTime = now,
        maxSoundTime = 0,
        soundAdvanced = false,
        visualComplete = false,
        visualCompleteAt = nil,

        fallback = not soundStarted,
        fallbackStart = now,
        fallbackStartProgress = completed,
        fallbackDuration = math.max(
            0.05,
            FALLBACK_FADE_TIME * (1 - completed)
        ),
    }

    if not soundStarted then
        print("TARDIS: SoundBlock FireInput failed; fallback clock")
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
        setTopLightTransparency(1, true)

        moveTardis(hiddenPivot)
        hidden = true

        if transition.kind == "auto_demat" and autoSequence then
            requestMaterialize("auto_materialize")
        end
    else
        currentFade = 0
        setShellTransparency(0, true)
        setTopLightTransparency(0, true)
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
            print("TARDIS: sound clock stalled; fallback")
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

    local pulse = soundPulse(pulseTime)

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

    local lampPulse = soundPulse(pulseTime) ^ 0.16
    setTopLightTransparency(1 - lampPulse, false)

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
        setTopLightTransparency(1, true)
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
