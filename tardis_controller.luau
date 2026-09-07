--------------------------------------------------
-- TARDIS CONTROLLER
--
-- A = normal state
--     true  = materialized
--     false = dematerialized
--
-- C = normal destination
--     Vector3 or CFrame
--
-- J = recall
--     rising edge causes:
--     demat -> remat on local player
--
-- NO OUTPUTS REQUIRED.
--------------------------------------------------

local inputA = script.inputs["a"]
local inputC = script.inputs["c"]
local inputJ = script.inputs["j"]

--------------------------------------------------
-- NAMES
--------------------------------------------------

local SHELL_NAME =
    "Tardis"

local DEMAT_SOUND_NAME =
    "TardisDematSound"

local MAT_SOUND_NAME =
    "TardisMatSound"

--------------------------------------------------
-- SETTINGS
--------------------------------------------------

-- First part of sound before fading begins.
local VISUAL_START_TIME = 0.25

-- We try to finish the visual this many seconds
-- before the audio itself finishes.
local SOUND_TAIL_TIME = 3

-- Used only if audio timing cannot be read.
local FALLBACK_FADE_TIME = 14
local FALLBACK_TAIL_TIME = 3

local SOUND_START_TIMEOUT = 4

local RECALL_GROUND_CLEARANCE = 0.10

local HIDDEN_POSITION =
    Vector3.new(-2000, 1, 2772)

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
    1.0
}

local SEGMENT_COUNT =
    #TRANSPARENCY_STEPS - 1

--------------------------------------------------
-- SAFE VALUE ACCESS
--------------------------------------------------

local function getBlockValue(
    block,
    key
)

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

--------------------------------------------------
-- SAFE VALUE WRITE
--------------------------------------------------

local function setBlockValue(
    block,
    key,
    value
)

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
        block:SetAttribute(
            key,
            value
        )
    end)

    if ok then
        return true
    end

    ok = pcall(function()
        block.attributes[key] = value
    end)

    return ok

end

--------------------------------------------------
-- DISPLAY NAME
--------------------------------------------------

local function getDisplayName(part)

    local value =
        getBlockValue(
            part,
            "DisplayName"
        )

    if type(value) == "string"
    and value ~= "" then

        return value

    end

    return nil

end

--------------------------------------------------
-- FIND NAMED BLOCK
--------------------------------------------------

local function findNamedBlock(name)

    for _, part in ipairs(
        workspace:GetDescendants(true)
    ) do

        if part ~= script then

            local displayName =
                getDisplayName(part)

            if displayName
            and string.lower(displayName)
                == string.lower(name) then

                return part

            end

        end

    end

    return nil

end

--------------------------------------------------
-- FIND SOUND BLOCKS
--------------------------------------------------

local dematSound =
    findNamedBlock(
        DEMAT_SOUND_NAME
    )

