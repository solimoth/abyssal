--!strict
-- GerstnerWave.lua
-- Provides utility helpers for sampling Gerstner wave layers. Based on the
-- reference implementation supplied by the user but wrapped into a module that
-- can be required from both server and client scripts.

local Workspace = game:GetService("Workspace")

local GerstnerWave = { WaveInfo = {}, System = {} }

local twoPi = 2 * math.pi
local sqrt = math.sqrt
local cos = math.cos
local sin = math.sin
local atan2 = math.atan2

local v2 = Vector2
local v3 = Vector3

export type WaveInfo = {
    Direction: Vector2,
    WaveLength: number,
    Steepness: number,
    Gravity: number,
}

function GerstnerWave.WaveInfo.new(direction: Vector2?, waveLength: number?, steepness: number?, gravity: number?): WaveInfo
    return {
        Direction = direction or v2.new(1, 0),
        WaveLength = waveLength or 1,
        Steepness = steepness or 0,
        Gravity = gravity or Workspace.Gravity,
    }
end

function GerstnerWave.System:CalculateWave(info: WaveInfo): (number, number, number, Vector2, number)
    local waveLength = info.WaveLength
    local gravity = info.Gravity
    local steepness = info.Steepness
    local direction = info.Direction

    local k = twoPi / waveLength
    local c = sqrt(math.abs(gravity) / k)
    local A = steepness / k

    return k, c, A, direction, steepness
end

function GerstnerWave.System:CalculateTransform(position: Vector2, runTime: number, calcNormals: boolean, k: number, c: number, A: number, dir: Vector2, steepness: number)
    local phase = k * (dir:Dot(position) - c * runTime)
    local cf = cos(phase)
    local sf = sin(phase)

    local displacement = v3.new(dir.X * (A * cf), A * sf, dir.Y * (A * cf))

    if not calcNormals then
        return displacement, v3.zero, v3.zero
    end

    local tangent = v3.new(0, 0, 0)
    local binormal = v3.new(0, 0, 0)

    local s = steepness * sf
    local dx = dir.X
    local dy = dir.Y

    tangent = v3.new(-dx * dx * s, dx * (steepness * cf), -dx * dy * s)
    binormal = v3.new(-dy * dx * s, dy * (steepness * cf), -dy * dy * s)

    return displacement, tangent, binormal
end

function GerstnerWave:GetTransform(waves: { WaveInfo }, position: Vector2, runTime: number): Vector3
    if type(waves) ~= "table" or #waves == 0 then
        return v3.zero
    end

    local transform = v3.zero
    for _, info in ipairs(waves) do
        local k, c, A, dir, steepness = self.System:CalculateWave(info)
        local disp = self.System:CalculateTransform(position, runTime, false, k, c, A, dir, steepness)
        transform += disp
    end
    return transform
end

function GerstnerWave:GetHeightAndNormal(waves: { WaveInfo }, position: Vector2, runTime: number): (Vector3, Vector3, Vector3)
    if type(waves) ~= "table" or #waves == 0 then
        return v3.zero, v3.xAxis, v3.zAxis
    end

    local transform = v3.zero
    local tangent = v3.xAxis
    local binormal = v3.zAxis

    for _, info in ipairs(waves) do
        local k, c, A, dir, steepness = self.System:CalculateWave(info)
        local disp, tan, bin = self.System:CalculateTransform(position, runTime, true, k, c, A, dir, steepness)
        transform += disp
        tangent += tan
        binormal += bin
    end

    return transform, tangent, binormal
end

function GerstnerWave:GetRotationAngle(tangent: Vector3, binormal: Vector3, rotationFactor: number): number
    return atan2((tangent - binormal).Y, rotationFactor)
end

return GerstnerWave
