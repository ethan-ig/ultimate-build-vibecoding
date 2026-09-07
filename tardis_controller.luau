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
-- IMPORTANT REPLICATION DESIGN
--
-- Ultimate Build Code runs locally, but writes through the UB metatable/proxy
-- are forwarded to the server. Raw .Part writes are LOCAL ONLY.
--
-- This controller therefore uses TWO visual paths:
--   1. Raw .Part writes at 60 Hz for smooth local animation.
--   2. Rate-limited UB proxy writes so the server + other clients see it.
--
-- This avoids flooding UB's property replication remote with
-- (part count * 60) transparency writes every second.

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

-- Local animation refresh.
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
-- NETWORK / SERVER REPLICATION
--------------------------------------------------

-- Leave lots of room below UB's property-remote limit for sound/light/input
-- traffic. This is a PROPERTY-WRITE budget, not frames per second.
local NETWORK_FADE_WRITE_BUDGET = 900
local NETWORK_FADE_MAX_HZ = 15
local NETWORK_FADE_MIN_HZ = 2

-- Movement is more important than fade fidelity. Send CFrames in controlled
-- batches, then do one guarded retry so a dropped packet cannot leave another
-- client looking at the old TARDIS location.
local NETWORK_MOVE_BATCH_SIZE = 25
local NETWORK_MOVE_BATCH_WAIT = 0.05
local NETWORK_MOVE_RETRY_DELAY = 0.45

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

    -- IMPORTANT: block[key], NOT block.Part[key].
    -- The UB proxy write is the path that replicates to the server.
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
-- RAW LOCAL INSTANCE HELPERS
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

local function setLocalProperty(block, property, value)
    local raw = getRawPart(block)
    if not raw then
        return false
    end

    local ok = pcall(function()
        raw[property] = value
    end)

    return ok
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

print(dematSound and "FOUND TardisDematSound" or "WARNING: TardisDematSound missing - fallback enabled")
print(matSound and "FOUND TardisMatSound" or "WARNING: TardisMatSound missing - fallback enabled")
print(tardisLight and "FOUND Tardislight" or "WARNING: Tardislight missing")

--------------------------------------------------
-- RAW SOUND / LIGHT INSTANCES
--------------------------------------------------

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
    return setSoundPowered(block, true)
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

-- SoundBlocks physically move + fade with shell.
addPart(moveParts, dematSound)
addPart(moveParts, matSound)
addPart(fadeParts, dematSound)
addPart(fadeParts, matSound)

-- Roof light moves with shell, but has its own audio-reactive transparency.
addPart(moveParts, tardisLight)

