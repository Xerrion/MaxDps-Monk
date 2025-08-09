local _, addonTable = ...
local Monk = addonTable.Monk
local MaxDps = rawget(_G or {}, 'MaxDps')
if not MaxDps then return end
local setSpell
local Common = Monk and Monk.MopCommon

-- =========================
-- Tunables
-- =========================
local AOE_THRESHOLD_RAID  = 4   -- AoE branch in raids
local AOE_THRESHOLD_OTHER = 3   -- AoE branch in dungeons/solo
local JAB_MIN_ENERGY      = 40  -- only Jab when we have at least this much Energy
local TEB_MIN_STACKS      = 10  -- glow/suggest Tigereye Brew at this stack count (unless dumping before TTD)
local TEB_DUMP_TTD        = 12  -- if target will die soon (<= this time), dump any TEB stacks
local FOF_TTD_MIN         = 5.5 -- minimum remaining TTD to commit to Fists of Fury
local FOF_MIN_HP_PCT      = 15  -- allow FoF on non-bosses only if target HP% is above this

-- Chi costs (MoP)
local CHI_COST_TP  = 1
local CHI_COST_RSK = 2
local CHI_COST_BOK = 2

-- =========================
-- API / Locals
-- =========================
local UnitPower, UnitPowerMax              = UnitPower, UnitPowerMax
local UnitChannelInfo, GetShapeshiftFormID = UnitChannelInfo, GetShapeshiftFormID
local EnergyPT, ChiPT                      = Enum.PowerType.Energy, Enum.PowerType.Chi

-- Frame State
local fd, ttd, cooldown, talents, targets, classtable
local Chi, ChiMax, Energy, EnergyMax, EnergyRegen, EnergyTimeToMax, stance
local curHP
local Windwalker = {}

-- =========================
-- Shared helpers (from Common)
-- =========================
local ContentMode   = Common and Common.ContentMode
local IsBossOrElite = Common and Common.IsBossOrElite
local TargetHpPct   = Common and Common.TargetHpPct

local function Buff(id)       return Common and Common.Buff(fd, id) end
local function Debuff(id)     return Common and Common.Debuff(fd, id) end
local AuraUp                  = Common and Common.AuraUp
local AuraRem                 = Common and Common.AuraRem
local function IsReady(id)    return Common and Common.IsReady(fd, id) end
local function CountBuffStacks(buffId) return Common and Common.CountBuff(fd, buffId) end

local function Usable(id, label)     return Common and Common.Usable and Common.Usable(fd, id, label) end
local function TrySet(id, label)
    if Common and Common.Usable and Common.TrySet then
        if Common.Usable(fd, id, label) then
            setSpell = Common.TrySet(setSpell, fd, id, label)
        end
    end
end

local function HasChi(n) return Chi and Chi >= n end
local function RskReady() return IsReady(classtable.RisingSunKick) end

-- =========================
-- Ability gates
-- =========================
local function CanTouchOfDeath()
    local tod = classtable.TouchOfDeath
    if not tod or not IsReady(tod) then return false end
    if not MaxDps:CheckSpellUsable(tod, 'TouchOfDeath') then return false end
    if UnitClassification('target') == 'worldboss' then return false end
    return UnitHealth('target') > 0 and UnitHealth('target') <= curHP
end

local function CanFoF()
    local rskCd  = cooldown and cooldown[classtable.RisingSunKick]
    local rskRem = (rskCd and rskCd.remains) or 0
    return MaxDps:CheckSpellUsable(classtable.FistsofFury, 'FistsofFury')
       and IsReady(classtable.FistsofFury)
       and not AuraUp(Buff(classtable.EnergizingBrew))
       and EnergyTimeToMax > 4
       and AuraRem(Buff(classtable.TigerPowerBuff)) > 4
       and AuraUp(Debuff(classtable.RisingSunKickDeBuff))
       and rskRem > 4.5
       and ttd > FOF_TTD_MIN
       and (IsBossOrElite() or TargetHpPct() > FOF_MIN_HP_PCT)
end

