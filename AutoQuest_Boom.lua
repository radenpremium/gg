local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
local pgui = lp.PlayerGui

local inputMethod = "none"
local VIM = nil
if type(keypress) == "function" and type(keyrelease) == "function" then
    inputMethod = "keypress"
elseif syn and syn.key_press then
    inputMethod = "syn"
else
    local ok, vim = pcall(function() return game:GetService("VirtualInputManager") end)
    if ok and vim then VIM = vim; inputMethod = "vim" end
end

local KeyCodeMap = {
    [Enum.KeyCode.One]=0x31,[Enum.KeyCode.Two]=0x32,
    [Enum.KeyCode.Three]=0x33,[Enum.KeyCode.Four]=0x34,
    [Enum.KeyCode.W]=0x57,[Enum.KeyCode.Space]=0x20,[Enum.KeyCode.E]=0x45,
}
local function pressKeyDown(kc)
    local n = KeyCodeMap[kc]
    if inputMethod=="keypress" and n then pcall(keypress,n)
    elseif inputMethod=="syn" and n then pcall(syn.key_press,n)
    elseif inputMethod=="vim" and VIM then pcall(function() VIM:SendKeyEvent(true,kc,false,game) end) end
end
local function pressKeyUp(kc)
    local n = KeyCodeMap[kc]
    if inputMethod=="keypress" and n then pcall(keyrelease,n)
    elseif inputMethod=="syn" and n then pcall(syn.key_release,n)
    elseif inputMethod=="vim" and VIM then pcall(function() VIM:SendKeyEvent(false,kc,false,game) end) end
end
local function pressKey(kc,hold)
    hold=hold or 0.12
    pressKeyDown(kc); task.wait(hold); pressKeyUp(kc); task.wait(0.08)
end

local NPC_POS = Vector3.new(-3063,18,-1040)
local TELEPORT_WAIT = 1.3

local TRAIN_COORDS = {
    Agility={
        {threshold=10000,pos=Vector3.new(-2489,78,-1002)},
        {threshold=0,    pos=Vector3.new(-3092,19,-1512)},
    },
    Speed={
        {threshold=10000,pos=Vector3.new(-2898,5,-428)},
        {threshold=0,    pos=Vector3.new(-2898,5,-485)},
    },
    Chakra={
        {threshold=100000000000000,pos=Vector3.new(-5577,7,-3584)},
        {threshold=1000000000000,  pos=Vector3.new(-5552,6,-893)},
        {threshold=100000000000,   pos=Vector3.new(-4170,325,-2671)},
        {threshold=1000000000,     pos=Vector3.new(-3238,8,775)},
        {threshold=100000000,      pos=Vector3.new(-4227,220,-534)},
        {threshold=10000000,       pos=Vector3.new(-3126,-72,477)},
        {threshold=1000000,        pos=Vector3.new(-4751,417,-1883)},
        {threshold=100000,         pos=Vector3.new(-4138,87,-1808)},
        {threshold=10000,          pos=Vector3.new(-4556,89,-472)},
        {threshold=1000,           pos=Vector3.new(-3317,21,-1112)},
        {threshold=0,              pos=Vector3.new(-3094,33,-885)},
    },
    Durability={
        {threshold=100000000000000,pos=Vector3.new(-6250,155,-2136)},
        {threshold=1000000000000,  pos=Vector3.new(-4938,-482,-4366)},
        {threshold=100000000000,   pos=Vector3.new(-725,-467,-1703)},
        {threshold=1000000000,     pos=Vector3.new(-4149,826,-663)},
        {threshold=100000000,      pos=Vector3.new(-1848,61,-83)},
        {threshold=10000000,       pos=Vector3.new(-2558,-16,646)},
        {threshold=1000000,        pos=Vector3.new(-2259,147,-1860)},
        {threshold=100000,         pos=Vector3.new(-2906,10,-2914)},
        {threshold=10000,          pos=Vector3.new(-989,41,-460)},
        {threshold=1000,           pos=Vector3.new(-2936,12,-2038)},
        {threshold=0,              pos=Vector3.new(-3097,7,-737)},
    },
    Strength={
        {threshold=100000000000000,pos=Vector3.new(-5830,135,-2936)},
        {threshold=1000000000000,  pos=Vector3.new(-5534,-446,-2295)},
        {threshold=100000000000,   pos=Vector3.new(-2479,131,339)},
        {threshold=1000000000,     pos=Vector3.new(-3876,87,-1909)},
        {threshold=100000000,      pos=Vector3.new(-2831,9,242)},
        {threshold=10000000,       pos=Vector3.new(-763,587,-1702)},
        {threshold=1000000,        pos=Vector3.new(-1925,4,-1259)},
        {threshold=100000,         pos=Vector3.new(-1623,3,-1449)},
        {threshold=10000,          pos=Vector3.new(-4554,89,-931)},
        {threshold=1000,           pos=Vector3.new(-3092,5,-1338)},
        {threshold=0,              pos=Vector3.new(-3093,7,-1192)},
    },
    Sword={{threshold=0,pos=Vector3.new(-3060,18,-1060)}},
}

