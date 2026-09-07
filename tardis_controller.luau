-- TARDIS CONTROLLER - RECOVERY / DIRECT UB PROXY VERSION
--
-- This intentionally backs away from the experimental wrapper-heavy versions.
-- The important rule in this file is:
--   * reads may be protected
--   * UB proxy PROPERTY WRITES are direct and are NOT wrapped in pcall
--
-- INPUTS
--   A = true materialized / false dematerialized
--   C = normal destination (Vector3 or CFrame)
--   J = one-shot recall: demat -> remat on local player
--
-- DISPLAY NAMES
--   Tardis
--   TardisDematSound
--   TardisMatSound
--   Tardislight
--
-- SOUNDBLOCKS
--   Set manually:
--     Repeat = false
--     ResetTimePosition = true
--
-- No Code outputs are required.

local inputA = script.inputs["a"]
local inputC = script.inputs["c"]
local inputJ = script.inputs["j"]

local SHELL_NAME = "Tardis"
local DEMAT_SOUND_NAME = "TardisDematSound"
local MAT_SOUND_NAME = "TardisMatSound"
local LIGHT_NAME = "Tardislight"

local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10

-- Visual timing
local VISUAL_START_TIME = 0.20
local SOUND_TAIL_TIME = 2.50
local FALLBACK_FADE_TIME = 14
local FALLBACK_TAIL_TIME = 2.50
local SOUND_START_TIMEOUT = 3

-- Audio-locked visual shaping
local FADE_AGGRESSION = 0.48
local WAVE_STRENGTH = 0.62

-- IMPORTANT: 357 parts x 4 Hz ~= 1428 replicated transparency writes/sec.
-- This stays comfortably below the old UB ~2500 remote writes/sec limit.
local REPLICATED_FADE_HZ = 4
local REPLICATED_FADE_INTERVAL = 1 / REPLICATED_FADE_HZ

-- Movement is a one-shot burst. Yield every batch so we do not hammer UB.
local MOVE_BATCH_SIZE = 32
local LOOP_INTERVAL = 1 / 30

--------------------------------------------------
-- SAFE READ HELPERS
--
-- Reads are allowed to be protected. PROPERTY WRITES below are not.
--------------------------------------------------

local function readProperty(object, property)
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

local function getDisplayName(object)
    local value = readAttribute(object, "Display name")

    if type(value) == "string" and value ~= "" then
        return value
    end

    -- Older Code-block builds exposed this spelling/property.
    value = readProperty(object, "DisplayName")

    if type(value) == "string" and value ~= "" then
        return value
    end

    return nil
end

local function hasCFrame(object)
    return typeof(readProperty(object, "CFrame")) == "CFrame"
end

--------------------------------------------------
-- DISCOVERY
--
-- GetChildren(true) is the version that previously found the 357 TARDIS
-- shell blocks correctly on this build. We keep that as the primary source.
-- A plain GetChildren() pass is merged only to give specialty blocks another
-- chance to appear without using the troublesome descendant scan.
--------------------------------------------------

print("TARDIS RECOVERY INIT 1")

local candidates = {}
local candidateSet = {}

local function addCandidates(list)
    if not list then
        return
    end

    for _, object in ipairs(list) do
        if object ~= script and not candidateSet[object] then
            candidateSet[object] = true
            table.insert(candidates, object)
        end
    end
end

local okOwned, owned = pcall(function()
    return workspace:GetChildren(true)
end)

if okOwned then
    addCandidates(owned)
end

local okAll, allChildren = pcall(function()
    return workspace:GetChildren()
end)

if okAll then
    addCandidates(allChildren)
end

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

local function addUnique(list, object)
    if object and not contains(list, object) then
        table.insert(list, object)
    end
end

for _, object in ipairs(candidates) do
    local displayName = getDisplayName(object)

    if displayName then
        local lower = string.lower(displayName)

        if lower == string.lower(SHELL_NAME) and hasCFrame(object) then
            table.insert(shellParts, object)
            addUnique(moveParts, object)
            addUnique(fadeParts, object)

        elseif lower == string.lower(DEMAT_SOUND_NAME) then
            dematSound = object

        elseif lower == string.lower(MAT_SOUND_NAME) then
            matSound = object

        elseif lower == string.lower(LIGHT_NAME) then
            tardisLight = object
        end
    end
end

-- Specialty blocks are optional. Core A/J behavior must still work without them.
if dematSound and hasCFrame(dematSound) then
    addUnique(moveParts, dematSound)
    addUnique(fadeParts, dematSound)
end

if matSound and hasCFrame(matSound) then
    addUnique(moveParts, matSound)
    addUnique(fadeParts, matSound)
end

if tardisLight and hasCFrame(tardisLight) then
    addUnique(moveParts, tardisLight)
end

