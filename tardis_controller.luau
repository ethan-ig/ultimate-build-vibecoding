-- TARDIS CONTROLLER 2.0 | Ultimate Build FIU | navigation-first
-- This script is NOT a manual flight system. No raw root flight, no new welds.
--
-- INPUTS
-- A (optional boolean level): true=materialize, false=dematerialize; changes only.
-- B (optional string): player-name destination for manual show/fallback travel.
-- C (required Vector3/CFrame or "X,Y,Z"): world destination from navigation.
-- D (optional boolean level): fast sound/effects for subsequent commands.
-- E (optional boolean PULSE): quick recall to your character.
-- F (optional boolean PULSE): travel to C (fallback B).
-- J (optional boolean PULSE): normal recall to your character.
-- OUTPUTS (all optional): A=status string, B=transition busy, C=exterior pivot.
--
-- FIU only: editable UB proxy CFrame updates move an independently anchored
-- exterior. No client-created weld is trusted for server replication.
-- Restore a healthy saved build if a previous experiment scattered its shell.

local VERSION = "CONTROLLER 2.0"
local SHELL = "tardis"
local SOUND_OUT = "tardismatsound"
local SOUND_IN = "interiortardismatsound"
local LIGHT = "tardislight"
local PORTAL = "tardisportal"
local ROTOR = "timerotor"
local HIDDEN = Vector3.new(-2000, 1, 2772)
local SHELL_RADIUS_LIMIT = 75
local MIN_SHELL = 10
local CLEARANCE = .12
local FADE_HZ, ROTOR_HZ, LOOP = 12, 20, 1/30
local NORMAL_SECONDS, QUICK_SECONDS = 11.0, 1.35
local SOUND_TAIL, MIN_SOUND_LENGTH = 2.2, 1.6
local SOUND = {
    show = {id="142277519", pitch=1},
    showFast = {id="140477091", pitch=.735},
    hide = {id="135858826", pitch=.633},
    hideFast = {id="135858448", pitch=1},
    endFast = {id="134966578", pitch=1},
}

local function port(tableName, letter)
    local p = nil
    pcall(function() p = script[tableName][letter] end)
    return p
end
local input = {}
local output = {}
for _, letter in ipairs({"a","b","c","d","e","f","j"}) do
    input[letter] = port("inputs",letter)
end
for _, letter in ipairs({"a","b","c"}) do
    output[letter] = port("outputs",letter)
end
local function emit(letter, value)
    local p = output[letter]
    if p then pcall(function() p:SetState(value) end) end
end
local function state(letter)
    local p = input[letter]
    if not p then return nil, false end
    local ok, value = pcall(function() return p:GetState() end)
    return value, ok
end
local function prop(object, key)
    if not object then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok and value ~= nil then return value end
    ok, value = pcall(function() return object:GetAttribute(key) end)
    if ok and value ~= nil then return value end
    ok, value = pcall(function() return object.attributes[key] end)
    return ok and value or nil
end
local function put(object, key, value)
    if not object then return false end
    local ok = pcall(function() object[key] = value end)
    if ok then return true end
    ok = pcall(function() object:SetAttribute(key, value) end)
    if ok then return true end
    ok = pcall(function() object.attributes[key] = value end)
    return ok
end
local function raw(block)
    local value = nil
    if block then pcall(function() value = block.Part end) end
    if value then return value end
    if typeof(block) == "Instance" then return block end
    return nil
end
local function label(block)
    local name = prop(block, "DisplayName") or prop(block, "Display name")
    return type(name) == "string" and string.lower(name) or nil
end
local function readCF(block)
    local ok, cf = pcall(function() return block.CFrame end)
    return ok and typeof(cf) == "CFrame" and cf or nil
end
local function showMessage(message)
    print("TARDIS:", message)
    emit("a", message)
end
local rootRaw = nil
local function rootFlag(name, value)
    if rootRaw then pcall(function() rootRaw:SetAttribute(name,value) end) end
