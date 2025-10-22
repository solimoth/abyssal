--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StreamingService = game:GetService("StreamingService")

local LODService = require(ReplicatedStorage.Modules.LODService)
type LODServiceModule = typeof(LODService)

local lodService = LODService.GetDefault()
lodService:SetUpdateInterval(0.12)
lodService:SetMaxUpdatesPerStep(20)
lodService:Start()

type GroupHandle = LODServiceModule.GroupHandle

type RegisteredEntry = {
    Handle: GroupHandle,
    Connections: {RBXScriptConnection},
}

local registered: { [Instance]: RegisteredEntry } = {}
type PendingEntry = {
    Connections: {RBXScriptConnection},
}

local pending: { [Instance]: PendingEntry } = {}

local function cleanupPending(root: Instance)
    local entry = pending[root]
    if not entry then
        return
    end

    for _, conn in ipairs(entry.Connections) do
        conn:Disconnect()
    end

    pending[root] = nil
end

local unregister

local function readNumberAttribute(instance: Instance, names: {string}): number?
    for _, name in ipairs(names) do
        local value = instance:GetAttribute(name)
        if typeof(value) == "number" then
            return value
        end
    end
    return nil
end

local function requestStreamingAround(position: Vector3)
    if not Workspace.StreamingEnabled then
        return
    end

    local attempts = {}

    if StreamingService and typeof(StreamingService.RequestStreamAroundAsync) == "function" then
        table.insert(attempts, function()
            StreamingService:RequestStreamAroundAsync(position)
        end)
    end

    if typeof(Workspace.RequestStreamAroundAsync) == "function" then
        table.insert(attempts, function()
            Workspace:RequestStreamAroundAsync(position)
        end)
    end

    if #attempts == 0 then
        warn("[LOD] Streaming request API is unavailable on this client")
        return
    end

    local lastErr: string? = nil
    for _, attempt in ipairs(attempts) do
        local ok, err = pcall(attempt)
        if ok then
            return
        end

        lastErr = tostring(err)
    end

    if lastErr then
        warn(string.format(
            "[LOD] Failed to request streaming around %.1f, %.1f, %.1f: %s",
            position.X,
            position.Y,
            position.Z,
            lastErr
        ))
    end
end

local function waitForModelStream(model: Model)
    if not Workspace.StreamingEnabled then
        return
    end

    local deadline = os.clock() + 4
    local lastCount = #(model:GetDescendants())
    local stableSteps = 0

    while os.clock() < deadline do
        task.wait()

        local currentCount = #(model:GetDescendants())
        if currentCount == 0 then
            continue
        end

        if currentCount == lastCount then
            stableSteps += 1
            if stableSteps >= 3 then
                break
            end
        else
            lastCount = currentCount
            stableSteps = 0
        end
    end
end

local function computeInstancePivot(instance: Instance): CFrame
    if instance:IsA("Model") then
        return instance:GetPivot()
    elseif instance:IsA("PVInstance") then
        return (instance :: PVInstance).CFrame
    elseif instance:IsA("Attachment") then
        return (instance :: Attachment).WorldCFrame
    end

    error(string.format("[LOD] Cannot compute pivot for %s", instance:GetFullName()))
end

local function resolveLevelsFolder(root: Model): Folder?
    local customPath = root:GetAttribute("LODLevelsPath")
    if typeof(customPath) == "string" and customPath ~= "" then
        local segments = string.split(customPath, "/")
        local current: Instance? = nil

        for index, rawSegment in ipairs(segments) do
            local segment = rawSegment
            if segment == "" then
                continue
            end

            if index == 1 then
                local ok, service = pcall(game.GetService, game, segment)
                if ok and service then
                    current = service
                else
                    current = Workspace:FindFirstChild(segment) or ReplicatedStorage:FindFirstChild(segment)
                end
            else
                if not current then
                    break
                end

                current = current:FindFirstChild(segment)
            end

            if not current then
                break
            end
        end

        if current then
            if current:IsA("Folder") then
                return current
            else
                warn(string.format(
                    "[LOD] LODLevelsPath '%s' on %s resolved to %s which is not a Folder",
                    customPath,
                    root:GetFullName(),
                    current:GetFullName()
                ))
            end
        else
            warn(string.format(
                "[LOD] LODLevelsPath '%s' on %s could not be resolved",
                customPath,
                root:GetFullName()
            ))
        end
    end

    local levelsFolder = root:FindFirstChild("LODLevels")
    if levelsFolder and levelsFolder:IsA("Folder") then
        return levelsFolder
    end

    return nil
