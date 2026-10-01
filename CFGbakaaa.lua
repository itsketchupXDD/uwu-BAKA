local shared = odh_shared_plugins
local section = shared.AddSection("Omega Auto Revert")

local internal_shared = odh_internal_shared
local gpl_preset = internal_shared.MM2_GPL

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")
local Terrain = game:GetService("Workspace"):FindFirstChildOfClass("Terrain")

local LocalPlayer = Players.LocalPlayer

local enabled = false
local adaptiveEngine = true -- ЕДИНЫЙ ТУМБЛЕР: Smooth Lerp + Smart Lag Predictor + EMA Ping Filter
local monitorEnabled = false
local fpsBoost = false
local locked = false
local upgrade = false

local currentProfile = ""
local updateConnection
local smoothedPing = 60
local lastApplied = {}

local origShadows = Lighting.GlobalShadows
local origAmbient = Lighting.OutdoorAmbient

---------------------------------------------------
-- ПИНГ ТЕЛЕМЕТРИЯ И СГЛАЖИВАНИЕ
---------------------------------------------------

local function GetPing()
    local pingValue = nil
    
    -- Источник 1: Stats.Network.ServerStatsItem (наиболее точный пинг сервера)
    pcall(function()
        local serverStats = Stats:FindFirstChild("Network") and Stats.Network:FindFirstChild("ServerStatsItem")
        if serverStats and serverStats:FindFirstChild("Data Ping") then
            pingValue = serverStats["Data Ping"]:GetValue()
        end
    end)
    
    -- Источник 2: Stats.PerformanceStats.Ping
    if not pingValue or pingValue <= 0 then
        pcall(function()
            local perfPing = Stats:FindFirstChild("PerformanceStats") and Stats.PerformanceStats:FindFirstChild("Ping")
            if perfPing then
                pingValue = perfPing:GetValue()
            end
        end)
    end
    
    -- Источник 3: LocalPlayer:GetNetworkPing()
    if not pingValue or pingValue <= 0 then
        pcall(function()
            if LocalPlayer and LocalPlayer.GetNetworkPing then
                local np = LocalPlayer:GetNetworkPing()
                if np and np > 0 then
                    pingValue = np * 1000
                end
            end
        end)
    end
    
    if not pingValue or pingValue <= 0 then
        pingValue = 60
    end
    
    local rawPing = math.clamp(math.floor(pingValue + 0.5), 5, 1200)

    -- Если включен Adaptive Engine — сглаживаем скачки (EMA Filter)
    if adaptiveEngine then
        local alpha = 0.25
        if math.abs(rawPing - smoothedPing) > 40 then
            alpha = 0.6 -- Быстрый отклик на реальное устойчивое изменение задержки
        end
        smoothedPing = (rawPing * alpha) + (smoothedPing * (1 - alpha))
        return math.floor(smoothedPing + 0.5)
    else
        smoothedPing = rawPing
        return rawPing
    end
end

---------------------------------------------------
-- АДАПТИВНЫЙ РАСЧЕТ КОНФИГУРАЦИИ
---------------------------------------------------

local PingControlPoints = {
    { Ping = 20,  Sim = 48, Interval = 70, H = 154, V = 144, X = -5.0,  Y = -14.0, Z = 0, Name = "A" },
    { Ping = 50,  Sim = 54, Interval = 66, H = 162, V = 152, X = -6.0,  Y = -14.0, Z = 0, Name = "A" },
    { Ping = 100, Sim = 68, Interval = 60, H = 176, V = 166, X = -8.0,  Y = -15.0, Z = 0, Name = "B" },
    { Ping = 150, Sim = 72, Interval = 64, H = 182, V = 170, X = -9.0,  Y = -12.0, Z = 0, Name = "C" },
    { Ping = 200, Sim = 76, Interval = 70, H = 188, V = 174, X = -10.0, Y = -11.0, Z = 0, Name = "D" },
    { Ping = 300, Sim = 82, Interval = 76, H = 196, V = 180, X = -12.0, Y = -10.0, Z = 0, Name = "D" },
}

local function Lerp(a, b, t)
    return a + (b - a) * t
end

