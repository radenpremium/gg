--[[
    AUTO TELEPORT MOB v3
    Alur:
      Tab kiri: Auto Farm (teleport mob) | Game Mode (Auto Dungeon) | Misc (Anti AFK)
      1. Klik "Scan Mob"  -> semua nama mob di workspace.World1.Enemy (nama kembar dijadikan 1)
      2. Dropdown 1       -> pilih 1 mob, berdiri di tempat yang diinginkan, klik "Save Posisi"
                             (boleh save berkali-kali untuk mob yang sama = banyak posisi, urut 1, 2, 3, ...)
      3. Dropdown 2       -> pilih mob target (boleh banyak, urutan = urutan kamu memilih)
      (Range attack: dibaca dari workspace.Radius_Client, hanya mob di dalam lingkaran merah yang dihitung)
      4. Start/Stop       -> teleport instan ke posisi mob 1, tunggu SEMUA mob bernama itu (dalam Radius dari titik save) mati (HP 0),
                             lalu langsung pindah ke posisi mob berikutnya, loop terus sampai di-Stop
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

----------------------------------------------------------------
-- PENGATURAN (boleh diubah)
----------------------------------------------------------------
local RETELEPORT_DISTANCE = 15    -- kalau karakter terdorong/respawn lebih jauh dari ini, balik ke titik save
local TELEPORT_SEBELUM_CEK = false -- true = teleport dulu baru cek mob (untuk game StreamingEnabled: mob jauh tidak ke-load)
local GRACE_TIME = 0.3            -- hanya dipakai kalau TELEPORT_SEBELUM_CEK = true (detik menunggu mob ter-load)
local SETTLE_TIME = 0.5           -- detik, mode Auto: jeda singkat setelah mob yang kena serang mati, untuk memastikan tidak ada mob lain yang mulai kena serang
local USE_RADIUS_CLIENT = true        -- true = pakai lingkaran range attack game (workspace.Radius_Client) sebagai batas deteksi mob
local RADIUS_CLIENT_NAME = "Radius_Client"
local RADIUS_CLIENT_SCALE = 1         -- kalikan radius lingkaran (misal 0.95 kalau mob di tepi lingkaran salah terdeteksi)
local DEFAULT_TIMEOUT = 20        -- detik, pindah paksa kalau jumlah mob tidak berubah selama ini (0 = nonaktif, bisa diubah di GUI)
local DEFAULT_RADIUS = 50         -- stud, hanya mob bernama sama yang jaraknya segini dari titik save yang dihitung (bisa diubah di GUI)

local function getEnemyFolder()
    local world = workspace:FindFirstChild("World1")
    return world and world:FindFirstChild("Enemy")
end

----------------------------------------------------------------
-- DATA
----------------------------------------------------------------
local savedPos = {}     -- savedPos[namaMob] = { CFrame1, CFrame2, ... } (satu mob bisa punya banyak posisi)
local savedOrder = {}   -- urutan nama mob yang sudah di-save
local running = false
local runToken = 0
local modeEngaged = false -- true = Auto (hanya mob yang kena seranganku), false = semua mob dalam lingkaran/radius
local dungeonLock = false   -- true saat sedang join/di dalam dungeon: Auto Farm dijeda
local farmWasRunning = false -- Auto Farm tadinya jalan, lanjut lagi setelah dungeon selesai
local radiusBox -- kolom Radius di GUI (dibuat di bawah)
local timeoutBox -- kolom Timeout di GUI (dibuat di bawah)

local function getRoot()
    local char = player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getTimeout()
    local n = timeoutBox and tonumber((tostring(timeoutBox.Text):gsub(",", ".")))
    if not n then n = DEFAULT_TIMEOUT end
    if n < 0 then n = 0 end
    return n
end

local function getRadius()
    local n = radiusBox and tonumber((tostring(radiusBox.Text):gsub(",", ".")))
    if not n or n < 1 then n = DEFAULT_RADIUS end
    return n
end

----------------------------------------------------------------
-- DETEKSI MOB
----------------------------------------------------------------
local HP_NAMES = { "Health", "HP", "health", "hp" }

-- Ambil semua model mob di folder Enemy
local function getMobModels()
    local folder = getEnemyFolder()
    local models = {}
    if not folder then return models, false end
    for _, d in ipairs(folder:GetDescendants()) do
        if d:IsA("Model") and (d.Parent == folder or d:FindFirstChildOfClass("Humanoid")) then
            table.insert(models, d)
        end
    end
    return models, true
end

local DEAD_FLAGS = { "Dead", "IsDead", "isDead", "Died" }

-- Baca HP mob. Mengembalikan (angka HP atau nil, keterangan singkat untuk debug)
-- Ambil semua angka dari nilai attribute (mendukung "0;750000000", angka, Vector2/3)
local function parseNumbers(value)
    local t = typeof(value)
    local nums = {}
    if t == "number" then
        nums[1] = value
    elseif t == "string" then
        for n in string.gmatch(value, "%-?%d+%.?%d*") do
            local x = tonumber(n)
            if x then table.insert(nums, x) end
        end
    elseif t == "Vector2" then
        nums = { value.X, value.Y }
    elseif t == "Vector3" then
        nums = { value.X, value.Y, value.Z }
    end
    return nums
end

local function readHP(model)
    -- Game ini: attribute "CurrentHP" berisi misalnya "0;750000000" (hidup) dan "0;0" (mati)
    local cur = model:GetAttribute("CurrentHP")
    if cur ~= nil then
        local nums = parseNumbers(cur)
        if #nums > 0 then
            local best = 0
            for _, x in ipairs(nums) do
                if x > best then best = x end
            end
            return best, "HP:" .. tostring(cur)
        end
    end

    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum then return hum.Health, string.format("H%.0f", hum.Health) end
    for _, n in ipairs(HP_NAMES) do
        local attr = model:GetAttribute(n)
        if type(attr) == "number" then
            return attr, string.format("A:%s=%.0f", n, attr)
        end
        local v = model:FindFirstChild(n)
        if v and (v:IsA("NumberValue") or v:IsA("IntValue")) then
            return v.Value, string.format("V:%s=%.0f", n, v.Value)
        end
    end
    return nil, "tanpa-HP"
end

-- Mob dianggap hidup kalau HP > 0 dan tidak ada penanda "Dead"
local function isAlive(model)
    if not model.Parent then return false end
    for _, f in ipairs(DEAD_FLAGS) do
        if model:GetAttribute(f) == true then return false end
        local v = model:FindFirstChild(f)
        if v and v:IsA("BoolValue") and v.Value then return false end
    end
    local hp = readHP(model)
    if hp ~= nil then return hp > 0 end

    -- tidak ada info HP: pakai penanda lain kalau ada
    if model:GetAttribute("Attackable") == false then return false end
    local reason = model:GetAttribute("DeathReason")
    if type(reason) == "string" and reason ~= "" then return false end

    return true -- tidak ada info apa pun: dianggap hidup selama modelnya masih ada di folder
end

-- Scan: daftar nama mob unik (nama kembar jadi 1)
local function scanMobNames()
    local models, ok = getMobModels()
    if not ok then return nil end
    local seen, names = {}, {}
    for _, m in ipairs(models) do
        if not seen[m.Name] then
            seen[m.Name] = true
            table.insert(names, m.Name)
        end
    end
    table.sort(names)
    return names
end

-- Pusat & radius deteksi.
-- Kalau lingkaran range attack game (Radius_Client) ada: pusat = posisi karakter (lingkaran mengikuti kamu),
-- radius = ukuran lingkaran / 2, jarak dihitung datar (abaikan tinggi).
-- Kalau tidak ada: pakai titik save + kolom Radius di GUI.
local function getEffectiveRange(fallbackCenter)
    if USE_RADIUS_CLIENT then
        local part = workspace:FindFirstChild(RADIUS_CLIENT_NAME)
        local root = getRoot()
        if part and part:IsA("BasePart") and root then
            local r = math.max(part.Size.X, part.Size.Z) / 2 * RADIUS_CLIENT_SCALE
            return root.Position, r, true
        end
    end
    return fallbackCenter, getRadius(), false
end

local function distanceTo(pos, center, flat)
    if flat then
        return Vector3.new(pos.X - center.X, 0, pos.Z - center.Z).Magnitude
    end
    return (pos - center).Magnitude
end

-- Hitung mob hidup dengan nama tertentu yang berada dalam radius dari titik save
-- Mengembalikan: jumlah, daftar keterangan (maks 3 mob, untuk debug)
local function countAlive(name, center, live)
    local models = getMobModels()
    local c, radius, flat = center, getRadius(), false
    if live then c, radius, flat = getEffectiveRange(center) end
    local count = 0
    local details = {}
    for _, m in ipairs(models) do
        if m.Name == name and isAlive(m) then
            local ok, pos = pcall(function() return m:GetPivot().Position end)
            if ok then
                local d = distanceTo(pos, c, flat)
                if d <= radius then
                    count += 1
                    if #details < 3 then
                        local _, info = readHP(m)
                        table.insert(details, string.format("%.0fst %s", d, info))
                    end
                end
            end
        end
    end
    return count, details
end

-- MODE AUTO: hanya hitung mob yang benar-benar kena seranganmu (HP-nya turun / mati setelah kamu tiba).
-- Mob di luar jangkauan seranganmu HP-nya tidak berubah, jadi diabaikan.
local function newTracker()
    local t = { initialHP = {}, prevHP = {}, engaged = {}, lastEngage = os.clock() }

    local function markEngaged(m)
        if not t.engaged[m] then
            t.engaged[m] = true
            t.lastEngage = os.clock()
        end
    end

    -- Mengembalikan: selesai?, mob hidup di radius, mob hidup yang kena serang, ada HP turun?, detail debug
    function t.update(name, center)
        local models = getMobModels()
        local c, radius, flat = getEffectiveRange(center)
        local aliveCount, pending, activity = 0, 0, false
        local details = {}

        for _, m in ipairs(models) do
            if m.Name == name then
                local ok, pos = pcall(function() return m:GetPivot().Position end)
                if ok then
                    local d = distanceTo(pos, c, flat)
                    if d <= radius then
                        local alive = isAlive(m)
                        local hp, info = readHP(m)

                        -- catat HP awal saat pertama terlihat hidup
                        if t.initialHP[m] == nil and alive then
                            t.initialHP[m] = hp or 0
                            t.prevHP[m] = hp or 0
                        end

                        if t.initialHP[m] ~= nil then
                            if not alive then
                                markEngaged(m) -- tadinya hidup, sekarang mati
                            elseif hp then
                                if hp < t.initialHP[m] then markEngaged(m) end
                                if hp < (t.prevHP[m] or hp) then activity = true end
                                t.prevHP[m] = hp
                            end
                        end

                        if alive then
                            aliveCount += 1
                            if t.engaged[m] then
                                pending += 1
                                if #details < 3 then
                                    table.insert(details, string.format("%.0fst %s", d, info))
                                end
                            end
                        end
                    end
                end
            end
        end

        -- mob yang dihapus dari game saat mati
        for m in pairs(t.initialHP) do
            if not m:IsDescendantOf(workspace) then markEngaged(m) end
        end

        if pending > 0 or activity then t.lastEngage = os.clock() end

        local anyEngaged = next(t.engaged) ~= nil
        local done = (aliveCount == 0)
            or (pending == 0 and anyEngaged and os.clock() - t.lastEngage >= SETTLE_TIME)

        return done, aliveCount, pending, activity, details
    end

    return t
end

----------------------------------------------------------------
-- GUI DASAR
----------------------------------------------------------------
local GUI_NAME = "AutoTeleportMobGUI"

local function getParent()
    local ok, result = pcall(function()
        if gethui then return gethui() end
        return game:GetService("CoreGui")
    end)
    if ok and result then return result end
    return player:WaitForChild("PlayerGui")
end

local parent = getParent()
local old = parent:FindFirstChild(GUI_NAME)
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parent

local SIDEBAR_W = 84   -- lebar kolom tab di kiri
local SIDEBAR_GAP = 4  -- jarak tab ke panel utama
local PANEL_W = 340
local FULL_SIZE = UDim2.new(0, PANEL_W, 0, 496)
local MINI_SIZE = UDim2.new(0, PANEL_W, 0, 32)

-- Root: wadah transparan berisi sidebar tab + panel utama (yang di-drag adalah root ini)
local root = Instance.new("Frame")
root.Name = "Root"
root.Size = UDim2.new(0, SIDEBAR_W + SIDEBAR_GAP + PANEL_W, 0, 496)
root.Position = UDim2.new(0.5, -(SIDEBAR_W + SIDEBAR_GAP + PANEL_W) / 2, 0.5, -248)
root.BackgroundTransparency = 1
root.BorderSizePixel = 0
root.Parent = gui

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = FULL_SIZE
main.Position = UDim2.new(0, SIDEBAR_W + SIDEBAR_GAP, 0, 0)
main.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
main.BorderSizePixel = 0
main.ClipsDescendants = true
main.Parent = root
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

-- Title bar
local title = Instance.new("Frame")
title.Name = "TitleBar"
title.Size = UDim2.new(1, 0, 0, 32)
title.BackgroundColor3 = Color3.fromRGB(45, 45, 58)
title.BorderSizePixel = 0
title.Parent = main

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -80, 1, 0)
titleLabel.Position = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Auto Teleport Mob"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 14
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = title

local function makeTitleButton(text, xOffset, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 28, 0, 22)
    b.Position = UDim2.new(1, xOffset, 0, 5)
    b.BackgroundColor3 = color
    b.Text = text
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.Parent = title
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    return b
end

local minBtn = makeTitleButton("-", -66, Color3.fromRGB(230, 170, 40))
local closeBtn = makeTitleButton("X", -34, Color3.fromRGB(210, 60, 60))

-- Semua isi GUI ada di sini (supaya gampang di-minimize)
local content = Instance.new("Frame")
content.Name = "Content"
content.Position = UDim2.new(0, 0, 0, 32)
content.Size = UDim2.new(1, 0, 1, -32)
content.BackgroundTransparency = 1
content.Parent = main

local function makeLabel(text, y)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -16, 0, 14)
    l.Position = UDim2.new(0, 8, 0, y)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = Color3.fromRGB(170, 170, 185)
    l.Font = Enum.Font.Gotham
    l.TextSize = 11
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = content
    return l