local matSound =
    findNamedBlock(
        MAT_SOUND_NAME
    )

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
-- FIND SOUND INPUT
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
        "A"
    }

    for _, name in ipairs(candidates) do

        local ok, value =
            pcall(function()
                return block.inputs[name]
            end)

        if ok and value then
            return value
        end

    end

    local ok, inputTable =
        pcall(function()
            return block.inputs
        end)

    if ok and inputTable then

        local success, result =
            pcall(function()

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

--------------------------------------------------
-- DIRECTLY POWER SOUNDBLOCK
--------------------------------------------------

local function setSoundPowered(
    block,
    state
)

    if not block then
        return false
    end

    local input =
        getSoundInput(block)

    if input then

        local ok =
            pcall(function()
                input:Fire(
                    state,
                    true
                )
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
        "a"
    }

    for _, inputName in ipairs(inputNames) do

        local ok =
            pcall(function()
                block:FireInput(
                    inputName,
                    state
                )
            end)

        if ok then
            return true
        end

    end

    print(
        "Could not control SoundBlock:",
        getDisplayName(block)
    )

    return false

end

--------------------------------------------------
-- CONFIGURE SOUND BLOCK
--------------------------------------------------

local function configureSound(block)

    if not block then
        return
    end

    setBlockValue(
        block,
        "Repeat",
        false
    )

    setBlockValue(
        block,
        "ResetTimePosition",
        false
    )

    setBlockValue(
        block,
        "Volume",
        SOUND_VOLUME
    )

    setBlockValue(
        block,
        "Pitch",
        SOUND_PITCH
    )

    setBlockValue(
        block,
        "Effects",
        false
    )

end

configureSound(dematSound)
configureSound(matSound)

--------------------------------------------------
-- STOP + RESET SOUND
--------------------------------------------------

local function stopSound(block)

    if not block then
        return
    end

    setSoundPowered(
        block,
        false
    )

    task.wait()

    setBlockValue(
        block,
        "TimePosition",
        0
    )

end

--------------------------------------------------
-- PAUSE SOUND
--------------------------------------------------

local function pauseSound(block)

    if not block then
        return
    end

    local position =
        tonumber(
            getBlockValue(
                block,
                "TimePosition"
            )
        ) or 0

    setSoundPowered(
        block,
        false
    )

    task.wait()

    setBlockValue(
        block,
        "TimePosition",
        position
    )

end

--------------------------------------------------
-- RESUME SOUND
--------------------------------------------------

local function resumeSound(block)

    if not block then
        return
    end

    setSoundPowered(
        block,
        true
    )

end

--------------------------------------------------
-- PLAY SOUND FROM POSITION
--------------------------------------------------

local function playSound(
    block,
    position
)

    if not block then
        return false
    end

    setSoundPowered(
        block,
        false
    )

    task.wait()

    setBlockValue(
        block,
        "TimePosition",
        position or 0
    )

    setSoundPowered(
        block,
        true
    )

    return true

end

--------------------------------------------------
-- STOP EVERYTHING
--------------------------------------------------

local function stopAllSounds()
    stopSound(dematSound)
    stopSound(matSound)
end

--------------------------------------------------
-- TARDIS PART STORAGE
--------------------------------------------------

local tardisParts = {}

-- Includes sound blocks.
local moveParts = {}

local relativeCFrames = {}

--------------------------------------------------
-- FIND SHELL BLOCKS
--------------------------------------------------

for _, part in ipairs(
    workspace:GetDescendants(true)
) do

    if part ~= script then

        local displayName =
            getDisplayName(part)

        if displayName
        and string.lower(displayName)
            == string.lower(SHELL_NAME) then

            local ok =
                pcall(function()
                    return part.CFrame
                end)

            if ok then

                table.insert(
                    tardisParts,
                    part
                )

                table.insert(
                    moveParts,
                    part
                )

            end

        end

    end

end

--------------------------------------------------
-- ADD SOUND BLOCKS TO MOVE GROUP
--------------------------------------------------

local function addMovePart(part)

    if not part then
        return
    end

    local ok =
        pcall(function()
            return part.CFrame
        end)

    if not ok then
        return
    end

    for _, existing in ipairs(moveParts) do
        if existing == part then
            return
        end
    end

    table.insert(
        moveParts,
        part
    )

end

addMovePart(dematSound)
addMovePart(matSound)

print(
    "TARDIS shell blocks:",
    #tardisParts
)

print(
    "TARDIS moving blocks:",
    #moveParts
)

--------------------------------------------------
-- STARTING PIVOT
--------------------------------------------------

local startingPivot = nil

if #tardisParts > 0 then
    startingPivot =
        tardisParts[1].CFrame
end

--------------------------------------------------
-- SAVE MOVING PART OFFSETS
--------------------------------------------------

if startingPivot then

    for _, part in ipairs(moveParts) do

        relativeCFrames[part] =
            startingPivot:ToObjectSpace(
                part.CFrame
            )

    end

end

--------------------------------------------------
-- ORIGINAL ROTATION
--------------------------------------------------

local defaultRotation =
    startingPivot
    and (
        startingPivot
        - startingPivot.Position
    )
    or CFrame.identity

--------------------------------------------------
-- FIND ACTUAL BOTTOM
--------------------------------------------------

local tardisBottomOffset = 0

if startingPivot then

    local lowestBottom = math.huge

    for _, part in ipairs(tardisParts) do

        pcall(function()

            local cf = part.CFrame
            local size = part.Size

            local halfHeight =
                math.abs(cf.RightVector.Y)
                * (size.X / 2)
                +
                math.abs(cf.UpVector.Y)
                * (size.Y / 2)
                +
                math.abs(cf.LookVector.Y)
                * (size.Z / 2)

            local bottom =
                cf.Position.Y
                - halfHeight

            if bottom < lowestBottom then
                lowestBottom = bottom
            end

        end)

    end

    if lowestBottom < math.huge then

        tardisBottomOffset =
            lowestBottom
            - startingPivot.Position.Y

    end

end

print(
    "TARDIS bottom offset:",
    tardisBottomOffset
)

--------------------------------------------------
-- MOVE TARDIS
-- Includes BOTH SoundBlocks.
--------------------------------------------------

local function moveTardis(pivot)

    for _, part in ipairs(moveParts) do

        local offset =
            relativeCFrames[part]

        if offset then

            pcall(function()
                part.CFrame =
                    pivot * offset
            end)

        end

    end

end

--------------------------------------------------
-- TRANSPARENCY
-- ONLY TARDIS SHELL FADES.
--------------------------------------------------

local function setTransparency(value)

    value =
        math.clamp(
            value,
            0,
            1
        )

    for _, part in ipairs(tardisParts) do

        pcall(function()
            part.Transparency = value
        end)

    end

end

--------------------------------------------------
-- SMOOTHSTEP
--------------------------------------------------

local function smoothStep(t)

    t =
        math.clamp(
            t,
            0,
            1
        )

    return
        t * t
        * (3 - 2 * t)

end

--------------------------------------------------
-- PROGRESS -> TRANSPARENCY
--------------------------------------------------

local function getTransparency(progress)

    progress =
        math.clamp(
            progress,
            0,
            1
        )

    if progress <= 0 then
        return 0
    end

    if progress >= 1 then
        return 1
    end

    local scaled =
        progress
        * SEGMENT_COUNT

    local segment =
        math.floor(scaled)

    local segmentProgress =
        scaled - segment

    local indexA =
        segment + 1

    local indexB =
        indexA + 1

    local a =
        TRANSPARENCY_STEPS[indexA]

    local b =
        TRANSPARENCY_STEPS[indexB]

    local eased =
        smoothStep(
            segmentProgress
        )

    return
        a
        + (
            b - a
        )
        * eased

end

--------------------------------------------------
-- INPUT C DESTINATION
--------------------------------------------------

local function getInputDestination()

    local value =
        inputC:GetState()

    if typeof(value) == "Vector3" then

        return
            CFrame.new(value)
            * defaultRotation

    end

    if typeof(value) == "CFrame" then
        return value
    end

    print(
        "Input C must be Vector3/CFrame"
    )

    return startingPivot

end

--------------------------------------------------
-- PLAYER ROOT
--------------------------------------------------

local function getLocalPlayerRoot()

    local Players = nil

    pcall(function()
        Players =
            game:GetService(
                "Players"
            )
    end)

    if Players then

        local player = nil

        pcall(function()
            player = Players.LocalPlayer
        end)

        if player then

            local character = nil

            pcall(function()
                character = player.Character
            end)

            if character then

                local root = nil

                pcall(function()
                    root =
                        character:FindFirstChild(
                            "HumanoidRootPart"
                        )
                end)

                if root then
                    return root
                end

            end

        end

    end

    return nil

end

--------------------------------------------------
-- PLAYER GROUND HEIGHT
--------------------------------------------------

local function getPlayerGroundY(root)

    local groundY =
        root.Position.Y - 3

    local character =
        root.Parent

    if not character then
        return groundY
    end

    local humanoid = nil

    pcall(function()
        humanoid =
            character:FindFirstChildOfClass(
                "Humanoid"
            )
    end)

    if humanoid then

        local hipHeight =
            humanoid.HipHeight

        local rootHeight =
            root.Size.Y

        if hipHeight
        and hipHeight > 0.5 then

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

    local root =
        getLocalPlayerRoot()

    if not root then

        print(
            "J RECALL: player root not found"
        )

        return nil

    end

    local groundY =
        getPlayerGroundY(root)

    local pivotY =
        groundY
        - tardisBottomOffset
        + RECALL_GROUND_CLEARANCE

    local position =
        Vector3.new(
            root.Position.X,
            pivotY,
            root.Position.Z
        )

    print(
        "J RECALL destination:",
        position
    )

    return
        CFrame.new(position)
        * defaultRotation

end

--------------------------------------------------
-- HIDDEN POSITION
--------------------------------------------------

local hiddenPivot =
    CFrame.new(
        HIDDEN_POSITION
    )
    * defaultRotation

--------------------------------------------------
-- SOUND TIMING
--------------------------------------------------

local function getSoundLength(block)

    return tonumber(
        getBlockValue(
            block,
            "TimeLength"
        )
    ) or 0

end

--------------------------------------------------
-- CALCULATE WHERE VISUAL SHOULD FINISH
--------------------------------------------------

local function getVisualEndTime(block)

    local length =
        getSoundLength(block)

    if length >
        VISUAL_START_TIME
        + SOUND_TAIL_TIME
        + 0.1 then

        return
            length
            - SOUND_TAIL_TIME

    end

    return
        VISUAL_START_TIME
        + FALLBACK_FADE_TIME

end

--------------------------------------------------
-- STATE
--------------------------------------------------

local inputState =
    inputA:GetState() == true

-- 0 visible
-- 1 invisible
local currentFade =
    inputState and 0 or 1

local hidden =
    not inputState

local lastInputState =
    inputState

local lastJState = false

--------------------------------------------------
-- INITIAL POSITION
--------------------------------------------------

if inputState then

    setTransparency(0)

else

    setTransparency(1)

    moveTardis(
        hiddenPivot
    )

end

--------------------------------------------------
-- TRANSITION STATE
--------------------------------------------------

local activeTransition = nil
local autoSequence = false

--------------------------------------------------
-- PREPARE MATERIALIZATION POSITION
-- Do this BEFORE sound begins so 3D audio is
-- already coming from the arrival location.
--------------------------------------------------

local function prepareMaterialization(kind)

    if not hidden then
        return true
    end

    setTransparency(1)

    local destination = nil

    if kind == "auto_materialize" then

        destination =
            getCharacterDestination()

    else

        destination =
            getInputDestination()

    end

    if not destination then
        return false
    end

    moveTardis(
        destination
    )

    hidden = false
    currentFade = 1

    return true

end

--------------------------------------------------
-- START TRANSITION
--------------------------------------------------

local function startTransition(
    kind,
    targetFade,
    sound
)

    if activeTransition
    and activeTransition.sound then

        stopSound(
            activeTransition.sound
        )

    end

    activeTransition = nil

    --------------------------------------------------
    -- MATERIALIZATION:
    -- MOVE INVISIBLY BEFORE AUDIO STARTS.
    --------------------------------------------------

    if targetFade <= 0 then

        local ok =
            prepareMaterialization(
                kind
            )

        if not ok then

            print(
                "Materialization destination unavailable"
            )

            return

        end

    end

    --------------------------------------------------
    -- STOP OPPOSITE SOUND
    --------------------------------------------------

    if sound == dematSound then
        stopSound(matSound)
    else
        stopSound(dematSound)
    end

    --------------------------------------------------
    -- GET AUDIO TIMING
    --------------------------------------------------

    local visualEnd =
        getVisualEndTime(sound)

    --------------------------------------------------
    -- DETERMINE MATCHING AUDIO POSITION
    -- If reversing midway, audio jumps to the
    -- correct point instead of restarting badly.
    --------------------------------------------------

    local visualProgress

    if targetFade >= 1 then
        visualProgress = currentFade
    else
        visualProgress = 1 - currentFade
    end

    visualProgress =
        math.clamp(
            visualProgress,
            0,
            1
        )

    local seekPosition = 0

    if visualProgress > 0.01 then

        seekPosition =
            VISUAL_START_TIME
            + visualProgress
            * (
                visualEnd
                - VISUAL_START_TIME
            )

    end

    --------------------------------------------------
    -- PLAY SOUND DIRECTLY
    --------------------------------------------------

    playSound(
        sound,
        seekPosition
    )

    --------------------------------------------------
    -- CREATE TRANSITION
    --------------------------------------------------

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
        fallbackTailStart = nil
    }