print("TARDIS shell blocks:", #shellParts)
print("TARDIS moving blocks:", #moveParts)
print("TARDIS fading blocks:", #fadeParts)

--------------------------------------------------
-- NETWORK FADE RATE
--------------------------------------------------

local fadePartCount = math.max(#fadeParts, 1)
local networkFadeHz = math.floor(NETWORK_FADE_WRITE_BUDGET / fadePartCount)
networkFadeHz = math.clamp(networkFadeHz, NETWORK_FADE_MIN_HZ, NETWORK_FADE_MAX_HZ)
local networkFadeInterval = 1 / networkFadeHz
local lastNetworkFadeAt = 0
local lastNetworkFadeValue = nil

print("TARDIS local fade: 60 Hz")
print("TARDIS server fade:", networkFadeHz, "Hz")

--------------------------------------------------
-- FORCE ANCHORED + COLLIDABLE
--------------------------------------------------

local function lockTardisAssemblyLocal()
    for _, part in ipairs(moveParts) do
        setLocalProperty(part, "Anchored", true)
        setLocalProperty(part, "CanCollide", true)
    end
end

local function lockTardisAssemblyServer()
    for index, part in ipairs(moveParts) do
        -- Proxy writes replicate to server.
        setBlockValue(part, "Anchored", true)
        setBlockValue(part, "CanCollide", true)

        if index % NETWORK_MOVE_BATCH_SIZE == 0 then
            task.wait(NETWORK_MOVE_BATCH_WAIT)
        end
    end
end

lockTardisAssemblyLocal()
task.spawn(lockTardisAssemblyServer)
print("TARDIS startup lock requested: Anchored=true, CanCollide=true")

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
-- REPLICATED MOVEMENT
--------------------------------------------------

local moveGeneration = 0

local function moveTardisLocal(pivot)
    -- Raw writes make the initiating client move instantly.
    for _, part in ipairs(moveParts) do
        local offset = relativeCFrames[part]

        if offset then
            setLocalProperty(part, "CFrame", pivot * offset)
        end
    end
end

local function replicatePivotPass(pivot, generation)
    for index, part in ipairs(moveParts) do
        if generation ~= moveGeneration then
            return
        end

        local offset = relativeCFrames[part]

        if offset then
            -- THIS is the important server-replicated path.
            setBlockValue(part, "CFrame", pivot * offset)
        end

        if index % NETWORK_MOVE_BATCH_SIZE == 0 then
            task.wait(NETWORK_MOVE_BATCH_WAIT)
        end
    end
end

local function moveTardis(pivot)
    moveGeneration = moveGeneration + 1
    local generation = moveGeneration

    lockTardisAssemblyLocal()
    moveTardisLocal(pivot)

    -- First server pass immediately, but asynchronously so visuals don't wait.
    task.spawn(function()
        replicatePivotPass(pivot, generation)
    end)

    -- Guarded second pass catches an occasional dropped/throttled property write.
    task.spawn(function()
        task.wait(NETWORK_MOVE_RETRY_DELAY)

        if generation == moveGeneration then
            replicatePivotPass(pivot, generation)
        end
    end)
end

--------------------------------------------------
-- REPLICATED TRANSPARENCY
--------------------------------------------------

local function setLocalFadeTransparency(value)
    value = math.clamp(value, 0, 1)

    for _, part in ipairs(fadeParts) do
        setLocalProperty(part, "Transparency", value)
    end
end

local function replicateFadeTransparency(value, force)
    value = math.clamp(value, 0, 1)

    local now = os.clock()

    if not force then
        if now - lastNetworkFadeAt < networkFadeInterval then
            return
        end

        if lastNetworkFadeValue ~= nil
        and math.abs(value - lastNetworkFadeValue) < 0.015 then
            return
        end
    end

    lastNetworkFadeAt = now
    lastNetworkFadeValue = value

    for _, part in ipairs(fadeParts) do
        -- Proxy write = server + other clients.
        setBlockValue(part, "Transparency", value)
    end
end

local function setShellTransparency(value, forceNetwork)
    value = math.clamp(value, 0, 1)

    -- Smooth on this client.
    setLocalFadeTransparency(value)

    -- Rate-limited replication for everyone else.
    replicateFadeTransparency(value, forceNetwork == true)
end

--------------------------------------------------
-- TOP LIGHT
--------------------------------------------------

local lightIdleBrightness =
    tonumber(getBlockValue(tardisLight, "Brightness"))
    or LIGHT_IDLE_BRIGHTNESS_DEFAULT

local lightIdleTransparency = 0

if tardisLight then
    local t = tonumber(getBlockValue(tardisLight, "Transparency"))
    if t then
        lightIdleTransparency = math.clamp(t, 0, 1)
    end
end

local lastLightNetworkAt = 0
local LIGHT_NETWORK_INTERVAL = 1 / 20

local function setTopLight(brightness, transparency, forceNetwork)
    if not tardisLight then
        return
    end

    brightness = math.max(0, brightness or 0)
    transparency = math.clamp(transparency or 0, 0, 1)

    -- Local glass + actual Light instance.
    setLocalProperty(tardisLight, "Transparency", transparency)

    if rawTopLight then
        pcall(function()
            rawTopLight.Brightness = brightness
            rawTopLight.Enabled = brightness > 0.01
        end)
    end

    -- Replicate the lamp at a modest rate. One part is cheap, but don't waste
    -- remote capacity while hundreds of shell pieces are also fading.
    local now = os.clock()
    if forceNetwork or now - lastLightNetworkAt >= LIGHT_NETWORK_INTERVAL then
        lastLightNetworkAt = now
        setBlockValue(tardisLight, "Transparency", transparency)
        setBlockValue(tardisLight, "Brightness", brightness)
    end
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
        transparency =
            aggressive
            + pulse * SHELL_WAVE_STRENGTH * (1 - aggressive)
    else
        local base = 1 - aggressive
        transparency =
            base
            - pulse * SHELL_WAVE_STRENGTH * base
    end

    transparency = math.clamp(transparency, 0, 1)
    setShellTransparency(transparency, false)

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

    setTopLight(brightness, lampTransparency, false)
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
-- PREPARE MATERIALIZATION
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

    -- currentFade follows the aggressive curve, so invert that curve when
    -- mapping a reversal back onto the sound playhead.
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
    local remainingProgress = 1 - linearCompleted

    activeTransition = {
        kind = kind,
        targetFade = targetFade,
        sound = sound,
        visualEnd = visualEnd,
        requestTime = now,
        maxSoundTime = seekPosition,
        visualComplete = false,

        fallback = not soundStarted,
        fallbackStart = now,
        fallbackStartLinearProgress = linearCompleted,
        fallbackDuration = math.max(0.05, FALLBACK_FADE_TIME * remainingProgress),
        fallbackTailStart = nil,

        peak = LOUDNESS_PEAK_FLOOR,
        envelope = 0,
        previousEnvelope = 0,
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

        -- Move only after the departure sound tail ends.
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
                    setShellTransparency(transition.targetFade, true)
                    setTopLight(0, 1, true)
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

        -- If TimePosition never advances, switch to fallback without hanging.
        if now - transition.requestTime >= SOUND_START_TIMEOUT
        and transition.maxSoundTime <= 0.01 then
            transition.fallback = true
            transition.fallbackStart = now
            transition.fallbackStartLinearProgress = 0
            transition.fallbackDuration = FALLBACK_FADE_TIME
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
        local localProgress = math.clamp(
            elapsed / transition.fallbackDuration,
            0,
            1
        )

        local progress =
            transition.fallbackStartLinearProgress
            + (1 - transition.fallbackStartLinearProgress) * localProgress

        if localProgress < 1 then
            applyAudioVisual(transition, progress, elapsed)

            if transition.targetFade >= 1 then
                currentFade = progress ^ FADE_AGGRESSION
            else
                currentFade = 1 - (progress ^ FADE_AGGRESSION)
            end

        elseif not transition.visualComplete then
            transition.visualComplete = true
            currentFade = transition.targetFade
            setShellTransparency(transition.targetFade, true)
            setTopLight(0, 1, true)
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
-- J is a rising-edge one-shot. While J recall is running, A is deliberately
-- ignored so the normal state input cannot immediately cancel the sequence.
-- Outside J recall, A works normally.
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
    task.wait(UPDATE_INTERVAL)
end