local function GetConfig(ping)
    -- 1. Режим полной непрерывной динамической адаптации (Smooth Curve Lerp)
    if adaptiveEngine then
        local points = PingControlPoints
        local pTarget = math.clamp(ping, 15, 400)

        if pTarget <= points[1].Ping then
            local p = points[1]
            return {
                Vertical = p.V, Horizontal = p.H, X = p.X, Y = p.Y, Z = p.Z,
                Sim = p.Sim, Interval = p.Interval, Name = "Dynamic_" .. math.floor(ping)
            }
        elseif pTarget >= points[#points].Ping then
            local p = points[#points]
            return {
                Vertical = p.V, Horizontal = p.H, X = p.X, Y = p.Y, Z = p.Z,
                Sim = p.Sim, Interval = p.Interval, Name = "Dynamic_" .. math.floor(ping)
            }
        end

        for i = 1, #points - 1 do
            local p1 = points[i]
            local p2 = points[i + 1]

            if pTarget >= p1.Ping and pTarget <= p2.Ping then
                local t = (pTarget - p1.Ping) / (p2.Ping - p1.Ping)
                local smoothT = t * t * (3 - 2 * t)

                local v = math.floor(Lerp(p1.V, p2.V, smoothT) + 0.5)
                local h = math.floor(Lerp(p1.H, p2.H, smoothT) + 0.5)
                local sim = math.floor(Lerp(p1.Sim, p2.Sim, smoothT) + 0.5)
                local interval = math.floor(Lerp(p1.Interval, p2.Interval, smoothT) + 0.5)
                local x = math.floor((Lerp(p1.X, p2.X, smoothT) * 10) + 0.5) / 10
                local y = math.floor((Lerp(p1.Y, p2.Y, smoothT) * 10) + 0.5) / 10
                local z = math.floor((Lerp(p1.Z, p2.Z, smoothT) * 10) + 0.5) / 10

                if upgrade then
                    v = v + 2
                    h = h + 2
                    sim = sim + 1
                end

                return {
                    Vertical = v, Horizontal = h, X = x, Y = y, Z = z,
                    Sim = sim, Interval = interval, Name = "Dynamic_" .. math.floor(ping)
                }
            end
        end
    end

    -- 2. Классический ступенчатый режим с гистерезисом (при отключенном Adaptive Engine)
    local h = 4
    if ping <= 50 + (currentProfile == "A" and h or 0) then
        return {Vertical=152, Horizontal=162, X=-6, Y=-14, Z=0, Sim=54, Interval=66, Name="A"}
    elseif ping <= 100 + (currentProfile == "B" and h or 0) then
        return {Vertical=166, Horizontal=176, X=-8, Y=-15, Z=0, Sim=68, Interval=60, Name="B"}
    elseif ping <= 150 + (currentProfile == "C" and h or 0) then
        return {Vertical=170, Horizontal=182, X=-9, Y=-12, Z=0, Sim=72, Interval=64, Name="C"}
    else
        return {Vertical=174, Horizontal=188, X=-10, Y=-11, Z=0, Sim=76, Interval=70, Name="D"}
    end
end

---------------------------------------------------
-- ПРИМЕНЕНИЕ КОНФИГУРАЦИИ В GPL
---------------------------------------------------

local function HasChanged(cfg)
    if not lastApplied.Sim then return true end
    return lastApplied.Sim ~= cfg.Sim
        or lastApplied.Interval ~= cfg.Interval
        or lastApplied.X ~= cfg.X
        or lastApplied.Y ~= cfg.Y
        or lastApplied.Z ~= cfg.Z
        or lastApplied.Horizontal ~= cfg.Horizontal
        or lastApplied.Vertical ~= cfg.Vertical
end

local function Apply(cfg)
    if locked or not cfg then return end

    pcall(function()
        if not internal_shared["RevertSettings_PrioritizeYourPing"] and gpl_preset[1] then
            gpl_preset[1]()
        end

        if not internal_shared["RevertSettings_PredictJump"] and gpl_preset[2] then
            gpl_preset[2]()
        end

        -- Авто-предикшн лагов при Adaptive Engine (при пинге > 110мс)
        if adaptiveEngine then
            local shouldLag = (smoothedPing > 110)
            if shouldLag and not internal_shared["RevertSettings_PredictLag"] and gpl_preset[3] then
                gpl_preset[3]()
            end
        else
            if not internal_shared["RevertSettings_PredictLag"] and gpl_preset[3] then
                gpl_preset[3]()
            end
        end

        -- Применяем настройки
        if HasChanged(cfg) then
            if gpl_preset[4]  then gpl_preset[4](cfg.Sim) end
            if gpl_preset[5]  then gpl_preset[5](cfg.Interval) end
            if gpl_preset[7]  then gpl_preset[7](cfg.X) end
            if gpl_preset[8]  then gpl_preset[8](cfg.Y) end
            if gpl_preset[9]  then gpl_preset[9](cfg.Z) end
            if gpl_preset[10] then gpl_preset[10](cfg.Horizontal) end
            if gpl_preset[11] then gpl_preset[11](cfg.Vertical) end

            lastApplied = {
                Sim = cfg.Sim,
                Interval = cfg.Interval,
                X = cfg.X,
                Y = cfg.Y,
                Z = cfg.Z,
                Horizontal = cfg.Horizontal,
                Vertical = cfg.Vertical
            }
        end
    end)
end

---------------------------------------------------
-- FPS BOOST
---------------------------------------------------

local function SetFPSBoost(state)
    fpsBoost = state

    pcall(function()
        Lighting.GlobalShadows = not state and origShadows or false
        Lighting.OutdoorAmbient = not state and origAmbient or Color3.fromRGB(128,128,128)

        if Terrain then
            Terrain.WaterWaveSize = state and 0 or 0.15
            Terrain.WaterWaveSpeed = state and 0 or 10
            Terrain.WaterReflectance = state and 0 or 1
            Terrain.WaterTransparency = state and 0 or 1
        end
    end)
end

---------------------------------------------------
-- МОНИТОР (ТОЧНО КАК В ОРИГИНАЛЬНОМ ФАЙЛЕ)
---------------------------------------------------

local function CreateMonitor()
    if _G.OmegaGui then 
        pcall(function() _G.OmegaGui:Destroy() end) 
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "Omega"
    pcall(function() gui.Parent = game.CoreGui end)
    if not gui.Parent then
        pcall(function() gui.Parent = LocalPlayer:FindFirstChildOfClass("PlayerGui") end)
    end
    _G.OmegaGui = gui

    local pingLabel = Instance.new("TextLabel")
    pingLabel.Size = UDim2.new(0, 180, 0, 25)
    pingLabel.Position = UDim2.new(0.75, 0, 0, 40)
    pingLabel.BackgroundTransparency = 1
    pingLabel.Font = Enum.Font.Code
    pingLabel.TextXAlignment = Enum.TextXAlignment.Right
    pingLabel.TextSize = 18
    pingLabel.Parent = gui

    local fpsLabel = Instance.new("TextLabel")
    fpsLabel.Size = UDim2.new(0, 180, 0, 25)
    fpsLabel.Position = UDim2.new(0.75, 0, 0, 65)
    fpsLabel.BackgroundTransparency = 1
    fpsLabel.Font = Enum.Font.Code
    fpsLabel.TextXAlignment = Enum.TextXAlignment.Right
    fpsLabel.TextSize = 18
    fpsLabel.Parent = gui

    updateConnection = RunService.RenderStepped:Connect(function(dt)
        if not monitorEnabled then
            if updateConnection then 
                pcall(function() updateConnection:Disconnect() end) 
            end
            return
        end

        local ping = GetPing()
        local fps = math.floor(1 / dt)

        pingLabel.Text = "Ping: " .. ping
        fpsLabel.Text = "FPS: " .. fps
    end)
end

---------------------------------------------------
-- ОСНОВНОЙ АДАПТИВНЫЙ ЦИКЛ
---------------------------------------------------

task.spawn(function()
    while true do
        task.wait(0.4)

        if enabled then
            local ping = GetPing()
            local cfg = GetConfig(ping)

            if currentProfile ~= cfg.Name or HasChanged(cfg) then
                Apply(cfg)
                currentProfile = cfg.Name
            end
        end
    end
end)

---------------------------------------------------
-- TOGGLES В МЕНЮ
---------------------------------------------------

section:AddToggle("Auto Revert", function(v)
    enabled = v
    if v then
        local ping = GetPing()
        local cfg = GetConfig(ping)
        Apply(cfg)
        currentProfile = cfg.Name
    end
end)

section:AddToggle("Adaptive Engine", function(v)
    adaptiveEngine = v
    if enabled and not locked then
        local ping = GetPing()
        local cfg = GetConfig(ping)
        Apply(cfg)
        currentProfile = cfg.Name
    end
end)

section:AddToggle("Lock Config", function(v)
    locked = v
end)

section:AddToggle("Upgrade Mode", function(v)
    upgrade = v
    internal_shared.__OMEGA_UPGRADE = v
    if enabled and not locked then
        local ping = GetPing()
        local cfg = GetConfig(ping)
        Apply(cfg)
        currentProfile = cfg.Name
    end
end)

section:AddToggle("Monitor", function(v)
    monitorEnabled = v

    if v then
        CreateMonitor()
    else
        if _G.OmegaGui then 
            pcall(function() _G.OmegaGui:Destroy() end) 
        end
        if updateConnection then 
            pcall(function() updateConnection:Disconnect() end) 
        end
    end
end)

section:AddToggle("FPS Boost", function(v)
    SetFPSBoost(v)
end)