end

-- One inventory scan. Keep an identity set to avoid duplicate wrapper/raw
-- entries. The controller only moves its own explicitly named exterior.
local shell, moving, faded, originalAlpha, offsets = {}, {}, {}, {}, {}
local rawMoving, rawSet, named, rotor = {}, {}, {}, {}
local exteriorSound, interiorSound, roofLight, portal = nil,nil,nil,nil
local all = workspace:GetDescendants()
local function add(list, block)
    if not block or table.find(list,block) then return end
    if readCF(block) then table.insert(list,block) end
end
for _, block in ipairs(all) do
    if block ~= script then
        local name = label(block)
        if name then
            if not named[name] then named[name] = {} end
            table.insert(named[name],block)
        end
    end
end
local function firstNamed(name)
    local list = named[name]
    if not list then return nil end
    -- Prefer the editable Ultimate Build proxy over its underlying BasePart.
    for _, item in ipairs(list) do
        local r=raw(item)
        if r and r~=item and readCF(item) then return item end
    end
    for _, item in ipairs(list) do
        if readCF(item) then return item end
    end
    return list[1]
end
-- Portal and time rotor are sometimes named on their raw Roblox Part rather
-- than through the Ultimate Build DisplayName field.
local function flexibleNamed(wanted)
    local direct=firstNamed(wanted)
    if direct then return direct end
    local proxy,rawMatch=nil,nil
    for _,block in ipairs(all) do
        local r=raw(block)
        local own=prop(block,"Name")
        local underlying=r and prop(r,"Name")
        if (type(own)=="string" and own:lower()==wanted)
            or (type(underlying)=="string" and underlying:lower()==wanted) then
            if r and r~=block and readCF(block) then proxy=block;break end
            if not rawMatch and readCF(block) then rawMatch=block end
        end
    end
    return proxy or rawMatch
end
exteriorSound, interiorSound = flexibleNamed(SOUND_OUT), flexibleNamed(SOUND_IN)
roofLight, portal = flexibleNamed(LIGHT), flexibleNamed(PORTAL)
local seenShell={}
for pass=1,2 do
    for _,block in ipairs(named[SHELL] or {}) do
        local r=raw(block) or block
        local isProxy=r~=block
        if ((pass==1 and isProxy) or (pass==2 and not isProxy))
            and not seenShell[r] and readCF(block) then
            seenShell[r]=true
            add(shell,block)
        end
    end
end
for _, block in ipairs(shell) do add(moving,block); add(faded,block) end
add(moving,exteriorSound)
add(moving,roofLight)
add(moving,portal)
if exteriorSound then add(faded,exteriorSound) end
local rotorSeen={}
for pass=1,2 do
    for _,block in ipairs(all) do
        local r=raw(block) or block
        local own=prop(block,"Name")
        local underlying=prop(r,"Name")
        local matches=label(block)==ROTOR
            or (type(own)=="string" and own:lower()==ROTOR)
            or (type(underlying)=="string" and underlying:lower()==ROTOR)
        local isProxy=r~=block
        if matches and not rotorSeen[r]
            and ((pass==1 and isProxy) or (pass==2 and not isProxy))
            and readCF(block) then
            rotorSeen[r]=true
            add(rotor,block)
        end
    end
end

local originalPivot = shell[1] and readCF(shell[1]) or nil
local lastVisiblePivot = originalPivot
local defaultRotation = originalPivot and (originalPivot-originalPivot.Position) or CFrame.identity
local lowestBottom = math.huge
local lightAlpha = tonumber(prop(roofLight,"Transparency")) or 0
local lightBrightness = tonumber(prop(roofLight,"Brightness")) or 2
local eligible, failure = originalPivot ~= nil and #shell >= MIN_SHELL, nil
if not eligible then failure="shell not found or incomplete" end
for _, block in ipairs(moving) do
    local cf = readCF(block)
    if cf and originalPivot then
        offsets[block] = originalPivot:ToObjectSpace(cf)
        originalAlpha[block] = math.clamp(tonumber(prop(block,"Transparency")) or 0,0,1)
        if label(block) == SHELL and offsets[block].Position.Magnitude > SHELL_RADIUS_LIMIT then
            eligible, failure = false, "scattered shell; restore a saved build"
        end
        local r = raw(block)
        if r and not rawSet[r] then
            rawSet[r]=true
            table.insert(rawMoving,r)
        end
    else
        eligible, failure = false, "unreadable exterior CFrame"
    end
