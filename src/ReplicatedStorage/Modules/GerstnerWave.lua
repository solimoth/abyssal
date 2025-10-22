--!strict
-- GerstnerWave.lua
-- Provides utility helpers for sampling Gerstner wave layers. Based on the
-- reference implementation supplied by the user but wrapped into a module that
-- can be required from both server and client scripts.

local Workspace = game:GetService("Workspace")

local GerstnerWave = { WaveInfo = {}, System = {} }

local twoPi = 2 * math.pi
local sqrt = math.sqrt
local abs = math.abs
local cos = math.cos
local sin = math.sin
local atan2 = math.atan2

local v2 = Vector2
local v3 = Vector3

export type WaveInfo = {
    Direction: Vector2,
    WaveLength: number,
    Steepness: number?,
    Gravity: number,
    PhaseOffset: number,
    Amplitude: number?,
    _k: number?,
    _c: number?,
    _A: number?,
}

function GerstnerWave.WaveInfo.new(direction: Vector2?, waveLength: number?, steepness: number?, gravity: number?, phaseOffset: number?, amplitude: number?): WaveInfo
    return {
        Direction = direction or v2.new(1, 0),
        WaveLength = waveLength or 1,
        Steepness = steepness,
        Gravity = gravity or Workspace.Gravity,
        PhaseOffset = phaseOffset or 0,
        Amplitude = amplitude,
    }
end

local function sanitizeDirection(direction: Vector2?): Vector2
    if not direction or direction.Magnitude < 1e-3 then
        return v2.new(1, 0)
    end
    return direction.Unit
end

local function computeSteepness(amplitude: number?, waveLength: number, suppliedSteepness: number?): number
    local k = twoPi / waveLength
    if suppliedSteepness then
        return math.clamp(suppliedSteepness, 0, 1.2)
    end
    amplitude = amplitude or 0
    return math.clamp(amplitude * k, 0, 1.2)
end

function GerstnerWave.WaveInfo.fromConfig(entry: { [string]: any }): WaveInfo
    local waveLength = entry.Wavelength or entry.WaveLength or 64
    local amplitude = entry.Amplitude or entry.Height or entry.A or 1
    amplitude = math.max(0, amplitude)
    local speed = entry.Speed or entry.PhaseSpeed
    local gravity = entry.Gravity
    local steepness = computeSteepness(amplitude, waveLength, entry.Steepness)
    gravity = gravity or (speed and (speed * speed * ((2 * math.pi) / waveLength))) or Workspace.Gravity
    local phaseOffset = entry.PhaseOffset or entry.Phase or entry.PhaseShift or 0

    return GerstnerWave.WaveInfo.new(
        sanitizeDirection(entry.Direction),
        waveLength,
        steepness,
        gravity,
        phaseOffset,
        amplitude
    )
end

function GerstnerWave.BuildWaveInfos(waveConfig: { [number]: { [string]: any } }?): { WaveInfo }
    local waves = waveConfig or {}
    local infos = table.create(#waves)
    for _, entry in ipairs(waves) do
        infos[#infos + 1] = GerstnerWave.WaveInfo.fromConfig(entry)
    end
    return infos
end

function GerstnerWave.System:CalculateWave(info: WaveInfo): (number, number, number, Vector2, number, number)
    local k = info._k
    local c = info._c
    local A = info._A

    if not (k and c) then
        local waveLength = info.WaveLength
        local gravity = info.Gravity

        k = twoPi / waveLength
        c = sqrt(abs(gravity) / k)

        info._k = k
        info._c = c
    end

    local steepness = info.Steepness

    if A == nil then
        if info.Amplitude ~= nil then
            A = info.Amplitude
        elseif steepness ~= nil then
            A = steepness / k
        else
            A = 0
        end
        info._A = A
    end

    if steepness == nil then
        steepness = A * k
        info.Steepness = steepness
    end

    return k, c, A, info.Direction, steepness, info.PhaseOffset or 0
end

function GerstnerWave.System:CalculateTransform(position: Vector2, runTime: number, calcNormals: boolean, k: number, c: number, A: number, dir: Vector2, steepness: number, phaseOffset: number)
    local phase = k * (dir:Dot(position) - c * runTime) + phaseOffset
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
        local k, c, A, dir, steepness, phaseOffset = self.System:CalculateWave(info)
        local disp = self.System:CalculateTransform(position, runTime, false, k, c, A, dir, steepness, phaseOffset)
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
        local k, c, A, dir, steepness, phaseOffset = self.System:CalculateWave(info)
        local disp, tan, bin = self.System:CalculateTransform(position, runTime, true, k, c, A, dir, steepness, phaseOffset)
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
