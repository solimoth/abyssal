--!strict

--[[
    Dynamic LOD management service.
    This module keeps track of a set of LOD groups and chooses which level to
    display for each group based on the local camera distance. It is designed to
    run on the client so that high-detail geometry can be spawned locally without
    impacting server replication costs, but it can also be used on the server for
    coarse toggles.

    Usage:
        local LODService = require(ReplicatedStorage.Modules.LODService)
        local service = LODService.GetDefault()
        service:Start()

        local handle = service:Register(someModel, {
            Levels = {
                {
                    Instance = highDetailModelClone,
                    MaxDistance = 250,
                    PivotOffset = basePivot:ToObjectSpace(highDetailModelClone:GetPivot()),
                },
                {
                    Instance = lowDetailModelClone,
                    PivotOffset = basePivot:ToObjectSpace(lowDetailModelClone:GetPivot()),
                },
            },
            GetPivot = function()
                return someModel:GetPivot()
            end,
        })

        -- Later when the group is no longer needed:
        handle:Destroy()
--]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type LevelDefinition = {
    Instance: Instance,
    MaxDistance: number?,
    MinDistance: number?,
    Activate: ((Instance, Instance) -> ())?,
    Deactivate: ((Instance) -> ())?,
    Placement: ((Instance, CFrame, CFrame?) -> ())?,
    PivotOffset: CFrame?,
}

export type RegisterConfig = {
    Levels: {LevelDefinition},
    GetPivot: (() -> CFrame)?,
    ActiveParent: Instance?,
    ActiveContainer: Instance?,
    ContainerName: string?,
    Hysteresis: number?,
    UnloadDistance: number?,
    DestroyInstances: boolean?,
}

export type GroupHandle = {
    Destroy: (GroupHandle) -> (),
}

type InternalLevel = {
    Instance: Instance,
    MaxDistance: number?,
    MinDistance: number,
    Activate: ((Instance, Instance) -> ())?,
    Deactivate: ((Instance) -> ())?,
    Placement: ((Instance, CFrame, CFrame?) -> ())?,
    PivotOffset: CFrame?,
    Active: boolean,
}

type InternalGroup = {
    Source: Instance,
    Levels: {InternalLevel},
    CurrentIndex: number,
    ActiveContainer: Instance?,
    AutoContainer: boolean,
    GetPivot: () -> CFrame,
    Options: {
        Hysteresis: number,
        UnloadDistance: number?,
        DestroyInstances: boolean,
    },
    LastPivot: CFrame?,
    LastDistance: number,
}

local GroupHandleClass = {}
GroupHandleClass.__index = GroupHandleClass

function GroupHandleClass.new(service, group: InternalGroup)
    return setmetatable({ _service = service, _group = group }, GroupHandleClass)
end

function GroupHandleClass:Destroy()
    local service = rawget(self, "_service")
    local group = rawget(self, "_group")
    if service and group then
        service:_removeGroup(group)
    end
    rawset(self, "_service", nil)
    rawset(self, "_group", nil)
end

local LODService = {}
LODService.__index = LODService

local defaultService: LODService?

local MIN_UPDATE_INTERVAL = 1 / 60

local function safePivotFromSource(source: Instance): () -> CFrame
    if source:IsA("Model") then
        return function()
            return source:GetPivot()
        end
    elseif source:IsA("BasePart") then
        return function()
            return source.CFrame
        end
    elseif source:IsA("Attachment") then
        return function()
            return source.WorldCFrame
        end
    end

    local basePart = source:FindFirstChildWhichIsA("BasePart", true)
    if basePart then
        return function()
            return basePart.CFrame
        end
    end

    error(string.format("[LODService] Unable to determine pivot for %s", source:GetFullName()))
end

local function alignInstance(instance: Instance, worldPivot: CFrame)
    if instance:IsA("Model") then
        instance:PivotTo(worldPivot)
    elseif instance:IsA("PVInstance") then
        (instance :: PVInstance).CFrame = worldPivot
    elseif instance:IsA("Attachment") then
        (instance :: Attachment).WorldCFrame = worldPivot
    else
        warn(string.format("[LODService] Cannot align instance of type %s", instance.ClassName))
    end
end

local function compareLevels(a: InternalLevel, b: InternalLevel): boolean
    local aMax = a.MaxDistance or math.huge
    local bMax = b.MaxDistance or math.huge
    if aMax == bMax then
        return a.MinDistance < b.MinDistance
    end
    return aMax < bMax
end

function LODService.new()
    local self = setmetatable({}, LODService)
    self._groups = {} :: {InternalGroup}
    self._updateInterval = 0.15
    self._maxUpdatesPerStep = 24
    self._defaultHysteresis = 25
    self._accumulator = 0
    self._connection = nil :: RBXScriptConnection?
    self._nextIndex = 1
    return self
end

function LODService.GetDefault(): LODService
    if not defaultService then
        defaultService = LODService.new()
    end
    return defaultService
end

function LODService:SetUpdateInterval(interval: number)
    self._updateInterval = math.max(MIN_UPDATE_INTERVAL, interval)
end

function LODService:GetUpdateInterval(): number
    return self._updateInterval
end

function LODService:SetMaxUpdatesPerStep(count: number)
    self._maxUpdatesPerStep = math.max(1, math.floor(count))
end

function LODService:GetMaxUpdatesPerStep(): number
    return self._maxUpdatesPerStep
end

function LODService:Start()
    if self._connection then
        return
    end

    self._accumulator = 0
    self._connection = RunService.Heartbeat:Connect(function(dt)
        self._accumulator += dt
        if self._accumulator < self._updateInterval then
            return
        end

        self:_step()
        self._accumulator = 0
    end)
end

function LODService:Stop()
    if self._connection then
        self._connection:Disconnect()
        self._connection = nil
    end
end

function LODService:IsRunning(): boolean
    return self._connection ~= nil
end

function LODService:Unregister(source: Instance)
    for index, group in ipairs(self._groups) do
        if group.Source == source then
            self:_removeGroupAt(index)
            break
        end
    end
end

function LODService:Register(source: Instance, config: RegisterConfig): GroupHandle
    assert(typeof(source) == "Instance", "LODService:Register expects an Instance source")
    assert(typeof(config) == "table", "LODService:Register expects a configuration table")
    assert(typeof(config.Levels) == "table" and #config.Levels > 0, "LODService:Register requires at least one level")

    local levels: {InternalLevel} = {}
    for _, level in ipairs(config.Levels) do
        local instance = level.Instance
        if not instance then
            error("[LODService] Level is missing Instance reference")
        end

        local internalLevel: InternalLevel = {
            Instance = instance,
            MaxDistance = typeof(level.MaxDistance) == "number" and level.MaxDistance or nil,
            MinDistance = typeof(level.MinDistance) == "number" and level.MinDistance or 0,
            Activate = level.Activate,
            Deactivate = level.Deactivate,
            Placement = level.Placement,
            PivotOffset = level.PivotOffset,
            Active = false,
        }

        instance.Parent = nil
        table.insert(levels, internalLevel)
    end

    table.sort(levels, compareLevels)

    local getPivot = config.GetPivot or safePivotFromSource(source)
    local hysteresis = typeof(config.Hysteresis) == "number" and config.Hysteresis or self._defaultHysteresis
    local unloadDistance = typeof(config.UnloadDistance) == "number" and config.UnloadDistance or nil
    local destroyInstances = config.DestroyInstances ~= false

    local activeParent = config.ActiveParent
    if not activeParent or not activeParent.Parent then
        activeParent = Workspace
    end

    local activeContainer = config.ActiveContainer
    local autoContainer = false
    if not activeContainer then
        activeContainer = Instance.new("Folder")
        activeContainer.Name = config.ContainerName or (source.Name .. "_LOD")
        activeContainer.Parent = activeParent
        autoContainer = true
    end

    local group: InternalGroup = {
        Source = source,
        Levels = levels,
        CurrentIndex = 0,
        ActiveContainer = activeContainer,
        AutoContainer = autoContainer,
        GetPivot = getPivot,
        Options = {
            Hysteresis = hysteresis,
            UnloadDistance = unloadDistance,
            DestroyInstances = destroyInstances,
        },
        LastPivot = nil,
        LastDistance = 0,
    }

    table.insert(self._groups, group)

    local handle = GroupHandleClass.new(self, group)

    self:_updateGroup(group, true)

    return handle
end

function LODService:_removeGroup(group: InternalGroup)
    for index, item in ipairs(self._groups) do
        if item == group then
            self:_removeGroupAt(index)
            break
        end
    end
end

function LODService:_removeGroupAt(index: number)
    local group = table.remove(self._groups, index)
    if not group then
        return
    end

    if index <= self._nextIndex then
        self._nextIndex = math.max(1, self._nextIndex - 1)
    end

    self:_deactivateCurrent(group)

    for _, level in ipairs(group.Levels) do
        if group.Options.DestroyInstances and level.Instance then
            pcall(function()
                level.Instance:Destroy()
            end)
        else
            if level.Instance and level.Instance.Parent then
                level.Instance.Parent = nil
            end
        end
    end

    if group.AutoContainer and group.ActiveContainer and group.ActiveContainer.Parent then
        group.ActiveContainer:Destroy()
    end
end

function LODService:_step()
    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end

    local count = #self._groups
    if count == 0 then
        return
    end

    local iterations = math.min(self._maxUpdatesPerStep, count)

    for i = 1, iterations do
        if self._nextIndex > #self._groups then
            self._nextIndex = 1
        end

        local group = self._groups[self._nextIndex]
        self._nextIndex += 1

        if group then
            self:_updateGroup(group, false)
        end
    end

    if self._nextIndex > #self._groups then
        self._nextIndex = 1
    end
end

function LODService:_updateGroup(group: InternalGroup, force: boolean)
    if not group.Source or not group.Source.Parent then
        self:_removeGroup(group)
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end

    local pivot: CFrame
    local ok, result = pcall(group.GetPivot)
    if ok then
        pivot = result
    else
        warn(string.format("[LODService] Failed to compute pivot for %s: %s", group.Source:GetFullName(), tostring(result)))
        return
    end

    group.LastPivot = pivot

    local cameraPosition = camera.CFrame.Position
    local distance = (cameraPosition - pivot.Position).Magnitude
    group.LastDistance = distance

    local targetIndex = self:_resolveTargetLevel(group, distance)
    if force or targetIndex ~= group.CurrentIndex then
        self:_applyLevel(group, targetIndex)
    end

    self:_updatePlacement(group)
end

function LODService:_resolveTargetLevel(group: InternalGroup, distance: number): number
    local unloadDistance = group.Options.UnloadDistance
    if unloadDistance and distance >= unloadDistance then
        return 0
    end

    local targetIndex = 1
    for index, level in ipairs(group.Levels) do
        local minDistance = level.MinDistance
        local maxDistance = level.MaxDistance or math.huge

        if distance < minDistance then
            targetIndex = math.max(1, index - 1)
            break
        end

        targetIndex = index

        if distance <= maxDistance then
            break
        end
    end

    local currentIndex = group.CurrentIndex
    if currentIndex > 0 and targetIndex ~= currentIndex then
        local hysteresis = group.Options.Hysteresis
        if targetIndex < currentIndex then
            local targetLevel = group.Levels[targetIndex]
            local threshold = (targetLevel.MaxDistance or math.huge) - hysteresis
            if distance > threshold then
                targetIndex = currentIndex
            end
        elseif targetIndex > currentIndex then
            local currentLevel = group.Levels[currentIndex]
            local threshold = (currentLevel.MaxDistance or math.huge) + hysteresis
            if distance < threshold then
                targetIndex = currentIndex
            end
        end
    end

    return targetIndex
end

function LODService:_deactivateCurrent(group: InternalGroup)
    local currentIndex = group.CurrentIndex
    if currentIndex <= 0 then
        return
    end

    local currentLevel = group.Levels[currentIndex]
    if currentLevel and currentLevel.Active then
        self:_deactivateLevel(group, currentLevel)
    end
    group.CurrentIndex = 0
end

function LODService:_applyLevel(group: InternalGroup, targetIndex: number)
    local previousIndex = group.CurrentIndex
    if previousIndex > 0 then
        local previousLevel = group.Levels[previousIndex]
        if previousLevel and previousLevel.Active and previousIndex ~= targetIndex then
            self:_deactivateLevel(group, previousLevel)
        end
    end

    if targetIndex <= 0 then
        group.CurrentIndex = 0
        return
    end

    local targetLevel = group.Levels[targetIndex]
    if not targetLevel then
        group.CurrentIndex = 0
        return
    end

    if not targetLevel.Active then
        self:_activateLevel(group, targetLevel)
    end

    group.CurrentIndex = targetIndex
end

function LODService:_activateLevel(group: InternalGroup, level: InternalLevel)
    local parent = group.ActiveContainer or Workspace
    local ok, err
    if level.Activate then
        ok, err = pcall(level.Activate, level.Instance, parent)
    else
        level.Instance.Parent = parent
        ok = true
    end

    if not ok then
        warn(string.format("[LODService] Failed to activate level: %s", tostring(err)))
    else
        level.Active = true
    end
end

function LODService:_deactivateLevel(group: InternalGroup, level: InternalLevel)
    local ok, err
    if level.Deactivate then
        ok, err = pcall(level.Deactivate, level.Instance)
    else
        level.Instance.Parent = nil
        ok = true
    end

    if not ok then
        warn(string.format("[LODService] Failed to deactivate level: %s", tostring(err)))
    else
        level.Active = false
    end
end

function LODService:_updatePlacement(group: InternalGroup)
    local currentIndex = group.CurrentIndex
    if currentIndex <= 0 then
        return
    end

    local currentLevel = group.Levels[currentIndex]
    if not currentLevel or not currentLevel.Active then
        return
    end

    local pivot = group.LastPivot
    if not pivot then
        return
    end

    local offset = currentLevel.PivotOffset or CFrame.identity
    local targetPivot = pivot * offset

    if currentLevel.Placement then
        local ok, err = pcall(currentLevel.Placement, currentLevel.Instance, pivot, offset)
        if not ok then
            warn(string.format("[LODService] Placement callback failed: %s", tostring(err)))
        end
        return
    end

    alignInstance(currentLevel.Instance, targetPivot)
end

return LODService