end
for _, block in ipairs(shell) do
    local cf, size = readCF(block), prop(block,"Size")
    if cf and typeof(size)=="Vector3" then
        local half = math.abs(cf.RightVector.Y)*size.X/2
            + math.abs(cf.UpVector.Y)*size.Y/2
            + math.abs(cf.LookVector.Y)*size.Z/2
        lowestBottom=math.min(lowestBottom,cf.Position.Y-half)
    end
end
local bottomOffset = lowestBottom < math.huge and lowestBottom-originalPivot.Position.Y or -7
local rootBlock = shell[1]
rootRaw = shell[1] and raw(shell[1]) or nil
if not rootRaw then
    eligible, failure=false, "root physical BasePart unavailable"
end
local rotorBase = {}
for _, block in ipairs(rotor) do rotorBase[block]=readCF(block) end

-- Refuse to detach old welds if ANY backing exterior part is not anchored.
-- Only our own old named joints may be removed. Map geometry stays untouched.
if eligible then
    local problems=0
    for i, block in ipairs(moving) do
        local ok, err=pcall(function() block.Anchored=true end)
        if not ok then
            problems=problems+1
            if problems <= 3 then print("TARDIS ANCHOR:",i,tostring(err)) end
        end
        if i%24==0 then task.wait(.02) end
    end
    task.wait(.40)
    for _, block in ipairs(moving) do
        local r=raw(block)
        local ok1,a=pcall(function() return block.Anchored end)
        local ok2,b=pcall(function() return r.Anchored end)
        if not ok1 or a~=true or not ok2 or b~=true then problems=problems+1 end
    end
    if problems>0 then eligible=false; failure=tostring(problems).." exterior anchors unconfirmed" end
end
if eligible and rootRaw then
    local childrenOK,children=pcall(function() return rootRaw:GetChildren() end)
    if childrenOK and type(children)=="table" then
        for _, joint in ipairs(children) do
            local name,kind=nil,nil
            pcall(function() name,kind=joint.Name,joint.ClassName end)
            if type(name)=="string" and name:sub(1,16)=="TardisRigidWeld_"
                and kind=="WeldConstraint" then
                local ok,err=pcall(function() joint:Destroy() end)
                if not ok then eligible=false; failure="old weld: "..tostring(err) end
            end
        end
    else
        eligible=false; failure="cannot inspect old flight joints"
    end
end
-- A build placed directly on a floor may have automatic joints to Map.Base.
-- After all exterior parts are independently anchored, detach ONLY rigid
-- joints crossing from a registered exterior part to an unrelated part.
-- Never destroy or unanchor the unrelated map geometry.
if eligible then
    local seenJoints,removedExternal={},0
    local rigid={Weld=true,WeldConstraint=true,ManualWeld=true,
        Snap=true,Motor=true,Motor6D=true}
    for _,member in ipairs(rawMoving) do
        local ok,joints=pcall(function() return member:GetJoints() end)
        if not ok or type(joints)~="table" then
            eligible,failure=false,"external joint scan unavailable"
            break
        end
        for _,joint in ipairs(joints) do
            if joint and not seenJoints[joint] then
                seenJoints[joint]=true
                local a,b,kind=nil,nil,nil
                pcall(function() a,b,kind=joint.Part0,joint.Part1,joint.ClassName end)
                if rigid[kind] and a and b and (rawSet[a]==true)~=(rawSet[b]==true) then
                    local removed,err=pcall(function() joint:Destroy() end)
                    if removed then
                        removedExternal=removedExternal+1
                    else
                        eligible,failure=false,"cross-boundary joint: "..tostring(err)
                    end
                end
            end
        end
        if not eligible then break end
    end
    print("TARDIS JOINT ISOLATION:",removedExternal,"map/exterior crossings removed")