end

local function makeButton(text, x, y, w, h, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, w, 0, h)
    b.Position = UDim2.new(0, x, 0, y)
    b.BackgroundColor3 = color
    b.Text = text
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.Parent = content
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

----------------------------------------------------------------
-- DROPDOWN
----------------------------------------------------------------
local allDropdowns = {}
local COLOR_ITEM = Color3.fromRGB(45, 45, 60)
local COLOR_ITEM_SELECTED = Color3.fromRGB(60, 120, 220)
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_PLACEHOLDER = Color3.fromRGB(130, 130, 145)

local function createDropdown(yPos, placeholder, multi, openUp, parentFrame)
    parentFrame = parentFrame or content
    local dd = { selected = nil, order = {}, items = {}, isOpen = false }
    local itemButtons = {}

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -16, 0, 30)
    btn.Position = UDim2.new(0, 8, 0, yPos)
    btn.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 12
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.Text = placeholder
    btn.TextColor3 = COLOR_PLACEHOLDER
    btn.Parent = parentFrame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    local pad = Instance.new("UIPadding", btn)
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 24)

    local arrow = Instance.new("TextLabel")
    arrow.Size = UDim2.new(0, 20, 1, 0)
    arrow.Position = UDim2.new(1, -22, 0, 0)
    arrow.BackgroundTransparency = 1
    arrow.Text = "▼"
    arrow.TextColor3 = COLOR_PLACEHOLDER
    arrow.Font = Enum.Font.Gotham
    arrow.TextSize = 10
    arrow.Parent = btn

    local list = Instance.new("ScrollingFrame")
    list.Visible = false
    list.ZIndex = 50
    list.BackgroundColor3 = Color3.fromRGB(35, 35, 46)
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 4
    list.CanvasSize = UDim2.new(0, 0, 0, 0)
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.Parent = parentFrame
    Instance.new("UICorner", list).CornerRadius = UDim.new(0, 6)
    local listPad = Instance.new("UIPadding", list)
    listPad.PaddingTop = UDim.new(0, 3)
    listPad.PaddingBottom = UDim.new(0, 3)
    listPad.PaddingLeft = UDim.new(0, 3)
    listPad.PaddingRight = UDim.new(0, 3)
    local layout = Instance.new("UIListLayout", list)
    layout.Padding = UDim.new(0, 2)
    layout.SortOrder = Enum.SortOrder.LayoutOrder

    local emptyLabel = Instance.new("TextLabel")
    emptyLabel.Size = UDim2.new(1, -6, 0, 26)
    emptyLabel.BackgroundTransparency = 1
    emptyLabel.Text = "Belum ada mob. Klik Scan Mob."
    emptyLabel.TextColor3 = COLOR_PLACEHOLDER
    emptyLabel.Font = Enum.Font.Gotham
    emptyLabel.TextSize = 12
    emptyLabel.LayoutOrder = 0
    emptyLabel.Parent = list

    local function refreshText()
        local has
        if multi then
            has = #dd.order > 0
            btn.Text = has and (#dd.order .. " dipilih: " .. table.concat(dd.order, ", ")) or placeholder
        else
            has = dd.selected ~= nil
            btn.Text = dd.selected or placeholder
        end
        btn.TextColor3 = has and COLOR_TEXT or COLOR_PLACEHOLDER
    end

    local function refreshItems()
        for _, name in ipairs(dd.items) do
            local b = itemButtons[name]
            if b then
                if multi then
                    local idx = table.find(dd.order, name)
                    b.Text = idx and (idx .. ". " .. name) or name
                    b.BackgroundColor3 = idx and COLOR_ITEM_SELECTED or COLOR_ITEM
                else
                    b.BackgroundColor3 = (dd.selected == name) and COLOR_ITEM_SELECTED or COLOR_ITEM
                end
            end
        end
    end

    function dd.close()
        list.Visible = false
        arrow.Text = "▼"
        dd.isOpen = false
    end

    function dd.open()
        for _, other in ipairs(allDropdowns) do
            if other ~= dd then other.close() end
        end
        local count = math.max(#dd.items, 1)
        local h = math.min(count * 28 + 6, 150)
        list.Size = UDim2.new(1, -16, 0, h)
        list.Position = UDim2.new(0, 8, 0, openUp and (yPos - 2 - h) or (yPos + 32))
        list.Visible = true
        arrow.Text = "▲"
        dd.isOpen = true
    end

    btn.MouseButton1Click:Connect(function()
        if dd.isOpen then dd.close() else dd.open() end
    end)

    function dd.setItems(names)
        for _, b in pairs(itemButtons) do b:Destroy() end
        itemButtons = {}
        dd.items = names
        emptyLabel.Visible = (#names == 0)

        -- buang pilihan yang sudah tidak ada di daftar baru
        local exists = {}
        for _, n in ipairs(names) do exists[n] = true end
        if dd.selected and not exists[dd.selected] then dd.selected = nil end
        local newOrder = {}
        for _, n in ipairs(dd.order) do
            if exists[n] then table.insert(newOrder, n) end
        end
        dd.order = newOrder

        for k, name in ipairs(names) do
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, -6, 0, 26)
            b.BackgroundColor3 = COLOR_ITEM
            b.BorderSizePixel = 0
            b.Text = name
            b.TextColor3 = COLOR_TEXT
            b.Font = Enum.Font.Gotham
            b.TextSize = 12
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.TextTruncate = Enum.TextTruncate.AtEnd
            b.LayoutOrder = k
            b.Parent = list
            Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
            local bp = Instance.new("UIPadding", b)
            bp.PaddingLeft = UDim.new(0, 8)
            itemButtons[name] = b

            b.MouseButton1Click:Connect(function()
                if multi then
                    local idx = table.find(dd.order, name)
                    if idx then table.remove(dd.order, idx) else table.insert(dd.order, name) end
                    refreshItems()
                    refreshText()
                else
                    dd.selected = name
                    refreshItems()
                    refreshText()
                    dd.close()
                end
            end)
        end

        refreshItems()
        refreshText()
    end

    function dd.getOrder()
        local copy = {}
        for _, n in ipairs(dd.order) do table.insert(copy, n) end
        return copy
    end

    function dd.select(name)
        if not multi then
            dd.selected = name
            refreshItems()
            refreshText()
        end
    end

    table.insert(allDropdowns, dd)
    return dd
end

local function closeAllDropdowns()
    for _, d in ipairs(allDropdowns) do d.close() end
end

----------------------------------------------------------------
-- ISI GUI (urutan dari atas ke bawah)
----------------------------------------------------------------
-- 1. Scan Mob
local scanBtn = makeButton("Scan Mob", 8, 8, 120, 30, Color3.fromRGB(140, 90, 210))

local scanInfo = Instance.new("TextLabel")
scanInfo.Size = UDim2.new(0, 60, 0, 30)
scanInfo.Position = UDim2.new(0, 134, 0, 8)
scanInfo.BackgroundTransparency = 1
scanInfo.Text = "0 mob"
scanInfo.TextColor3 = Color3.fromRGB(200, 200, 210)
scanInfo.Font = Enum.Font.Gotham
scanInfo.TextSize = 12
scanInfo.TextXAlignment = Enum.TextXAlignment.Left
scanInfo.Parent = content

local radiusLabel = Instance.new("TextLabel")
radiusLabel.Size = UDim2.new(0, 44, 0, 30)
radiusLabel.Position = UDim2.new(0, 196, 0, 8)
radiusLabel.BackgroundTransparency = 1
radiusLabel.Text = "Radius"
radiusLabel.TextColor3 = Color3.fromRGB(170, 170, 185)
radiusLabel.Font = Enum.Font.Gotham
radiusLabel.TextSize = 12
radiusLabel.TextXAlignment = Enum.TextXAlignment.Left
radiusLabel.Parent = content

radiusBox = Instance.new("TextBox")
radiusBox.Size = UDim2.new(0, 90, 0, 26)
radiusBox.Position = UDim2.new(0, 242, 0, 10)
radiusBox.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
radiusBox.Text = tostring(DEFAULT_RADIUS)
radiusBox.TextColor3 = Color3.fromRGB(255, 255, 255)
radiusBox.Font = Enum.Font.Gotham
radiusBox.TextSize = 12
radiusBox.ClearTextOnFocus = false
radiusBox.Parent = content
Instance.new("UICorner", radiusBox).CornerRadius = UDim.new(0, 5)

-- 2. Dropdown 1 (single select) + 3. Save Posisi
makeLabel("Pilih mob untuk save posisi", 44)
local dd1 = createDropdown(60, "Pilih mob...", false, false)
local saveBtn = makeButton("Save Posisi", 8, 96, 324, 30, Color3.fromRGB(60, 120, 220))

-- 4. Keterangan mob & posisi tersimpan
makeLabel("Mob & posisi tersimpan", 132)
local infoList = Instance.new("ScrollingFrame")
infoList.Position = UDim2.new(0, 8, 0, 148)
infoList.Size = UDim2.new(1, -16, 0, 100)
infoList.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
infoList.BorderSizePixel = 0
infoList.ScrollBarThickness = 4
infoList.CanvasSize = UDim2.new(0, 0, 0, 0)
infoList.AutomaticCanvasSize = Enum.AutomaticSize.Y
infoList.Parent = content
Instance.new("UICorner", infoList).CornerRadius = UDim.new(0, 6)
local infoPad = Instance.new("UIPadding", infoList)
infoPad.PaddingTop = UDim.new(0, 3)
infoPad.PaddingBottom = UDim.new(0, 3)
infoPad.PaddingLeft = UDim.new(0, 3)
infoPad.PaddingRight = UDim.new(0, 3)
local infoLayout = Instance.new("UIListLayout", infoList)
infoLayout.Padding = UDim.new(0, 2)
infoLayout.SortOrder = Enum.SortOrder.LayoutOrder

-- 5. Dropdown 2 (multi select, terbuka ke atas supaya muat)
makeLabel("Target auto teleport (urutan = urutan pilih)", 254)
local dd2 = createDropdown(270, "Pilih mob target...", true, true)

-- 6. Timeout (pindah paksa kalau macet)
local timeoutLabel = Instance.new("TextLabel")
timeoutLabel.Size = UDim2.new(0, 190, 0, 26)
timeoutLabel.Position = UDim2.new(0, 8, 0, 306)
timeoutLabel.BackgroundTransparency = 1
timeoutLabel.Text = "Pindah paksa jika macet (detik):"
timeoutLabel.TextColor3 = Color3.fromRGB(170, 170, 185)
timeoutLabel.Font = Enum.Font.Gotham
timeoutLabel.TextSize = 11
timeoutLabel.TextXAlignment = Enum.TextXAlignment.Left
timeoutLabel.Parent = content

timeoutBox = Instance.new("TextBox")
timeoutBox.Size = UDim2.new(0, 60, 0, 26)
timeoutBox.Position = UDim2.new(0, 200, 0, 306)
timeoutBox.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
timeoutBox.Text = tostring(DEFAULT_TIMEOUT)
timeoutBox.TextColor3 = Color3.fromRGB(255, 255, 255)
timeoutBox.Font = Enum.Font.Gotham
timeoutBox.TextSize = 12
timeoutBox.ClearTextOnFocus = false
timeoutBox.Parent = content
Instance.new("UICorner", timeoutBox).CornerRadius = UDim.new(0, 5)

local timeoutHint = Instance.new("TextLabel")
timeoutHint.Size = UDim2.new(0, 66, 0, 26)
timeoutHint.Position = UDim2.new(0, 266, 0, 306)
timeoutHint.BackgroundTransparency = 1
timeoutHint.Text = "0 = nonaktif"
timeoutHint.TextColor3 = COLOR_PLACEHOLDER
timeoutHint.Font = Enum.Font.Gotham
timeoutHint.TextSize = 10
timeoutHint.TextXAlignment = Enum.TextXAlignment.Left
timeoutHint.Parent = content

-- Mode deteksi (toggle)
local modeBtn = makeButton("", 8, 334, 324, 26, Color3.fromRGB(50, 130, 90))
modeBtn.TextSize = 12

local function refreshModeBtn()
    if modeEngaged then
        modeBtn.Text = "Mode: Auto (hanya mob yang kena seranganku)"
        modeBtn.BackgroundColor3 = Color3.fromRGB(50, 130, 90)
    else
        modeBtn.Text = "Mode: Semua mob dalam radius"
        modeBtn.BackgroundColor3 = Color3.fromRGB(90, 90, 105)
    end
end
refreshModeBtn()

modeBtn.MouseButton1Click:Connect(function()
    modeEngaged = not modeEngaged
    refreshModeBtn()
end)

-- 7. Status + debug
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -16, 0, 18)
statusLabel.Position = UDim2.new(0, 8, 0, 364)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Status: berhenti"
statusLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Parent = content

local function setStatus(text)
    local full = "Status: " .. text
    if statusLabel.Text ~= full then statusLabel.Text = full end
end

local debugLabel = Instance.new("TextLabel")
debugLabel.Size = UDim2.new(1, -16, 0, 30)
debugLabel.Position = UDim2.new(0, 8, 0, 382)
debugLabel.BackgroundTransparency = 1
debugLabel.Text = ""
debugLabel.TextColor3 = Color3.fromRGB(140, 140, 155)
debugLabel.Font = Enum.Font.Code
debugLabel.TextSize = 10
debugLabel.TextWrapped = true
debugLabel.TextXAlignment = Enum.TextXAlignment.Left
debugLabel.TextYAlignment = Enum.TextYAlignment.Top
debugLabel.Parent = content

local function setDebug(text)
    if debugLabel.Text ~= text then debugLabel.Text = text end
end

-- 8. Start / Stop
local toggleBtn = makeButton("START AUTO MOB", 8, 416, 324, 40, Color3.fromRGB(50, 170, 90))
toggleBtn.TextSize = 14

----------------------------------------------------------------
-- LIST POSISI TERSIMPAN
----------------------------------------------------------------
local function refreshSavedList()
    for _, c in ipairs(infoList:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
    end

    if #savedOrder == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, -6, 0, 24)
        empty.BackgroundTransparency = 1
        empty.Text = "Belum ada posisi tersimpan"
        empty.TextColor3 = COLOR_PLACEHOLDER
        empty.Font = Enum.Font.Gotham
        empty.TextSize = 12
        empty.Parent = infoList
        return
    end

    local k = 0
    for _, name in ipairs(savedOrder) do
        for idx, cf in ipairs(savedPos[name] or {}) do
            k += 1
            local p = cf.Position

            local row = Instance.new("Frame")
            row.Size = UDim2.new(1, -6, 0, 24)
            row.BackgroundColor3 = Color3.fromRGB(50, 50, 66)
            row.BorderSizePixel = 0
            row.LayoutOrder = k
            row.Parent = infoList
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

            local txt = Instance.new("TextLabel")
            txt.Size = UDim2.new(1, -30, 1, 0)
            txt.Position = UDim2.new(0, 6, 0, 0)
            txt.BackgroundTransparency = 1
            txt.Text = string.format("%s (%d)  (%.0f, %.0f, %.0f)", name, idx, p.X, p.Y, p.Z)
            txt.TextColor3 = Color3.fromRGB(90, 220, 120)
            txt.Font = Enum.Font.Gotham
            txt.TextSize = 11
            txt.TextXAlignment = Enum.TextXAlignment.Left
            txt.TextTruncate = Enum.TextTruncate.AtEnd
            txt.Parent = row

            local del = Instance.new("TextButton")
            del.Size = UDim2.new(0, 22, 0, 18)
            del.Position = UDim2.new(1, -25, 0, 3)
            del.BackgroundColor3 = Color3.fromRGB(190, 60, 60)
            del.Text = "X"
            del.TextColor3 = COLOR_TEXT
            del.Font = Enum.Font.GothamBold
            del.TextSize = 11
            del.Parent = row
            Instance.new("UICorner", del).CornerRadius = UDim.new(0, 4)

            del.MouseButton1Click:Connect(function()
                local list = savedPos[name]
                if list then
                    table.remove(list, idx)
                    if #list == 0 then
                        savedPos[name] = nil
                        local o = table.find(savedOrder, name)
                        if o then table.remove(savedOrder, o) end
                    end
                end
                refreshSavedList()
            end)
        end
    end
end

refreshSavedList()

----------------------------------------------------------------
-- SCAN & SAVE
----------------------------------------------------------------
scanBtn.MouseButton1Click:Connect(function()
    local names = scanMobNames()
    if not names then
        setStatus("folder workspace.World1.Enemy tidak ditemukan")
        return
    end
    dd1.setItems(names)
    dd2.setItems(names) -- dropdown 1 dan 2 memakai daftar yang sama
    scanInfo.Text = #names .. " mob"
    setStatus("scan selesai, " .. #names .. " nama mob")
end)

saveBtn.MouseButton1Click:Connect(function()
    local name = dd1.selected
    if not name then
        setStatus("pilih mob di dropdown atas dulu")
        return
    end
    local root = getRoot()
    if not root then
        setStatus("karakter tidak ditemukan")
        return
    end
    if not savedPos[name] then savedPos[name] = {} end
    table.insert(savedPos[name], root.CFrame)
    if not table.find(savedOrder, name) then
        table.insert(savedOrder, name)
    end
    refreshSavedList()
    setStatus(string.format("posisi %s ke-%d tersimpan", name, #savedPos[name]))
end)

----------------------------------------------------------------
-- AUTO TELEPORT
----------------------------------------------------------------
local function setButtonState(isRunning)
    if isRunning then
        toggleBtn.Text = "STOP AUTO MOB"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(210, 60, 60)
    else
        toggleBtn.Text = "START AUTO MOB"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(50, 170, 90)
    end
end

local function stopAuto()
    running = false
    runToken += 1
    setButtonState(false)
    setStatus("berhenti")
    setDebug("")
end

local function startAuto()
    if dungeonLock then
        farmWasRunning = true -- akan jalan otomatis setelah dungeon selesai
        setStatus("ditahan: sedang dungeon, lanjut otomatis setelah selesai")
        return
    end
    local order = dd2.getOrder()
    if #order == 0 then
        setStatus("pilih mob target di dropdown bawah dulu")
        return
    end
    local anySaved = false
    for _, name in ipairs(order) do
        if savedPos[name] then anySaved = true break end
    end
    if not anySaved then
        setStatus("mob target belum ada posisi tersimpan")
        return
    end

    closeAllDropdowns()
    running = true
    runToken += 1
    local myToken = runToken
    setButtonState(true)

    local function alive()
        return running and runToken == myToken
    end

    -- teleport instan; kalau karakter belum ada (respawn) tunggu dulu
    local function teleportTo(cf)
        local root = getRoot()
        while not root and alive() do
            RunService.Heartbeat:Wait()
            root = getRoot()
        end
        if root then root.CFrame = cf end
    end

    task.spawn(function()
        while alive() do
            local didFight = false

            for _, name in ipairs(dd2.getOrder()) do
                if not alive() then break end

                local copy = {}
                for _, c in ipairs(savedPos[name] or {}) do table.insert(copy, c) end

                for posIdx, cf in ipairs(copy) do
                    if not alive() then break end
                    local center = cf.Position

                    if TELEPORT_SEBELUM_CEK then
                        teleportTo(cf)
                        local t = 0
                        while alive() and t < GRACE_TIME and countAlive(name, center) == 0 do
                            t += RunService.Heartbeat:Wait()
                        end
                    end

                    local sisa = countAlive(name, center)
                    if sisa > 0 then
                        if not TELEPORT_SEBELUM_CEK then teleportTo(cf) end
                        didFight = true

                        -- tunggu semua mob dengan nama ini mati (HP 0), lalu langsung lanjut
                        local tracker = newTracker()
                        local lastSisa, lastChange = sisa, os.clock()
                        while alive() do
                            local detail, activity = {}, false
                            local statusText

                            if modeEngaged then
                                -- Auto: selesai kalau semua mob yang kena seranganku sudah mati
                                local done, aliveCount, pending, act, det = tracker.update(name, center)
                                if done then break end
                                sisa, detail, activity = aliveCount, det, act
                                statusText = string.format("%s (%d/%d) | hidup: %d, kena serang: %d",
                                    name, posIdx, #copy, sisa, pending)
                            else
                                -- Radius: selesai kalau semua mob bernama itu dalam radius sudah mati
                                sisa, detail = countAlive(name, center, true)
                                if sisa == 0 then break end
                                statusText = string.format("%s (%d/%d) | mob tersisa: %d",
                                    name, posIdx, #copy, sisa)
                            end

                            -- macet: tidak ada perubahan (jumlah mob / HP) terlalu lama -> pindah paksa
                            if sisa ~= lastSisa or activity then
                                lastSisa, lastChange = sisa, os.clock()
                            end
                            local limit = getTimeout()
                            if limit > 0 and os.clock() - lastChange > limit then
                                setStatus(name .. " macet, pindah paksa")
                                break
                            end

                            setStatus(statusText)
                            local _, rr, isCircle = getEffectiveRange(center)
                            local tag = string.format("[%s R%.0f] ", isCircle and "lingkaran" or "radius", rr)
                            setDebug(tag .. table.concat(detail, "  |  "))

                            local r = getRoot()
                            if r and (r.Position - center).Magnitude > RETELEPORT_DISTANCE then
                                r.CFrame = cf
                            end
                            RunService.Heartbeat:Wait()
                        end
                        setDebug("")
                    end
                end
            end

            if alive() and not didFight then
                setStatus("semua target mati / belum respawn, menunggu...")
            end
            RunService.Heartbeat:Wait()
        end
    end)
end

toggleBtn.MouseButton1Click:Connect(function()
    if running then stopAuto() else startAuto() end
end)

----------------------------------------------------------------
-- ANTI AFK (logika dari script Anti AFK: tekan LeftShift tiap 30 detik)
----------------------------------------------------------------
local okVIM, VirtualInputManager = pcall(function()
    return game:GetService("VirtualInputManager")
end)

local AntiAFK = false
local afkThread

local function simulateInput()
    if not okVIM then return end
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
        task.wait(0.1)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
    end)
end

local function StartAntiAFK()
    if AntiAFK then return end
    AntiAFK = true

    afkThread = task.spawn(function()
        while AntiAFK do
            simulateInput()
            task.wait(30)
        end
    end)
end

local function StopAntiAFK()
    AntiAFK = false

    if afkThread then
        pcall(task.cancel, afkThread)
        afkThread = nil
    end
end

----------------------------------------------------------------
-- HALAMAN TAB
----------------------------------------------------------------
local function newPage()
    local f = Instance.new("Frame")
    f.Position = UDim2.new(0, 0, 0, 32)
    f.Size = UDim2.new(1, 0, 1, -32)
    f.BackgroundTransparency = 1
    f.Visible = false
    f.Parent = main
    return f
end

local pageGame = newPage() -- Game Mode: kosong dulu
local pageMisc = newPage() -- Misc: Anti AFK

-- Misc: baris Anti AFK dengan checkbox
local afkRow = Instance.new("Frame")
afkRow.Size = UDim2.new(1, -16, 0, 56)
afkRow.Position = UDim2.new(0, 8, 0, 8)
afkRow.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
afkRow.BorderSizePixel = 0
afkRow.Parent = pageMisc
Instance.new("UICorner", afkRow).CornerRadius = UDim.new(0, 8)

local checkBox = Instance.new("TextButton")
checkBox.Size = UDim2.new(0, 28, 0, 28)
checkBox.Position = UDim2.new(0, 12, 0.5, -14)
checkBox.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
checkBox.Text = ""
checkBox.TextColor3 = Color3.fromRGB(255, 255, 255)
checkBox.Font = Enum.Font.GothamBold
checkBox.TextSize = 18
checkBox.AutoButtonColor = false
checkBox.Parent = afkRow
Instance.new("UICorner", checkBox).CornerRadius = UDim.new(0, 6)
local checkStroke = Instance.new("UIStroke")
checkStroke.Thickness = 2
checkStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
checkStroke.Color = Color3.fromRGB(110, 110, 125)
checkStroke.Parent = checkBox

local afkTitle = Instance.new("TextLabel")
afkTitle.Size = UDim2.new(1, -64, 0, 20)
afkTitle.Position = UDim2.new(0, 52, 0, 8)
afkTitle.BackgroundTransparency = 1
afkTitle.Text = "Anti AFK"
afkTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
afkTitle.Font = Enum.Font.GothamBold
afkTitle.TextSize = 14
afkTitle.TextXAlignment = Enum.TextXAlignment.Left
afkTitle.Parent = afkRow

local afkDesc = Instance.new("TextLabel")
afkDesc.Size = UDim2.new(1, -64, 0, 18)
afkDesc.Position = UDim2.new(0, 52, 0, 29)
afkDesc.BackgroundTransparency = 1
afkDesc.Text = "Cegah kick AFK (simulasi tombol tiap 30 detik)"
afkDesc.TextColor3 = Color3.fromRGB(150, 150, 165)
afkDesc.Font = Enum.Font.Gotham
afkDesc.TextSize = 11
afkDesc.TextXAlignment = Enum.TextXAlignment.Left
afkDesc.TextTruncate = Enum.TextTruncate.AtEnd
afkDesc.Parent = afkRow

local function refreshAfkBox()
    if AntiAFK then
        checkBox.Text = "✔"
        checkBox.BackgroundColor3 = Color3.fromRGB(50, 170, 90)
        checkStroke.Color = Color3.fromRGB(50, 170, 90)
    else
        checkBox.Text = ""
        checkBox.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
        checkStroke.Color = Color3.fromRGB(110, 110, 125)
    end
end

checkBox.MouseButton1Click:Connect(function()
    if AntiAFK then StopAntiAFK() else StartAntiAFK() end
    refreshAfkBox()
end)

----------------------------------------------------------------
-- SIDEBAR TAB (kiri)
----------------------------------------------------------------
local sidebar = Instance.new("Frame")
sidebar.Name = "Sidebar"
sidebar.Position = UDim2.new(0, 0, 0, 36)
sidebar.Size = UDim2.new(0, SIDEBAR_W, 1, -36)
sidebar.BackgroundTransparency = 1
sidebar.Parent = root
local sideLayout = Instance.new("UIListLayout", sidebar)
sideLayout.Padding = UDim.new(0, 5)
sideLayout.SortOrder = Enum.SortOrder.LayoutOrder

local pages = { ["farm"] = content, ["game"] = pageGame, ["misc"] = pageMisc }
local tabButtons = {}
local currentTab = "farm"
local minimized = false

local COLOR_TAB_ACTIVE = Color3.fromRGB(237, 28, 36)
local COLOR_TAB_IDLE = Color3.fromRGB(255, 255, 255)

local function applyTabs()
    sidebar.Visible = not minimized
    for key, page in pairs(pages) do
        page.Visible = (not minimized) and key == currentTab
    end
    for key, b in pairs(tabButtons) do
        local active = (key == currentTab)
        b.BackgroundColor3 = active and COLOR_TAB_ACTIVE or COLOR_TAB_IDLE
        b.TextColor3 = active and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(20, 20, 20)
    end
end

local function selectTab(key)
    currentTab = key
    closeAllDropdowns()
    applyTabs()
end

local function makeTab(key, text, order)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 38)
    b.Text = text
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.AutoButtonColor = false
    b.LayoutOrder = order
    b.Parent = sidebar
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
    b.MouseButton1Click:Connect(function() selectTab(key) end)
    tabButtons[key] = b
end

makeTab("farm", "Auto Farm", 1)
makeTab("game", "Game Mode", 2)
makeTab("misc", "Misc", 3)
applyTabs()

----------------------------------------------------------------
-- GAME MODE: AUTO DUNGEON
----------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Daftar dungeon / difficulty (tambah baris baru kalau nanti ada difficulty baru)
local DUNGEONS = {
    { label = "Easy", id = "EasyDungeon", model = "EasyDungeon" }, -- model = workspace.EasyDungeon (berisi folder Rooms)
}

-- PENGATURAN DUNGEON (boleh diubah)
local DUNGEON_INTERVAL_MIN = 30     -- dungeon dibuka tiap 30 menit (menit 00 dan 30 dihitung dari jam server)
local DUNGEON_OFFSET_SEC = 0        -- geser jadwal (detik) kalau dungeon tidak persis di :00 / :30
local JOIN_WINDOW = 30              -- lama popup join terbuka (detik)
local JOIN_LEAD = 15                -- mulai kirim join sekian detik SEBELUM dungeon dibuka
local JOIN_SPAM_INTERVAL = 1        -- jeda antar kirim join (detik), jangan terlalu kecil supaya tidak lag
local JOIN_BURST_AFTER_PROMPT = 3   -- setelah popup muncul, kirim join sekian kali lalu berhenti
local JOIN_GRACE = 45               -- kalau sekian detik setelah dibuka belum masuk, menyerah & auto farm lanjut
local DUNGEON_TIME_LIMIT = 900      -- batas waktu dungeon (detik), pengaman supaya auto farm tidak dijeda selamanya
local DUNGEON_ROOM_MARGIN = 60      -- toleransi (stud) di sekitar room dungeon untuk dianggap "di dalam"
local DUNGEON_AWAY_DISTANCE = 300   -- pindah sejauh ini dari posisi awal = dianggap sudah masuk dungeon
local END_WORDS = { "end", "finish", "complete", "over", "result", "win", "lose", "fail", "exit", "leave" }

local dungeon = {
    enabled = false,
    phase = "idle",        -- idle | joining | inside
    key = nil,             -- penanda jadwal yang sedang ditangani (supaya tidak join dua kali di jadwal yang sama)
    windowStart = 0,
    lastFire = 0,
    promptSeen = false,
    burst = 0,
    startSeen = false,
    endSeen = false,
    startedAt = 0,
    prePos = nil,
    modelSeen = false,
    wasAway = false,
    outsideSince = nil,
    handled = {},
    lastPrompt = nil,
    lastEvent = "-",
    offset = DUNGEON_OFFSET_SEC,
    note = "",
    err = nil,
}
local roomInfo = { inside = nil, found = false, t = 0 }
local answerRemote = nil
local dungeonReady = false
local dungeonFailed = false
local dungeonConns = {}
local ddDungeon -- dropdown difficulty (dibuat di bawah)

local function serverNow()
    return workspace:GetServerTimeNow()
end

local function getSelectedDungeon()
    local label = ddDungeon and ddDungeon.selected
    for _, d in ipairs(DUNGEONS) do
        if d.label == label then return d end
    end
    return DUNGEONS[1]
end

-- Folder Rooms dungeon: workspace.<model>.Rooms (isinya kosong kalau dungeon tidak sedang berjalan)
local function getRooms(d)
    local dm = workspace:FindFirstChild(d.model)
    return dm and dm:FindFirstChild("Rooms")
end

-- Kotak (CFrame, ukuran) sebuah room
local function boundsOf(inst)
    if inst:IsA("Model") then
        local ok, cf, size = pcall(function() return inst:GetBoundingBox() end)
        if ok then return cf, size end
    elseif inst:IsA("BasePart") then
        return inst.CFrame, inst.Size
    else
        -- Folder / lainnya: gabungkan semua part di dalamnya (kotak sejajar sumbu)
        local minV, maxV
        for _, p in ipairs(inst:GetDescendants()) do
            if p:IsA("BasePart") then
                local r = p.Size.Magnitude / 2
                local lo = p.Position - Vector3.new(r, r, r)
                local hi = p.Position + Vector3.new(r, r, r)
                minV = minV and Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z)) or lo
                maxV = maxV and Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z)) or hi
            end
        end
        if minV then return CFrame.new((minV + maxV) / 2), maxV - minV end
    end
    return nil
end

-- Mengembalikan: (posisimu di dalam salah satu room? true/false/nil), (dungeon sedang berjalan = Rooms berisi?)
local function insideRoom(d)
    local rooms = getRooms(d)
    if not rooms then return nil, false end
    local kids = rooms:GetChildren()
    if #kids == 0 then return nil, false end -- folder kosong = dungeon tidak aktif

    local root = getRoot()
    if not root then return false, true end

    local m = DUNGEON_ROOM_MARGIN
    for _, room in ipairs(kids) do
        local cf, size = boundsOf(room)
        if cf then
            local rel = cf:PointToObjectSpace(root.Position)
            if math.abs(rel.X) <= size.X / 2 + m
                and math.abs(rel.Y) <= size.Y / 2 + m
                and math.abs(rel.Z) <= size.Z / 2 + m then
                return true, true
            end
        end
    end
    return false, true
end

local function refreshRoom(d)
    local inside, found = insideRoom(d)
    roomInfo.inside, roomInfo.found, roomInfo.t = inside, found, os.clock()
end

local function awayFromPre()
    local root = getRoot()
    return root ~= nil and dungeon.prePos ~= nil
        and (root.Position - dungeon.prePos).Magnitude > DUNGEON_AWAY_DISTANCE
end

local function fireJoin(d)
    dungeon.lastFire = os.clock()
    if not answerRemote then return end
    pcall(function() answerRemote:FireServer(d.id, true) end)
end

-- Jeda / lanjutkan Auto Farm (supaya tidak teleport keluar dari dungeon)
local function pauseFarmForDungeon()
    dungeonLock = true
    if running then
        farmWasRunning = true
        stopAuto()
    end
    setStatus("dijeda: dungeon")
end

local function resumeFarmAfterDungeon()
    dungeonLock = false
    if farmWasRunning then
        farmWasRunning = false
        startAuto()
    end
end

local function beginJoin(d, windowStart, key)
    dungeon.phase = "joining"
    dungeon.windowStart = windowStart
    dungeon.key = key
    dungeon.promptSeen = false
    dungeon.burst = 0
    dungeon.startSeen = false
    dungeon.endSeen = false
    dungeon.lastFire = 0
    dungeon.modelSeen = false
    dungeon.wasAway = false
    dungeon.outsideSince = nil
    dungeon.note = ""
    local root = getRoot()
    dungeon.prePos = root and root.Position or nil
    pauseFarmForDungeon()
end

local function goInside(key, t)
    dungeon.phase = "inside"
    dungeon.startedAt = t
    dungeon.handled[key] = true
    dungeon.modelSeen = roomInfo.found
    dungeon.endSeen = false
    dungeon.outsideSince = nil
    if not dungeon.prePos then
        local root = getRoot()
        dungeon.prePos = root and root.Position or nil
    end
    dungeon.wasAway = awayFromPre()
    dungeon.note = ""
    pauseFarmForDungeon()
end

local function dungeonFinish(note)
    dungeon.phase = "idle"
    dungeon.outsideSince = nil
    dungeon.note = note or ""
    resumeFarmAfterDungeon()
end

local function dungeonReset()
    dungeon.phase = "idle"
    dungeon.outsideSince = nil
    dungeon.note = ""
    resumeFarmAfterDungeon()
end

-- Event dari game
local function onPrompt(id)
    if typeof(id) ~= "string" then return end
    local t = serverNow()
    dungeon.lastPrompt = t
    local d = getSelectedDungeon()
    if not dungeon.enabled or id ~= d.id then return end

    -- kalibrasi jadwal kalau popup muncul jauh dari perkiraan
    local interval = DUNGEON_INTERVAL_MIN * 60
    local m = (t - dungeon.offset) % interval
    if m > 25 and m < interval - 25 then
        dungeon.offset = t % interval
    end

    if dungeon.phase == "idle" then
        local base = math.floor((t - dungeon.offset) / interval) * interval + dungeon.offset
        local key = (t - base < JOIN_GRACE) and base or t
        if not dungeon.handled[key] then
            beginJoin(d, t, key)
        end
    end

    if dungeon.phase == "joining" and not dungeon.promptSeen then
        dungeon.promptSeen = true
        dungeon.burst = 1
        fireJoin(d)
    end
end

local function onStart()
    dungeon.startSeen = true
    dungeon.lastEvent = "Start " .. os.date("%H:%M:%S")
end

local function onOtherEvent(name)
    dungeon.lastEvent = name .. " " .. os.date("%H:%M:%S")
    local lname = string.lower(name)
    for _, w in ipairs(END_WORDS) do
        if string.find(lname, w, 1, true) then
            if dungeon.phase == "inside" then dungeon.endSeen = true end
            break
        end
    end
end

-- Hubungkan ke remote dungeon (tidak memblokir GUI)
task.spawn(function()
    local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
    local folder = remotes and remotes:WaitForChild("Dungeons", 10)
    if not folder then dungeonFailed = true return end

    answerRemote = folder:FindFirstChild("Answer")
    local promptR = folder:FindFirstChild("Prompt")
    local startR = folder:FindFirstChild("Start")
    if not (answerRemote and promptR) then dungeonFailed = true return end

    table.insert(dungeonConns, promptR.OnClientEvent:Connect(onPrompt))
    if startR then
        table.insert(dungeonConns, startR.OnClientEvent:Connect(onStart))
    end
    for _, r in ipairs(folder:GetChildren()) do
        if r:IsA("RemoteEvent") and r ~= promptR and r ~= startR and r ~= answerRemote then
            table.insert(dungeonConns, r.OnClientEvent:Connect(function()
                onOtherEvent(r.Name)
            end))
        end
    end
    dungeonReady = true
end)

----------------------------------------------------------------
-- UI tab Game Mode
----------------------------------------------------------------
local function mkLabel(parent, text, x, y, w, h, size, color, font)
    local l = Instance.new("TextLabel")
    l.Position = UDim2.new(0, x, 0, y)
    l.Size = UDim2.new(0, w, 0, h)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = color or Color3.fromRGB(200, 200, 210)
    l.Font = font or Enum.Font.Gotham
    l.TextSize = size or 12
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Top
    l.TextWrapped = true
    l.Parent = parent
    return l
end

mkLabel(pageGame, "Auto Dungeon", 8, 8, 324, 20, 14, Color3.fromRGB(255, 255, 255), Enum.Font.GothamBold)
mkLabel(pageGame, "Difficulty", 8, 30, 324, 14, 11, Color3.fromRGB(170, 170, 185))

ddDungeon = createDropdown(46, "Pilih difficulty...", false, false, pageGame)
do
    local names = {}
    for _, d in ipairs(DUNGEONS) do table.insert(names, d.label) end
    ddDungeon.setItems(names)
    ddDungeon.select(DUNGEONS[1].label)
end

-- Checkbox Auto Join Dungeon
local djRow = Instance.new("Frame")
djRow.Size = UDim2.new(1, -16, 0, 56)
djRow.Position = UDim2.new(0, 8, 0, 86)
djRow.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
djRow.BorderSizePixel = 0
djRow.Parent = pageGame
Instance.new("UICorner", djRow).CornerRadius = UDim.new(0, 8)

local djBox = Instance.new("TextButton")
djBox.Size = UDim2.new(0, 28, 0, 28)
djBox.Position = UDim2.new(0, 12, 0.5, -14)
djBox.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
djBox.Text = ""
djBox.TextColor3 = Color3.fromRGB(255, 255, 255)
djBox.Font = Enum.Font.GothamBold
djBox.TextSize = 18
djBox.AutoButtonColor = false
djBox.Parent = djRow
Instance.new("UICorner", djBox).CornerRadius = UDim.new(0, 6)
local djStroke = Instance.new("UIStroke")
djStroke.Thickness = 2
djStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
djStroke.Color = Color3.fromRGB(110, 110, 125)
djStroke.Parent = djBox

mkLabel(djRow, "Auto Join Dungeon", 52, 8, 250, 20, 14, Color3.fromRGB(255, 255, 255), Enum.Font.GothamBold)
mkLabel(djRow, "Join otomatis tiap dungeon dibuka", 52, 29, 250, 18, 11, Color3.fromRGB(150, 150, 165))

local function refreshDjBox()
    if dungeon.enabled then
        djBox.Text = "✔"
        djBox.BackgroundColor3 = Color3.fromRGB(50, 170, 90)
        djStroke.Color = Color3.fromRGB(50, 170, 90)
    else
        djBox.Text = ""
        djBox.BackgroundColor3 = Color3.fromRGB(25, 25, 32)
        djStroke.Color = Color3.fromRGB(110, 110, 125)
    end
end

djBox.MouseButton1Click:Connect(function()
    dungeon.enabled = not dungeon.enabled
    refreshDjBox()
end)

-- Panel info
local infoFrame = Instance.new("Frame")
infoFrame.Size = UDim2.new(1, -16, 0, 176)
infoFrame.Position = UDim2.new(0, 8, 0, 152)
infoFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
infoFrame.BorderSizePixel = 0
infoFrame.Parent = pageGame
Instance.new("UICorner", infoFrame).CornerRadius = UDim.new(0, 8)

mkLabel(infoFrame, "Dungeon berikutnya dibuka dalam", 12, 8, 300, 14, 11, Color3.fromRGB(170, 170, 185))
local lblCount = mkLabel(infoFrame, "--:--", 12, 24, 300, 30, 26, Color3.fromRGB(255, 231, 59), Enum.Font.GothamBold)
local lblSub = mkLabel(infoFrame, "", 12, 58, 300, 16, 11, Color3.fromRGB(170, 170, 185))
local lblState = mkLabel(infoFrame, "", 12, 82, 300, 40, 12, Color3.fromRGB(230, 230, 240))
local lblDebug = mkLabel(infoFrame, "", 12, 128, 300, 44, 10, Color3.fromRGB(130, 130, 145), Enum.Font.Code)

----------------------------------------------------------------
-- Pengendali auto dungeon (jalan tiap 0.25 detik)
----------------------------------------------------------------
local function dungeonTick()
    local t = serverNow()
    local interval = DUNGEON_INTERVAL_MIN * 60
    local base = math.floor((t - dungeon.offset) / interval) * interval + dungeon.offset
    local nextOpen = base + interval
    local sinceOpen = t - base
    local d = getSelectedDungeon()

    -- ===== kontrol =====
    if not dungeon.enabled then
        if dungeon.phase ~= "idle" or dungeonLock then dungeonReset() end
    elseif dungeonReady then
        if dungeon.phase ~= "idle" and os.clock() - roomInfo.t >= 0.5 then
            refreshRoom(d)
        end
        local ph = dungeon.phase

        if ph == "idle" then
            -- jadwal yang dituju: jendela yang sedang terbuka, atau yang berikutnya
            local target = (sinceOpen < JOIN_GRACE) and base or nextOpen
            if not dungeon.handled[target] and (target - t) <= JOIN_LEAD then
                refreshRoom(d)
                if roomInfo.inside == true then
                    goInside(target, t) -- sudah di dalam dungeon, tidak perlu join
                else
                    beginJoin(d, target, target)
                end
            end

        elseif ph == "joining" then
            local inRoom, found = roomInfo.inside, roomInfo.found
            local away = awayFromPre()
            local joined = (inRoom == true) or away

            if joined then
                dungeon.handled[dungeon.key] = true
                dungeon.phase = "inside"
                dungeon.startedAt = t
                dungeon.modelSeen = found
                dungeon.wasAway = away
                dungeon.outsideSince = nil
                dungeon.endSeen = false
            elseif t - dungeon.windowStart > JOIN_GRACE then
                dungeon.handled[dungeon.key] = true
                dungeonFinish("gagal join (tidak masuk dalam " .. JOIN_GRACE .. " dtk), auto farm lanjut")
            else
                local now = os.clock()
                if not dungeon.promptSeen then
                    if now - dungeon.lastFire >= JOIN_SPAM_INTERVAL then fireJoin(d) end
                elseif dungeon.burst < JOIN_BURST_AFTER_PROMPT and now - dungeon.lastFire >= JOIN_SPAM_INTERVAL then
                    dungeon.burst += 1
                    fireJoin(d)
                end
            end

        elseif ph == "inside" then
            local inRoom, found = roomInfo.inside, roomInfo.found
            if found then dungeon.modelSeen = true end
            local away = awayFromPre()
            if away then dungeon.wasAway = true end

            local outside = false
            if found then
                outside = (inRoom == false)
            elseif dungeon.modelSeen then
                outside = true -- model dungeon hilang = dungeon selesai
            elseif dungeon.wasAway then
                outside = not away -- sudah kembali dekat posisi awal
            end

            if outside then
                dungeon.outsideSince = dungeon.outsideSince or t
            else
                dungeon.outsideSince = nil
            end

            if dungeon.endSeen then
                dungeonFinish("dungeon selesai, auto farm lanjut")
            elseif dungeon.outsideSince and t - dungeon.outsideSince >= 3 then
                dungeonFinish("keluar dari dungeon, auto farm lanjut")
            elseif t - dungeon.startedAt > DUNGEON_TIME_LIMIT + 60 then
                dungeonFinish("batas waktu dungeon habis, auto farm lanjut")
            end
        end
    end

    -- ===== info UI =====
    local openNow = sinceOpen < JOIN_WINDOW
    if openNow then
        lblCount.Text = "SEDANG DIBUKA"
        lblSub.Text = string.format("Popup join sisa %d dtk", math.max(0, math.floor(JOIN_WINDOW - sinceOpen)))
    else
        local untilOpen = math.max(0, nextOpen - t)
        lblCount.Text = string.format("%02d:%02d", math.floor(untilOpen / 60), math.floor(untilOpen % 60))
        lblSub.Text = string.format("±%d menit lagi • dibuka pukul %s (waktu lokal)",
            math.ceil(untilOpen / 60), os.date("%H:%M", math.floor(nextOpen)))
    end

    local stateText
    if dungeonFailed then
        stateText = "Remote dungeon tidak ditemukan di game ini."
    elseif not dungeonReady then
        stateText = "Menghubungkan ke remote dungeon..."
    elseif not dungeon.enabled then
        stateText = "Auto join nonaktif. Centang untuk mengaktifkan."
    elseif dungeon.phase == "idle" then
        stateText = string.format("Menunggu jadwal. Join otomatis mulai %d dtk sebelum dibuka.", JOIN_LEAD)
    elseif dungeon.phase == "joining" then
        stateText = dungeon.promptSeen and "Popup dungeon muncul, mengirim join..."
            or "Mencoba join dungeon (kirim tiap " .. JOIN_SPAM_INTERVAL .. " dtk)..."
        stateText = stateText .. "\nAuto farm dijeda."
    else
        stateText = "Di dalam dungeon. Auto farm dijeda, lanjut otomatis setelah selesai."
    end
    if dungeon.note ~= "" and dungeon.phase == "idle" then
        stateText = stateText .. "\nTerakhir: " .. dungeon.note
    end
    lblState.Text = stateText

    local roomStr
    if dungeon.phase == "idle" then
        roomStr = "-"
    elseif not roomInfo.found then
        roomStr = "Rooms kosong"
    else
        roomStr = roomInfo.inside and "di dalam" or "di luar"
    end
    local promptStr = dungeon.lastPrompt and os.date("%H:%M:%S", math.floor(dungeon.lastPrompt)) or "-"
    lblDebug.Text = string.format("Popup terakhir: %s | Event: %s | Ruang: %s%s",
        promptStr, dungeon.lastEvent, roomStr, dungeon.err and ("\nERR: " .. dungeon.err) or "")
end

task.spawn(function()
    while gui.Parent do
        local ok, err = pcall(dungeonTick)
        dungeon.err = (not ok) and tostring(err) or nil
        task.wait(0.25)
    end
end)

-- Bersihkan semua proses kalau GUI ditutup / dijalankan ulang
gui.Destroying:Connect(function()
    dungeon.enabled = false
    for _, c in ipairs(dungeonConns) do c:Disconnect() end
    running = false
    runToken += 1
    StopAntiAFK()
end)

----------------------------------------------------------------
-- MINIMIZE / CLOSE / DRAG
----------------------------------------------------------------
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    closeAllDropdowns()
    applyTabs()
    main.Size = minimized and MINI_SIZE or FULL_SIZE
    minBtn.Text = minimized and "+" or "-"
end)

closeBtn.MouseButton1Click:Connect(function()
    stopAuto()
    StopAntiAFK()
    gui:Destroy()
end)

local dragging, dragStart, startPos = false, nil, nil

title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = root.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        root.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end)