end

local function createPivotResolver(root: Model): () -> CFrame
    local anchorName = root:GetAttribute("LODAnchor")
    if typeof(anchorName) == "string" and anchorName ~= "" then
        local anchor = root:FindFirstChild(anchorName, true)
        if anchor then
            if anchor:IsA("Model") then
                return function()
                    return anchor:GetPivot()
                end
            elseif anchor:IsA("BasePart") then
                return function()
                    return anchor.CFrame
                end
            elseif anchor:IsA("Attachment") then
                return function()
                    return anchor.WorldCFrame
                end
            else
                warn(string.format("[LOD] Anchor %s on %s is not a supported type", anchor:GetFullName(), root:GetFullName()))
            end
        else
            warn(string.format("[LOD] Anchor %s not found on %s; falling back to model pivot", anchorName, root:GetFullName()))
        end
    end

    return function()
        return root:GetPivot()
    end
end

local function resolveActiveParent(root: Model): Instance?
    local target = root:GetAttribute("LODActiveParent")
    if typeof(target) == "string" and target ~= "" then
        local descendant = root:FindFirstChild(target, true)
        if descendant then
            return descendant
        end

        local workspaceCandidate = Workspace:FindFirstChild(target)
        if workspaceCandidate then
            return workspaceCandidate
        end

        warn(string.format("[LOD] Unable to resolve LODActiveParent '%s' for %s", target, root:GetFullName()))
    end

    return nil
end

local function buildLevelConfigurations(root: Model, basePivot: CFrame)
    local levelsFolder = resolveLevelsFolder(root)
    if not levelsFolder then
        warn(string.format("[LOD] %s does not have a LODLevels folder", root:GetFullName()))
        return nil
    end

    local definitions = levelsFolder:GetChildren()
    table.sort(definitions, function(a, b)
        return a.Name < b.Name
    end)

    local levels = {}
    local consumedDefinitions = {}
    for _, definition in ipairs(definitions) do
        if not definition.Archivable then
            warn(string.format("[LOD] %s is not archivable and will be skipped", definition:GetFullName()))
            continue
        end

        if not (definition:IsA("Model") or definition:IsA("PVInstance")) then
            warn(string.format("[LOD] %s is not a Model or PVInstance and will be skipped", definition:GetFullName()))
            continue
        end

        local maxDistance = readNumberAttribute(definition, { "LODMaxDistance", "MaxDistance" })
        local minDistance = readNumberAttribute(definition, { "LODMinDistance", "MinDistance" }) or 0
        if maxDistance and minDistance > maxDistance then
            warn(string.format("[LOD] MinDistance %.2f exceeds MaxDistance %.2f on %s", minDistance, maxDistance, definition:GetFullName()))
            minDistance = maxDistance
        end

        local ok, pivot = pcall(computeInstancePivot, definition)
        if not ok then
            warn(string.format("[LOD] Failed to compute pivot for %s: %s", definition:GetFullName(), tostring(pivot)))
            continue
        end

        if definition:IsA("Model") then
            waitForModelStream(definition)
        end

        local clone = definition:Clone()
        clone.Parent = nil
        clone.Name = definition.Name

        local offset = basePivot:ToObjectSpace(pivot)

        if clone:IsA("Model") then
            clone:PivotTo(basePivot * offset)
        elseif clone:IsA("PVInstance") then
            (clone :: PVInstance).CFrame = basePivot * offset
        end

        table.insert(levels, {
            Instance = clone,
            MaxDistance = maxDistance,
            MinDistance = minDistance,
            PivotOffset = offset,
        })

        table.insert(consumedDefinitions, definition)
    end

    if #levels == 0 then
        warn(string.format("[LOD] %s has no valid LOD definitions", root:GetFullName()))
        return nil
    end

    table.sort(levels, function(a, b)
        local aMax = a.MaxDistance or math.huge
        local bMax = b.MaxDistance or math.huge
        if aMax == bMax then
            return (a.MinDistance or 0) < (b.MinDistance or 0)
        end
        return aMax < bMax
    end)

    for _, definition in ipairs(consumedDefinitions) do
        local ok, err = pcall(function()
            definition.Parent = nil
        end)
        if not ok then
            warn(string.format("[LOD] Failed to remove source level %s: %s", definition:GetFullName(), tostring(err)))
        end
    end

    if #levelsFolder:GetChildren() == 0 then
        local ok, err = pcall(function()
            levelsFolder.Parent = nil
        end)
        if not ok then
            warn(string.format("[LOD] Failed to clean up LODLevels folder on %s: %s", root:GetFullName(), tostring(err)))
        end
    end

    return levels
