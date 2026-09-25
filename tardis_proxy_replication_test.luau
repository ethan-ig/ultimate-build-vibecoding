-- TARDIS PROXY REPLICATION TEST | Ultimate Build FIU Code Block
-- Exact method used by our old replicated hovering chat cubes:
--   workspace.AdminCubeTemplate:Clone()
--   clone.attributes["Display name"] = ...
--   clone.CFrame = calculatedCFrame   (15 updates/second)
--
-- TEST ONLY. Does not touch the TARDIS, controller, or any existing cube.
-- Save first. Place one standalone, unwelded UB Display or Basic block,
-- set its Display name to AdminCubeTemplate, and wait for it to register.
-- Start this Code Block with a second client watching the same location.
-- Automatically runs ONCE after 10 seconds. Input A TRUE pulse can start
-- early. Output A: test phase (string); Output B: desired CFrame (optional).
--
-- Sequence: create probe near pilot, wait 6 sec, fly 30 studs up over
-- 3 sec, hold 10 sec, return over 3 sec, hold 5 sec, destroy CLONE.
-- A local accepted assignment is not proof of server replication.
-- The other client must actually see the clone and watch it move.

local TEMPLATE = "AdminCubeTemplate"
local HEIGHT = 30
local NETWORK_RATE = 15
local MOVE_TIME = 3
local START_DELAY = 10
local INITIAL_HOLD = 6
local TOP_HOLD = 10
local END_HOLD = 5
local interval = 1 / NETWORK_RATE

local inputA, outputA, outputB = nil, nil, nil
pcall(function() inputA = script.inputs["a"] end)
pcall(function() outputA = script.outputs["a"] end)
pcall(function() outputB = script.outputs["b"] end)

local Players = nil
pcall(function() Players = game:GetService("Players") end)
local player = nil
if Players then pcall(function() player = Players.LocalPlayer end) end

local started, lastInput, cloned = false, false, nil
local writeCount, writeErrors = 0, 0
local currentPhase = "READY"

local function log(phase, detail)
    currentPhase = phase
    print("TARDIS PROXY TEST:", phase, detail or "")
    if outputA then pcall(function() outputA:SetState(phase) end) end
end

local function setProperty(object, key, value)
    if not object then return false, "object missing" end
    local ok, err = pcall(function() object[key] = value end)
    return ok, err
end

local function setDisplayName(object, value)
    local ok = pcall(function() object.attributes["Display name"] = value end)
    if not ok then
        ok = pcall(function() object:SetAttribute("Display name", value) end)
    end
    return ok
end

local function readCF(object)
    local ok, cf = pcall(function() return object.CFrame end)
    if ok and typeof(cf) == "CFrame" then return cf end
    return nil
end

local function findTemplate()
    local candidate = nil
    pcall(function() candidate = workspace[TEMPLATE] end)
    return candidate
end

local function startPosition(template)
    local root = nil
    pcall(function()
        local character = player and player.Character
        if character then root = character:FindFirstChild("HumanoidRootPart") end
    end)
    if root then
        local ok, p = pcall(function() return root.Position end)
        if ok and typeof(p) == "Vector3" then
            return p + Vector3.new(8, 7, 0)
        end
    end
    local cf = readCF(template)
    if cf then return cf.Position + Vector3.new(8, 7, 0) end
    return nil
end

local function writeCF(cf)
    if not cloned then return false end
    -- IMPORTANT: use the UB clone proxy itself, not clone.Part.CFrame.
    local ok, err = setProperty(cloned, "CFrame", cf)
    if not ok then
        writeErrors = writeErrors + 1
        log("CFRAME WRITE FAILED", tostring(err))
        return false
    end
    writeCount = writeCount + 1
    if outputB then pcall(function() outputB:SetState(cf) end) end
    return true
end

local function motion(fromCF, toCF, duration, label)
    log(label, "moving via 15 Hz UB proxy CFrame writes")
    local startAt = os.clock()
    while true do
        local t = math.clamp((os.clock() - startAt) / duration, 0, 1)
        local eased = t * t * (3 - 2 * t)
        if not writeCF(fromCF:Lerp(toCF, eased)) then return false end
        if t >= 1 then break end
        task.wait(interval)
    end
    return true
end

local function report(label, expected)
    local cf = readCF(cloned)
    local errorDistance = cf and (cf.Position - expected.Position).Magnitude or -1
    print("TARDIS PROXY CHECK:", label,
        "proxy displacement from expected", errorDistance,
        "writes", writeCount, "errors", writeErrors,
        "proxy typeof", typeof(cloned))
end

local function run()
    if started then return end
    started = true

    local template = findTemplate()
    if not template then
        log("NO TEMPLATE", "Create standalone UB block with Display name AdminCubeTemplate; reload script")
        return
    end

    local pos = startPosition(template)
    if not pos then
        log("NO POSITION", "Player and template positions are unreadable")
        return
    end

    log("CLONING", "original AdminCubeTemplate is never modified")
    local ok, result = pcall(function() return template:Clone() end)
    if not ok or not result then
        log("CLONE FAILED", tostring(result))
        return
    end
    if result == template then
        log("UNSAFE CLONE", "Clone returned the original object")
        return
    end
    cloned = result

    local marker = "TardisProxyTest"
    if player then pcall(function() marker = marker .. "_" .. tostring(player.UserId) end) end
    local nameOK = setDisplayName(cloned, marker)
    print("TARDIS PROXY CLONE:", marker,
        "proxy typeof", typeof(cloned), "name write", tostring(nameOK))

    -- Configure ONLY the newly cloned probe, exactly like the old cubes.
    setProperty(cloned, "Size", Vector3.new(2, 2, 2))
    setProperty(cloned, "Anchored", true)
    setProperty(cloned, "CanCollide", false)
    setProperty(cloned, "Color", Color3.fromRGB(0, 255, 255))
    setProperty(cloned, "Transparency", 0)

    local atStart = CFrame.new(pos)
    local atTop = CFrame.new(pos + Vector3.new(0, HEIGHT, 0))
    if not writeCF(atStart) then return end
    log("PROBE CREATED", "look for CYAN 2x2 block near pilot; second client must see it")
    task.wait(INITIAL_HOLD)

    if not motion(atStart, atTop, MOVE_TIME, "GOING UP") then return end
    report("AT TOP", atTop)
    log("TOP HOLD", "second client should see cyan probe 30 studs above start")
    task.wait(TOP_HOLD)

    if not motion(atTop, atStart, MOVE_TIME, "COMING DOWN") then return end
    report("RETURNED", atStart)
    log("END HOLD", "second client should see probe back at start")
    task.wait(END_HOLD)

    local removed, removeErr = pcall(function() cloned:Destroy() end)
    log("COMPLETE", "writes " .. tostring(writeCount) ..
        ", errors " .. tostring(writeErrors) ..
        ", clone cleanup " .. tostring(removed))
    if not removed then
        print("TARDIS PROXY CLEANUP ERROR:", tostring(removeErr),
            "delete ONLY the cloned TardisProxyTest block manually")
    end
end

log("READY", "automatic test in 10 sec; second client watch cyan cube")
local loadedAt = os.clock()
while not started do
    if inputA then
        local state = false
        pcall(function() state = inputA:GetState() == true end)
        if state and not lastInput then
            run()
            break
        end
        lastInput = state
    end
    if os.clock() - loadedAt >= START_DELAY then
        run()
        break
    end
    task.wait(.10)
end
