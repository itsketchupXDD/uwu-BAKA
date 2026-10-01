-- ODH 2026 adapter. Embedded in every plugin; no downloads/dependencies.
local ODHX = (function()
    local X = { ready=false, silent=false, restoring=false, replay=true, records={}, byKey={}, data={version=1, controls={}}, external=true }
    X.id, X.title, X.file = "PM_VALEX", "PM VALEX", "ODH_PM_VALEX_settings.json"
    local host = odh_shared_plugins
    assert(host and type(host.CreateTab)=="function", X.title .. ": load through the current Overdrive H plugin menu")
    local env = {}
    if type(getgenv)=="function" then local ok,g=pcall(getgenv); if ok and type(g)=="table" then env=g end end
    local rd = type(readfile)=="function" and readfile or env.readfile
    local wr = type(writefile)=="function" and writefile or env.writefile
    local exists = type(isfile)=="function" and isfile or env.isfile
    local http = game:GetService("HttpService")
    local reported = {}
    local function report(message)
        if reported[message] then return end
        reported[message]=true
        warn("[" .. X.title .. "] " .. message)
        if type(host.Notify)=="function" then pcall(host.Notify, X.title .. ": " .. message, 5) end
    end
    X.Report = report
    local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
    local function encode(v, depth)
        depth=depth or 0
        if depth>20 then error("settings nesting too deep") end
        if typeof(v)=="Color3" then return {__odhColor={v.R,v.G,v.B}} end
        local t=type(v)
        if t=="boolean" or t=="string" then return v end
        if t=="number" then if finite(v) then return v end; return nil end
        if t=="table" then
            local result={}
            for k,item in pairs(v) do
                if type(k)=="string" or type(k)=="number" then result[k]=encode(item,depth+1) end
            end
            return result
        end
        return nil -- never serialize Instances, connections, functions or players
    end
    local function decode(v, depth)
        depth=depth or 0
        if depth>20 then error("settings nesting too deep") end
        if type(v)~="table" then return v end
        if v.__odhColor then
            local c=v.__odhColor
            assert(type(c)=="table" and finite(c[1]) and finite(c[2]) and finite(c[3]),"invalid color")
            return Color3.new(math.clamp(c[1],0,1),math.clamp(c[2],0,1),math.clamp(c[3],0,1))
        end
        local result={}
        for k,item in pairs(v) do result[k]=decode(item,depth+1) end
        return result
    end
    X.Encode, X.Decode = encode, decode
    if not X.external then
        if type(rd)=="function" and type(wr)=="function" then
            local present=true
            if type(exists)=="function" then local ok,v=pcall(exists,X.file); if ok then present=v end end
            if present then
                local ok,text=pcall(rd,X.file)
                if ok then
                    local good,data=pcall(function() return decode(http:JSONDecode(text)) end)
                    if good and type(data)=="table" and data.version==1 and type(data.controls)=="table" then X.data=data
                    else X.badFile=true; report("Invalid settings file; defaults loaded. A manual change will replace it.") end
                elseif type(exists)=="function" then report("Could not read settings file: " .. tostring(text)); X.badFile=true end
            end
        else report("readfile/writefile unavailable; settings last only for this session.") end
    end
    local tab
    X.shared=setmetatable({}, {__index=host}) -- never mutate the host API
    X.shared.Notify=function(text,seconds)
        if X.restoring then return end
        if type(host.Notify)=="function" then return host.Notify(text,seconds or 3) end
    end
    local function key(section,name,kind) return section .. " / " .. kind .. " / " .. name end
    local function safeValue(r,v)
        if r.kind=="Toggle" then if type(v)=="boolean" then return v end
        elseif r.kind=="Slider" then if finite(v) then return math.clamp(v,r.min,r.max) end
        elseif r.kind=="Colorpicker" then if typeof(v)=="Color3" then return v end
        elseif r.kind=="Dropdown" then
            for _,item in ipairs(r.items) do if v==item then return v end end
        end
        return nil
    end
    local function show(r,v)
        if v==nil or r.shown==v then return end
        local prior=X.silent; X.silent=true
        local ok,err=pcall(function()
            if r.kind=="Toggle" then
                if r.visual~=v then assert(type(r.handle)=="function","AddToggle must return a closure"); r.handle() end
            elseif r.kind=="Slider" then r.handle:SetValue(v)
            elseif r.kind=="Colorpicker" then r.handle:SetRGBValue(v)
            elseif r.kind=="Dropdown" then r.handle:Select(v) end
        end)
        X.silent=prior
        if ok then r.shown=v else report("UI sync failed: " .. r.name .. ": " .. tostring(err)) end
    end
    function X.Bind(section,name,kind,getter)
        local r=X.byKey[key(section,name,kind)]
        assert(r,"Unknown binding " .. section .. " / " .. name)
        r.get=getter
    end
    function X.Sync()
        for _,r in ipairs(X.records) do
            if r.get then
                local ok,v=pcall(r.get)
                if ok then
                    v=safeValue(r,v)
                    if v~=nil then
                        r.value=v
                        if not r.exclude then X.data.controls[r.key]=v end
                        show(r,v)
                    end
                end
            end
        end
    end
    function X.Commit()
        if not X.ready or X.silent or X.restoring or X.stopped or X.committing then return end
        X.committing=true
        local ok,err=pcall(function()
            X.Sync()
            if X.capture then X.data.snapshot=X.capture() end
            if X.external then
                if not X.backend or not X.backend(X.data) then error("native settings file could not be saved") end
            elseif type(wr)=="function" then
                wr(X.file,http:JSONEncode(encode(X.data)))
            end
        end)
        X.committing=false
        if not ok then report("Settings save failed: " .. tostring(err)) end
    end
    function X.Restore()
        X.restoring=true
        -- Options before enabling modules. Actions and player selections are never replayed.
        for _,togglePass in ipairs({false,true}) do
            for _,r in ipairs(X.records) do
                if not r.exclude and ((r.kind=="Toggle")==togglePass) then
                    local v=safeValue(r,X.data.controls[r.key])
                    if v==nil and r.get then local ok,x=pcall(r.get); if ok then v=safeValue(r,x) end end
                    if v==nil then v=r.default end
                    if v~=nil then
                        show(r,v)
                        local ok,err=pcall(r.callback,v)
                        if not ok then report("Restore failed: " .. r.name .. ": " .. tostring(err)) end
                        r.value=v; X.data.controls[r.key]=v
                    end
                end
            end
        end
        X.restoring=false
    end
    function X.Finish()
        if X.replay then X.Restore() else X.Sync() end
        X.ready=true
        if not X.badFile then X.Commit() end
    end
    function X.Set(section,name,kind,v,apply)
        local r=X.byKey[key(section,name,kind)]
        if not r then return end
        v=safeValue(r,v); if v==nil then return end
        show(r,v); r.value=v; X.data.controls[r.key]=v
        if apply then r.callback(v) end
    end
    function X.ResetControls()
        X.data.controls={}
        for _,r in ipairs(X.records) do
            if r.kind=="Toggle" and not r.exclude then X.Set(r.section,r.name,r.kind,false,true) end
        end
    end
    function X.shared.AddSection(name,subtitle)
        if not tab then tab=host.CreateTab(X.title,"/mellnikovden968-web/CFG_PM2/refs/heads/main/icon") end
        local raw=tab:AddSection(name,subtitle or "")
        local section={Name=name,Raw=raw}
        local function register(kind,label,callback,default,min,max,items)
            local r={section=name,name=label,kind=kind,callback=callback,default=default,min=min,max=max,items=items,visual=false}
            r.key=key(name,label,kind)
            r.exclude=(name=="🔑 Keys") -- key-capture toggles are actions, not enabled modes
            X.records[#X.records+1]=r; X.byKey[r.key]=r
            local function changed(v)
                if kind=="Toggle" then r.visual=(v==true) end
                if not X.ready or X.silent or X.restoring or X.stopped then return end
                v=safeValue(r,v); if v==nil then return end
                r.shown=v
                local ok,err=pcall(callback,v)
                if ok then
                    r.value=v
                    if not r.exclude then X.data.controls[r.key]=v end
                    X.Commit()
                else report("Callback failed: " .. label .. ": " .. tostring(err)) end
            end
            if kind=="Toggle" then r.handle=raw:AddToggle(label,changed)
            elseif kind=="Slider" then r.handle=raw:AddSlider(label,min,max,default,changed)
            elseif kind=="Colorpicker" then r.handle=raw:AddColorpicker(label,default,changed)
            elseif kind=="Dropdown" then r.handle=raw:AddDropdown(label,items,changed) end
            return r.handle
        end
        function section:AddToggle(label,cb) return register("Toggle",label,cb,false) end
        function section:AddSlider(label,min,max,default,cb) return register("Slider",label,cb,default,min,max) end
        function section:AddColorpicker(label,default,cb) return register("Colorpicker",label,cb,default) end
        function section:AddDropdown(label,items,cb) return register("Dropdown",label,cb,items[1],nil,nil,items) end
        local function action(cb)
            return function(...)
                if not X.ready or X.stopped then return end
                local ok,err=pcall(cb,...)
                if not ok then report("Action failed: " .. tostring(err)) end
                X.Commit()
            end
        end
        function section:AddButton(label,cb) return raw:AddButton(label,action(cb)) end
        function section:AddKeybind(label,default,cb) return raw:AddKeybind(label,default,action(cb)) end
        function section:AddPlayerDropdown(label,cb) return raw:AddPlayerDropdown(label,action(cb)) end
        function section:AddTextBox(label,cb) return raw:AddTextBox(label,action(cb)) end
        function section:AddLabel(...) return raw:AddLabel(...) end
        function section:AddParagraph(...) return raw:AddParagraph(...) end
        return section
    end
    -- Stable GUI paths, never serialized Instances. Player name is session-independent.
    function X.Path(object)
        local parts={}
        local player=game:GetService("Players").LocalPlayer
        while object and object~=game do
            table.insert(parts,1,object==player and "$LocalPlayer" or object.Name)
            object=object.Parent
            if #parts>32 then return nil end
        end
        if object~=game then return nil end
        return parts
    end
    function X.Resolve(parts)
        if type(parts)~="table" then return nil end
        local object=game
        for _,name in ipairs(parts) do
            if name=="$LocalPlayer" then object=game:GetService("Players").LocalPlayer
            elseif type(name)=="string" and object then object=object:FindFirstChild(name)
            else return nil end
        end
        return object
    end
    X.connections={}
    function X.Connect(signal,callback)
        local c=signal:Connect(function(...) if not X.stopped then return callback(...) end end)
        X.connections[#X.connections+1]=c
        return c
    end
    function X.Stop()
        if X.stopped then return end
        X.Commit()
        X.stopped=true
        for _,c in ipairs(X.connections) do pcall(function() c:Disconnect() end) end
        if X.cleanup then pcall(X.cleanup) end
    end
    local registry=rawget(_G,"ODH_2026_PluginRuntimes")
    if type(registry)~="table" then registry={}; rawset(_G,"ODH_2026_PluginRuntimes",registry) end
    local previous=registry[X.id]
    if previous and type(previous.Stop)=="function" then pcall(previous.Stop) end
    registry[X.id]=X
    return X
end)()
-- END ODH 2026 ADAPTER

--[[
    ⚡ PM VALEX • VOID RESET   —   V1.1
    Murder Mystery 2 · Overdrive Hub plugin
    Author: VALEX
    ==========================================================================
    Плагин точечного и массового «войд-сброса» игроков в MM2: сброс по ролям
    (Sheriff / Murderer), по списку, по ближайшей цели, авто-режимы, аура,
    сброс по клику, хоткеи, плавающие бинды и живой HUD-статус.

    ── ВОЗМОЖНОСТИ ────────────────────────────────────────────────────────────
      • Ручной сброс: Sheriff, Murderer, Everyone, Selected, Nearest, Cancel
        и выбор конкретного игрока из списка.
      • Авто-режимы: Auto Sheriff, Auto Murderer, Loop (по списку),
        Aura (по радиусу), Click (сброс кликом по игроку).
      • Плавающие бинды-кружки: перетаскивание с запоминанием позиции, размер,
        подсветка активности, общий звук клика.
      • Хоткеи на все действия: захват клавиши тумблером, игнорирование
        модификаторов и нажатий при открытом чате.
      • HUD-статус: пульс, имя текущей цели, перетаскивание с сохранением позиции.
      • Списки: выбор цели, список для Loop, вайтлист (добавить/убрать/очистить).
      • Сохранение настроек в файл (readfile/writefile + JSON): тайминги,
        размеры и позиции кнопок/HUD, хоткеи, вайтлист; автосохранение с debounce.
      • «🛑 Panic» — мгновенная остановка всего; «🧹 Clean duplicates» — очистка
        меню от чужих и устаревших секций.

    ── АРХИТЕКТУРА И НАДЁЖНОСТЬ ───────────────────────────────────────────────
      • Один общий RenderStepped-диспетчер на весь плагин вместо N подключений;
        hover/press-анимации считаются вручную, без создания Tween-объектов.
      • Общие обработчики ввода для биндов (1× InputChanged, 1× InputEnded),
        состояние перетаскивания — обычная запись: утечек подключений нет.
      • Мультитач: драг и клик реагируют только на ТОТ палец, что нажал кнопку.
        Палец на джойстике движения кнопку не таскает и не «нажимает» её.
      • Remote ролей находится один раз и кэшируется (TTL + инвалидация при
        смене игроков); поиск цели идёт по квадратам дистанций, без sqrt.
      • Раскладка биндов пересчитывается при добавлении/удалении/смене размера —
        кнопки не «уезжают» и не накладываются друг на друга.
      • FallenPartsDestroyHeight возвращается всегда: cleanup + watchdog.
      • «⏹ Cancel» останавливает и текущий сброс, и массовый, и ретрай.
      • Авто-режим выключается мгновенно: поток гасится, а не досыпает wait.
      • Мёртвые цели не сбрасываются; кулдаун на цель защищает от спама.
      • Уникальный маркер «своих» GUI-карточек: автоочистка не может задеть
        чужие секции и окно хоста, а выгрузка убирает строго своё.
      • Выгрузка доступна хосту и повторному запуску: повторный load сначала
        корректно выгружает прошлый экземпляр и только потом строит новый GUI.
      • Headless-режим: если у хоста нет AddSection — ядро, HUD, бинды и хоткеи
        продолжают работать; все вызовы API хоста обёрнуты в защиту.

    ── НАСТРОЙКИ ──────────────────────────────────────────────────────────────
      Конфиг: pm_valex.json (в рабочей папке executor'а)
      Смена имени плагина: константы BRAND / AUTHOR / PLUGIN_ID ниже.
]]

-- ── Идентичность плагина (меняется в одном месте) ─────────────────────────
local AUTHOR            = "VALEX"
local BRAND             = "PM VALEX"            -- отображаемое имя
local PLUGIN_ID         = "pm_valex"            -- внутренние имена: файлы, GUI, маркеры
local PLUGIN_NAME       = BRAND .. " • VOID RESET"
local VERSION           = "V1.1"
local VERSION_TAG       = "pmvalex"             -- уникальная метка в меню
local MARKER_PREFIX     = "@pmvalex_"           -- префикс маркера «своей» карточки
local CONFIG_PATH       = PLUGIN_ID .. ".json"
local STORAGE_NAME      = "@" .. PLUGIN_ID
local UNLOAD_GLOBAL     = "__PM_VALEX_UNLOAD"
-- хранилища GUI чужих/прежних сборок, которые нужно убрать при старте
local LEGACY_STORAGES   = { "@bindstorage_v6", "@bindstorage_v5" }
-- подчищать секции устаревших сборок меню (список LEGACY_TITLES ниже)
local CLEAN_LEGACY_MENU = true

-- ====== Хост-уведомления (работают и без shared.Notify) ======
-- StarterGui объявлен заранее и заполняется в блоке сервисов ниже:
-- hostNotify вызывается из guard'а, то есть до инициализации сервисов
local StarterGui = nil

local function hostNotify(text, dur)
    if odh_shared_plugins and type(odh_shared_plugins.Notify) == "function" then
        if pcall(odh_shared_plugins.Notify, text, dur or 3) then return end
    end
    pcall(function()
        local sg = StarterGui or game:GetService("StarterGui")
        sg:SetCore("SendNotification", {
            Title = BRAND, Text = tostring(text), Duration = dur or 3,
        })
    end)
end

local shared = ODHX.shared
if not shared or (shared.game_name and shared.game_name ~= "Murder Mystery 2") then
    hostNotify(BRAND .. " " .. VERSION .. ": Only works in MM2!", 3)
    return
end

-- ====== Повторная загрузка: сначала выгружаем прошлый экземпляр ======
-- Важно сделать это ДО создания своего GUI: иначе новый экземпляр подхватит
-- ScreenGui старого, а его очистка затем уничтожит уже наш интерфейс.
pcall(function()
    if type(getgenv) ~= "function" then return end
    local g = getgenv()
    if type(g) ~= "table" then return end
    local prev = rawget(g, UNLOAD_GLOBAL)
    rawset(g, UNLOAD_GLOBAL, nil)   -- снимаем сразу, чтобы не вызвать дважды
    if type(prev) == "function" then pcall(prev) end
end)

-- ====== Maid ======
local Maid = {}
Maid.__index = Maid

function Maid._cleanup(item)
    local t = typeof(item)
    if t == "RBXScriptConnection" then
        pcall(function() item:Disconnect() end)
    elseif t == "Instance" then
        pcall(function() item:Destroy() end)
    elseif t == "function" then
        local ok, err = pcall(item)
        if not ok then warn("[" .. BRAND .. "][maid] " .. tostring(err)) end
    elseif t == "thread" then
        pcall(task.cancel, item)
    elseif t == "table" and type(item.Destroy) == "function" then
        pcall(item.Destroy, item)
    end
end

function Maid.new()
    return setmetatable({ _tasks = {}, _destroyed = false }, Maid)
end

function Maid:GiveTask(item)
    if item == nil then return nil end
    if self._destroyed then
        Maid._cleanup(item)
        return nil
    end
    local tasks = self._tasks
    tasks[#tasks + 1] = item
    return item
end

function Maid:DoCleaning()
    if self._destroyed then return end
    self._destroyed = true
    local tasks = self._tasks
    self._tasks = {}
    for i = #tasks, 1, -1 do
        Maid._cleanup(tasks[i])
        tasks[i] = nil
    end
end

function Maid:Destroy()
    self:DoCleaning()
end

local RootMaid = Maid.new()

-- ====== Сервисы ======
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local LocalPlayer       = Players.LocalPlayer
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local TweenService      = game:GetService("TweenService")
local HttpService       = game:GetService("HttpService")
local CoreGui           = game:GetService("CoreGui")
StarterGui              = game:GetService("StarterGui")

-- ====== Шорткаты (меньше глобальных lookup'ов в кадре) ======
local new      = Instance.new
local clamp    = math.clamp
local sin, cos, floor = math.sin, math.cos, math.floor
local now      = os.clock
local insert   = table.insert
local ud2      = UDim2.new
local ud       = UDim.new
local v2       = Vector2.new
local v3       = Vector3.new
local cfr      = CFrame.new
local rgb      = Color3.fromRGB
local pclr     = Color3.new
local cs       = ColorSequence.new
local csk      = ColorSequenceKeypoint.new
local tinfo    = TweenInfo.new
local V3_ZERO  = Vector3.zero
local UIT      = Enum.UserInputType
local MOUSE1   = UIT.MouseButton1
local TOUCH    = UIT.Touch
local MOUSEMOV = UIT.MouseMovement
local EASING   = Enum.EasingStyle
local EDIR     = Enum.EasingDirection
local FALLBACK_VIEWPORT = v2(1920, 1080)

local function clearTable(t)
    if table.clear then table.clear(t) else for k in pairs(t) do t[k] = nil end end
end

-- ====== Конфигурация ======
-- ссылки заполняются ниже, но объявлены здесь: serializeConfig/applyLoaded
-- обращаются к ним как к upvalue'ам, а не как к глобальным
local state_whitelist_ref = nil
local loadedWhitelist = {}
local persistDisabled = false

local DEFAULTS = {
    maxRetries        = 3,
    retryDelay        = 0.18,
    auraStuds         = 15,
    resetDuration     = 0.55,
    autoSheriffDelay  = 0.25,
    autoMurdererDelay = 0.35,
    loopInterval      = 0.4,
    auraInterval      = 0.4,
    bindButtonSize    = 0.11,
    targetCooldown    = 0.8,   -- новое: мин. пауза между сбросами одной цели
    roleCacheTTL      = 0.8,   -- новое: время жизни кэша ролей
    muteSounds        = false, -- было: локальная muteButtonSounds
    notifications     = true,  -- новое
    keybinds          = {},    -- новое: {sheriff="F", ...}
    bindPositions     = {},    -- новое: {[id]={x=,y=}}
    hudPos            = { x = 0.5, y = 6 },
    pluginUI          = {}, -- persistent toggle/slider state in the existing config
    whitelist         = {},    -- новое: {{id=,name=}, ...}
}

local config = {}
for key, value in pairs(DEFAULTS) do
    if type(value) == "table" then
        local copy = {}
        for kk, vv in pairs(value) do copy[kk] = vv end
        config[key] = copy
    else
        config[key] = value
    end
end

local canPersist = (type(writefile) == "function" and type(readfile) == "function")
local jsonBroken = false

local function jsonEncode(tbl)
    if jsonBroken then return nil end
    local ok, res = pcall(function() return HttpService:JSONEncode(tbl) end)
    if ok and type(res) == "string" then return res end
    jsonBroken = true
    return nil
end

local function jsonDecode(str)
    if jsonBroken then return nil end
    local ok, res = pcall(function() return HttpService:JSONDecode(str) end)
    if ok and type(res) == "table" then return res end
    return nil
end

-- whitelist: {[UserId]=Name} в памяти <-> список {{id,name}} в файле
local function packWhitelist(map)
    local out = {}
    for id, name in pairs(map) do
        insert(out, { id = id, name = tostring(name) })
    end
    return out
end

local function unpackWhitelist(list)
    local map = {}
    if type(list) == "table" then
        for _, row in ipairs(list) do
            if type(row) == "table" and type(row.id) == "number" then
                map[row.id] = tostring(row.name or row.id)
            end
        end
    end
    return map
end

local function serializeConfig()
    return {
        maxRetries = config.maxRetries, retryDelay = config.retryDelay,
        auraStuds = config.auraStuds, resetDuration = config.resetDuration,
        autoSheriffDelay = config.autoSheriffDelay, autoMurdererDelay = config.autoMurdererDelay,
        loopInterval = config.loopInterval, auraInterval = config.auraInterval,
        bindButtonSize = config.bindButtonSize, targetCooldown = config.targetCooldown,
        roleCacheTTL = config.roleCacheTTL, muteSounds = config.muteSounds,
        notifications = config.notifications, pluginUI = config.pluginUI,
        keybinds = config.keybinds, bindPositions = config.bindPositions,
        hudPos = config.hudPos, whitelist = packWhitelist(state_whitelist_ref or {}),
    }
end

local function applyLoaded(data)
    if type(data) ~= "table" then return false end
    local scalars = {
        "maxRetries", "retryDelay", "auraStuds", "resetDuration", "autoSheriffDelay",
        "autoMurdererDelay", "loopInterval", "auraInterval", "bindButtonSize",
        "targetCooldown", "roleCacheTTL", "muteSounds", "notifications",
    }
    for _, key in ipairs(scalars) do
        local v = data[key]
        if v ~= nil and type(v) == type(DEFAULTS[key]) then config[key] = v end
    end
    if type(data.keybinds) == "table" then config.keybinds = data.keybinds end
    if type(data.bindPositions) == "table" then config.bindPositions = data.bindPositions end
    if type(data.hudPos) == "table" and type(data.hudPos.x) == "number" and type(data.hudPos.y) == "number" then
        config.hudPos = { x = data.hudPos.x, y = data.hudPos.y }
    end
    if type(data.pluginUI)=="table" then config.pluginUI=data.pluginUI end
    loadedWhitelist = unpackWhitelist(data.whitelist)
    return true
end

local function loadConfig()
    if not canPersist or type(isfile) ~= "function" then return false end
    local applied = false
    pcall(function()
        if not isfile(CONFIG_PATH) then return end
        applied = applyLoaded(jsonDecode(readfile(CONFIG_PATH))) and true or false
    end)
    return applied
end

local saveQueued, saveThread = false, nil

local function saveConfig(force)
    if not canPersist or persistDisabled then return false end
    if force then
        if saveThread then pcall(task.cancel,saveThread) end
        saveThread,saveQueued=nil,false
        local ok,err=pcall(function()
            local payload=jsonEncode(serializeConfig())
            assert(payload,"JSON encode failed")
            writefile(CONFIG_PATH,payload)
        end)
        if not ok then ODHX.Report("Could not save " .. CONFIG_PATH .. ": " .. tostring(err)) end
        return ok
    end
    if saveQueued and not force then return true end
    saveQueued = true
    if saveThread then pcall(task.cancel, saveThread) end
    saveThread = task.delay(force and 0 or 0.35, function()
        saveQueued = false
        saveThread = nil
        pcall(function()
            local payload = jsonEncode(serializeConfig())
            if payload then writefile(CONFIG_PATH, payload) end
        end)
    end)
    return true
end

local configLoaded = loadConfig()
ODHX.data.controls=config.pluginUI or {}
ODHX.backend=function(data)
    config.pluginUI=data.controls
    return saveConfig(true)
end

-- ====== Состояние ======
local state = {
    whitelist       = loadedWhitelist,   -- {[UserId] = Name}
    selectedPlayers = {},                -- массив для Loop
    selectedSet     = {},                -- {[UserId] = true} — быстрый дедуп
    resetSelPlr     = nil,
    lastResetAt     = {},                -- {[UserId] = os.clock()} — кулдаун цели
}
state_whitelist_ref = state.whitelist

local maids = {
    loopPlr = nil, clickReset = nil, resetAura = nil,
    autoSheriff = nil, autoMurderer = nil,
}

-- ====== Уведомления ======
local lastNotify = { text = nil, at = 0 }
local function Notify(title, msg, dur)
    if not config.notifications then return end
    local text = msg and (title .. ": " .. msg) or title
    local t = now()
    if lastNotify.text == text and (t - lastNotify.at) < 0.35 then return end
    lastNotify.text, lastNotify.at = text, t
    hostNotify(text, dur or 3)
end

-- ====== Единый тикер (1 RenderStepped на весь плагин) ======
local Ticker = { _fns = {}, _conn = nil }

function Ticker._start()
    if Ticker._conn then return end
    Ticker._conn = RunService.RenderStepped:Connect(function(dt)
        local fns = Ticker._fns
        local i = 1
        while i <= #fns do
            local fn = fns[i]
            if fn then
                local ok, err = xpcall(fn, debug.traceback, dt)
                if not ok then
                    warn("[" .. BRAND .. "][ticker] " .. tostring(err))
                    table.remove(fns, i)
                    i = i - 1
                end
            end
            i = i + 1
        end
        if #fns == 0 and Ticker._conn then
            Ticker._conn:Disconnect()
            Ticker._conn = nil
        end
    end)
end

function Ticker.add(fn)
    if type(fn) ~= "function" then return function() end end
    local fns = Ticker._fns
    fns[#fns + 1] = fn
    Ticker._start()
    local removed = false
    return function()
        if removed then return end
        removed = true
        for i = 1, #fns do
            if fns[i] == fn then
                table.remove(fns, i)
                break
            end
        end
    end
end

RootMaid:GiveTask(function()
    if Ticker._conn then Ticker._conn:Disconnect(); Ticker._conn = nil end
    clearTable(Ticker._fns)
end)

-- ====== Заголовки секций: устаревшие (подчистить) / текущие (не трогать) ======
-- LEGACY_TITLES — данные для автоочистки чужого мусора в меню: по этим строкам
-- сканер находит и удаляет секции прежних сборок. Не нужно — CLEAN_LEGACY_MENU = false.
local LEGACY_TITLES = {
    ["⚡ Quick Actions"] = true,
    ["🤖 Automation"] = true,
    ["📋 Lists Management"] = true,
    ["⚙️ Reset Settings"] = true,
    ["⚙ Reset Settings"] = true,
    ["🔄 Bind Buttons (circles)"] = true,
    ["📊 Status"] = true,
    ["ℹ️ Info"] = true,
    ["⚡ Reset"] = true,             -- совпадающие имена ловятся по маркеру
    ["🤖 Auto"] = true,
    ["📋 Lists"] = true,
    ["⚙️ Tuning"] = true,
    ["⚙ Tuning"] = true,
    ["🔘 Binds"] = true,
    ["ℹ️"] = true,
}
-- Сюда можно дописать заголовки любых старых секций, которые надо подчистить:
--   EXTRA_LEGACY_TITLES = { ["Название старой секции"] = true }
local EXTRA_LEGACY_TITLES = {}
for _title in pairs(EXTRA_LEGACY_TITLES) do LEGACY_TITLES[_title] = true end
local CUR_TITLES = {
    ["💀 " .. BRAND] = true,
    ["⚡ Reset"] = true,
    ["🤖 Auto"] = true,
    ["📋 Lists"] = true,
    ["⚙️ Tuning"] = true,
    ["⚙ Tuning"] = true,
    ["🔘 Binds"] = true,
    ["🔑 Keys"] = true,
    ["💾 Config"] = true,
    ["ℹ️"] = true,
}
-- слова-защитники: карточка с ними — это окно самого хоста, её нельзя трогать.
-- ВАЖНО: сюда НЕ входит VERSION_TAG, иначе мы не смогли бы найти и пометить
-- собственную главную карточку (проверка на версию сделана в cardIsOurs).
local HOST_WORDS = {
    "Looking for a feature", "Plugins", "Overdrive", "Logged in as", "gg/overdrivehub",
}
local MAX_CARD_HEIGHT = 520

local RUN_ID = MARKER_PREFIX .. tostring(floor(now() * 1000) % 100000000)
    .. "_" .. tostring(math.random(1000, 9999))

-- ====== Хранилище GUI ======
local storageGui = nil
local function getStorage()
    if storageGui and storageGui.Parent then return storageGui end

    local parent
    local ok, res = pcall(function()
        if gethui then return gethui() end
        if getcore then return getcore() end
        return nil
    end)
    if ok and typeof(res) == "Instance" then parent = res else parent = CoreGui end
    if typeof(parent) ~= "Instance" then parent = LocalPlayer:FindFirstChildOfClass("PlayerGui") end
    if typeof(parent) ~= "Instance" then parent = LocalPlayer:WaitForChild("PlayerGui", 5) end
    if typeof(parent) ~= "Instance" then parent = CoreGui end

    -- подчищаем хранилища прежних сборок, если они остались
    pcall(function()
        for _, legacyName in ipairs(LEGACY_STORAGES) do
            local legacy = parent:FindFirstChild(legacyName)
            if legacy then legacy:Destroy() end
        end
    end)

    local sg = parent:FindFirstChild(STORAGE_NAME)
    if not sg then
        sg = new("ScreenGui")
        sg.Name = STORAGE_NAME
        sg.ResetOnSpawn = false
        sg.IgnoreGuiInset = true
        pcall(function() sg.ScreenInsets = Enum.ScreenInsets.None end)
        if syn and syn.protect_gui then pcall(syn.protect_gui, sg) end
        sg.Parent = parent
    end
    storageGui = sg
    return sg
end

-- ====== Реестр своих секций ======
local mySections = {}
local headlessMode = false

local function stubSection()
    return setmetatable({}, { __index = function() return function() end end })
end

-- защита от отсутствующих/падающих методов чужого меню
local function protectSection(sec)
    if typeof(sec) ~= "table" then return stubSection() end
    local proxy = { _raw = sec }
    return setmetatable(proxy, {
        __index = function(p, key)
            local raw = p._raw
            local value = raw[key]
            if type(value) == "function" then
                return function(first, ...)
                    -- вызов вида sec:AddButton(...) передаёт прокси первым
                    -- аргументом — его нужно отбросить, иначе все аргументы
                    -- уедут на одну позицию
                    local ok, err
                    if first == p then
                        ok, err = pcall(value, raw, ...)
                    else
                        ok, err = pcall(value, raw, first, ...)
                    end
                    if not ok then warn("[" .. BRAND .. "][menu] " .. tostring(key) .. ": " .. tostring(err)) end
                    return ok and err or nil
                end
            end
            return value
        end,
    })
end

local function AddSection(name)
    local ok, sec = pcall(function() return shared.AddSection(name) end)
    local obj
    if ok and sec then
        obj = protectSection(sec)
    else
        headlessMode = true
        obj = stubSection()
    end
    insert(mySections, { name = name, obj = obj })
    return obj
end

-- ====== Сканер GUI: поиск карточек, маркеры, дедупликация ======
local function guiRoots()
    local roots, seen = {}, {}
    local function add(r)
        if typeof(r) == "Instance" and not seen[r] then
            seen[r] = true
            roots[#roots + 1] = r
        end
    end
    pcall(function() add(gethui and gethui()) end)
    pcall(function() add(getcore and getcore()) end)
    add(CoreGui)
    pcall(function() add(LocalPlayer:FindFirstChildOfClass("PlayerGui")) end)
    return roots
end

-- мемоизированная проверка «это окно хоста?» (было: пересчёт для каждого label)
local function hasHostWords(node, memo)
    local cached = memo[node]
    if cached ~= nil then return cached end
    local res = false
    local descendants = node:GetDescendants()
    for i = 1, #descendants do
        local d = descendants[i]
        if d:IsA("TextLabel") then
            local txt = d.Text
            for w = 1, #HOST_WORDS do
                if txt:find(HOST_WORDS[w], 1, true) then
                    res = true
                    break
                end
            end
            if res then break end
        end
    end
    memo[node] = res
    return res
end

-- поднимается вверх от label и ищет «карточку» секции
local function findCard(node, memo)
    for _ = 1, 7 do
        if not node or typeof(node) ~= "Instance" or node == game then return nil end
        if node:IsA("Frame") or node:IsA("ScrollingFrame") then
            local framed = node:FindFirstChildOfClass("UIStroke") or node:FindFirstChildOfClass("UICorner")
            if framed then
                local sz = node.AbsoluteSize
                if sz.Y > 0 and sz.Y < MAX_CARD_HEIGHT and not hasHostWords(node, memo) then
                    return node
                end
            end
        end
        node = node.Parent
    end
    return nil
end

local function markerOf(card)
    if not card then return nil end
    local descendants = card:GetDescendants()
    for i = 1, #descendants do
        local d = descendants[i]
        if d.Name:sub(1, #MARKER_PREFIX) == MARKER_PREFIX then return d.Name end
    end
    return nil
end

local function attachMarker(card)
    if not card or markerOf(card) then return false end
    local ok = pcall(function()
        local sv = new("StringValue")
        sv.Name = RUN_ID
        sv.Value = VERSION
        sv.Parent = card
    end)
    return ok
end

local lastPurge = 0
local PURGE_COOLDOWN = 0.5

-- «своя» карточка: есть наш маркер ИЛИ в ней виден текст нашей версии
-- (страховка на случай, если маркер не прикрепился)
local function cardIsOurs(card)
    if markerOf(card) == RUN_ID then return true end
    local descendants = card:GetDescendants()
    for i = 1, #descendants do
        local d = descendants[i]
        if d:IsA("TextLabel") and d.Text:find(VERSION_TAG, 1, true) then return true end
    end
    return false
end

-- удаляет карточки, созданные НЕ этим запуском (старые версии + чужие дубли)
local function purgeForeign(force)
    local t = now()
    if not force and (t - lastPurge) < PURGE_COOLDOWN then return 0 end
    lastPurge = t
    local killed = 0
    for _, root in ipairs(guiRoots()) do
        local memo = {}
        local descendants = root:GetDescendants()
        for i = 1, #descendants do
            local d = descendants[i]
            if d.Parent and d:IsA("TextLabel") then
                local txt = d.Text
                if CUR_TITLES[txt] or (CLEAN_LEGACY_MENU and LEGACY_TITLES[txt]) then
                    local card = findCard(d, memo)
                    if card and not cardIsOurs(card) then
                        if pcall(function() card:Destroy() end) then killed = killed + 1 end
                    end
                end
            end
        end
    end
    return killed
end

-- помечает наши карточки уникальным маркером (после постройки меню)
local markedCount = 0
local function markOwnCards()
    local marked = 0
    for _, root in ipairs(guiRoots()) do
        local memo = {}
        local descendants = root:GetDescendants()
        for i = 1, #descendants do
            local d = descendants[i]
            if d.Parent and d:IsA("TextLabel") and CUR_TITLES[d.Text] then
                local card = findCard(d, memo)
                if card and markerOf(card) == nil and attachMarker(card) then
                    marked = marked + 1
                end
            end
        end
    end
    markedCount = markedCount + marked
    return marked
end

-- fallback на случай, если маркеры не прикрепились (старая логика по заголовкам)
local function removeByTitles()
    local removed = 0
    for _, root in ipairs(guiRoots()) do
        local memo = {}
        local descendants = root:GetDescendants()
        for i = 1, #descendants do
            local d = descendants[i]
            if d.Parent and d:IsA("TextLabel") and CUR_TITLES[d.Text] then
                local card = findCard(d, memo)
                if card and not markerOf(card) then
                    if pcall(function() card:Destroy() end) then removed = removed + 1 end
                end
            end
        end
    end
    return removed
end

local function removeMySections()
    local removed = 0
    for _, root in ipairs(guiRoots()) do
        local descendants = root:GetDescendants()
        for i = 1, #descendants do
            local d = descendants[i]
            if d.Name == RUN_ID and d.Parent then
                local card = d.Parent
                pcall(function() d:Destroy() end)
                if pcall(function() card:Destroy() end) then removed = removed + 1 end
            end
        end
    end
    if removed == 0 and markedCount == 0 then removed = removeByTitles() end
    return removed
end

-- срезать мусор прошлых версий ещё до построения своего меню
pcall(purgeForeign, true)

-- ====== Звук клика (один на все кнопки) ======
local Audio = { click = nil }
function Audio.init()
    local s = new("Sound")
    s.Name = "@click"
    s.SoundId = "rbxassetid://3868133279"
    s.Volume = config.muteSounds and 0 or 0.5
    s.Parent = getStorage()
    Audio.click = s
    RootMaid:GiveTask(s)
end
function Audio.play()
    local s = Audio.click
    if not s or s.Volume <= 0 then return end
    pcall(function() s:Play() end)
end
function Audio.setMuted(muted)
    config.muteSounds = muted and true or false
    if Audio.click then Audio.click.Volume = config.muteSounds and 0 or 0.5 end
    saveConfig()
end

-- ====== Bindable Buttons ======
local BindableButtons = {
    Buttons = {},   -- {[id] = ImageButton}   (совместимость с V5.x)
    Maids   = {},   -- {[id] = Maid}          (совместимость с V5.x)
    recs    = {},   -- {[id] = запись анимации/позиции}
    order   = {},   -- порядок раскладки
    Count   = 0,
    ResetActive = false,
    CurrentSize = config.bindButtonSize or 0.11,
}

local __SHAPES = {
    [0] = "rbxassetid://86221076925479",
    [1] = "rbxassetid://96242665417546",
    [2] = "rbxassetid://97129189935336",
    [3] = "rbxassetid://76165862027868",
    [4] = "rbxassetid://125868092127496",
}
local GLOW_IMG = "rbxassetid://131961136"

local __NORMAL_COLOR = cs({
    csk(0,   pclr(0.133333, 0.827451, 0.494118)),
    csk(0.6, pclr(0.231373, 0.509804, 0.498039)),
    csk(1,   pclr(0.501961, 0.501961, 0.501961)),
})
local __WAIT_COLOR = cs({
    csk(0,   pclr(0.827451, 0.133333, 0.133333)),
    csk(0.6, pclr(0.509804, 0.231373, 0.231373)),
    csk(1,   pclr(0.501961, 0.501961, 0.501961)),
})
local __GOLD_NORMAL_COLOR = cs({
    csk(0,   rgb(255, 215, 0)),
    csk(0.6, rgb(218, 165, 32)),
    csk(1,   rgb(128, 128, 128)),
})
local __GOLD_WAIT_COLOR = cs({
    csk(0,   rgb(255, 69, 0)),
    csk(0.6, rgb(139, 0, 0)),
    csk(1,   rgb(128, 128, 128)),
})

local function bind_safecallback(callback)
    if not callback then return end
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then warn("[" .. BRAND .. "][bind] " .. tostring(err)) end
end

-- раскладка сеткой + восстановленные из конфига позиции
function BindableButtons.relayout()
    local camera = Workspace.CurrentCamera
    local screen = (camera and camera.ViewportSize) or FALLBACK_VIEWPORT
    local h = BindableButtons.CurrentSize or 0.11
    local w = h * (screen.Y / screen.X)
    local perRow = math.max(1, floor(0.84 / (w + 0.008)))
    for i = 1, #BindableButtons.order do
        local id = BindableButtons.order[i]
        local rec = BindableButtons.recs[id]
        if rec then
            local saved = config.bindPositions[id]
            if saved and type(saved.x) == "number" and type(saved.y) == "number" then
                rec.x, rec.y = saved.x, saved.y
            else
                local row = floor((i - 1) / perRow)
                local col = (i - 1) % perRow
                rec.x = 0.08 + col * (w + 0.008)
                rec.y = 0.88 - row * (h + 0.02)
            end
            rec.btn.Position = ud2(rec.x, 0, rec.y, 0)
            rec.glow.Position = ud2(rec.x, 0, rec.y, 0)
        end
    end
end

function BindableButtons.setSize(sizeScale)
    BindableButtons.CurrentSize = clamp(sizeScale or 0.11, 0.02, 0.4)
    config.bindButtonSize = BindableButtons.CurrentSize
    BindableButtons.relayout()
    saveConfig()
end

-- один общий обработчик движения/отпускания на все кнопки
local dragState = nil

local binderGlobalMaid = Maid.new()
RootMaid:GiveTask(binderGlobalMaid)

-- Драг обязан реагировать ТОЛЬКО на тот ввод, который его начал.
-- На телефоне каждое касание — отдельный InputObject: если принимать любой
-- Touch, то палец на джойстике движения будет таскать кнопку за собой
-- (именно так было в первой переписи — в старом плагине стояла сверка
-- input == dragInput, поэтому там кнопка оставалась на месте).
local function isDragInput(input)
    if not dragState then return false end
    if input == dragState.dragInput then return true end   -- мышь: MouseMovement-объект самой кнопки
    if input == dragState.input then return true end       -- тач: один InputObject на всё касание
    return false
end

binderGlobalMaid:GiveTask(UserInputService.InputChanged:Connect(function(input)
    if not dragState then return end
    if input.UserInputType ~= MOUSEMOV and input.UserInputType ~= TOUCH then return end
    if not isDragInput(input) then return end             -- чужой палец/курсор — игнорируем
    local rec = dragState.rec
    if not rec or not rec.btn then return end
    local delta = input.Position - dragState.startInput
    if delta.Magnitude > 7 then dragState.moved = true end
    local parentGui = rec.btn.Parent
    if not parentGui then return end
    local screen = parentGui.AbsoluteSize
    if screen.X <= 0 or screen.Y <= 0 then return end
    rec.x = clamp(dragState.startX + (delta.X / screen.X), 0.03, 0.97)
    rec.y = clamp(dragState.startY + (delta.Y / screen.Y), 0.05, 0.95)
    rec.btn.Position = ud2(rec.x, 0, rec.y, 0)
    rec.glow.Position = ud2(rec.x, 0, rec.y, 0)
end))

binderGlobalMaid:GiveTask(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType ~= MOUSE1 and input.UserInputType ~= TOUCH then return end
    -- анимацию нажатия сбрасываем всегда
    for _, rec in pairs(BindableButtons.recs) do rec.targetPress = 0 end
    if not dragState then return end
    -- Завершаем драг только если отпущен ТОТ ЖЕ ввод, что его начал.
    -- Иначе отпускание пальца с джойстика засчитывалось бы как тап по кнопке
    -- и запускало действие. Для мыши InputObject при отпускании может
    -- отличаться, поэтому там сверяем тип кнопки (как в старой версии).
    local mine = (input == dragState.input)
        or (input == dragState.dra... (48 KB left)
