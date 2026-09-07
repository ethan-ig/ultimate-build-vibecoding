--------------------------------------------------
-- TARDIS CONTROLLER
--
-- Input A
--   true  = materialized
--   false = dematerialized
--
-- Input C
--   normal materialization destination
--   Vector3 or CFrame
--
-- Input J
--   rising edge = demat, then remat on local player
--
-- The SoundBlocks are the MASTER CLOCK.
-- While a sound is playing, its TimePosition directly
-- determines the TARDIS transparency.
--
-- No Code-block outputs are required.
--------------------------------------------------

local inputA = script.inputs["a"]
local inputC = script.inputs["c"]
local inputJ = script.inputs["j"]

--------------------------------------------------
-- DISPLAY NAMES
--------------------------------------------------

local SHELL_NAME = "Tardis"
local DEMAT_SOUND_NAME = "TardisDematSound"
local MAT_SOUND_NAME = "TardisMatSound"

--------------------------------------------------
-- AUDIO / VISUAL SYNC
--------------------------------------------------

-- Audio starts first. The shell begins fading when
-- the sound playhead reaches this point.
local VISUAL_START_TIME = 0.25

-- The shell reaches fully visible/invisible this many
-- seconds BEFORE the audio clip ends.
local SOUND_TAIL_TIME = 3

-- Only used if SoundBlock timing cannot be read.
local FALLBACK_FADE_TIME = 14
local FALLBACK_TAIL_TIME = 3
local SOUND_START_TIMEOUT = 4

-- How often we sample sound TimePosition and write
-- transparency. The SOUND is still the clock; this is
-- only the visual refresh rate.
local UPDATE_INTERVAL = 1 / 30

--------------------------------------------------
-- POSITIONING
--------------------------------------------------

local HIDDEN_POSITION = Vector3.new(-2000, 1, 2772)
local RECALL_GROUND_CLEARANCE = 0.10

--------------------------------------------------
-- SOUND SETTINGS MANAGED BY SCRIPT
--------------------------------------------------

local SOUND_VOLUME = 1
local SOUND_PITCH = 1

--------------------------------------------------
-- TRANSPARENCY KEYFRAMES
--------------------------------------------------

local TRANSPARENCY_STEPS = {
    0.0,
    0.1,
    0.2,
    0.3,
    0.4,
    0.5,
    0.6,
    0.7,
    0.8,
    0.9,
    1.0,
}

local SEGMENT_COUNT = #TRANSPARENCY_STEPS - 1

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
-- FIND NAMED BLOCK
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

--------------------------------------------------
-- SOUND BLOCKS
--------------------------------------------------

local dematSound = findNamedBlock(DEMAT_SOUND_NAME)
local matSound = findNamedBlock(MAT_SOUND_NAME)

if dematSound then
    print("FOUND:", DEMAT_SOUND_NAME)
else
    print("ERROR: missing", DEMAT_SOUND_NAME)
end

if matSound then
    print("FOUND:", MAT_SOUND_NAME)
else
    print("ERROR: missing", MAT_SOUND_NAME)
end

--------------------------------------------------
-- DIRECT SOUNDBLOCK CONTROL
--------------------------------------------------

local function getSoundInput(block)
    if not block then
        return nil
    end

    local candidates = {
        "Input",
        "input",
        "Toggle",
        "toggle",
        "a",
        "A",
    }

    for _, name in ipairs(candidates) do
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
            -- bypass=true forces the update even if the input
            -- already thinks it has the requested state.
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

    local inputNames = {
        "Input",
        "input",
        "Toggle",
        "toggle",
        "a",
    }

    for _, inputName in ipairs(inputNames) do
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

--------------------------------------------------
-- SOUND PLAY / PAUSE / STOP
--------------------------------------------------

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

    -- Some SoundBlock configurations reset when powered off.
    -- Restore the playhead so this behaves like a real pause.
    setBlockValue(block, "TimePosition", position)
end

local function resumeSound(block)
    if not block then
        return
    end

    setSoundPowered(block, true)
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
--
-- shellParts:
--   only actual TARDIS shell pieces; used for the
--   landing-height calculation.
--
-- moveParts:
--   shell + both SoundBlocks.
--
-- fadeParts:
--   shell + both SoundBlocks.
--
-- The SoundBlocks therefore MOVE and FADE with the
-- shell even though they have different DisplayNames.
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

    if not ok then
        return
    end

    table.insert(list, part)