print("TARDIS candidates:", #candidates)
print("TARDIS shell:", #shellParts)
print("TARDIS movers:", #moveParts)
print(dematSound and "FOUND demat sound" or "MISSING demat sound")
print(matSound and "FOUND mat sound" or "MISSING mat sound")
print(tardisLight and "FOUND Tardislight" or "MISSING Tardislight")

if #shellParts == 0 then
    print("TARDIS FATAL: zero shell pieces detected")
    return
end

--------------------------------------------------
-- STARTUP PHYSICS
--
-- DIRECT UB PROXY WRITES. DO NOT wrap these in pcall.
--------------------------------------------------

for index, part in ipairs(shellParts) do
    part.Anchored = true
    part.CanCollide = true

    if index % MOVE_BATCH_SIZE == 0 then
        task.wait()
    end
end

print("TARDIS RECOVERY INIT 2: shell anchored + collidable")

--------------------------------------------------
-- PIVOT / OFFSETS
--------------------------------------------------

local startingPivot = shellParts[1].CFrame
local defaultRotation = startingPivot - startingPivot.Position

for _, part in ipairs(moveParts) do
    local cf = readProperty(part, "CFrame")

    if typeof(cf) == "CFrame" then
        relativeCFrames[part] = startingPivot:ToObjectSpace(cf)
    end
end

--------------------------------------------------
-- BOTTOM OF SHELL
--------------------------------------------------

local tardisBottomOffset = 0
local lowestBottom = math.huge

for _, part in ipairs(shellParts) do
    local cf = readProperty(part, "CFrame")
    local size = readProperty(part, "Size")

    if typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
        local verticalHalfExtent =
            math.abs(cf.RightVector.Y) * (size.X / 2)
            + math.abs(cf.UpVector.Y) * (size.Y / 2)
            + math.abs(cf.LookVector.Y) * (size.Z / 2)

        local bottom = cf.Position.Y - verticalHalfExtent

        if bottom < lowestBottom then
            lowestBottom = bottom
        end
    end
end

if lowestBottom < math.huge then
    tardisBottomOffset = lowestBottom - startingPivot.Position.Y
end

print("TARDIS RECOVERY INIT 3: offsets ready")

--------------------------------------------------
-- DIRECT SERVER-REPLICATED MOVEMENT
--
-- This is the critical change: no pcall around part.CFrame assignment.
--------------------------------------------------

local function moveTardis(pivot)
    if not pivot then
        return
    end

    print("TARDIS MOVE BEGIN ->", pivot.Position)

    for index, part in ipairs(moveParts) do
        local offset = relativeCFrames[part]

        if offset then
            part.CFrame = pivot * offset
        end

        if index % MOVE_BATCH_SIZE == 0 then
            task.wait()
        end
    end

    print("TARDIS MOVE COMPLETE")
end

--------------------------------------------------
-- DIRECT SERVER-REPLICATED TRANSPARENCY
--------------------------------------------------

local lastFadeWrite = -math.huge
local lastReplicatedTransparency = nil

local function setTardisTransparency(value, force)
    value = math.clamp(value, 0, 1)

    local now = os.clock()

    if not force then
        if now - lastFadeWrite < REPLICATED_FADE_INTERVAL then
            return
        end

        if lastReplicatedTransparency ~= nil
        and math.abs(value - lastReplicatedTransparency) < 0.015 then
            return
        end
    end

    lastFadeWrite = now
    lastReplicatedTransparency = value

    for _, part in ipairs(fadeParts) do
        part.Transparency = value
    end
end

--------------------------------------------------
-- TOP LIGHT
--
-- For stability we only pulse the physical light block's Transparency here.
-- No Brightness attribute writes until the core is proven stable again.
--------------------------------------------------

local lastLightWrite = -math.huge

local function setTopLightTransparency(value, force)
    if not tardisLight then
        return
    end

    local now = os.clock()

    if not force and now - lastLightWrite < REPLICATED_FADE_INTERVAL then
        return
    end

    lastLightWrite = now
    tardisLight.Transparency = math.clamp(value, 0, 1)
end

--------------------------------------------------
-- SOUNDBLOCK CONTROL
--
-- No sound attributes are written from Code.
--------------------------------------------------

local function fireSound(block, state)
    if not block then
        return false
    end

    local input = nil

    local ok = pcall(function()
        input = block.inputs["Input"]
    end)

    if not ok or not input then
        return false
    end

    -- This is the documented wiring API.
    input:Fire(state, true)
    return true
end

local function stopSound(block)
    if block then
        fireSound(block, false)
    end
end

local function playSound(block)
    if not block then
        return false
    end

    -- With ResetTimePosition=true, the false edge rewinds before the true edge.
    fireSound(block, false)
    return fireSound(block, true)
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

    print("INPUT C invalid; using original position")
    return startingPivot
end

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
-- SOUND-TIME-LOCKED PULSE
--
-- UB exposes TimePosition but not a real waveform/loudness value in the
-- documented SoundBlock interface. This makes a sharp pulse whose PHASE is
-- locked to TimePosition, so it pauses/seeks/restarts with the sound.
--------------------------------------------------

local function soundPulse(t)
    t = t or 0

    local a = math.abs(math.sin(t * 5.9))
    local b = math.abs(math.sin(t * 12.7 + 0.6))
    local c = math.abs(math.sin(t * 25.1 + 1.4))

    local pulse = a * 0.46 + b * 0.34 + c * 0.20
    return math.clamp(pulse, 0, 1) ^ 0.28
end

local function getVisualEndTime(sound)
    local length = getSoundLength(sound)

    if length > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
        return length - SOUND_TAIL_TIME
    end

    return VISUAL_START_TIME + FALLBACK_FADE_TIME
end

local function getAudioDrivenTransparency(targetFade, baseFade, pulse)
    baseFade = math.clamp(baseFade, 0, 1)
    pulse = math.clamp(pulse or 0, 0, 1)

    if targetFade >= 1 then
        return math.clamp(
            baseFade + pulse * WAVE_STRENGTH * (1 - baseFade),
            0,
            1
        )
    end

    return math.clamp(
        baseFade - pulse * WAVE_STRENGTH * baseFade,
        0,
        1
    )
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
    setTardisTransparency(0, true)
    setTopLightTransparency(0, true)
else
    setTardisTransparency(1, true)
    setTopLightTransparency(1, true)
    moveTardis(hiddenPivot)
end

print("TARDIS RECOVERY INIT COMPLETE")

--------------------------------------------------
-- PREP MATERIALIZATION
--------------------------------------------------

local function prepareMaterialization(kind)
    if not hidden then
        return true
    end

    setTardisTransparency(1, true)
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

    -- Move while invisible.
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

    local now = os.clock()
    local soundStarted = playSound(sound)

    activeTransition = {
        kind = kind,
        targetFade = targetFade,
        startFade = currentFade,
        sound = sound,
        requestTime = now,
        visualEnd = getVisualEndTime(sound),
        maxSoundTime = 0,
        soundAdvanced = false,
        fallback = not soundStarted,
        fallbackStart = now,
        visualComplete = false,
        visualCompleteAt = nil,
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
        setTardisTransparency(1, true)
        setTopLightTransparency(1, true)

        moveTardis(hiddenPivot)
        hidden = true

        if transition.kind == "auto_demat" and autoSequence then
            requestMaterialize("auto_materialize")
        end
    else
        currentFade = 0
        setTardisTransparency(0, true)
        setTopLightTransparency(0, true)
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
    local rawProgress = nil
    local pulseTime = 0

    --------------------------------------------------
    -- AUDIO CLOCK
    --------------------------------------------------

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

            rawProgress = math.clamp(
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
            print("TARDIS: audio clock unavailable; fallback timing")
        end
    end

    --------------------------------------------------
    -- FALLBACK CLOCK
    --------------------------------------------------

    if transition.fallback then
        local elapsed = now - transition.fallbackStart
        pulseTime = elapsed

        rawProgress = math.clamp(
            elapsed / FALLBACK_FADE_TIME,
            0,
            1
        )
    end

    if rawProgress == nil then
        return
    end

    --------------------------------------------------
    -- AGGRESSIVE BASE FADE + SOUND-LOCKED PULSE
    --------------------------------------------------

    local easedProgress = rawProgress ^ FADE_AGGRESSION

    local baseFade =
        transition.startFade
        + (transition.targetFade - transition.startFade) * easedProgress

    currentFade = baseFade

    local pulse = soundPulse(pulseTime)
    local visualTransparency = getAudioDrivenTransparency(
        transition.targetFade,
        baseFade,
        pulse
    )

    if rawProgress < 1 then
        setTardisTransparency(visualTransparency, false)

        local lampPulse = pulse ^ 0.16
        setTopLightTransparency(1 - lampPulse, false)
        return
    end

    --------------------------------------------------
    -- VISUAL COMPLETE / AUDIO TAIL
    --------------------------------------------------

    if not transition.visualComplete then
        transition.visualComplete = true
        transition.visualCompleteAt = now
        currentFade = transition.targetFade
        setTardisTransparency(transition.targetFade, true)
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

        -- Some SoundBlocks do not report an end cleanly. Do not hang forever.
        if not finished
        and transition.visualCompleteAt
        and now - transition.visualCompleteAt >= SOUND_TAIL_TIME + 1 then
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

    if hidden or currentFade >= 0.999 then
        currentFade = 1
        setTardisTransparency(1, true)
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

    -- During a J recall, A is deliberately ignored until the automatic cycle ends.
    if not autoSequence then
        local newAState = inputA:GetState() == true

        if newAState ~= lastInputState then
            lastInputState = newAState

            if newAState then
                print("INPUT A: MATERIALIZE")
                requestMaterialize("manual_materialize")
            else
                print("INPUT A: DEMATERIALIZE")
                requestDemat("manual_demat")
            end
        end
    end

    updateTransition()
    task.wait(LOOP_INTERVAL)
end