local function getBestCoord(statName,currentStat)
    local list=TRAIN_COORDS[statName]
    if not list then return nil,0 end
    for _,entry in ipairs(list) do
        if currentStat>=entry.threshold then return entry.pos,entry.threshold end
    end
    return list[#list].pos,list[#list].threshold
end

local suffixes={{"Qn",1e18},{"Qd",1e15},{"T",1e12},{"B",1e9},{"M",1e6},{"K",1e3}}
local function parseNum(str)
    if not str or str=="" then return 0 end
    str=str:gsub(",",""):gsub("%s","")
    for _,sv in ipairs(suffixes) do
        local n=str:match("^([%d%.]+)"..sv[1].."$")
        if n then return math.floor((tonumber(n) or 0)*sv[2]) end
    end
    return math.floor(tonumber(str) or 0)
end

local function getStat(name)
    local ok,v=pcall(function()
        local node=pgui.Main.HUD.StatTracker:FindFirstChild(name)
        if not node then return 0 end
        local top=node:FindFirstChild("Top")
        return top and parseNum(top.Text) or 0
    end)
    return ok and v or 0
end

local function getQuests()
    local ok,res=pcall(function()
        local list=pgui.Main.HUD.QuestTracker.Main.Holder.List
        local out={}
        for _,child in ipairs(list:GetChildren()) do
            if not child.Name:find("Progress_Main%.Boom") then continue end
            local main=child:FindFirstChild("Main")
            local qbar=child:FindFirstChild("QuestBar")
            if not(main and qbar) then continue end
            local qname=child.Name
            local tf=main:FindFirstChild("Title")
            if tf then
                if tf:IsA("TextLabel") then qname=tf.Text
                else for _,v in ipairs(tf:GetChildren()) do
                    if v:IsA("TextLabel") then qname=v.Text;break end
                end end
            end
            local cur,mx,pct=0,1,0
            local pl=qbar:FindFirstChild("QuestBarProgressAmount")
            if pl then
                local c,m,p=pl.Text:match("^(.-)%s*/%s*(.-)%s*%((%d+)%%%)")
                if c and m and p then cur=parseNum(c);mx=parseNum(m);pct=tonumber(p) or 0 end
            end
            local isDone=(pct>=100) and (mx>0) and (cur>=mx)
            table.insert(out,{name=qname,isDone=isDone,pct=pct,cur=cur,mx=mx})
        end
        return out
    end)
    return (ok and res) or {}
end

local function allDone(qs)
    if #qs==0 then return false end
    for _,q in ipairs(qs) do if not q.isDone then return false end end
    return true
end

local function teleportTo(pos)
    pcall(function() lp.Character.HumanoidRootPart.CFrame=CFrame.new(pos+Vector3.new(0,4,0)) end)
    task.wait(TELEPORT_WAIT)
end

local function finishDialog()
    for i=1,20 do
        task.wait(0.4)
        pressKey(Enum.KeyCode.E,0.1)
        task.wait(0.2)
        local open=false
        pcall(function()
            local d=pgui.Main.HUD:FindFirstChild("Dialogue")
            if d and d.Enabled then open=true end
        end)
        if not open then break end
    end
    task.wait(0.5)
end

local function goNPC()
    teleportTo(NPC_POS)
    task.wait(0.5)
    pressKey(Enum.KeyCode.E,0.15)
    task.wait(0.8)
    finishDialog()
    task.wait(0.5)
end

local function getQType(name)
    local l=name:lower()
    if l:find("sword") then return "Sword" end
    if l:find("agility") then return "Agility" end
    if l:find("speed") then return "Speed" end
    if l:find("chakra") then return "Chakra" end
    if l:find("durability") then return "Durability" end
    if l:find("strength") then return "Strength" end
end

local CFG={
    Sword=     {mk=Enum.KeyCode.Four,  ak=nil,                tp=false},
    Chakra=    {mk=Enum.KeyCode.Three, ak=nil,                tp=true},
    Durability={mk=Enum.KeyCode.Two,   ak=nil,                tp=true},
    Strength=  {mk=Enum.KeyCode.One,   ak=nil,                tp=true},
    Speed=     {mk=nil,                ak=Enum.KeyCode.W,     tp=true},
    Agility=   {mk=nil,                ak=Enum.KeyCode.Space, tp=true},
}

local isRunning=false
local stopReq=false
local curMode=nil
local statusText=""
local logLines={}
local lastThresh={}

local function setStatus(msg)
    statusText=msg
    table.insert(logLines,1,os.date("%H:%M:%S").." "..msg)
    if #logLines>50 then table.remove(logLines) end
end

local function setMode(key)
    if curMode==key then return end
    if curMode then pressKey(curMode,0.1);task.wait(0.3) end
    curMode=key
    if key then pressKey(key,0.1);task.wait(0.5) end
end

local function clearMode()
    if curMode then pressKey(curMode,0.1);task.wait(0.3);curMode=nil end
end

local speedActive=false
local speedConn=nil
local speedPos=nil

local function startSpeed(pos)
    speedPos=pos+Vector3.new(0,4,0)
    speedActive=true
    pcall(function() lp.Character.Humanoid.WalkSpeed=0 end)
    pressKeyDown(Enum.KeyCode.W)
    speedConn=RunService.Heartbeat:Connect(function()
        if not speedActive then return end
        pcall(function()
            local hrp=lp.Character.HumanoidRootPart
            if (hrp.Position-speedPos).Magnitude>3 then
                hrp.CFrame=CFrame.new(speedPos)
            end
        end)
    end)
end

local function stopSpeed()
    speedActive=false
    if speedConn then speedConn:Disconnect();speedConn=nil end
    pressKeyUp(Enum.KeyCode.W)
    pcall(function() lp.Character.Humanoid.WalkSpeed=16 end)
end

local function waitQuestDone(qname)
    while isRunning and not stopReq do
        task.wait(0.5)
        local qs=getQuests()
        local found=false
        for _,q in ipairs(qs) do
            if q.name==qname then
                found=true
                if q.isDone then return true end
                setStatus("Speed: "..tostring(q.pct).."%")
                break
            end
        end
        if not found then return true end
    end
    return false
end

local function mainLoop()
    lastThresh={}
    while isRunning and not stopReq do
        local qs=getQuests()
        if #qs==0 then
            setStatus("Tidak ada quest -> NPC...")
            clearMode();goNPC();task.wait(2)
            goto cont
        end
        if allDone(qs) then
            setStatus("Semua "..#qs.." quest selesai -> Claim NPC")
            clearMode();goNPC();task.wait(2)
            goto cont
        end
        for _,q in ipairs(qs) do
            if stopReq or not isRunning then break end
            if q.isDone then
                setStatus("Done: "..q.name.." tunggu lainnya...")
                task.wait(0.3);continue
            end
            local qt=getQType(q.name)
            if not qt then task.wait(0.2);continue end
            local cfg=CFG[qt]
            if not cfg then continue end
            if cfg.tp then
                local stat=getStat(qt)
                local pos,thresh=getBestCoord(qt,stat)
                if pos and lastThresh[qt]~=thresh then
                    lastThresh[qt]=thresh
                    setStatus("TP "..qt.." stat="..tostring(stat).." tier="..tostring(thresh))
                    if qt=="Speed" then stopSpeed() end
                    clearMode();teleportTo(pos)
                end
            end
            if qt=="Speed" then
                if not speedActive then
                    local stat=getStat(qt)
                    local pos=getBestCoord(qt,stat)
                    if pos then setStatus("Speed: hold W...");teleportTo(pos);startSpeed(pos) end
                end
                setStatus("Speed: "..tostring(q.pct).."%")
                local done=waitQuestDone(q.name)
                stopSpeed()
                if done then setStatus("Speed selesai!") end
            elseif qt=="Agility" then
                if curMode then clearMode() end
                setStatus("Agility: Space "..tostring(q.pct).."%")
                pressKeyDown(Enum.KeyCode.Space);task.wait(0.5);pressKeyUp(Enum.KeyCode.Space);task.wait(0.2)
            else
                if cfg.mk then setMode(cfg.mk) end
                setStatus("Training "..q.name.." "..tostring(q.pct).."%")
                task.wait(0.5)
            end
            break
        end
        ::cont::
        task.wait(0.5)
    end
    stopSpeed();clearMode();setStatus("Dihentikan.")
end

-- GUI (struktur v4 yang bisa jalan)
local function buildGUI()
    local old=pgui:FindFirstChild("AutoQuestGUI")
    if old then old:Destroy() end

    local sg=Instance.new("ScreenGui",pgui)
    sg.Name="AutoQuestGUI";sg.ResetOnSpawn=false

    local main=Instance.new("Frame",sg)
    main.Size=UDim2.new(0.5,0,0,0)
    main.Position=UDim2.new(0,8,0.12,0)
    main.BackgroundColor3=Color3.fromRGB(13,13,20)
    main.BorderSizePixel=0
    main.Active=true
    main.Draggable=true
    main.AutomaticSize=Enum.AutomaticSize.Y
    Instance.new("UICorner",main).CornerRadius=UDim.new(0,10)
    local ms=Instance.new("UIStroke",main)
    ms.Color=Color3.fromRGB(100,50,200);ms.Thickness=1.2

    local pad=Instance.new("UIPadding",main)
    pad.PaddingLeft=UDim.new(0,8);pad.PaddingRight=UDim.new(0,8)
    pad.PaddingTop=UDim.new(0,8);pad.PaddingBottom=UDim.new(0,8)

    local layout=Instance.new("UIListLayout",main)
    layout.SortOrder=Enum.SortOrder.LayoutOrder
    layout.Padding=UDim.new(0,6)

    -- title
    local tb=Instance.new("Frame",main)
    tb.Size=UDim2.new(1,0,0,30)
    tb.BackgroundColor3=Color3.fromRGB(70,30,145)
    tb.BorderSizePixel=0;tb.LayoutOrder=1
    Instance.new("UICorner",tb).CornerRadius=UDim.new(0,7)

    local tl=Instance.new("TextLabel",tb)
    tl.Size=UDim2.new(1,-32,1,0);tl.Position=UDim2.new(0,8,0,0)
    tl.BackgroundTransparency=1;tl.Text="Auto Quest Boom v7"
    tl.TextColor3=Color3.fromRGB(255,255,255);tl.Font=Enum.Font.GothamBold
    tl.TextSize=11;tl.TextXAlignment=Enum.TextXAlignment.Left

    local cb=Instance.new("TextButton",tb)
    cb.Size=UDim2.new(0,24,0,24);cb.Position=UDim2.new(1,-28,0.5,-12)
    cb.BackgroundColor3=Color3.fromRGB(180,35,35);cb.Text="X"
    cb.TextColor3=Color3.fromRGB(255,255,255);cb.Font=Enum.Font.GothamBold
    cb.TextSize=11;cb.BorderSizePixel=0
    Instance.new("UICorner",cb).CornerRadius=UDim.new(0,5)
    cb.MouseButton1Click:Connect(function() sg:Destroy() end)

    -- input badge
    local ib=Instance.new("Frame",main)
    ib.Size=UDim2.new(1,0,0,22);ib.BackgroundColor3=Color3.fromRGB(25,25,40)
    ib.BorderSizePixel=0;ib.LayoutOrder=2
    Instance.new("UICorner",ib).CornerRadius=UDim.new(0,5)
    local ibl=Instance.new("TextLabel",ib)
    ibl.Size=UDim2.new(1,-8,1,0);ibl.Position=UDim2.new(0,6,0,0)
    ibl.BackgroundTransparency=1;ibl.Text="Input: "..inputMethod
    ibl.TextColor3=Color3.fromRGB(160,160,255);ibl.Font=Enum.Font.Code
    ibl.TextSize=10;ibl.TextXAlignment=Enum.TextXAlignment.Left

    -- status
    local sf=Instance.new("Frame",main)
    sf.Size=UDim2.new(1,0,0,0);sf.AutomaticSize=Enum.AutomaticSize.Y
    sf.BackgroundColor3=Color3.fromRGB(20,20,32);sf.BorderSizePixel=0;sf.LayoutOrder=3
    Instance.new("UICorner",sf).CornerRadius=UDim.new(0,6)
    local sfp=Instance.new("UIPadding",sf)
    sfp.PaddingLeft=UDim.new(0,6);sfp.PaddingRight=UDim.new(0,6)
    sfp.PaddingTop=UDim.new(0,4);sfp.PaddingBottom=UDim.new(0,4)
    local statusLbl=Instance.new("TextLabel",sf)
    statusLbl.Size=UDim2.new(1,0,0,0);statusLbl.AutomaticSize=Enum.AutomaticSize.Y
    statusLbl.BackgroundTransparency=1;statusLbl.Text="Idle"
    statusLbl.TextColor3=Color3.fromRGB(170,170,255);statusLbl.Font=Enum.Font.Gotham
    statusLbl.TextSize=10;statusLbl.TextXAlignment=Enum.TextXAlignment.Left;statusLbl.TextWrapped=true

    -- quest info
    local qf=Instance.new("Frame",main)
    qf.Size=UDim2.new(1,0,0,0);qf.AutomaticSize=Enum.AutomaticSize.Y
    qf.BackgroundColor3=Color3.fromRGB(18,22,35);qf.BorderSizePixel=0;qf.LayoutOrder=4
    Instance.new("UICorner",qf).CornerRadius=UDim.new(0,6)
    local qfp=Instance.new("UIPadding",qf)
    qfp.PaddingLeft=UDim.new(0,6);qfp.PaddingRight=UDim.new(0,6)
    qfp.PaddingTop=UDim.new(0,4);qfp.PaddingBottom=UDim.new(0,4)
    local questLbl=Instance.new("TextLabel",qf)
    questLbl.Size=UDim2.new(1,0,0,0);questLbl.AutomaticSize=Enum.AutomaticSize.Y
    questLbl.BackgroundTransparency=1;questLbl.Text="Quest: -"
    questLbl.TextColor3=Color3.fromRGB(255,210,80);questLbl.Font=Enum.Font.Code
    questLbl.TextSize=10;questLbl.TextXAlignment=Enum.TextXAlignment.Left;questLbl.TextWrapped=true

    -- start/stop
    local startBtn=Instance.new("TextButton",main)
    startBtn.Size=UDim2.new(1,0,0,34);startBtn.BackgroundColor3=Color3.fromRGB(45,160,65)
    startBtn.Text="START";startBtn.TextColor3=Color3.fromRGB(255,255,255)
    startBtn.Font=Enum.Font.GothamBold;startBtn.TextSize=12
    startBtn.BorderSizePixel=0;startBtn.LayoutOrder=5
    Instance.new("UICorner",startBtn).CornerRadius=UDim.new(0,7)

    -- stat
    local stf=Instance.new("Frame",main)
    stf.Size=UDim2.new(1,0,0,0);stf.AutomaticSize=Enum.AutomaticSize.Y
    stf.BackgroundColor3=Color3.fromRGB(16,16,26);stf.BorderSizePixel=0;stf.LayoutOrder=6
    Instance.new("UICorner",stf).CornerRadius=UDim.new(0,6)
    local stp=Instance.new("UIPadding",stf)
    stp.PaddingLeft=UDim.new(0,6);stp.PaddingRight=UDim.new(0,6)
    stp.PaddingTop=UDim.new(0,4);stp.PaddingBottom=UDim.new(0,4)
    local statLbl=Instance.new("TextLabel",stf)
    statLbl.Size=UDim2.new(1,0,0,0);statLbl.AutomaticSize=Enum.AutomaticSize.Y
    statLbl.BackgroundTransparency=1;statLbl.Text="STR:-  CHK:-  DUR:-\nSPD:-  AGI:-  SWD:-"
    statLbl.TextColor3=Color3.fromRGB(80,190,255);statLbl.Font=Enum.Font.Code
    statLbl.TextSize=9;statLbl.TextXAlignment=Enum.TextXAlignment.Left;statLbl.TextWrapped=true

    -- log
    local lh=Instance.new("TextLabel",main)
    lh.Size=UDim2.new(1,0,0,14);lh.BackgroundTransparency=1;lh.Text="LOG"
    lh.TextColor3=Color3.fromRGB(120,120,175);lh.Font=Enum.Font.GothamBold
    lh.TextSize=9;lh.TextXAlignment=Enum.TextXAlignment.Left;lh.LayoutOrder=7

    local lf=Instance.new("ScrollingFrame",main)
    lf.Size=UDim2.new(1,0,0,130);lf.BackgroundColor3=Color3.fromRGB(12,12,20)
    lf.BorderSizePixel=0;lf.ScrollBarThickness=2
    lf.CanvasSize=UDim2.new(0,0,0,0);lf.AutomaticCanvasSize=Enum.AutomaticSize.Y
    lf.LayoutOrder=8
    Instance.new("UICorner",lf).CornerRadius=UDim.new(0,5)
    local ll=Instance.new("UIListLayout",lf)
    ll.SortOrder=Enum.SortOrder.LayoutOrder;ll.Padding=UDim.new(0,1)
    local lpad=Instance.new("UIPadding",lf)
    lpad.PaddingLeft=UDim.new(0,5);lpad.PaddingTop=UDim.new(0,3);lpad.PaddingRight=UDim.new(0,4)

    local logCount=0
    local function addLog(msg)
        logCount=logCount+1
        local e=Instance.new("TextLabel",lf)
        e.Size=UDim2.new(1,0,0,12);e.BackgroundTransparency=1;e.Text=msg
        e.TextColor3=Color3.fromRGB(180,180,200);e.Font=Enum.Font.Code;e.TextSize=9
        e.TextXAlignment=Enum.TextXAlignment.Left;e.TextTruncate=Enum.TextTruncate.AtEnd
        e.LayoutOrder=logCount
        task.defer(function()
            if lf and lf.Parent then lf.CanvasPosition=Vector2.new(0,lf.AbsoluteCanvasSize.Y) end
        end)
    end

    startBtn.MouseButton1Click:Connect(function()
        if isRunning then
            isRunning=false;stopReq=true
            stopSpeed();clearMode()
            startBtn.BackgroundColor3=Color3.fromRGB(45,160,65);startBtn.Text="START"
        else
            isRunning=true;stopReq=false
            startBtn.BackgroundColor3=Color3.fromRGB(180,38,38);startBtn.Text="STOP"
            setStatus("Memulai...");task.spawn(mainLoop)
        end
    end)

    local lastSt="";local lastLogN=0;local stTimer=0
    local function fmt(n)
        if n>=1e15 then return string.format("%.1fQd",n/1e15)
        elseif n>=1e12 then return string.format("%.1fT",n/1e12)
        elseif n>=1e9 then return string.format("%.1fB",n/1e9)
        elseif n>=1e6 then return string.format("%.1fM",n/1e6)
        elseif n>=1e3 then return string.format("%.1fK",n/1e3)
        else return tostring(math.floor(n)) end
    end

    RunService.Heartbeat:Connect(function(dt)
        if not sg.Parent then return end
        if statusText~=lastSt then lastSt=statusText;statusLbl.Text=statusText end
        if #logLines>lastLogN then
            for i=lastLogN+1,#logLines do addLog(logLines[i]) end
            lastLogN=#logLines
        end
        stTimer=stTimer+dt
        if stTimer>=2 then stTimer=0
            pcall(function()
                statLbl.Text=string.format(
                    "STR:%s  CHK:%s  DUR:%s\nSPD:%s  AGI:%s  SWD:%s",
                    fmt(getStat("Strength")),fmt(getStat("Chakra")),fmt(getStat("Durability")),
                    fmt(getStat("Speed")),fmt(getStat("Agility")),fmt(getStat("Sword")))
                local qs=getQuests()
                if #qs==0 then questLbl.Text="Quest: (tidak ada)"
                else
                    local lines={}
                    for _,q in ipairs(qs) do
                        local icon=q.isDone and "[V]" or ("[.]"..tostring(q.pct).."%")
                        table.insert(lines,icon.." "..q.name)
                    end
                    questLbl.Text=table.concat(lines,"\n")
                end
            end)
        end
    end)
end

buildGUI()
setStatus("Siap | input="..inputMethod)
print("[AutoQuest v7] input="..inputMethod)
