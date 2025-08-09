local _, addonTable = ...
local MaxDps = rawget(_G or {}, 'MaxDps')
if not MaxDps then return end

addonTable.Monk = addonTable.Monk or {}
local Monk = addonTable.Monk

local Common = {}
Monk.MopCommon = Common

-- Frame helpers
function Common.Buff(fd, id)
    return (fd and fd.buff and id and fd.buff[id]) or {}
end

function Common.Debuff(fd, id)
    return (fd and fd.debuff and id and fd.debuff[id]) or {}
end

function Common.AuraUp(a)
    return a and a.up
end

function Common.AuraRem(a)
    return (a and a.remains) or 0
end

function Common.AuraCount(a)
    return (a and (a.count or a.stacks or a.charges or 0)) or 0
end

function Common.IsReady(fd, id)
    local cd = fd and fd.cooldown and id and fd.cooldown[id]
    return cd and cd.ready
end

-- Content / target helpers
function Common.ContentMode()
    local inInstance, instType = IsInInstance()
    if not inInstance then return 'solo' end
    if instType == 'raid' then return 'raid' end
    if instType == 'party' then return 'dungeon' end
    return 'solo'
end

function Common.IsBossOrElite()
    if MaxDps:boss() then return true end
    local c = UnitClassification('target')
    return c == 'worldboss' or c == 'elite' or c == 'rare' or c == 'rareelite' or UnitLevel('target') == -1
end

function Common.TargetHpPct()
    local p = MaxDps:TargetPercentHealth('target')
    if p and p > 0 then return p end
    local hp, mhp = UnitHealth('target'), UnitHealthMax('target')
    return (mhp and mhp > 0) and (hp / mhp) * 100 or 100
end

-- Convenience: count stacks of a specific player buff
function Common.CountBuff(fd, id)
    return Common.AuraCount(Common.Buff(fd, id))
end

-- Convenience helpers used by rotations
function Common.Usable(fd, id, label)
    local MaxDpsRef = rawget(_G or {}, 'MaxDps')
    if not id or not MaxDpsRef then return false end
    if not MaxDpsRef:CheckSpellUsable(id, label) then return false end
    return Common.IsReady(fd, id) and true or false
end

function Common.TrySet(current, fd, id, label)
    if not current and Common.Usable(fd, id, label) then
        return id
    end
    return current
end
