-- TARDIS TWEEN REPLICATION TEST | separate Ultimate Build code block
-- DO NOT run this alongside the active flight code block.
-- Save the build first. Controller should be materialized and idle.
--
-- Two separate trials:
--   RAW TWEEN: Roblox TweenService on the underlying physical BasePart.
--   FIU TWEEN: Roblox TweenService on Ultimate Build's wrapped block.
-- Each requests 30 studs of WORLD vertical travel over 3 seconds, waits
-- one second, then tweens back. Compare from a second Roblox client.
--
-- This intentionally does not unanchor, weld, alter mass, or claim that
-- TweenService replicates. A native Ultimate Build Tween Block could have
-- different replication behavior and requires its actual port contract.
--
-- Input A (optional): pulse TRUE to run RAW trial, if GUI unavailable.
-- Output A (optional): latest desired CFrame, for diagnosis only.

local lift = 30
local seconds = 3
local hold = 1
local inputA, outputA = nil, nil
pcall(function() inputA = script.inputs["a"] end)
pcall(function() outputA = script.outputs["a"] end)

local TweenService, Players = nil, nil
pcall(function() TweenService = game:GetService("TweenService") end)
pcall(function() Players = game:GetService("Players") end)
local player = nil
if Players then pcall(function() player = Players.LocalPlayer end) end

local gui, statusLabel = nil, nil
local rawRoot, wrapper = nil, nil
local running, lastA = false, false
local lastRootLookup = 0

local function announce(message)
    print("TARDIS TWEEN TEST:", tostring(message))
    if statusLabel then
        pcall(function() statusLabel.Text = tostring(message) end)
    end
end

local function rawOf(obj)
    if not obj then return nil end
    local raw = nil
    pcall(function() raw = obj.Part end)
    raw = raw or obj
    local ok, isPart = pcall(function() return raw:IsA("BasePart") end)
    return ok and isPart and raw or nil
end

local function attribute(obj, name)
    if not obj then return nil end
    local ok, value = pcall(function() return obj:GetAttribute(name) end)
    if ok then return value end
    return nil
end

local function findRig()
    local selected, wrapped = nil, nil
    local found = workspace:GetDescendants()
    for _, obj in ipairs(found) do
        local raw = rawOf(obj)
        if raw and attribute(raw, "TardisRigRoot") == true then
            selected = raw
            if obj ~= raw then
                local ok, cf = pcall(function() return obj.CFrame end)
                if ok and typeof(cf) == "CFrame" then
                    wrapped = obj
                    break
                end
            end
        end
    end
    return selected, wrapped
end

local function readCF(obj)
    local ok, cf = pcall(function() return obj.CFrame end)
    if ok and typeof(cf) == "CFrame" then return cf end
    return nil
end

local function printPosition(label, startCF)
    local actual = readCF(rawRoot)
    local external = wrapper and readCF(wrapper) or nil
    local rawDist = actual and (actual.Position - startCF.Position).Magnitude or -1
    local wrapperDist = external and (external.Position - startCF.Position).Magnitude or -1
    print("TARDIS TWEEN:", label,
        "RAW displacement", rawDist,
        "WRAPPER displacement", wrapperDist)
end