end

--------------------------------------------------
-- FIND SHELL PARTS
--------------------------------------------------

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

--------------------------------------------------
-- SOUND BLOCKS MOVE + FADE WITH SHELL
--------------------------------------------------

addPart(moveParts, dematSound)
addPart(moveParts, matSound)

addPart(fadeParts, dematSound)
addPart(fadeParts, matSound)

print("TARDIS shell blocks:", #shellParts)
print("TARDIS moving blocks:", #moveParts)
print("TARDIS fading blocks:", #fadeParts)

--------------------------------------------------
-- STARTING PIVOT
--------------------------------------------------

local startingPivot = nil

if #shellParts > 0 then
    startingPivot = shellParts[1].CFrame
end

--------------------------------------------------
-- SAVE MOVEMENT OFFSETS
--------------------------------------------------

if startingPivot then
    for _, part in ipairs(moveParts) do
        relativeCFrames[part] =
            startingPivot:ToObjectSpace(part.CFrame)
    end
end

--------------------------------------------------
-- ORIGINAL ROTATION
--------------------------------------------------

local defaultRotation =
    startingPivot
    and (startingPivot - startingPivot.Position)
    or CFrame.identity

--------------------------------------------------
-- FIND ACTUAL BOTTOM OF SHELL
--
-- SoundBlocks are intentionally excluded here so
-- their position cannot affect landing height.
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
        tardisBottomOffset =
            lowestBottom - startingPivot.Position.Y
    end
end

print("TARDIS bottom offset:", tardisBottomOffset)

--------------------------------------------------
-- MOVE WHOLE TARDIS
--------------------------------------------------

local function moveTardis(pivot)
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
-- APPLY ONE TRANSPARENCY VALUE TO SHELL + SOUNDS
--------------------------------------------------

local function setTransparency(value)
    value = math.clamp(value, 0, 1)

    for _, part in ipairs(fadeParts) do
        pcall(function()
            part.Transparency = value
        end)
    end
end

--------------------------------------------------
-- HARD-CODED .1 TRANSPARENCY CURVE
--------------------------------------------------

local function smoothStep(t)
    t = math.clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
end

local function getTransparency(progress)
    progress = math.clamp(progress, 0, 1)

    if progress <= 0 then
        return 0
    end

    if progress >= 1 then
        return 1
    end

    local scaled = progress * SEGMENT_COUNT
    local segment = math.floor(scaled)
    local segmentProgress = scaled - segment

    local indexA = segment + 1
    local indexB = indexA + 1

    local valueA = TRANSPARENCY_STEPS[indexA]
    local valueB = TRANSPARENCY_STEPS[indexB]

    local eased = smoothStep(segmentProgress)

    return valueA + (valueB - valueA) * eased
end

--------------------------------------------------
-- NORMAL DESTINATION FROM INPUT C
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

--------------------------------------------------
-- LOCAL PLAYER ROOT
--------------------------------------------------

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

--------------------------------------------------
-- PLAYER GROUND HEIGHT
--------------------------------------------------

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
            groundY =
                root.Position.Y
                - (rootHeight / 2)
                - hipHeight
        end
    end

    return groundY
end

--------------------------------------------------
-- J RECALL DESTINATION
--------------------------------------------------

local function getCharacterDestination()
    local root = getLocalPlayerRoot()

    if not root then
        print("J RECALL: player root not found")
        return nil
    end

    local groundY = getPlayerGroundY(root)

    local pivotY =
        groundY
        - tardisBottomOffset
        + RECALL_GROUND_CLEARANCE

    local position = Vector3.new(
        root.Position.X,
        pivotY,
        root.Position.Z
    )

    print("J RECALL destination:", position)

    return CFrame.new(position) * defaultRotation
end

--------------------------------------------------
-- HIDDEN PIVOT
--------------------------------------------------

local hiddenPivot =
    CFrame.new(HIDDEN_POSITION) * defaultRotation

--------------------------------------------------
-- SOUND TIMING HELPERS
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

--------------------------------------------------
-- STATE
--------------------------------------------------

local inputState = inputA:GetState() == true

-- 0 = fully visible
-- 1 = fully invisible
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
    setTransparency(0)
else
    setTransparency(1)
    moveTardis(hiddenPivot)
end

--------------------------------------------------
-- PREPARE MATERIALIZATION POSITION
--
-- Shell + both SoundBlocks move while fully invisible
-- BEFORE the arrival sound begins, so 3D audio comes
-- from the destination.
--------------------------------------------------

local function prepareMaterialization(kind)
    if not hidden then
        return true
    end

    setTransparency(1)

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
-- START AUDIO-CLOCKED TRANSITION
--------------------------------------------------

local function startTransition(kind, targetFade, sound)
    --------------------------------------------------
    -- Stop currently active sound if direction changes.
    --------------------------------------------------

    if activeTransition and activeTransition.sound then
        stopSound(activeTransition.sound)
    end

    activeTransition = nil

    --------------------------------------------------
    -- Arrival location must be established first.
    --------------------------------------------------

    if targetFade <= 0 then
        local ok = prepareMaterialization(kind)

        if not ok then
            print("Materialization destination unavailable")
            return
        end
    end

    --------------------------------------------------
    -- Stop opposite audio.
    --------------------------------------------------

    if sound == dematSound then
        stopSound(matSound)
    else
        stopSound(dematSound)
    end

    local visualEnd = getVisualEndTime(sound)

    --------------------------------------------------
    -- If we reverse halfway through a fade, seek the
    -- new sound to the equivalent point so SOUND and
    -- TRANSPARENCY stay locked together.
    --------------------------------------------------

    local desiredVisualProgress

    if targetFade >= 1 then
        desiredVisualProgress = currentFade
    else
        desiredVisualProgress = 1 - currentFade
    end

    desiredVisualProgress =
        math.clamp(desiredVisualProgress, 0, 1)

    local seekPosition = 0

    if desiredVisualProgress > 0.01 then
        seekPosition =
            VISUAL_START_TIME
            + desiredVisualProgress
            * (visualEnd - VISUAL_START_TIME)
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

        -- Fallback data. This is only used when the
        -- SoundBlock fails to provide usable timing.
        fallback = sound == nil,
        fallbackStart = os.clock(),
        fallbackStartFade = currentFade,
        fallbackTailStart = nil,
    }

    print(
        "TARDIS transition:",
        kind,
        "sound-controlled"
    )
end

local function requestDemat(kind)
    startTransition(kind, 1, dematSound)
end

local function requestMaterialize(kind)
    startTransition(kind, 0, matSound)
end

--------------------------------------------------
-- FINISH TRANSITION AFTER SOUND TAIL
--------------------------------------------------

local function finishTransition(transition)
    if activeTransition ~= transition then
        return
    end

    activeTransition = nil
    stopSound(transition.sound)

    --------------------------------------------------
    -- FULLY DEMATERIALIZED
    --------------------------------------------------

    if transition.targetFade >= 1 then
        setTransparency(1)
        currentFade = 1

        -- Audio has finished. Now move shell + sounds
        -- to the hidden parking location.
        moveTardis(hiddenPivot)
        hidden = true

        if transition.kind == "auto_demat" then
            requestMaterialize("auto_materialize")
        end

    --------------------------------------------------
    -- FULLY MATERIALIZED
    --------------------------------------------------

    else
        setTransparency(0)
        currentFade = 0
        hidden = false

        if transition.kind == "auto_materialize" then
            autoSequence = false
            lastInputState = inputA:GetState() == true
            print("J RECALL COMPLETE")
        end
    end
end

--------------------------------------------------
-- AUDIO MASTER CLOCK
--
-- THIS IS THE IMPORTANT PART:
--
-- transparency is NOT incremented using elapsed time.
-- Every update we read SoundBlock.TimePosition and
-- calculate the exact fade value from that playhead.
--
-- DEMAT:
--   sound position  ->  0 ... 1 transparency
--
-- MATERIALIZE:
--   sound position  ->  1 ... 0 transparency
--------------------------------------------------

local function updateTransition()
    local transition = activeTransition

    if not transition then
        return
    end

    local now = os.clock()
    local sound = transition.sound

    local soundTime =
        tonumber(getBlockValue(sound, "TimePosition"))

    local timeLength = getSoundLength(sound)
    local isPlaying = getBlockValue(sound, "IsPlaying") == true

    --------------------------------------------------
    -- USE SOUND PLAYHEAD AS MASTER CLOCK
    --------------------------------------------------

    if not transition.fallback and soundTime ~= nil then
        if soundTime > transition.maxSoundTime then
            transition.maxSoundTime = soundTime
        end

        --------------------------------------------------
        -- As soon as actual clip length is available,
        -- make the visual endpoint follow it.
        --------------------------------------------------

        if timeLength > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
            transition.visualEnd = timeLength - SOUND_TAIL_TIME
        end

        --------------------------------------------------
        -- Before VISUAL_START_TIME, sound plays but the
        -- TARDIS stays at its starting transparency.
        --------------------------------------------------

        if not transition.visualComplete
        and soundTime >= VISUAL_START_TIME then

            local visualDuration =
                math.max(
                    transition.visualEnd - VISUAL_START_TIME,
                    0.01
                )

            --------------------------------------------------
            -- AUDIO -> VISUAL PROGRESS
            --------------------------------------------------

            local audioProgress =
                math.clamp(
                    (soundTime - VISUAL_START_TIME)
                    / visualDuration,
                    0,
                    1
                )

            --------------------------------------------------
            -- AUDIO PROGRESS DIRECTLY SETS TRANSPARENCY
            --------------------------------------------------

            if transition.targetFade >= 1 then
                currentFade = audioProgress
            else
                currentFade = 1 - audioProgress
            end

            setTransparency(
                getTransparency(currentFade)
            )

            --------------------------------------------------
            -- VISUAL REACHED END; audio tail keeps playing.
            --------------------------------------------------

            if audioProgress >= 1 then
                transition.visualComplete = true
                currentFade = transition.targetFade
                setTransparency(transition.targetFade)

                print(
                    "Visual complete at sound position:",
                    soundTime,
                    "audio tail continuing"
                )
            end
        end

        --------------------------------------------------
        -- SOUND FINISHED
        --------------------------------------------------

        if transition.visualComplete then
            local soundFinished = false

            if timeLength > 0
            and transition.maxSoundTime >= timeLength - 0.08 then
                soundFinished = true
            end

            if not isPlaying
            and transition.maxSoundTime > VISUAL_START_TIME then
                soundFinished = true
            end

            if soundFinished then
                finishTransition(transition)
                return
            end
        end

        --------------------------------------------------
        -- Sound never started / TimePosition never moved.
        --------------------------------------------------

        if now - transition.requestTime >= SOUND_START_TIMEOUT
        and transition.maxSoundTime <= 0.01 then
            print("Sound clock unavailable; using fallback timer")

            transition.fallback = true
            transition.fallbackStart = now
            transition.fallbackStartFade = currentFade
        end

    --------------------------------------------------
    -- NO SOUND TIMING AVAILABLE
    --------------------------------------------------

    elseif not transition.fallback then
        if now - transition.requestTime >= SOUND_START_TIMEOUT then
            print("Sound timing unreadable; using fallback timer")

            transition.fallback = true
            transition.fallbackStart = now
            transition.fallbackStartFade = currentFade
        end
    end

    --------------------------------------------------
    -- FALLBACK ONLY
    --
    -- This section is deliberately separate. If the
    -- SoundBlock works, NONE of this controls the fade.
    --------------------------------------------------

    if transition.fallback then
        local elapsed = now - transition.fallbackStart

        if not transition.visualComplete then
            local progress =
                math.clamp(
                    elapsed / FALLBACK_FADE_TIME,
                    0,
                    1
                )

            currentFade =
                transition.fallbackStartFade
                + (transition.targetFade - transition.fallbackStartFade)
                * progress

            setTransparency(getTransparency(currentFade))

            if progress >= 1 then
                transition.visualComplete = true
                currentFade = transition.targetFade
                setTransparency(transition.targetFade)
                transition.fallbackTailStart = now
            end

        elseif transition.fallbackTailStart
        and now - transition.fallbackTailStart >= FALLBACK_TAIL_TIME then
            finishTransition(transition)
        end
    end
end

--------------------------------------------------
-- J AUTO RECALL
--------------------------------------------------

local function startAutoRecall()
    print("J RECALL START")

    autoSequence = true

    if hidden or currentFade >= 1 then
        setTransparency(1)
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
    --------------------------------------------------
    -- J RECALL - rising edge only
    --------------------------------------------------

    local jState = inputJ:GetState() == true

    if jState
    and not lastJState
    and not autoSequence then
        startAutoRecall()
    end

    lastJState = jState

    --------------------------------------------------
    -- NORMAL A CONTROL
    --------------------------------------------------

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

    --------------------------------------------------
    -- SOUND -> TRANSPARENCY UPDATE
    --------------------------------------------------

    updateTransition()

    task.wait(UPDATE_INTERVAL)
end