-- =========================
-- Rotations
-- =========================
function Windwalker:single()
    -- Off-GCD/low-cost
    if talents[classtable.ChiWave] and EnergyTimeToMax > 2 then
        TrySet(classtable.ChiWave, 'ChiWave')
    end
    if talents[classtable.ChiBurst] and MaxDps:CheckSpellUsable(classtable.ChiBurst, 'ChiBurst') then
        MaxDps:GlowCooldown(classtable.ChiBurst, IsReady(classtable.ChiBurst))
    end
    if talents[classtable.ZenSphere]
       and not AuraUp(Debuff(classtable.ZenSphereDeBuff))
       and EnergyTimeToMax > 2 then
        TrySet(classtable.ZenSphere, 'ZenSphere')
    end

    -- Combo Breakers
    if AuraUp(Buff(classtable.ComboBreakerTpBuff))
       and (AuraRem(Buff(classtable.ComboBreakerTpBuff)) <= 2 or EnergyTimeToMax >= 2) then
        TrySet(classtable.TigerPalm, 'TigerPalm')
    end

    -- Maintain Tiger Power unless CB:BoK is waiting; don't snipe Chi from an imminent RSK
    do
        local hasCBTP = AuraUp(Buff(classtable.ComboBreakerTpBuff))
        if AuraRem(Buff(classtable.TigerPowerBuff)) < 2
           and not AuraUp(Buff(classtable.ComboBreakerBokBuff))
           and (hasCBTP or HasChi(CHI_COST_TP)) then
            if hasCBTP or (not RskReady()) or HasChi(CHI_COST_RSK + CHI_COST_TP) then
                TrySet(classtable.TigerPalm, 'TigerPalm')
            end
        end
    end

    -- Builder
    if Energy >= JAB_MIN_ENERGY and (ChiMax - Chi) >= 2 then
        TrySet(classtable.Jab, 'Jab')
    end

    -- Filler spender (require Chi unless CB:BoK)
    local rskRem = ((cooldown[classtable.RisingSunKick] and cooldown[classtable.RisingSunKick].remains) or 0)
    if (HasChi(CHI_COST_BOK) or AuraUp(Buff(classtable.ComboBreakerBokBuff)))
       and (Energy + EnergyRegen * rskRem) >= 40 then
        TrySet(classtable.BlackoutKick, 'BlackoutKick')
    end
end

function Windwalker:aoe()
    if talents[classtable.RushingJadeWind] then
        TrySet(classtable.RushingJadeWind, 'RushingJadeWind')
    end
    if talents[classtable.ChiWave] and EnergyTimeToMax > 1.5 then
        TrySet(classtable.ChiWave, 'ChiWave')
    end
    if talents[classtable.ChiBurst] and MaxDps:CheckSpellUsable(classtable.ChiBurst, 'ChiBurst') then
        MaxDps:GlowCooldown(classtable.ChiBurst, IsReady(classtable.ChiBurst))
    end

    -- Keep Tiger Power; don't block imminent RSK unless CB:TP is free
    do
        local hasCBTP = AuraUp(Buff(classtable.ComboBreakerTpBuff))
        if AuraRem(Buff(classtable.TigerPowerBuff)) < 2
           and not AuraUp(Buff(classtable.ComboBreakerBokBuff))
           and (hasCBTP or HasChi(CHI_COST_TP)) then
            if hasCBTP or (not RskReady()) or HasChi(CHI_COST_RSK + CHI_COST_TP) then
                TrySet(classtable.TigerPalm, 'TigerPalm')
            end
        end
    end

    if (not talents[classtable.RushingJadeWind]) and Chi < ChiMax then
        TrySet(classtable.SpinningCraneKick, 'SpinningCraneKick')
    end
    if Energy >= JAB_MIN_ENERGY and (ChiMax - Chi) >= 2 then
        TrySet(classtable.Jab, 'Jab')
    end
    local rskRem = ((cooldown[classtable.RisingSunKick] and cooldown[classtable.RisingSunKick].remains) or 0)
    if (HasChi(CHI_COST_BOK) or AuraUp(Buff(classtable.ComboBreakerBokBuff)))
       and (Energy + EnergyRegen * rskRem) >= 40 then
        TrySet(classtable.BlackoutKick, 'BlackoutKick')
    end