end

local function attemptRegistration(root: Model, pivotResolver: () -> CFrame): (boolean, string?, any?)
    if registered[root] then
        return true
    end

    if not root.Parent then
        return false, "Orphaned"
    end

    local ok, basePivot = pcall(pivotResolver)
    if not ok then
        return false, "PivotUnavailable", basePivot
    end

    requestStreamingAround(basePivot.Position)

    local levels = buildLevelConfigurations(root, basePivot)
    if not levels then
        return false, "LevelsUnavailable"
    end

    cleanupPending(root)

    local hysteresis = readNumberAttribute(root, { "LODHysteresis" })
    local unloadDistance = readNumberAttribute(root, { "LODUnloadDistance" })
    local destroyInstancesAttr = root:GetAttribute("LODDestroyInstances")
    local destroyInstances = if typeof(destroyInstancesAttr) == "boolean" then destroyInstancesAttr else true

    local activeParent = resolveActiveParent(root)
    local containerNameAttribute = root:GetAttribute("LODContainerName")
    local containerName = if typeof(containerNameAttribute) == "string" and containerNameAttribute ~= "" then containerNameAttribute else (root.Name .. "_LOD")

    local handle = lodService:Register(root, {
        Levels = levels,
        GetPivot = pivotResolver,
        ActiveParent = activeParent,
        ContainerName = containerName,
        Hysteresis = hysteresis,
        UnloadDistance = unloadDistance,
        DestroyInstances = destroyInstances,
    })

    local connections = {
        root.Destroying:Connect(function()
            unregister(root)
        end),
        root:GetPropertyChangedSignal("Parent"):Connect(function()
            if not root.Parent then
                unregister(root)
            end
        end),
    }

    registered[root] = {
        Handle = handle,
        Connections = connections,
    }

    return true
end

function unregister(root: Instance)
    cleanupPending(root)

    local entry = registered[root]
    if not entry then
        return
    end

    entry.Handle:Destroy()
    for _, conn in ipairs(entry.Connections) do
        conn:Disconnect()
    end

    registered[root] = nil
end

local function register(root: Instance)
    if registered[root] or pending[root] then
        return
    end

    if not root:IsA("Model") then
        warn(string.format("[LOD] Only Models can be tagged as LODGroup (%s)", root:GetFullName()))
        return
    end

    local pivotResolver = createPivotResolver(root)

    local success, reason, detail = attemptRegistration(root, pivotResolver)
    if success then
        return
    end

    local detailMessage = if reason == "PivotUnavailable" then tostring(detail) elseif reason == "LevelsUnavailable" then "LOD levels are not available yet" elseif reason == "Orphaned" then "instance is not parented" else "unknown reason"
    warn(string.format("[LOD] Waiting for %s to stream in before registering LODGroup (%s)", root:GetFullName(), detailMessage))

    local function retry()
        if not pending[root] then
            return
        end

        if registered[root] then
            cleanupPending(root)
            return
        end

        if not root.Parent then
            return
        end

        local retrySuccess = attemptRegistration(root, pivotResolver)
        if retrySuccess then
            return
        end
    end

    local connections = {
        root.DescendantAdded:Connect(function()
            task.defer(retry)
        end),
        root:GetPropertyChangedSignal("Parent"):Connect(function()
            if root.Parent then
                task.defer(retry)
            end
        end),
        root.Destroying:Connect(function()
            cleanupPending(root)
        end),
    }

    pending[root] = {
        Connections = connections,
    }

    task.defer(retry)
end

for _, instance in ipairs(CollectionService:GetTagged("LODGroup")) do
    register(instance)
end

CollectionService:GetInstanceAddedSignal("LODGroup"):Connect(register)
CollectionService:GetInstanceRemovedSignal("LODGroup"):Connect(unregister)