end

--------------------------------------------------
-- DEMAT
--------------------------------------------------

local function requestDemat(kind)

    startTransition(
        kind,
        1,
        dematSound
    )

end

--------------------------------------------------
-- MATERIALIZE
--------------------------------------------------

local function requestMaterialize(kind)

    startTransition(
        kind,
        0,
        matSound
    )

end

--------------------------------------------------
-- FINISH ENTIRE TRANSITION
-- Called AFTER audio has finished.
--------------------------------------------------

local function finishTransition(transition)

    if activeTransition ~= transition then
        return
    end

    activeTransition = nil

    stopSound(
        transition.sound
    )

    --------------------------------------------------
    -- DEMAT
    --------------------------------------------------

    if transition.targetFade >= 1 then

        setTransparency(1)
        currentFade = 1

        --------------------------------------------------
        -- NOW THAT AUDIO TAIL FINISHED,
        -- PARK SHELL + SOUNDBLOCKS AWAY.
        --------------------------------------------------

        moveTardis(
            hiddenPivot
        )

        hidden = true

        --------------------------------------------------
        -- J RECALL:
        -- START ARRIVAL SEQUENCE.
        --------------------------------------------------

        if transition.kind == "auto_demat" then

            requestMaterialize(
                "auto_materialize"
            )

        end

    --------------------------------------------------
    -- MATERIALIZED
    --------------------------------------------------

    else

        setTransparency(0)
        currentFade = 0
        hidden = false

        if transition.kind == "auto_materialize" then

            autoSequence = false

            lastInputState =
                inputA:GetState() == true

            print(
                "J RECALL COMPLETE"
            )

        end

    end

