-- Anti-Lag Combined: current Overdrive H plugin API + saved preferences.
-- Sources: uploaded AntiLag.lua and erixniex/FixLag/main/AntiLag.lua (loader upload).
-- No remote Lua execution. These are optional movement workarounds, NOT a ping/FPS guarantee.
local shared=odh_shared_plugins
if not shared or type(shared.CreateTab)~="function" then
    warn("[Anti-Lag] Load through the current Overdrive H plugin menu.");return
end
local KEY="ODH_AntiLagCombinedRuntime_v1"
if type(_G[KEY])=="table" and _G[KEY].alive then
    if type(shared.Notify)=="function" then pcall(shared.Notify,"Anti-Lag Combined is already loaded.",4) end
    return
end
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local Input=game:GetService("UserInputService")
local Http=game:GetService("HttpService")
local Player=Players.LocalPlayer
if not Player then warn("[Anti-Lag] LocalPlayer unavailable.");return end
local runtime={alive=true,initializing=true,version=1,connections={},saved={},saveStatus="Not saved"}
local prefs={enabled=false,shift=false,freeze=false,input=false,smoothing=false,physics=false,states=false}
runtime.preferences=prefs
local FILE="ODH_AntiLagCombined_settings.json"
local RENDER="ODH_AntiLagCombined_Input"
runtime.settingsFile=FILE
local warnings={}
local function Notify(text)
    if type(shared.Notify)=="function" then pcall(shared.Notify,"Anti-Lag: "..text,5) end
end
local function WarnOnce(key,text)
    if warnings[key] then return end
    warnings[key]=true;warn("[Anti-Lag] "..text);Notify(text)
end
local env={}
if type(getgenv)=="function" then
    local ok,value=pcall(getgenv);if ok and type(value)=="table" then env=value end
end
local read=type(readfile)=="function" and readfile or env.readfile
local write=type(writefile)=="function" and writefile or env.writefile
local exists=type(isfile)=="function" and isfile or env.isfile
local canSave=type(read)=="function" and type(write)=="function"
local function LoadSettings()
    if not canSave then
        runtime.saveStatus="Session only";WarnOnce("files","readfile/writefile unavailable; preferences are session-only.");return
    end
    if type(exists)=="function" then
        local ok,found=pcall(exists,FILE);if ok and not found then return end
    end
    local ok,text=pcall(read,FILE)
    if not ok then WarnOnce("read","Cannot read preferences; defaults used.");return end
    local decoded,data=pcall(function() return Http:JSONDecode(text) end)
    if not decoded or type(data)~="table" or data.version~=1 or type(data.values)~="table" then
        WarnOnce("read","Invalid preferences file; kept unchanged until you edit a setting.");return
    end
    for key in pairs(prefs) do if type(data.values[key])=="boolean" then prefs[key]=data.values[key] end end
    runtime.saveStatus="Loaded"
end
local function SaveSettings()
    if not runtime.alive or runtime.initializing or not canSave then return false end
    local ok,err=pcall(function() write(FILE,Http:JSONEncode({version=1,values=prefs})) end)
    if not ok then runtime.saveStatus="Write error";WarnOnce("write","Cannot save preferences: "..tostring(err));return false end
    warnings.write=nil;runtime.saveStatus="Saved";return true
end
LoadSettings()
local statusLabel,statsLabel
local function Label(control,text)
    if control then pcall(function() control:SetValue(text) end) end
end
local function Status(text) runtime.status=text;Label(statusLabel,text) end
local character,humanoid,root
local childConnection,heartbeatConnection,shiftConnection
local renderBound=false
local baseHumanoid,baseWalkSpeed
local states={Enum.HumanoidStateType.Ragdoll,Enum.HumanoidStateType.FallingDown,
    Enum.HumanoidStateType.Seated,Enum.HumanoidStateType.PlatformStanding,
    Enum.HumanoidStateType.Swimming,Enum.HumanoidStateType.Climbing}

-- Track original values (including nil CustomPhysicalProperties and false states).
-- Restore only values still belonging to this plugin; don't clobber other scripts.
local function ReadValue(obj,key,isState)
    if isState then return obj:GetStateEnabled(key) end
    return obj[key]
end
local function WriteValue(obj,key,value,isState)
    if isState then obj:SetStateEnabled(key,value) else obj[key]=value end
