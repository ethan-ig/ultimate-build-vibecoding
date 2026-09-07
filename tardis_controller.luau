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
-- INPUT A is authoritative: changing A always cancels J/auto recall.
-- Sound TimePosition is the master transition clock when available.

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
local UPDATE_INTERVAL = 1 / 60

-- Aggressive audio following.
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

local dematSound = findNamedBlock(DEMAT_SOUND_NAME)
local matSound = findNamedBlock(MAT_SOUND_NAME)
local tardisLight = findNamedBlock(LIGHT_NAME)

print(dematSound and "FOUND TardisDematSound" or "WARNING: TardisDematSound missing - fallback visual enabled")
print(matSound and "FOUND TardisMatSound" or "WARNING: TardisMatSound missing - fallback visual enabled")
print(tardisLight and "FOUND Tardislight" or "WARNING: Tardislight missing")

--------------------------------------------------
-- RAW INSTANCE HELPERS
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

local function findRawLight(block)
    local rawPart = getRawPart(block)
    if not rawPart then
        return nil
    end

    for _, className in ipairs({"PointLight", "SpotLight", "SurfaceLight"}) do
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

local function playSound(block, position)
    if not block then
        return false
    end

    setSoundPowered(block, false)
    task.wait()
    setBlockValue(block, "TimePosition", position or 0)

    local ok = setSoundPowered(block, true)
    return ok
end

--------------------------------------------------
-- PART GROUPS
--------------------------------------------------

local shellParts = {}
local moveParts = {}
local fadeParts = {}
local relativeCFrames = {}

local function contains(list, part)
    for _, existing in ipairs(list) do
        if existing == part then
            return true
        end
    end
    return false
end

local function addPart(list, part)
    if not part or contains(list, part) then
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

-- Sound blocks move and fade with the shell.
addPart(moveParts, dematSound)
addPart(moveParts, matSound)
addPart(fadeParts, dematSound)
addPart(fadeParts, matSound)

-- Roof light moves with the shell; its transparency is controlled separately.
addPart(moveParts, tardisLight)