end
if eligible then
    local ok,connected=pcall(function()
        return rootRaw:GetConnectedParts(true)
    end)
    if not ok or type(connected)~="table" then
        eligible,failure=false,"cannot verify exterior assembly isolation"
    else
        for _,other in ipairs(connected) do
            if not rawSet[other] then
                eligible,failure=false,"exterior still linked to map or unrelated part"
                break
            end
        end
    end
end

if rootRaw then
    pcall(function()
        rootRaw:SetAttribute("TardisRigRoot",true)
        rootRaw:SetAttribute("TardisRigMode","NAV_V2")
        rootRaw:SetAttribute("TardisRigReady",eligible)
        rootRaw:SetAttribute("TardisRigError",failure or "")
        rootRaw:SetAttribute("TardisTransitioning",false)
        rootRaw:SetAttribute("TardisFlightActive",false)
        rootRaw:SetAttribute("TardisPilotGroundOffset",-bottomOffset + .8)
    end)
end
showMessage("CONTROLLER 2.0 / "..#shell.." SHELL / "
    ..#moving.." MOVING / "..(eligible and "READY" or tostring(failure)))
if not eligible then
    -- Do not continue with a controller that could destroy an incomplete build.
    return
end

local hiddenPivot = CFrame.new(HIDDEN)*defaultRotation
local phase = (originalPivot.Position-HIDDEN).Magnitude < 95 and "HIDDEN" or "SOLID"
local currentFade = phase=="HIDDEN" and 1 or 0
local pendingDestination, queued, transition = nil,nil,nil
local rotorTime,lastRotor,lastFade = 0,0,0
local activeSound, soundStarted, quickStingUntil = nil,0,0
local busy = false
local latestDestination = nil
local inputHistory = {}
local function setBusy(flag)
    busy=flag
    rootFlag("TardisTransitioning",flag)
    emit("b",flag)
end
local function setFade(fade,wave)
    fade=math.clamp(fade,0,1)
    for _,block in ipairs(faded) do
        local original=originalAlpha[block] or 0
        local visual=math.clamp(fade + wave*(1-fade)*.15,0,1)
        put(block,"Transparency",original+(1-original)*visual)
    end
    if roofLight then
        local visibility=1-fade
        local pulse=.2+.8*wave
        put(roofLight,"Transparency",math.clamp(
            1-visibility*pulse*(1-lightAlpha),0,1))
        put(roofLight,"Brightness",math.max(0,
            lightBrightness*visibility*(.15+3.3*wave)))
    end
    if portal then put(portal,"Transparency",1) end
end
local function setFinalFade(fade)
    currentFade=fade
    for _,block in ipairs(faded) do
        local original=originalAlpha[block] or 0
        put(block,"Transparency",original+(1-original)*fade)
    end
    if roofLight then
        put(roofLight,"Transparency",fade>=1 and 1 or lightAlpha)
        put(roofLight,"Brightness",fade>=1 and 0 or lightBrightness)
    end
    if portal then put(portal,"Transparency",1) end
end
setFinalFade(currentFade)

local function soundInput(block)
    if not block then return nil end
    for _,key in ipairs({"Input","input","Toggle","toggle","a","A"}) do
        local ok,value=pcall(function() return block.inputs[key] end)
        if ok and value then return value end
    end
    return nil
end
local function powerSound(block,on)
    if not block then return false end
    local p=soundInput(block)
    if p then
        if pcall(function() p:Fire(on,true) end) then return true end
        if pcall(function() p:SetState(on) end) then return true end
    end
    for _,key in ipairs({"Input","input","Toggle","a"}) do
        if pcall(function() block:FireInput(key,on) end) then return true end
    end
    return false
end
local function actualSound(block)
    local r=raw(block)
    if not r then return nil end
    local sound=nil
    pcall(function() sound=r:FindFirstChildWhichIsA("Sound",true) end)
    return sound
end
local realOuter,realInner=actualSound(exteriorSound),actualSound(interiorSound)
for _,block in pairs({exteriorSound,interiorSound}) do
    if block then
        put(block,"Repeat",false)
        put(block,"ResetTimePosition",false)
        put(block,"Volume",1)
        put(block,"Effects",false)
    end
end
local function stopAudio()
    for _,b in pairs({exteriorSound,interiorSound}) do
        if b then powerSound(b,false) end
    end
    activeSound=nil
end
local function startAudio(key)
    local profile=SOUND[key]
    if not profile then return end
    stopAudio()
    for _,pair in ipairs({{exteriorSound,realOuter},{interiorSound,realInner}}) do
        local block,instance=pair[1],pair[2]
        if block then
            put(block,"SoundId","rbxassetid://"..profile.id)
            put(block,"Pitch",profile.pitch)
            put(block,"TimePosition",0)
        end
        if instance then
            pcall(function()
                instance.SoundId="rbxassetid://"..profile.id
                instance.PlaybackSpeed=profile.pitch
                instance.TimePosition=0
            end)
        end
    end
    task.wait()
    powerSound(exteriorSound,true)
    powerSound(interiorSound,true)
    activeSound=key
    soundStarted=os.clock()
end
local function audioClock()
    for _,sound in pairs({realOuter,exteriorSound}) do
        if sound then
            local t=tonumber(prop(sound,"TimePosition"))
            local length=tonumber(prop(sound,"TimeLength"))
            if t and length and length>MIN_SOUND_LENGTH and t>0 then
                return t,length
            end
        end
    end
    return nil,nil
end
local function wave(time)
    local loudness=tonumber(prop(realOuter,"PlaybackLoudness"))
        or tonumber(prop(exteriorSound,"PlaybackLoudness"))
    if loudness and loudness>0 then
        return math.clamp(math.sqrt(loudness/250),0,1)
    end
    return .55+.27*math.sin(time*17)+.18*math.sin(time*30+1.2)
end

local function move(pivot)
    -- One immutable pivot, no root-only writes. This runs only while hidden.
    if not pivot then return false end
    local old=readCF(rootBlock)
    local count=0
    for i,block in ipairs(moving) do
        local offset=offsets[block]
        if offset then
            local ok=pcall(function() block.CFrame=pivot*offset end)
            if ok then count=count+1 end
        end
        if i%24==0 then task.wait() end
    end
    if count~=#moving then
        -- Best-effort rollback of a partial teleport, keeping the last
        -- known exterior intact instead of announcing successful travel.
        if old then
            for i,block in ipairs(moving) do
                local offset=offsets[block]
                if offset then pcall(function() block.CFrame=old*offset end) end
                if i%24==0 then task.wait() end
            end
        end
        showMessage("MOVE FAILED: "..count.."/"..#moving.." PROXIES / ROLLBACK")
        return false
    end
    emit("c",pivot)
    if portal then put(portal,"Transparency",1) end
    return true
end

-- Raycast terrain/unions when available. Geometry-box fallback handles FIU
-- wrappers without functional RaycastParams. Never land on our own shell.
local function slab(o,d,low,high,t0,t1)
    if math.abs(d)<1e-7 then
        return t0,t1,o>=low and o<=high
    end
    local a,b=(low-o)/d,(high-o)/d
    if a>b then a,b=b,a end
    t0,t1=math.max(t0,a),math.min(t1,b)
    return t0,t1,t0<=t1
end
local function hitBox(block,x,z,ceiling)
    local part=raw(block) or block
    if rawSet[part] or part==script then return nil end
    if prop(block,"CanCollide")==false or prop(part,"CanCollide")==false then return nil end
    local cf=readCF(block) or readCF(part)
    local size=prop(block,"Size") or prop(part,"Size")
    if not cf or typeof(size)~="Vector3" then return nil end
    local origin=cf:PointToObjectSpace(Vector3.new(x,ceiling+2,z))
    local direction=cf:VectorToObjectSpace(Vector3.new(0,-20000,0))
    local lo,hi,ok=0,1,true
    lo,hi,ok=slab(origin.X,direction.X,-size.X/2,size.X/2,lo,hi)
    if not ok then return nil end
    lo,hi,ok=slab(origin.Y,direction.Y,-size.Y/2,size.Y/2,lo,hi)
    if not ok then return nil end
    lo,hi,ok=slab(origin.Z,direction.Z,-size.Z/2,size.Z/2,lo,hi)
    if not ok or lo<0 or lo>1 then return nil end
    local y=ceiling+2-20000*lo
    return y<=ceiling+.4 and y or nil
end
local function groundAt(x,z,ceiling)
    local params=nil
    pcall(function()
        params=RaycastParams.new()
        params.FilterType=Enum.RaycastFilterType.Exclude
        local exclude={}
        for _,r in ipairs(rawMoving) do
            if typeof(r)=="Instance" then table.insert(exclude,r) end
        end
        local Players=game:GetService("Players")
        for _,p in ipairs(Players:GetPlayers()) do
            if p.Character then table.insert(exclude,p.Character) end
        end
        params.FilterDescendantsInstances=exclude
        pcall(function() params.RespectCanCollide=true end)
    end)
    if params then
        local ok,hit=pcall(function()
            return workspace:Raycast(
                Vector3.new(x,ceiling+2,z),Vector3.new(0,-20000,0),params)
        end)
        if ok and hit then
            local pos=prop(hit,"Position")
            if typeof(pos)=="Vector3" then return pos.Y end
        end
    end
    local best=nil
    for _,block in ipairs(all) do
        local name=label(block)
        if name~=SHELL and name~=SOUND_OUT and name~=LIGHT and name~=PORTAL then
            local y=hitBox(block,x,z,ceiling)
            if y and (not best or y>best) then best=y end
        end
    end
    return best
end
local function validPos(value)
    return typeof(value)=="Vector3" and value.X==value.X
        and value.Y==value.Y and value.Z==value.Z
        and math.max(math.abs(value.X),math.abs(value.Y),math.abs(value.Z))<1e7
end
local function parseDestination(value)
    local kind=typeof(value)
    if kind=="CFrame" then return value end
    if kind=="Vector3" and validPos(value) then
        return CFrame.new(value)*defaultRotation
    end
    if type(value)=="string" then
        local fields={}
        for field in string.gmatch(value,"[^,%s]+") do
            table.insert(fields,tonumber(field))
        end
        if #fields==3 and fields[1] and fields[2] and fields[3] then
            local pos=Vector3.new(fields[1],fields[2],fields[3])
            if validPos(pos) then return CFrame.new(pos)*defaultRotation end
        end
    end
    return nil
end
local function groundPivot(cf,hintIsNav)
    if not cf then return nil end
    local p=cf.Position
    local ceiling=p.Y+(hintIsNav and 8 or 3)
    local y=groundAt(p.X,p.Z,ceiling)
    if not y then return nil end
    return CFrame.new(p.X,y-bottomOffset+CLEARANCE,p.Z)*(cf-p)
end
local function playerRoot(query)
    local players=nil
    pcall(function() players=game:GetService("Players") end)
    if not players then return nil end
    if not query or query=="" then
        local localPlayer=nil
        pcall(function() localPlayer=players.LocalPlayer end)
        local c=localPlayer and localPlayer.Character
        return c and c:FindFirstChild("HumanoidRootPart") or nil
    end
    local match=nil
    local wanted=string.lower(query)
    for _,p in ipairs(players:GetPlayers()) do
        local name=string.lower(p.Name)
        local display=string.lower(p.DisplayName)
        if name==wanted or display==wanted then match=p; break end
        if not match and (name:sub(1,#wanted)==wanted
            or display:sub(1,#wanted)==wanted) then match=p end
    end
    local c=match and match.Character
    return c and c:FindFirstChild("HumanoidRootPart") or nil
end
local function toPlayer(query)
    local r=playerRoot(query)
    if not r then return nil end
    local p=r.Position
    local y=groundAt(p.X,p.Z,p.Y+2) or p.Y-3
    return CFrame.new(p.X,y-bottomOffset+CLEARANCE,p.Z)*defaultRotation
end
local function coordinateTarget()
    local value,ok=state("c")
    local parsed=ok and parseDestination(value) or nil
    if not parsed then return nil end
    return groundPivot(parsed,true)
end
local function destinationFromInputs()
    local playerName, readable = state("b")
    local targetPlayer = readable and type(playerName)=="string" and playerName or nil
    return coordinateTarget() or (
        targetPlayer and targetPlayer~="" and toPlayer(targetPlayer) or nil)
end

local function changePhase(to,quick)
    transition={
        from=currentFade,
        target=to=="HIDING" and 1 or 0,
        phase=to,
        quick=quick,
        started=os.clock(),
        soundKey=(to=="HIDING" and (quick and "hideFast" or "hide")
            or (quick and "showFast" or "show")),
    }
    phase=to
    setBusy(true)
    startAudio(transition.soundKey)
    showMessage(to..(quick and " / QUICK" or ""))
end
local function beginCommand(command)
    if not command then return end
    if phase=="HIDING" or phase=="SHOWING" then
        queued=command
        showMessage("QUEUED: "..command.kind)
        return
    end
    local quick=command.quick==true
    if command.kind=="HIDE" then
        pendingDestination=nil
        if phase=="SOLID" then
            lastVisiblePivot=readCF(rootBlock) or lastVisiblePivot
            changePhase("HIDING",quick)
        else
            showMessage("ALREADY HIDDEN")
        end
    elseif command.kind=="SHOW" then
        if phase=="HIDDEN" then
            local dest=command.target or lastVisiblePivot
            if not dest or not move(dest) then
                showMessage("SHOW FAILED / DESTINATION UNAVAILABLE")
                return
            end
            changePhase("SHOWING",quick)
        else
            showMessage("ALREADY MATERIALIZED")
        end
    elseif command.kind=="TRAVEL" then
        if not command.target then
            showMessage("TRAVEL REJECTED / NO VALID GROUND OR TARGET")
            return
        end
        if phase=="SOLID" then
            lastVisiblePivot=readCF(rootBlock) or lastVisiblePivot
            pendingDestination=command.target
            changePhase("HIDING",quick)
        elseif phase=="HIDDEN" then
            if move(command.target) then
                lastVisiblePivot=command.target
                changePhase("SHOWING",quick)
            end
        end
    end
end
local function processQueued()
    local cmd=queued
    queued=nil
    if cmd then beginCommand(cmd) end
end
local function finishTransition()
    local t=transition
    if not t then return end
    transition=nil
    if t.phase=="HIDING" then
        setFinalFade(1)
        phase="HIDDEN"
        if not move(hiddenPivot) then
            setBusy(false); showMessage("HIDE MOVE FAILED / STOPPED"); return
        end
        if pendingDestination then
            local destination=pendingDestination
            pendingDestination=nil
            if move(destination) then
                lastVisiblePivot=destination
                changePhase("SHOWING",t.quick)
                return
            end
        end
        setBusy(false)
        showMessage("DEMATERIALIZED")
    else
        setFinalFade(0)
        phase="SOLID"
        lastVisiblePivot=readCF(rootBlock) or lastVisiblePivot
        setBusy(false)
        showMessage("MATERIALIZED")
        if t.quick then
            startAudio("endFast")
            quickStingUntil=os.clock()+2.8
        else
            stopAudio()
        end
    end
    processQueued()
end
local function updateTransition(now)
    local t=transition
    if not t then
        if quickStingUntil>0 and now>=quickStingUntil then
            quickStingUntil=0
            stopAudio()
        end
        return
    end
    local wall=now-t.started
    local duration=t.quick and QUICK_SECONDS or NORMAL_SECONDS
    local soundTime,length=audioClock()
    if length and length>MIN_SOUND_LENGTH then
        local visualLength=math.max(.3,length-(t.quick and .25 or SOUND_TAIL))
        duration=t.quick and math.min(duration,visualLength) or visualLength
    end
    local progress=math.clamp(wall/math.max(.3,duration),0,1)
    -- Audio is preferred while it actually advances, but wall time is the
    -- safety clock. A stalled/unloaded SoundBlock can never freeze the box.
    if soundTime and soundTime>0 then
        progress=math.max(progress,math.clamp(
            soundTime/math.max(.3,duration),0,1))
    end
    local shaped=math.pow(progress,t.quick and .48 or .68)
    currentFade=t.from+(t.target-t.from)*shaped
    if now-lastFade>=1/FADE_HZ or progress>=1 then
        lastFade=now
        setFade(currentFade,wave(soundTime or wall))
    end
    if progress>=1 then finishTransition() end
end
local function updateRotor(now,dt)
    if #rotor==0 or now-lastRotor<1/ROTOR_HZ then return end
    local elapsed=math.max(0,now-lastRotor)
    lastRotor=now
    if phase=="SOLID" then return end
    rotorTime=rotorTime+math.min(elapsed,.1)
    local cycle=(rotorTime/2.8)%1
    local triangle=cycle<.5 and 2*cycle or 2-2*cycle
    local smooth=triangle*triangle*(3-2*triangle)
    local rise=6*smooth
    for _,block in ipairs(rotor) do
        local base=rotorBase[block]
        if base then pcall(function() block.CFrame=base+Vector3.new(0,rise,0) end) end
    end
end

local lastPulse={e=false,f=false,j=false}
local latch=nil
local lastLoop=os.clock()
emit("b",false)
if phase=="HIDDEN" then setFinalFade(1) else setFinalFade(0) end
showMessage(VERSION.." / "..phase.." / NAV ONLY")
while true do
    local now=os.clock()
    local dt=math.clamp(now-lastLoop,.001,.1)
    lastLoop=now

    local a,aOK=state("a")
    if aOK and type(a)=="boolean" then
        if latch==nil then
            -- Startup unreadability cannot trigger accidental relocation.
            latch=a
            if a and phase=="HIDDEN" then
                beginCommand({kind="SHOW",target=destinationFromInputs()})
            elseif not a and phase=="SOLID" then
                beginCommand({kind="HIDE"})
            end
        elseif a~=latch then
            latch=a
            local d=state("d")
            beginCommand({kind=a and "SHOW" or "HIDE",
                quick=d==true,
                target=a and destinationFromInputs() or nil})
        end
    end
    for _,letter in ipairs({"e","f","j"}) do
        local value,ok=state(letter)
        if ok and type(value)=="boolean" then
            if value and not lastPulse[letter] then
                local fast=state("d")
                if letter=="e" then
                    beginCommand({kind="TRAVEL",target=toPlayer(nil),quick=true})
                elseif letter=="j" then
                    beginCommand({kind="TRAVEL",target=toPlayer(nil),quick=false})
                else
                    beginCommand({kind="TRAVEL",
                        target=destinationFromInputs(),quick=fast==true})
                end
            end
            lastPulse[letter]=value
        end
    end
    updateTransition(now)
    updateRotor(now,dt)
    task.wait(LOOP)
end