local function runTrial(mode)
    if running then announce("TEST ALREADY RUNNING"); return end
    if not TweenService then announce("TweenService unavailable"); return end
    rawRoot, wrapper = findRig()
    if not rawRoot then announce("CONTROLLER RIG ROOT NOT FOUND"); return end
    if attribute(rawRoot, "TardisRigReady") ~= true
        or attribute(rawRoot, "TardisTransitioning") == true then
        announce("MATERIALIZE FIRST; CONTROLLER RIG MUST BE READY")
        return
    end
    local targetObject = mode == "FIU" and wrapper or rawRoot
    if not targetObject then
        announce("NO FIU WRAPPER: native TweenService cannot test it")
        return
    end
    local startCF = readCF(targetObject)
    if not startCF then announce("CFRAME UNREADABLE ON " .. mode); return end
    local goalCF = CFrame.new(0, lift, 0) * startCF
    local startMass = nil
    pcall(function() startMass = rawRoot.AssemblyMass end)
    print("TARDIS TWEEN START:", mode,
        "target typeof", typeof(targetObject),
        "mass", tostring(startMass),
        "height delta", lift)
    if outputA then pcall(function() outputA:SetState(goalCF) end) end

    local infoOK, info = pcall(function()
        return TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
    end)
    if not infoOK then
        announce("TweenInfo FAILED: " .. tostring(info))
        return
    end
    local createOK, tween = pcall(function()
        return TweenService:Create(targetObject, info, {CFrame = goalCF})
    end)
    if not createOK or not tween then
        announce(mode .. " CREATE FAILED; check output")
        print("TARDIS TWEEN CREATE ERROR:", tostring(tween))
        return
    end

    running = true
    announce(mode .. " TWEEN: 30 STUDS UP. WATCH SECOND CLIENT")
    local playOK, playError = pcall(function() tween:Play() end)
    if not playOK then
        announce(mode .. " PLAY FAILED: " .. tostring(playError))
        running = false
        return
    end

    task.wait(seconds + 0.15)
    printPosition(mode .. " AT TOP", startCF)
    task.wait(hold)

    announce(mode .. " TWEEN: RETURNING")
    local backOK, backTween = pcall(function()
        return TweenService:Create(targetObject, info, {CFrame = startCF})
    end)
    if backOK and backTween then
        local returnOK, returnErr = pcall(function() backTween:Play() end)
        if not returnOK then
            print("TARDIS TWEEN RETURN PLAY ERROR:", tostring(returnErr))
        else
            task.wait(seconds + 0.15)
        end
    else
        print("TARDIS TWEEN RETURN CREATE ERROR:", tostring(backTween))
        -- Best effort restore, only to the exact original CFrame.
        pcall(function() targetObject.CFrame = startCF end)
    end
    printPosition(mode .. " RETURNED", startCF)
    running = false
    announce(mode .. " TEST ENDED. DID SECOND CLIENT SEE THE ENTIRE BOX?")
end

local function tryGui()
    if gui or not player then return end
    local ok, err = pcall(function()
        local pg = player:FindFirstChildOfClass("PlayerGui")
            or player:FindFirstChild("PlayerGui")
        if not pg then return end
        local old = pg:FindFirstChild("TardisTweenReplicationTest")
        if old then old:Destroy() end
        local screen = Instance.new("ScreenGui")
        screen.Name = "TardisTweenReplicationTest"
        screen.ResetOnSpawn = false
        screen.DisplayOrder = 975
        screen.Parent = pg
        gui = screen
        local panel = Instance.new("Frame")
        panel.Size = UDim2.new(0, 310, 0, 135)
        panel.Position = UDim2.new(0, 22, 0, 36)
        panel.BackgroundColor3 = Color3.fromRGB(14, 27, 42)
        panel.BorderSizePixel = 0
        panel.Parent = screen

        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Position = UDim2.new(0, 10, 0, 6)
        label.Size = UDim2.new(1, -20, 0, 25)
        label.Text = "TARDIS TWEEN REPLICATION TEST"
        label.TextColor3 = Color3.fromRGB(141, 228, 255)
        label.TextSize = 15
        label.Font = Enum.Font.GothamBold
        label.Parent = panel
        local function addButton(text, x, mode)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(0, 140, 0, 30)
            b.Position = UDim2.new(0, x, 0, 40)
            b.Text = text
            b.TextSize = 14
            b.BackgroundColor3 = Color3.fromRGB(36, 80, 106)
            b.TextColor3 = Color3.fromRGB(255, 255, 255)
            b.Parent = panel
            local function click()
                if not running then
                    task.spawn(function() runTrial(mode) end)
                end
            end
            local evtOK = pcall(function() b.Activated:Connect(click) end)
            if not evtOK then b.MouseButton1Click:Connect(click) end
        end
        addButton("TEST RAW", 10, "RAW")
        addButton("TEST FIU", 160, "FIU")
        local message = Instance.new("TextLabel")
        message.BackgroundTransparency = 1
        message.Position = UDim2.new(0, 10, 0, 76)
        message.Size = UDim2.new(1, -20, 0, 50)
        message.Text = "Ready. Save build; stop flight before test."
        message.TextWrapped = true
        message.TextColor3 = Color3.fromRGB(204, 241, 219)
        message.TextSize = 12
        message.Parent = panel
        statusLabel = message
    end)
    if not ok then
        print("TARDIS TWEEN GUI ERROR:", tostring(err))
        if gui then pcall(function() gui:Destroy() end) end
        gui, statusLabel = nil, nil
    end
end

tryGui()
print("TARDIS TWEEN TEST READY; RAW and FIU are separate trials")
while true do
    if not gui then tryGui() end
    local a = false
    if inputA then pcall(function() a = inputA:GetState() == true end) end
    if a and not lastA and not running then
        task.spawn(function() runTrial("RAW") end)
    end
    lastA = a
    task.wait(0.10)
end