print("TARDIS shell blocks:", #shellParts)
print("TARDIS moving blocks:", #moveParts)

--------------------------------------------------
-- FORCE ANCHORED + COLLIDABLE ON START
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
print("TARDIS LOCKED: Anchored=true, CanCollide=true")

--------------------------------------------------
-- PIVOT / OFFSETS
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
-- FIND SHELL BOTTOM
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

--------------------------------------------------
-- MOVE WHOLE ASSEMBLY
--------------------------------------------------

local function moveTardis(pivot)
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
-- TRANSPARENCY
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
-- TOP LIGHT
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

local function setIdleLight(isHidden)
    if isHidden then
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

    return CFrame.new(
        root.Position.X,
        pivotY,
        root.Position.Z
    ) * defaultRotation
end

local hiddenPivot = CFrame.new(HIDDEN_POSITION) * defaultRotation

--------------------------------------------------
-- AUDIO HELPERS
--------------------------------------------------

local function getSoundLength(block)
    return tonumber(getBlockValue(block, "TimeLength")) or 0
end

local function getRawSound(block)
    if block == dematSound then
        return rawDematSound
    elseif block == matSound then
        return rawMatSound
    end
    return nil
end

local function readPlaybackLoudness(block)
    local raw = getRawSound(block)

    if raw then
        local ok, value = pcall(function()
            return raw.PlaybackLoudness
        end)
        if ok and type(value) == "number" then
            return value, true
        end
    end

    local value = tonumber(getBlockValue(block, "PlaybackLoudness"))
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

local function getAudioPulse(transition, soundTime)
    local loudness, hasReal = readPlaybackLoudness(transition.sound)

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

--------------------------------------------------
-- AUDIO -> VISUAL
--------------------------------------------------

local function applyAudioVisual(transition, progress, soundTime)
    progress = math.clamp(progress, 0, 1)

    local aggressive = progress ^ FADE_AGGRESSION
    local pulse = getAudioPulse(transition, soundTime)

    local transparency

    if transition.targetFade >= 1 then
        -- Dematerializing: peaks kick HARD toward invisible.
        transparency =
            aggressive
            + pulse * SHELL_WAVE_STRENGTH * (1 - aggressive)
    else
        -- Materializing: peaks kick HARD toward visible.
        local base = 1 - aggressive
        transparency =
            base
            - pulse * SHELL_WAVE_STRENGTH * base
    end

    transparency = math.clamp(transparency, 0, 1)
    setShellTransparency(transparency)

    local lampPulse = pulse ^ 0.12

    local brightness =
        LIGHT_MIN_BRIGHTNESS
        + (LIGHT_MAX_BRIGHTNESS - LIGHT_MIN_BRIGHTNESS) * lampPulse

    local lampTransparency = math.clamp(
        1 - lampPulse * 1.2,
        0,
        1
    )

    if pulse > 0.72 then
        brightness = LIGHT_MAX_BRIGHTNESS
        lampTransparency = 0
    end

    setTopLight(brightness, lampTransparency)
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
    setShellTransparency(0)
    setIdleLight(false)
else
    setShellTransparency(1)
    setIdleLight(true)
    moveTardis(hiddenPivot)
end

--------------------------------------------------
-- PREPARE MATERIALIZATION
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

    local seekPosition = 0
    if completedProgress > 0.01 then
        seekPosition =
            VISUAL_START_TIME
            + completedProgress * (visualEnd - VISUAL_START_TIME)
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
        visualComplete = false,

        -- IMPORTANT: missing/broken sound can NEVER make Input A a no-op.
        fallback = not soundStarted,
        fallbackStart = now,
        fallbackTailStart = nil,

        peak = LOUDNESS_PEAK_FLOOR,
        envelope = 0,
        previousEnvelope = 0,
    }

    if not soundStarted then
        print("TARDIS: sound unavailable; transition started immediately on fallback clock")
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
        setShellTransparency(1)
        setIdleLight(true)

        moveTardis(hiddenPivot)
        hidden = true

        if transition.kind == "auto_demat" and autoSequence then
            requestMaterialize("auto_materialize")
        end
    else
        currentFade = 0
        setShellTransparency(0)
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

    --------------------------------------------------
    -- SOUND-CLOCKED MODE
    --------------------------------------------------

    if not transition.fallback and transition.sound then
        local soundTime = tonumber(getBlockValue(transition.sound, "TimePosition"))
        local timeLength = getSoundLength(transition.sound)
        local isPlaying = getBlockValue(transition.sound, "IsPlaying") == true

        if soundTime then
            transition.maxSoundTime = math.max(
                transition.maxSoundTime,
                soundTime
            )

            if timeLength > VISUAL_START_TIME + SOUND_TAIL_TIME + 0.1 then
                transition.visualEnd = timeLength - SOUND_TAIL_TIME
            end

            if not transition.visualComplete
            and soundTime >= VISUAL_START_TIME then
                local progress = math.clamp(
                    (soundTime - VISUAL_START_TIME)
                    / math.max(0.05, transition.visualEnd - VISUAL_START_TIME),
                    0,
                    1
                )

                applyAudioVisual(transition, progress, soundTime)

                if transition.targetFade >= 1 then
                    currentFade = progress ^ FADE_AGGRESSION
                else
                    currentFade = 1 - (progress ^ FADE_AGGRESSION)
                end

                if progress >= 1 then
                    transition.visualComplete = true
                    currentFade = transition.targetFade
                    setShellTransparency(transition.targetFade)
                    setTopLight(0, 1)
                end
            end

            if transition.visualComplete then
                local finished = false

                if timeLength > 0
                and transition.maxSoundTime >= timeLength - 0.08 then
                    finished = true
                end

                if not isPlaying
                and transition.maxSoundTime > VISUAL_START_TIME then
                    finished = true
                end

                if finished then
                    finishTransition(transition)
                    return
                end
            end
        end

        -- If the sound never actually advances, switch over quickly.
        if now - transition.requestTime >= SOUND_START_TIMEOUT
        and transition.maxSoundTime <= 0.01 then
            transition.fallback = true
            transition.fallbackStart = now
            transition.peak = LOUDNESS_PEAK_FLOOR
            transition.envelope = 0
            transition.previousEnvelope = 0
            print("TARDIS: Sound TimePosition stalled; using fallback clock")
        end
    end

    --------------------------------------------------
    -- FALLBACK MODE
    --------------------------------------------------

    if transition.fallback then
        local elapsed = now - transition.fallbackStart

        if elapsed <= FALLBACK_FADE_TIME then
            local progress = math.clamp(
                elapsed / FALLBACK_FADE_TIME,
                0,
                1
            )

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
        and now - transition.fallbackTailStart >= FALLBACK_TAIL_TIME then
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
        currentFade = 1
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
--
-- INPUT A IS CHECKED FIRST AND IS ALWAYS AUTHORITATIVE.
-- A change cancels any J recall and immediately takes control.
--------------------------------------------------

while true do
    --------------------------------------------------
    -- MANUAL INPUT A FIRST
    --------------------------------------------------

    local newAState = inputA:GetState() == true
    local aChanged = newAState ~= lastInputState

    if aChanged then
        lastInputState = newAState

        if autoSequence then
            print("INPUT A: cancelling J recall / auto sequence")
        end

        autoSequence = false

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

    --------------------------------------------------
    -- J ONLY FIRES IF A DID NOT CHANGE THIS FRAME
    --------------------------------------------------

    local jState = inputJ:GetState() == true

    if not aChanged
    and jState
    and not lastJState
    and not autoSequence then
        startAutoRecall()
    end

    lastJState = jState

    --------------------------------------------------
    -- UPDATE EFFECT
    --------------------------------------------------

    updateTransition()
    task.wait(UPDATE_INTERVAL)
end