end

local function ClearGlows()
    MaxDps:GlowCooldown(classtable.ChiBurst, false)
    MaxDps:GlowCooldown(classtable.EnergizingBrew, false)
    MaxDps:GlowCooldown(classtable.TigereyeBrew, false)
end

function Windwalker:callaction(mode)
    -- Stance
    if stance ~= 24 then
        TrySet(classtable.StanceoftheFierceTiger, 'StanceoftheFierceTiger')
    end

    -- Builders
    if talents[classtable.PowerStrikes]
       and Usable(classtable.ChiSphere, 'ChiSphere')
       and AuraUp(Buff(classtable.ChiSphereBuff))
       and Chi < 4 then
        TrySet(classtable.ChiSphere, 'ChiSphere')
    end
    local chiBrewCD = cooldown[classtable.ChiBrew] or {}
    if talents[classtable.ChiBrew]
       and MaxDps:CheckSpellUsable(classtable.ChiBrew, 'ChiBrew')
       and Chi <= 2
       and (chiBrewCD.charges or 0) >= 1 then
        TrySet(classtable.ChiBrew, 'ChiBrew')
    end

    -- Highest: CB:BoK
    if AuraUp(Buff(classtable.ComboBreakerBokBuff)) then
        TrySet(classtable.BlackoutKick, 'BlackoutKick')
    end
    -- Next: CB:TP
    if AuraUp(Buff(classtable.ComboBreakerTpBuff)) then
        TrySet(classtable.TigerPalm, 'TigerPalm')
    end

    -- Maintenance (Chi-gated unless free CB:TP); don't block imminent RSK
    do
        local hasCBTP = AuraUp(Buff(classtable.ComboBreakerTpBuff))
        if not AuraUp(Buff(classtable.TigerPowerBuff))
           and (hasCBTP or HasChi(CHI_COST_TP)) then
            if hasCBTP or (not RskReady()) or HasChi(CHI_COST_RSK + CHI_COST_TP) then
                TrySet(classtable.TigerPalm, 'TigerPalm')
            end
        end
    end
    if not AuraUp(Debuff(classtable.RisingSunKickDeBuff)) and HasChi(CHI_COST_RSK) then
        TrySet(classtable.RisingSunKick, 'RisingSunKick')
    end

    -- Tigereye Brew: glow normally; suggest only when a big window is imminent
    do
        local stacks  = CountBuffStacks(classtable.TigereyeBrewStackBuff)
        local ready   = IsReady(classtable.TigereyeBrew)
        local active  = AuraUp(Buff(classtable.TigereyeBrewUseBuff))

        local rskCd   = cooldown and cooldown[classtable.RisingSunKick]
        local rskRem  = (rskCd and rskCd.remains) or 0
        local windowSoon = (rskRem <= 1.0) or CanFoF()  -- RSK about to be pressed or FoF gates pass

        local dumpSoon   = (ttd > 0 and ttd <= TEB_DUMP_TTD and stacks >= 3)
        local shouldGlow = ready and (not active) and (
            stacks >= TEB_MIN_STACKS or dumpSoon or (windowSoon and stacks >= math.max(5, TEB_MIN_STACKS - 2))
        )

        MaxDps:GlowCooldown(classtable.TigereyeBrew, shouldGlow)

        -- Only suggest/cast when a burst window is imminent and we have full value stacks
        if shouldGlow and windowSoon and stacks >= TEB_MIN_STACKS
           and MaxDps:CheckSpellUsable(classtable.TigereyeBrew, 'TigereyeBrew') then
            if not setSpell then setSpell = classtable.TigereyeBrew end
        end
    end

    -- Core CDs
    if CanTouchOfDeath() then
        TrySet(classtable.TouchOfDeath, 'TouchOfDeath')
    end
    if CanFoF() then
        TrySet(classtable.FistsofFury, 'FistsofFury')
    end

    -- RSK on cooldown (Chi-gated)
    if HasChi(CHI_COST_RSK) then
        TrySet(classtable.RisingSunKick, 'RisingSunKick')
    end

    -- Invoke Xuen
    if talents[classtable.InvokeXuen] and Usable(classtable.InvokeXuen, 'InvokeXuen') then
        local boss = IsBossOrElite()
        if (mode == 'solo' and boss) or (mode ~= 'solo' and (targets >= 3 or boss)) then
            TrySet(classtable.InvokeXuen, 'InvokeXuen')
        end
    end

    -- Energizing Brew glow
    if Usable(classtable.EnergizingBrew, 'EnergizingBrew') and EnergyTimeToMax > 5 then
        MaxDps:GlowCooldown(classtable.EnergizingBrew, true)
    end

    -- Choose ST vs AoE
    local aoeThreshold = (mode == 'raid') and AOE_THRESHOLD_RAID or AOE_THRESHOLD_OTHER
    if targets >= aoeThreshold then
        Windwalker:aoe()
    else
        Windwalker:single()
    end
