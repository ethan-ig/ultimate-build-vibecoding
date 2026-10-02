-- TARDIS NAVIGATION 2.0 | Ultimate Build FIU
-- Navigation is a destination picker, NOT a manual flight controller.
--
-- INPUT A (optional): TRUE pulse toggles overhead navigation.
-- OUTPUT A (required): Vector3 ground hint -> controller input C.
-- OUTPUT B (optional): TRUE pulse -> controller input F to initiate travel.
-- A visible NAV button also opens/closes the map without any input wiring.
--
-- Click land to preview. Click CONFIRM TRAVEL to commit. Escape/CANCEL abort.
-- Right drag pans, mouse wheel zooms. No physical Part is ever created.

local VERSION = "NAVIGATION 2.0"
local HIDDEN = Vector3.new(-2000,1,2772)
local HIDDEN_RADIUS = 100
local NAV_HEIGHT, MIN_HEIGHT, MAX_HEIGHT = 450,70,2200
local FOV = 55
local FRAME, HOVER_RATE, REFRESH_RATE = 1/45,1/10,.75
local SMOOTH = 10
local MAX_RANGE = 20000
local Y_HINT_BIAS = 7   -- Controller raycasts from hint + 8.
local FILTER_NAMES = {
    tardis=true,tardisportal=true,tardismatsound=true,
    interiortardismatsound=true,tardislight=true,
    tardishiddensupport=true,
}

local function port(tableName, letter)
    local value=nil
    pcall(function() value=script[tableName][letter] end)
    return value
end
local toggleInput=port("inputs","a")
local destinationOutput=port("outputs","a")
local travelOutput=port("outputs","b")
local function emit(portObject,value)
    if not portObject then return false end
    return pcall(function() portObject:SetState(value) end)
end
local function prop(object,key)
    if not object then return nil end
    local ok,value=pcall(function() return object[key] end)
    if ok and value~=nil then return value end
    ok,value=pcall(function() return object:GetAttribute(key) end)
    if ok and value~=nil then return value end
    ok,value=pcall(function() return object.attributes[key] end)
    return ok and value or nil
end
local function raw(block)
    local value=nil
    if block then pcall(function() value=block.Part end) end
    if value then return value end
    return typeof(block)=="Instance" and block or nil
end
local function name(block)
    local value=prop(block,"DisplayName") or prop(block,"Display name")
    return type(value)=="string" and string.lower(value) or nil
end
local function getCF(block)
    local ok,value=pcall(function() return block.CFrame end)
    if ok and typeof(value)=="CFrame" then return value end
    local r=raw(block)
    if r then
        ok,value=pcall(function() return r.CFrame end)
        if ok and typeof(value)=="CFrame" then return value end
    end
    return nil
end
local Players,UIS,RunService=nil,nil,nil
pcall(function() Players=game:GetService("Players") end)
pcall(function() UIS=game:GetService("UserInputService") end)
pcall(function() RunService=game:GetService("RunService") end)
local player,mouse=nil,nil
if Players then pcall(function() player=Players.LocalPlayer end) end
if player then pcall(function() mouse=player:GetMouse() end) end
local function camera()
    local cam=nil
    pcall(function() cam=workspace.CurrentCamera end)
    return cam
end

local opened=false
local committing=false
local previousCamera=nil
local navCenter,desiredCenter=Vector3.zero,Vector3.zero
local height,desiredHeight=NAV_HEIGHT,NAV_HEIGHT
local selected,hover,lastDestination=nil,nil,nil
local lastKnownExterior=nil
local lastLoop,lastHover,lastExterior=0,0,0
local rightHeld,lastCursor,lastSelect= false,nil,0
local candidates,exclusions,params={}, {}, nil
local screen,button,panel,coords,status,confirm=nil,nil,nil,nil,nil,nil

local function log(text)
    print("TARDIS NAV:",text)
    if status then pcall(function() status.Text=text end) end
end
local function playerPosition()
    local character=player and player.Character
    local root=nil
    if character then pcall(function() root=character:FindFirstChild("HumanoidRootPart") end) end
    return root and prop(root,"Position") or nil
end
local function exteriorPosition()
    for _,object in ipairs(workspace:GetDescendants()) do
        if name(object)=="tardis" then
            local cf=getCF(object)
            if cf then
                local p=cf.Position
                if (p-HIDDEN).Magnitude>HIDDEN_RADIUS then return p end
            end
        end
    end
    return nil