end

--------------------------------------------------
-- UPDATE AUDIO-CLOCKED TRANSITION
--------------------------------------------------

local function updateTransition()

    local transition =
        activeTransition

    if not transition then
        return
    end

    local sound =
        transition.sound

    local now =
        os.clock()

    local soundTime =
        tonumber(
            getBlockValue(
                sound,
                "TimePosition"
            )
        )

    local isPlaying =
        getBlockValue(
            sound,
            "IsPlaying"
        ) == true

    local timeLength =
        getSoundLength(sound)

    --------------------------------------------------
    -- AUDIO TIMING WORKING
    --------------------------------------------------

    if not transition.fallback
    and soundTime then

        if soundTime > transition.maxSoundTime then
            transition.maxSoundTime = soundTime
        end

        --------------------------------------------------
        -- UPDATE END CUE ONCE LENGTH LOADS
        --------------------------------------------------

        if timeLength >
            VISUAL_START_TIME
            + SOUND_TAIL_TIME
            + 0.1 then

            transition.visualEnd =
                timeLength
                - SOUND_TAIL_TIME

        end

        --------------------------------------------------
        -- VISUAL PHASE
        --------------------------------------------------

        if not transition.visualComplete
        and soundTime >= VISUAL_START_TIME then

            local visualProgress =
                math.clamp(
                    (
                        soundTime
                        - VISUAL_START_TIME
                    )
                    /
                    (
                        transition.visualEnd
                        - VISUAL_START_TIME
                    ),
                    0,
                    1
                )

            if transition.targetFade >= 1 then
                currentFade = visualProgress
            else
                currentFade = 1 - visualProgress
            end

            setTransparency(
                getTransparency(
                    currentFade
                )
            )

            if visualProgress >= 1 then

                transition.visualComplete = true
                currentFade = transition.targetFade

                setTransparency(
                    transition.targetFade
                )

                print(
                    "Visual complete; audio tail playing"
                )

            end

        end

        --------------------------------------------------
        -- SOUND FINISHED NATURALLY
        --------------------------------------------------

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

            finishTransition(
                transition
            )

            return

        end

        --------------------------------------------------
        -- SOUND NEVER STARTED?
        --------------------------------------------------

        if (
            now
            - transition.requestTime
        ) >= SOUND_START_TIMEOUT
        and transition.maxSoundTime <= 0.01 then

            print(
                "Audio clock unavailable; using fallback"
            )

            transition.fallback = true
            transition.fallbackStart = now

        end

    --------------------------------------------------
    -- NO AUDIO FEEDBACK
    --------------------------------------------------

    elseif not transition.fallback then

        if (
            now
            - transition.requestTime
        ) >= SOUND_START_TIMEOUT then

            transition.fallback = true
            transition.fallbackStart = now

        end

    end

    --------------------------------------------------
    -- FALLBACK MODE
    --------------------------------------------------

    if transition.fallback then

        local elapsed =
            now
            - transition.fallbackStart

        if elapsed <= FALLBACK_FADE_TIME then

            local progress =
                math.clamp(
                    elapsed
                    / FALLBACK_FADE_TIME,
                    0,
                    1
                )

            if transition.targetFade >= 1 then
                currentFade = progress
            else
                currentFade = 1 - progress
            end

            setTransparency(
                getTransparency(
                    currentFade
                )
            )

        elseif not transition.visualComplete then

            transition.visualComplete = true
            currentFade = transition.targetFade

            setTransparency(
                transition.targetFade
            )

            transition.fallbackTailStart = now

        elseif transition.fallbackTailStart
        and (
            now
            - transition.fallbackTailStart
        ) >= FALLBACK_TAIL_TIME then

            finishTransition(
                transition
            )

        end

    end

end

--------------------------------------------------
-- J AUTO RECALL
--------------------------------------------------

local function startAutoRecall()

    print(
        "J RECALL START"
    )

    autoSequence = true

    if hidden
    or currentFade >= 1 then

        setTransparency(1)
        hidden = true

        requestMaterialize(
            "auto_materialize"
        )

    else

        requestDemat(
            "auto_demat"
        )

    end

end

--------------------------------------------------
-- MAIN LOOP
--------------------------------------------------

while true do

    --------------------------------------------------
    -- J RECALL
    --------------------------------------------------

    local jState =
        inputJ:GetState() == true

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

        local newState =
            inputA:GetState() == true

        if newState ~= lastInputState then

            lastInputState = newState

            if newState then

                requestMaterialize(
                    "manual_materialize"
                )

            else

                requestDemat(
                    "manual_demat"
                )

            end

        end

    end

    --------------------------------------------------
    -- AUDIO + VISUAL UPDATE
    --------------------------------------------------

    updateTransition()

    task.wait(0.03)

end