end

function Monk:Windwalker()
    fd        = MaxDps.FrameData
    ttd       = (fd.timeToDie and fd.timeToDie) or 500
    cooldown  = fd.cooldown or {}
    talents   = fd.talents or {}
    targets   = MaxDps:SmartAoe()
    classtable= MaxDps.SpellTable

    Chi       = UnitPower('player', ChiPT)
    ChiMax    = UnitPowerMax('player', ChiPT)
    Energy    = UnitPower('player', EnergyPT)
    EnergyMax = UnitPowerMax('player', EnergyPT)
    EnergyRegen     = (fd.energyRegen and fd.energyRegen) or 10
    EnergyTimeToMax = (EnergyMax - Energy) / math.max(EnergyRegen, 0.001)
    stance          = GetShapeshiftFormID()
    curHP           = UnitHealth('player')

    -- Fallback IDs
    classtable.RisingSunKickDeBuff    = classtable.RisingSunKickDeBuff or 130320
    classtable.StanceoftheFierceTiger = classtable.StanceoftheFierceTiger or 103985
    classtable.TigerPowerBuff         = classtable.TigerPowerBuff or 125359

    -- Tigereye Brew auras / press
    classtable.TigereyeBrewStackBuff  = classtable.TigereyeBrewStackBuff or 1247279 -- stacks aura
    classtable.TigereyeBrewUseBuff    = classtable.TigereyeBrewUseBuff   or 1247275 -- ACTIVE dmg buff
    classtable.TigereyeBrew           = classtable.TigereyeBrew          or 116740  -- press

    classtable.ChiSphere              = classtable.ChiSphere or 124081
    classtable.InvokeXuen             = classtable.InvokeXuen or 123904
    classtable.FistsofFury            = classtable.FistsofFury or 113656
    classtable.RushingJadeWind        = classtable.RushingJadeWind or 116847
    classtable.SpinningCraneKick      = classtable.SpinningCraneKick or 101546
    classtable.ChiBurst               = classtable.ChiBurst or 123986
    classtable.ChiWave                = classtable.ChiWave or 115098
    classtable.TouchOfDeath           = classtable.TouchOfDeath or 115080
    classtable.EnergizingBrew         = classtable.EnergizingBrew or 115288
    classtable.TigerPalm              = classtable.TigerPalm or 100787
    classtable.RisingSunKick          = classtable.RisingSunKick or 107428
    classtable.BlackoutKick           = classtable.BlackoutKick or 100784
    classtable.Jab                    = classtable.Jab or 100780
    classtable.ChiBrew                = classtable.ChiBrew or 115399
    classtable.ChiSphereBuff          = classtable.ChiSphereBuff or 129914
    classtable.ComboBreakerBokBuff    = classtable.ComboBreakerBokBuff or 116768
    classtable.ComboBreakerTpBuff     = classtable.ComboBreakerTpBuff or 118864

    setSpell = nil
    ClearGlows()
    local mode = ContentMode()
    Windwalker:callaction(mode)

    if setSpell then
        return setSpell
    end
end