end
local function refreshExterior()
    local p=exteriorPosition()
    if p then lastKnownExterior=p end
end
local function initialCenter()
    refreshExterior()
    return lastDestination or lastKnownExterior
        or playerPosition() or Vector3.new(0,0,0)
end

local function isPlayerPart(part)
    if not Players or not part then return false end
    local ps=nil
    pcall(function() ps=Players:GetPlayers() end)
    for _,p in ipairs(ps or {}) do
        local character=p.Character
        if character then
            local ok,descendant=pcall(function() return part:IsDescendantOf(character) end)
            if ok and descendant then return true end
        end
    end
    return false
end
local function target(block)
    local r=raw(block) or block
    local cf=getCF(r)
    local size=prop(r,"Size") or prop(block,"Size")
    return cf and typeof(size)=="Vector3" and r or nil
end
local function canLandOn(block,part)
    if FILTER_NAMES[name(block)] then return false end
    local partName=prop(part,"Name")
    if type(partName)=="string" and FILTER_NAMES[string.lower(partName)] then return false end
    if prop(block,"CanCollide")==false or prop(part,"CanCollide")==false then return false end
    if isPlayerPart(part) then return false end
    return true
end
local function buildCandidates()
    candidates,exclusions,params={}, {}, nil
    local all=workspace:GetDescendants()
    local seen={}
    for _,block in ipairs(all) do
        local part=target(block)
        if part and FILTER_NAMES[name(block)] then exclusions[part]=true end
    end
    for _,block in ipairs(all) do
        local part=target(block)
        if part and not seen[part] then
            seen[part]=true
            if exclusions[part] or isPlayerPart(part) then
                exclusions[part]=true
            elseif canLandOn(block,part) then
                table.insert(candidates,part)
            end
        end
    end
    pcall(function()
        local rp=RaycastParams.new()
        rp.FilterType=Enum.RaycastFilterType.Exclude
        local exclude={}
        for part in pairs(exclusions) do
            if typeof(part)=="Instance" then table.insert(exclude,part) end
        end
        if Players then
            for _,p in ipairs(Players:GetPlayers()) do
                if p.Character then table.insert(exclude,p.Character) end
            end
        end
        rp.FilterDescendantsInstances=exclude
        pcall(function() rp.RespectCanCollide=true end)
        params=rp
    end)
    print("TARDIS NAV LAND:",#candidates,"candidates")
end

local function cursor()
    local p=nil
    if UIS then pcall(function() p=UIS:GetMouseLocation() end) end
    if p then return p end
    local x,y=nil,nil
    if mouse then pcall(function() x,y=mouse.X,mouse.Y end) end
    if type(x)=="number" and type(y)=="number" then return Vector2.new(x,y) end
    return nil
end
local function cursorRay()
    local cam,p=camera(),cursor()
    if not cam or not p then return nil,nil end
    local ray=nil
    pcall(function() ray=cam:ScreenPointToRay(p.X,p.Y) end)
    if not ray then pcall(function() ray=cam:ViewportPointToRay(p.X,p.Y) end) end
    if not ray and mouse then pcall(function() ray=mouse.UnitRay end) end
    local origin,direction=nil,nil
    if ray then pcall(function() origin,direction=ray.Origin,ray.Direction end) end
    if not origin or not direction or direction.Magnitude<.0001 then return nil,nil end
    return origin,direction.Unit
end
local function slab(o,d,lo,hi,t0,t1)
    if math.abs(d)<1e-7 then return t0,t1,o>=lo and o<=hi end
    local a,b=(lo-o)/d,(hi-o)/d
    if a>b then a,b=b,a end
    t0,t1=math.max(t0,a),math.min(t1,b)
    return t0,t1,t0<=t1
end
local function boxDistance(part,origin,direction)
    local cf=getCF(part)
    local size=prop(part,"Size")
    if not cf or typeof(size)~="Vector3" then return nil end
    local o=cf:PointToObjectSpace(origin)
    local d=cf:VectorToObjectSpace(direction)
    local lo,hi,ok=0,MAX_RANGE,true
    lo,hi,ok=slab(o.X,d.X,-size.X/2,size.X/2,lo,hi)
    if not ok then return nil end
    lo,hi,ok=slab(o.Y,d.Y,-size.Y/2,size.Y/2,lo,hi)
    if not ok then return nil end
    lo,hi,ok=slab(o.Z,d.Z,-size.Z/2,size.Z/2,lo,hi)
    return ok and lo>=0 and lo<=MAX_RANGE and lo or nil
end
local function cursorLand()
    local origin,direction=cursorRay()
    if not origin then return nil end
    if params then
        local ok,hit=pcall(function()
            return workspace:Raycast(origin,direction*MAX_RANGE,params)
        end)
        if ok and hit then
            local p=prop(hit,"Position")
            local part=prop(hit,"Instance")
            if typeof(p)=="Vector3" and not exclusions[part]
                and not isPlayerPart(part)
                and prop(part,"CanCollide")~=false then
                return p
            end
        end
    end
    local best=nil
    for _,part in ipairs(candidates) do
        local d=boxDistance(part,origin,direction)
        if d and (not best or d<best) then best=d end
    end
    return best and (origin+direction*best) or nil
end

local function restoreCamera()
    local cam=camera()
    if cam and previousCamera then
        local saved=previousCamera
        -- FIU may reject a wrapped table as CameraSubject; do not block
        -- restoring the regular camera just because that optional write fails.
        if saved.cf then pcall(function() cam.CFrame=saved.cf end) end
        if saved.subject then pcall(function() cam.CameraSubject=saved.subject end) end
        if saved.fov then pcall(function() cam.FieldOfView=saved.fov end) end
        pcall(function()
            cam.CameraType=saved.kind==Enum.CameraType.Scriptable
                and Enum.CameraType.Custom or (saved.kind or Enum.CameraType.Custom)
        end)
    end
    previousCamera=nil
end
local function writeCamera()
    local cam=camera()
    if not opened or not cam then return end
    local cf=CFrame.new(
        navCenter.X,navCenter.Y+height,navCenter.Z)
        *CFrame.Angles(-math.pi/2,0,0)
    pcall(function()
        cam.CameraType=Enum.CameraType.Scriptable
        cam.CFrame=cf
    end)
end
local function destroyGui()
    if screen then pcall(function() screen:Destroy() end) end
    screen,button,panel,coords,status,confirm=nil,nil,nil,nil,nil,nil
end
local function corner(parent,r)
    pcall(function()
        local c=Instance.new("UICorner")
        c.CornerRadius=UDim.new(0,r)
        c.Parent=parent
    end)
end
local function connectButton(b,callback)
    -- Some FIU UI proxies accept Activated connections but never dispatch
    -- them. Listen to both events, debouncing their duplicate click reports.
    local last=0
    local function fire()
        local now=os.clock()
        if now-last<.22 then return end
        last=now
        callback()
    end
    pcall(function() b.Activated:Connect(fire) end)
    pcall(function() b.MouseButton1Click:Connect(fire) end)
end
local open,close,commit
local function buildGui()
    if screen or not player then return end
    local pg=nil
    pcall(function() pg=player:FindFirstChildOfClass("PlayerGui")
        or player:FindFirstChild("PlayerGui") end)
    if not pg then return end
    local ok,err=pcall(function()
        local old=pg:FindFirstChild("TardisNavigationGui")
        if old then old:Destroy() end
        screen=Instance.new("ScreenGui")
        screen.Name="TardisNavigationGui"
        screen.ResetOnSpawn=false
        screen.IgnoreGuiInset=true
        screen.DisplayOrder=1000
        screen.Parent=pg
        button=Instance.new("TextButton")
        button.Name="NavigationToggle"
        button.Position=UDim2.new(0,16,0,16)
        button.Size=UDim2.new(0,105,0,38)
        button.Text="NAV / MAP"
        button.Font=Enum.Font.GothamBold
        button.TextSize=13
        button.TextColor3=Color3.fromRGB(220,245,255)
        button.BackgroundColor3=Color3.fromRGB(12,51,76)
        button.Parent=screen
        corner(button,7)
        connectButton(button,function() if opened then close("CANCELLED") else open() end end)

        panel=Instance.new("Frame")
        panel.Name="MapControls"
        panel.AnchorPoint=Vector2.new(.5,0)
        panel.Position=UDim2.new(.5,0,0,16)
        panel.Size=UDim2.new(0,570,0,106)
        panel.BackgroundColor3=Color3.fromRGB(9,19,31)
        panel.BackgroundTransparency=.12
        panel.BorderSizePixel=0
        panel.Visible=false
        panel.Parent=screen
        corner(panel,9)
        local function labelLine(y,h,fontSize,color,text)
            local t=Instance.new("TextLabel")
            t.BackgroundTransparency=1
            t.Position=UDim2.new(0,12,0,y)
            t.Size=UDim2.new(1,-24,0,h)
            t.Font=Enum.Font.Code
            t.TextSize=fontSize
            t.TextXAlignment=Enum.TextXAlignment.Left
            t.TextColor3=color
            t.Text=text
            t.Parent=panel
            return t
        end
        labelLine(4,22,16,Color3.fromRGB(150,230,255),
            "TYPE 40  /  NAVIGATION")
        coords=labelLine(28,23,14,Color3.fromRGB(227,243,255),
            "MOVE CURSOR OVER SOLID GROUND")
        status=labelLine(52,18,12,Color3.fromRGB(175,203,211),
            "LEFT CLICK PREVIEWS  |  RIGHT DRAG PANS  |  WHEEL ZOOMS")
        local function action(text,x,width,fn)
            local b=Instance.new("TextButton")
            b.Position=UDim2.new(0,x,0,76)
            b.Size=UDim2.new(0,width,0,26)
            b.Text=text
            b.TextSize=12
            b.Font=Enum.Font.GothamBold
            b.TextColor3=Color3.fromRGB(238,251,255)
            b.BackgroundColor3=Color3.fromRGB(31,85,111)
            b.Parent=panel
            corner(b,5)
            connectButton(b,fn)
            return b
        end
        confirm=action("CONFIRM TRAVEL",12,153,function() commit() end)
        action("CANCEL / ESC",174,128,function() close("CANCELLED") end)
        action("RECENTER",311,115,function()
            desiredCenter=initialCenter()
            log("RECENTERED")
        end)
        action("CLEAR PIN",435,123,function()
            selected=nil
            log("DESTINATION CLEARED")
        end)
    end)
    if not ok then
        print("TARDIS NAV GUI ERROR:",tostring(err))
        destroyGui()
    end
end

close=function(reason)
    if not opened then return end
    opened=false
    rightHeld=false
    lastCursor=nil
    hover=nil
    restoreCamera()
    if panel then pcall(function() panel.Visible=false end) end
    if button then pcall(function() button.Text="NAV / MAP" end) end
    if reason then print("TARDIS NAV:",reason) end
end
open=function()
    if opened or committing then return end
    local cam=camera()
    if not cam then log("CAMERA UNAVAILABLE"); return end
    if not screen then buildGui() end
    local snapshot={}
    pcall(function()
        snapshot.kind=cam.CameraType
        snapshot.cf=cam.CFrame
        snapshot.subject=cam.CameraSubject
        snapshot.fov=cam.FieldOfView
    end)
    previousCamera=snapshot
    desiredCenter=initialCenter()
    navCenter=desiredCenter
    height,desiredHeight=NAV_HEIGHT,NAV_HEIGHT
    selected,hover=nil,nil
    rightHeld=false
    lastCursor=cursor()
    opened=true
    pcall(function()
        cam.CameraType=Enum.CameraType.Scriptable
        cam.FieldOfView=FOV
    end)
    buildCandidates()
    if panel then pcall(function() panel.Visible=true end) end
    if button then pcall(function() button.Text="CLOSE MAP" end) end
    writeCamera()
    log("LEFT CLICK TO PREVIEW A LANDING")
end
local function selectLand()
    if not opened or rightHeld or committing then return end
    -- A GUI click isn't a map click, including in FIU runtimes that do
    -- not reliably set the UserInputService gameProcessed flag.
    local pointOnScreen=cursor()
    if pointOnScreen and panel then
        local ok,pos,size=pcall(function()
            return panel.AbsolutePosition,panel.AbsoluteSize
        end)
        if ok and pos and size and
            pointOnScreen.X>=pos.X and pointOnScreen.X<=pos.X+size.X and
            pointOnScreen.Y>=pos.Y and pointOnScreen.Y<=pos.Y+size.Y then
            return
        end
    end
    local now=os.clock()
    if now-lastSelect<.16 then return end
    lastSelect=now
    local point=cursorLand() or hover
    if not point then log("NO COLLIDABLE LAND UNDER CURSOR"); return end
    selected=point
    local x,y,z=point.X,point.Y,point.Z
    if coords then
        pcall(function()
            coords.Text=string.format("PIN: X %.1f    Y %.1f    Z %.1f",x,y,z)
        end)
    end
    log("PIN SET / CONFIRM TRAVEL OR CANCEL")
end
commit=function()
    if committing then return end
    if not opened or not selected then
        log("SELECT A DESTINATION FIRST")
        return
    end
    committing=true
    local p=selected
    local hint=Vector3.new(p.X,p.Y-Y_HINT_BIAS,p.Z)
    if not emit(destinationOutput,hint) then
        committing=false
        log("OUTPUT A MISSING / WIRE TO CONTROLLER C")
        return
    end
    lastDestination=p
    close("DESTINATION SET")
    print("TARDIS NAV DESTINATION:",p,"controller hint:",hint)
    if travelOutput then
        -- Let the other Code Block observe A before the F pulse.
        task.wait(.18)
        local ok=emit(travelOutput,true)
        task.wait(.22)
        emit(travelOutput,false)
        if not ok then print("TARDIS NAV: travel pulse rejected; trigger controller F manually") end
    else
        print("TARDIS NAV: B not wired; pulse controller F to travel")
    end
    committing=false
end

local function zoom(value)
    if not opened or value==0 then return end
    desiredHeight=math.clamp(
        desiredHeight*math.pow(.86,value),MIN_HEIGHT,MAX_HEIGHT)
end
local function pan()
    if not opened then return end
    local cur=cursor()
    if not cur then return end
    if not rightHeld then
        lastCursor=cur
        return
    end
    if not lastCursor then lastCursor=cur; return end
    local delta=cur-lastCursor
    lastCursor=cur
    local cam=camera()
    if not cam then return end
    local viewportY=720
    pcall(function() viewportY=math.max(1,cam.ViewportSize.Y) end)
    local perPixel=2*height*math.tan(math.rad(FOV)/2)/viewportY
    local right=cam.CFrame.RightVector
    local up=cam.CFrame.UpVector
    desiredCenter=desiredCenter
        -Vector3.new(right.X,0,right.Z)*delta.X*perPixel
        +Vector3.new(up.X,0,up.Z)*delta.Y*perPixel
end
local keyboardMouseOK=false
if UIS then
    keyboardMouseOK=pcall(function()
        UIS.InputBegan:Connect(function(key,processed)
            if not opened then return end
            if key.KeyCode==Enum.KeyCode.Escape then
                close("CANCELLED"); return
            end
            if key.UserInputType==Enum.UserInputType.MouseButton2 then
                rightHeld=true
                lastCursor=cursor()
            elseif key.UserInputType==Enum.UserInputType.MouseButton1
                and not processed then
                selectLand()
            end
        end)
        UIS.InputEnded:Connect(function(key)
            if key.UserInputType==Enum.UserInputType.MouseButton2 then
                rightHeld=false
            end
        end)
        UIS.InputChanged:Connect(function(key)
            if opened and key.UserInputType==Enum.UserInputType.MouseWheel then
                zoom(key.Position.Z)
            end
        end)
    end)
end
if mouse and not keyboardMouseOK then
    pcall(function()
        mouse.Button1Down:Connect(selectLand)
        mouse.Button2Down:Connect(function() rightHeld=true;lastCursor=cursor() end)
        mouse.Button2Up:Connect(function() rightHeld=false end)
        mouse.WheelForward:Connect(function() zoom(1) end)
        mouse.WheelBackward:Connect(function() zoom(-1) end)
    end)
end

buildGui()
local lastA=false
emit(travelOutput,false)
print(VERSION,"/ A -> CONTROLLER C, B -> CONTROLLER F")
while true do
    local now=os.clock()
    local dt=math.clamp(now-lastLoop,0,.1)
    lastLoop=now
    if toggleInput then
        local ok,value=pcall(function() return toggleInput:GetState() end)
        if ok and type(value)=="boolean" then
            if value and not lastA then
                if opened then close("CANCELLED") else open() end
            end
            lastA=value
        end
    end
    if not opened then
        if now-lastExterior>=REFRESH_RATE then
            lastExterior=now
            refreshExterior()
        end
        if not screen and player then buildGui() end
    else
        pan()
        local alpha=1-math.exp(-SMOOTH*dt)
        navCenter=navCenter:Lerp(desiredCenter,alpha)
        height=height+(desiredHeight-height)*alpha
        writeCamera()
        if now-lastHover>=HOVER_RATE then
            lastHover=now
            hover=cursorLand()
            if coords and not selected then
                local line=hover and string.format(
                    "LAND: X %.1f  Y %.1f  Z %.1f  |  HEIGHT %.0f",
                    hover.X,hover.Y,hover.Z,height)
                    or string.format("NO LAND UNDER CURSOR  |  HEIGHT %.0f",height)
                pcall(function() coords.Text=line end)
            end
        end
    end
    task.wait(FRAME)
end