end
local function Patch(obj,key,value,group,isState)
    if not obj then return false end
    local ok,current=pcall(ReadValue,obj,key,isState)
    if not ok then WarnOnce("read-"..group,"Cannot read "..group.." properties on this character.");return false end
    local records=runtime.saved[obj]
    if not records then records={};runtime.saved[obj]=records end
    local record=records[key]
    if not record then
        record={original=current,group=group,isState=isState};records[key]=record
    elseif current~=record.last and current~=record.original and current~=record.before then
        -- An external change before a new explicit write becomes the new baseline.
        record.original=current
    end
    record.before=current;record.last=value
    local wrote,err=pcall(WriteValue,obj,key,value,isState)
    local verified,actual=pcall(ReadValue,obj,key,isState)
    if wrote and verified and actual==value then record.before=nil;return true end
    WarnOnce("write-"..group,"Could not apply "..group..": "..tostring(err));return false
end
local function Restore(group)
    local complete=true
    for obj,records in pairs(runtime.saved) do
        for key,record in pairs(records) do
            if not group or record.group==group then
                local ok,current=pcall(ReadValue,obj,key,record.isState)
                local parentOK,parent=pcall(function() return obj.Parent end)
                if not parentOK or not parent then
                    records[key]=nil
                elseif not ok then
                    complete=false
                elseif current==record.original then
                    records[key]=nil
                elseif current~=record.last and (record.before==nil or current~=record.before) then
                    records[key]=nil
                    WarnOnce("conflict-"..record.group,"Another script changed "..record.group.."; its value was left untouched.")
                else
                    local wrote=pcall(WriteValue,obj,key,record.original,record.isState)
                    local verified,actual=pcall(ReadValue,obj,key,record.isState)
                    if wrote and verified and actual==record.original then records[key]=nil else complete=false end
                end
            end
        end
        if next(records)==nil then runtime.saved[obj]=nil end
    end
    if not complete then WarnOnce("restore","Some original values could not be restored. Press Reapply / Retry.") end
    return complete
end
local function ValidCharacter()
    return runtime.alive and character and character==Player.Character and humanoid and humanoid.Health>0
end
local function ApplyProfiles()
    local active=runtime.alive and prefs.enabled
    if active and prefs.physics and root then
        -- Roblox ranges: RootPriority <= 127, physical weights <= 100.
        local ok,profile=pcall(function() return PhysicalProperties.new(5,.02,.10,100,100) end)
        if ok then Patch(root,"CustomPhysicalProperties",profile,"physics",false) end
        Patch(root,"RootPriority",127,"physics",false)
    else Restore("physics") end
    if active and prefs.states and humanoid then
        for _,state in ipairs(states) do Patch(humanoid,state,false,"states",true) end
    else Restore("states") end
    if active and prefs.shift and humanoid then
        if baseHumanoid~=humanoid then baseHumanoid=humanoid;baseWalkSpeed=humanoid.WalkSpeed end
    else
        Restore("shift");baseHumanoid=nil;baseWalkSpeed=nil
    end
end
local function DisconnectActive()
    if heartbeatConnection then heartbeatConnection:Disconnect();heartbeatConnection=nil end
    if shiftConnection then shiftConnection:Disconnect();shiftConnection=nil end
    if renderBound then pcall(function() RunService:UnbindFromRenderStep(RENDER) end);renderBound=false end
end
local freezeCount=0
local elapsed,frameCount,sampleTime=0,0,0
local pingValues,pingIndex,pingCount,pingSum={},0,0,0
local averagePing=0
local function SamplePing()
    local ok,ping=pcall(function() return Player:GetNetworkPing() end)
    if not ok or type(ping)~="number" or ping~=ping or ping<0 or ping==math.huge then return end
    pingIndex=pingIndex%15+1
    pingSum=pingSum-(pingValues[pingIndex] or 0)+ping
    pingValues[pingIndex]=ping;pingCount=math.min(pingCount+1,15)
    averagePing=pingSum/pingCount
    runtime.ping=averagePing
end
local function OnHeartbeat(dt)
    if not runtime.alive or not prefs.enabled or type(dt)~="number" or dt<=0 or dt~=dt or dt==math.huge then return end
    elapsed=elapsed+dt;frameCount=frameCount+1;sampleTime=sampleTime+dt
    if sampleTime>=1 then SamplePing();sampleTime=0 end
    if elapsed>=1 then
        runtime.fps=frameCount/elapsed
        Label(statsLabel,string.format("FPS: %.0f | GetNetworkPing average: %.0f ms",runtime.fps,averagePing*1000))
        elapsed=0;frameCount=0
    end
    if not ValidCharacter() or not root or root.Anchored or humanoid.Sit or humanoid.PlatformStand then freezeCount=0;return end
    if not prefs.freeze and not prefs.smoothing then return end
    local velocity=root.AssemblyLinearVelocity
    local horizontal=math.sqrt(velocity.X*velocity.X+velocity.Z*velocity.Z)
    local factor=1
    if prefs.freeze then
        if dt>.08 then freezeCount=freezeCount+1 else freezeCount=math.max(0,freezeCount-1) end
        if freezeCount>=2 then
            if horizontal>60 then factor=factor*.85 end
            freezeCount=0
        end
    end
    if prefs.smoothing and pingCount>0 and averagePing>.25 and horizontal>8 then
        factor=factor*(.98^math.min(dt*60,6))
    end
    if factor<1 then
        -- Preserve vertical velocity and never force Landed while the avatar is airborne.
        pcall(function() root.AssemblyLinearVelocity=Vector3.new(velocity.X*factor,velocity.Y,velocity.Z*factor) end)
    end
