local shared = odh_shared_plugins

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local userWantsEnabled = false
local enabled = false
local velocityConnection = nil
local hadKnifeLastFrame = false

local ignoreListEnabled = true
local slot1Player = nil
local slot2Player = nil
local slot3Player = nil

local aaSection = shared.AddSection("Anti-Aim Extension")

local function getPlayerList()
    local list = {"None"}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            table.insert(list, p.Name)
        end
    end
    return list
end

local function findPlayerByName(name)
    if not name or name == "None" then return nil end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name == name then
            return p
        end
    end
    return nil
end

local function hasKnife()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local character = LocalPlayer.Character
    if backpack and backpack:FindFirstChild("Knife") then
        return true
    end
    if character and character:FindFirstChild("Knife") then
        return true
    end
    return false
end

local function isPlayerNearby(hrp)
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
            local otherHrp = player.Character.HumanoidRootPart
            if (otherHrp.Position - hrp.Position).Magnitude <= 6 then
                return true
            end
        end
    end
    return false
end

local function isInWater(humanoid)
    local state = humanoid:GetState()
    return state == Enum.HumanoidStateType.Swimming or humanoid.FloorMaterial == Enum.Material.Water
end

local function isIgnoredPlayerArmed()
    if not ignoreListEnabled then
        return false
    end

    local targets = {slot1Player, slot2Player, slot3Player}
    for _, player in ipairs(targets) do
        if player and player.Parent then
            local backpack = player:FindFirstChild("Backpack")
            local character = player.Character
            
            if backpack then
                for _, item in ipairs(backpack:GetChildren()) do
                    if item:IsA("Tool") then
                        return true
                    end
                end
            end
            
            if character then
                for _, item in ipairs(character:GetChildren()) do
                    if item:IsA("Tool") then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function performRoleStep(humanoid)
    task.spawn(function()
        local randomX = math.random() > 0.5 and 1 or -1
        local randomZ = math.random() > 0.5 and 1 or -1
        local moveDir = Vector3.new(randomX, 0, randomZ).Unit

        local startTime = tick()
        while tick() - startTime < 0.15 do
            if humanoid and humanoid.Parent then
                humanoid:Move(moveDir, false)
            end
            RunService.RenderStepped:Wait()
        end
    end)
end

local function stopAntiAim()
    if velocityConnection then
        velocityConnection:Disconnect()
        velocityConnection = nil
    end
end

local function startAntiAim()
    if velocityConnection then return end
    velocityConnection = RunService.Heartbeat:Connect(function()
        if isIgnoredPlayerArmed() then
            if enabled then
                enabled = false
            end
            return
        else
            if userWantsEnabled and not enabled then
                enabled = true
            end
        end

        local character = LocalPlayer.Character
        if character and character:FindFirstChild("HumanoidRootPart") and character:FindFirstChild("Humanoid") then
            local humanoid = character.Humanoid
            if humanoid.Health > 0 then
                local hrp = character.HumanoidRootPart
                local currentlyHasKnife = hasKnife()

                if currentlyHasKnife and not hadKnifeLastFrame then
                    performRoleStep(humanoid)
                end
                hadKnifeLastFrame = currentlyHasKnife

                if currentlyHasKnife and not isPlayerNearby(hrp) and not isInWater(humanoid) then
                    local oldVelocity = hrp.AssemblyLinearVelocity
                    local state = humanoid:GetState()
                    local isJumping = (state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall)
                    local isStopped = (humanoid.MoveDirection.Magnitude == 0)

                    local multiplier = math.random(1, 2) == 1 and 320 or -320
                    
                    if isJumping then
                        local jumpMultY = math.random(1, 2) == 1 and 250 or -250
                        hrp.AssemblyLinearVelocity = Vector3.new(multiplier, jumpMultY, multiplier)
                    elseif isStopped then
                        local stopMult = math.random(1, 2) == 1 and 400 or -400
                        hrp.AssemblyLinearVelocity = Vector3.new(stopMult, 0, stopMult)
                    else
                        hrp.AssemblyLinearVelocity = Vector3.new(multiplier, 0, multiplier)
                    end
                    
                    RunService.RenderStepped:Wait()
                    hrp.AssemblyLinearVelocity = oldVelocity
                end
            end
        else
            hadKnifeLastFrame = false
        end
    end)
end

aaSection:AddToggle("Enable Anti-Aim", function(bool)
    userWantsEnabled = bool
    enabled = bool
    if bool then
        startAntiAim()
        shared.Notify("Anti-Aim Enabled", 2)
    else
        stopAntiAim()
        shared.Notify("Anti-Aim Disabled", 2)
    end
end)

aaSection:AddToggle("Enable Ignore List", function(bool)
    ignoreListEnabled = bool
    if bool then
        shared.Notify("Ignore List Enabled", 2)
    else
        shared.Notify("Ignore List Disabled", 2)
    end
end)

local drop1, drop2, drop3

local function updateDropdowns()
    local list = getPlayerList()
    if drop1 then drop1.Change(list) end
    if drop2 then drop2.Change(list) end
    if drop3 then drop3.Change(list) end
end

drop1 = aaSection:AddDropdown("Ignore Player 1", getPlayerList(), function(selected)
    slot1Player = findPlayerByName(selected)
    if slot1Player then
        shared.Notify("Slot 1: " .. slot1Player.Name, 2)
    else
        shared.Notify("Slot 1: None", 2)
    end
end)

drop2 = aaSection:AddDropdown("Ignore Player 2", getPlayerList(), function(selected)
    slot2Player = findPlayerByName(selected)
    if slot2Player then
        shared.Notify("Slot 2: " .. slot2Player.Name, 2)
    else
        shared.Notify("Slot 2: None", 2)
    end
end)

drop3 = aaSection:AddDropdown("Ignore Player 3", getPlayerList(), function(selected)
    slot3Player = findPlayerByName(selected)
    if slot3Player then
        shared.Notify("Slot 3: " .. slot3Player.Name, 2)
    else
        shared.Notify("Slot 3: None", 2)
    end
end)

Players.PlayerAdded:Connect(function()
    updateDropdowns()
end)

Players.PlayerRemoving:Connect(function(player)
    if slot1Player == player then slot1Player = nil end
    if slot2Player == player then slot2Player = nil end
    if slot3Player == player then slot3Player = nil end
    updateDropdowns()
end)