end
local function InputStep()
    if not prefs.enabled or not prefs.input or not ValidCharacter() or not Input.KeyboardEnabled then return end
    if humanoid.Sit or humanoid.PlatformStand then return end
    local ok,focused=pcall(function() return Input:GetFocusedTextBox() end)
    if not ok or focused then return end
    local got,last=pcall(function() return Input:GetLastInputType() end)
    if got and last and (last==Enum.UserInputType.Touch or last.Name:find("Gamepad",1,true)) then return end
    local x=(Input:IsKeyDown(Enum.KeyCode.D) and 1 or 0)-(Input:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
    local z=(Input:IsKeyDown(Enum.KeyCode.S) and 1 or 0)-(Input:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
    if x==0 and z==0 then return end -- don't override mobile/gamepad/automatic movement
    local vector=Vector3.new(x,0,z)
    if vector.Magnitude>1 then vector=vector.Unit end
    -- MoveDirection is read-only. Use the supported camera-relative movement method.
    humanoid:Move(vector,true)
end
local function Reconcile()
    if not runtime.alive then return end
    DisconnectActive()
    freezeCount=0;elapsed=0;frameCount=0;sampleTime=0
    pingValues={};pingIndex=0;pingCount=0;pingSum=0;averagePing=0
    ApplyProfiles()
    if not prefs.enabled then
        local complete=Restore()
        Status(complete and "OFF — tracked properties restored" or "OFF — restoration pending")
        Label(statsLabel,"Monitoring paused")
        return
    end
    local activeCount=0
    for key,value in pairs(prefs) do if key~="enabled" and value then activeCount=activeCount+1 end end
    Status(character and ("ON — "..activeCount.." options selected") or "ON — waiting for character")
    heartbeatConnection=RunService.Heartbeat:Connect(function(dt)
        local ok,err=pcall(OnHeartbeat,dt)
        if not ok then WarnOnce("heartbeat",tostring(err)) end
    end)
    if prefs.shift then
        shiftConnection=Input:GetPropertyChangedSignal("MouseBehavior"):Connect(function()
            if not prefs.enabled or not prefs.shift or not ValidCharacter() or baseHumanoid~=humanoid then return end
            if humanoid.WalkSpeed>0 and baseWalkSpeed and humanoid.WalkSpeed~=baseWalkSpeed then
                Patch(humanoid,"WalkSpeed",baseWalkSpeed,"shift",false)
            end
        end)
    end
    if prefs.input then
        if not Input.KeyboardEnabled then
            WarnOnce("keyboard","WASD assistance is keyboard-only; touch and gamepad controls are left unchanged.")
        end
        local ok,err=pcall(function()
            RunService:BindToRenderStep(RENDER,Enum.RenderPriority.Input.Value+1,function()
                local success,problem=pcall(InputStep)
                if not success then WarnOnce("input",tostring(problem)) end
            end)
        end)
        renderBound=ok
        if not ok then WarnOnce("bind","Input assistance unavailable: "..tostring(err)) end
    end
end
local function RefreshCharacter()
    if not runtime.alive or not character or character~=Player.Character then return end
    humanoid=character:FindFirstChildOfClass("Humanoid")
    root=character:FindFirstChild("HumanoidRootPart")
    ApplyProfiles()
end
local function AttachCharacter(nextCharacter)
    if childConnection then childConnection:Disconnect();childConnection=nil end
    Restore()
    character=nextCharacter;humanoid=nil;root=nil;baseHumanoid=nil;baseWalkSpeed=nil
    if character then
        childConnection=character.ChildAdded:Connect(function(child)
            if child.Name=="HumanoidRootPart" or child:IsA("Humanoid") then RefreshCharacter() end
        end)
        humanoid=character:FindFirstChildOfClass("Humanoid")
        root=character:FindFirstChild("HumanoidRootPart")
    end
    Reconcile()
end
runtime.Reapply=Reconcile
runtime.SaveSettings=SaveSettings
function runtime.Cleanup()
    if not runtime.alive then return Restore() end
    runtime.alive=false;DisconnectActive()
    if childConnection then childConnection:Disconnect();childConnection=nil end
    for _,connection in ipairs(runtime.connections) do connection:Disconnect() end
    local restored=Restore()
    Status(restored and "Unloaded" or "Unloaded — some originals could not be restored")
    return restored
end

local tab=shared.CreateTab("Anti-Lag Combined","/mellnikovden968-web/CFG_PM2/refs/heads/main/icon")
local main=tab:AddSection("Anti-Lag Combined","Two sources • current API • saved settings")
statusLabel=main:AddLabel("Loading...",true)
statsLabel=main:AddLabel("Monitoring paused",true)
main:AddParagraph("Read first","These options alter movement, not rendering quality. They cannot guarantee higher FPS or lower ping. Start with all options OFF and enable only a workaround you need. Graphics, JumpPower, camera settings and emote IDs are not changed.")
local toggles={}
local function AddToggle(section,label,key)
    toggles[key]=section:AddToggle(label,function(value)
        if runtime.initializing or not runtime.alive then return end
        prefs[key]=value==true;SaveSettings();Reconcile()
    end)
end
AddToggle(main,"Enable Anti-Lag","enabled")
main:AddButton("Reapply / Retry",function() if runtime.alive then Reconcile() end end)
main:AddButton("Unload this session",function() runtime.Cleanup() end)
local movement=tab:AddSection("Movement Workarounds","Based on erixniex / FixLag")
AddToggle(movement,"Fix ShiftLock Stutter (speed lock)","shift")
movement:AddParagraph("ShiftLock warning","Captures WalkSpeed when activated and restores that speed on MouseBehavior changes. May conflict with sprint/speed scripts. Does not repair camera stutter or raise FPS.")
AddToggle(movement,"Anti Freeze (horizontal damping)","freeze")
movement:AddParagraph("Frame-spike workaround","After two slow frames, reduces unusually high horizontal velocity. Cannot prevent frame stalls. Never forces Landed in midair; vertical velocity is preserved.")
AddToggle(movement,"Fix Input Lag (WASD assistance)","input")
movement:AddParagraph("Keyboard only","Uses Humanoid:Move instead of writing read-only MoveDirection. Runs after default input priority; ignores text entry, touch and gamepad input. Does not reduce hardware latency.")
AddToggle(movement,"Network Smoothing (horizontal damping)","smoothing")
movement:AddParagraph("Network warning","Damps horizontal movement when the sampled GetNetworkPing average exceeds 250 ms. May slow movement; cannot reduce actual ping. The displayed API value may differ from the game's ping display.")
local advanced=tab:AddSection("Experimental Character Options","From uploaded AntiLag.lua • OFF by default")
AddToggle(advanced,"Physics Optimize (experimental profile)","physics")
advanced:AddParagraph("Physics profile","Applies density 5, friction 0.02, elasticity 0.10, weights 100, RootPriority 127. Changes character physics and may affect gameplay; it is not a proven performance improvement. Original values, including nil, are recorded for restoration.")
AddToggle(advanced,"State Culling (disable states)","states")
advanced:AddParagraph("State warning","Disables Ragdoll, FallingDown, Seated, PlatformStanding, Swimming and Climbing. Can break seats, ladders and swimming. Each original enabled/disabled state is restored; JumpPower is never changed.")
local notes=tab:AddSection("Compatibility & Saving","No fake network/GC switches")
notes:AddParagraph("Removed non-working code","SetNetworkOwner is server-side and SetNetworkOwnershipAuto is not a Player method. Network Optimize / Ownership Lock were removed rather than silently failing every frame. Forced GC is unavailable in normal Roblox Luau. Event Throttling only inspected an unused table; this plugin manages its own connections instead.")
notes:AddParagraph("Restoration","Turning an option/master OFF restores its tracked properties if another script has not replaced them. Velocity damping is a transient physics action; old velocity is not replayed on disable. Rejoin after replacing the old plugins, because their pre-existing modifications cannot be reconstructed reliably.")
notes:AddParagraph("Preferences",FILE.." is loaded before controls initialize. readfile/writefile are required for cross-session saving. Unload stops this session without erasing your saved master/toggle choices. Restart to load the file again.")
for key,flip in pairs(toggles) do
    if prefs[key] and type(flip)=="function" then pcall(flip) end
end
runtime.initializing=false
_G[KEY]=runtime
runtime.connections[#runtime.connections+1]=Player.CharacterAdded:Connect(function(c) if runtime.alive then AttachCharacter(c) end end)
runtime.connections[#runtime.connections+1]=Player.CharacterRemoving:Connect(function(c)
    if runtime.alive and c==character then AttachCharacter(nil) end
end)
AttachCharacter(Player.Character)
return runtime
