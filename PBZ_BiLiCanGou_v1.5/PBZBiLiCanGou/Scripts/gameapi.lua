-- gameapi.lua —— 对《影之刃零》运行时的唯一访问层
--
-- 设计原则：
--   * 每次访问都包 pcall：UE4SS 里一个属性不存在会抛错，不能让整条 tick 挂掉
--   * 昂贵调用做缓存（属性集、ASC、背包、输入动作），每帧只读判定帧与煞气
--   * 所有符号名都来自本游戏社区 mod 已验证可用的路径（见 README「符号来源」）
--
-- 用到的真实符号（其他 PBZ Lua mod 已在游戏里跑通）：
--   /Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary : GetAbilitySystemComponent
--   FindAllOf("BasicAttributeSet")        属性集，Shachi / Shachi_Max 的 CurrentValue 就是杀气
--   FindAllOf("PBZBackPackSubsystem")      MainWeapons / CurrentWeaponIndex / CurrentMainWeaponID（DualHook = 别离残钩）
--   pawn.DeflectComponent                  PBZDeflectSystem.DeflectComponent，ReceiveFrames 是来袭判定表
--   /PBZDeflectSystem/Input/IA_xxx.IA_xxx  输入动作（IA_Stance / IA_Deflect / IA_AttackH_*）
--   EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction  注入按键
local G = {}

local Log = nil
local Cfg = nil
local H = nil          -- UEHelpers
local now_fn = os.clock

local cache = {
    pawnAddr = nil,
    set = nil, setAt = -1e9, setAddr = nil,
    asc = nil, ascAt = -1e9, ascAddr = nil,
    bag = nil, bagAt = -1e9,
    weapon = nil, weaponAt = -1e9,
    weaponActor = nil, weaponActorAt = -1e9, weaponScanAt = -1e9,
    deflect = nil, deflectAt = -1e9, deflectSrc = nil,
    actionIndex = nil, actionIndexAt = -1e9,
    actions = {},
}

-- ---------------------------------------------------------------- 基础工具
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
G.valid = valid

local function unwrap(v)
    if v == nil then return nil end
    local ok, inner = pcall(function() return v:get() end)
    if ok and inner ~= nil then return inner end
    return v
end
G.unwrap = unwrap

local function num(v)
    if v == nil then return nil end
    if type(v) == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        return v
    end
    local n = tonumber(unwrap(v))
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function addressOf(o)
    if not valid(o) then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if not ok or a == nil then return nil end
    return tostring(a)
end
G.addressOf = addressOf

local function shortName(o)
    if not valid(o) then return nil end
    local ok, n = pcall(function() return o:GetName() end)
    if ok and type(n) == "string" then return n end
    local ok2, f = pcall(function() return o:GetFullName() end)
    if ok2 and type(f) == "string" then
        return f:gsub("^.*[./]", ""):gsub(":.*$", "")
    end
    return nil
end

-- DeflectBulletType 枚举（游戏内顺序）
local BULLET_TYPES = {
    [0] = "CantDeflect",
    [1] = "Normal",
    [2] = "BlueEye",
    [3] = "RedEye",
    [4] = "PowerAttack",
    [5] = "HoldDeflect",
}
G.BULLET_TYPES = BULLET_TYPES

-- ---------------------------------------------------------------- 初始化
function G.init(log, cfg, clock)
    Log = log
    Cfg = cfg or {}
    if type(clock) == "function" then now_fn = clock end
    local ok, mod = pcall(require, "UEHelpers")
    if ok and type(mod) == "table" then
        H = mod
        return true, "UEHelpers ok"
    end
    H = nil
    return false, "UEHelpers 不可用：" .. tostring(mod)
end

function G.now()
    local ok, t = pcall(now_fn)
    if ok and type(t) == "number" then return t end
    return os.time()
end

-- ---------------------------------------------------------------- 玩家对象
function G.pawn()
    if not H then return nil end
    local ok, p = pcall(H.GetPlayer)
    if ok and valid(p) then return p end
    local ok2, p2 = pcall(function() return H.GetPlayer() end)
    if ok2 and valid(p2) then return p2 end
    return nil
end

function G.controller()
    if not H then return nil end
    local ok, c = pcall(function() return H.GetPlayerController() end)
    if ok and valid(c) then return c end
    return nil
end

-- ---------------------------------------------------------------- 属性集 / 煞气
function G.attributeSet(pawn)
    pawn = pawn or G.pawn()
    if not valid(pawn) then return nil end
    local addr = addressOf(pawn)
    local t = G.now()
    if cache.setAddr == addr and valid(cache.set) then
        -- 同一个角色的属性集直接复用，5 秒复核一次归属
        if t - cache.setAt < 5 then return cache.set end
    end
    cache.setAt = t
    cache.setAddr = addr
    cache.set = nil
    local ok, all = pcall(FindAllOf, "BasicAttributeSet")
    if not ok or type(all) ~= "table" then return nil end
    local found = nil
    for _, s in ipairs(all) do
        local okO, outer = pcall(function() return s:GetOuter() end)
        if okO and valid(outer) and addressOf(outer) == addr then
            found = s
            break
        end
    end
    cache.set = found
    return found
end

local function readAttr(set, name)
    if not valid(set) then return nil end
    local ok, data = pcall(function() return set[name] end)
    if not ok or data == nil then return nil end
    local ok2, v = pcall(function() return data.CurrentValue end)
    if ok2 then return num(v) end
    local ok3, v2 = pcall(function() return data.BaseValue end)
    if ok3 then return num(v2) end
    return nil
end
G.readAttr = readAttr

function G.shachi(pawn)
    local set = G.attributeSet(pawn)
    if not set then return nil, nil, nil end
    local cur = readAttr(set, "Shachi")
    local max = readAttr(set, "Shachi_Max")
    local pct = nil
    if cur and max and max > 0 then pct = cur / max * 100 end
    return cur, max, pct
end

-- 写回杀气：读回校验，读回对不上就报失败（上层会停写，不会反复污染）
function G.addShachi(amount)
    amount = num(amount)
    if not amount or amount <= 0 then return false, "bad_amount" end
    local pawn = G.pawn()
    local set = G.attributeSet(pawn)
    if not set then return false, "no_attribute_set" end
    local cur, max = G.shachi(pawn)
    if not cur then return false, "no_shachi_value" end
    local target = cur + amount
    if max and max > 0 and target > max then target = max end
    local before = cur
    local okW, err = pcall(function() set.Shachi.CurrentValue = target end)
    if not okW then return false, "write_error:" .. tostring(err) end
    if Cfg and Cfg.refund and Cfg.refund.write_base_value then
        pcall(function() set.Shachi.BaseValue = target end)
    end
    local after = readAttr(set, "Shachi")
    if not after then return false, "no_readback" end
    if math.abs(after - target) > 0.6 then
        return false, string.format("readback_mismatch target=%.2f got=%.2f", target, after)
    end
    return true, { before = before, after = after, delta = after - before, target = target }
end

-- 把杀气直接填到上限（黑光 / 蓝光反制成功后「恢复 100%」用）
function G.fillShachi()
    local pawn = G.pawn()
    local set = G.attributeSet(pawn)
    if not set then return false, "no_attribute_set" end
    local cur, max = G.shachi(pawn)
    if not cur then return false, "no_shachi_value" end
    if not max or max <= 0 then return false, "no_max_value" end
    if max - cur < 0.5 then
        return true, { before = cur, after = cur, delta = 0, target = max, already = true }
    end
    local okW, err = pcall(function() set.Shachi.CurrentValue = max end)
    if not okW then return false, "write_error:" .. tostring(err) end
    if Cfg and Cfg.refund and Cfg.refund.write_base_value then
        pcall(function() set.Shachi.BaseValue = max end)
    end
    local after = readAttr(set, "Shachi")
    if not after then return false, "no_readback" end
    return true, { before = cur, after = after, delta = after - cur, target = max }
end

-- ---------------------------------------------------------------- 标签（架势状态）
function G.abilitySystem(pawn)
    pawn = pawn or G.pawn()
    if not valid(pawn) then return nil end
    local addr = addressOf(pawn)
    local t = G.now()
    if cache.ascAddr == addr and valid(cache.asc) and t - cache.ascAt < 5 then return cache.asc end
    cache.ascAddr, cache.ascAt = addr, t
    cache.asc = nil
    local lib = nil
    local okL, l = pcall(StaticFindObject, "/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if okL and valid(l) then lib = l end
    if not lib then return nil end
    local okA, asc = pcall(function() return lib:GetAbilitySystemComponent(pawn) end)
    if okA and valid(asc) then
        cache.asc = asc
        return asc
    end
    return nil
end

function G.hasTag(asc, name)
    if not valid(asc) then return false end
    -- FName 在不同 UE4SS 版本里可能是函数、也可能不可直接调用，两种都试
    local tagArg
    local okF, fname = pcall(function() return FName(name) end)
    if okF and fname ~= nil then
        tagArg = { TagName = fname }
    else
        tagArg = { TagName = name }
    end
    local ok, has = pcall(function() return asc:HasMatchingGameplayTag(tagArg) end)
    if not ok then return false end
    local v = unwrap(has)
    return v == true
end

function G.stanceTags()
    local tags = Cfg and Cfg.detect and Cfg.detect.stance_tags or {}
    local asc = G.abilitySystem()
    local out = {}
    if not asc then return out, false end
    for _, t in ipairs(tags) do
        if G.hasTag(asc, t) then out[#out + 1] = t end
    end
    return out, true
end

-- ---------------------------------------------------------------- 武器（别离残钩）
local function textOf(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:GetFullName() end)
    if ok and type(s) == "string" then return s end
    local ok2, raw = pcall(function() return v:get() end)
    if ok2 and type(raw) == "string" then return raw end
    return nil
end

local function backpack()
    local t = G.now()
    if valid(cache.bag) and t - cache.bagAt < 5 then return cache.bag end
    cache.bagAt = t
    cache.bag = nil
    local ok, all = pcall(FindAllOf, "PBZBackPackSubsystem")
    if not ok or type(all) ~= "table" then return nil end
    for _, bp in ipairs(all) do
        if valid(bp) and not tostring(shortName(bp) or ""):find("^Default__") then
            cache.bag = bp
            return bp
        end
    end
    return nil
end

function G.weapon()
    local pawnForWeapon = G.pawn()
    local t = G.now()
    if cache.weapon and t - cache.weaponAt < 0.5 then return cache.weapon end
    cache.weaponAt = t
    local bp = backpack()
    local out = { current = nil, next = nil, ok = false }
    if not bp then cache.weapon = out return out end
    pcall(function()
        local names, n = {}, 0
        local list = bp.MainWeapons
        if list ~= nil then
            local okn, len = pcall(function() return #list end)
            len = okn and tonumber(len) or nil
            if len and len > 0 then
                n = len
                for i = 1, n do names[i] = textOf(list[i]) end
            else
                pcall(function()
                    list:ForEach(function(_, v) names[#names + 1] = textOf(v) end)
                end)
                n = #names
            end
        end
        local idx = tonumber(unwrap(bp.CurrentWeaponIndex))
        out.current = (idx and names[idx + 1]) or textOf(bp.CurrentMainWeaponID)
        if idx and n > 1 then out.next = names[(idx + 1) % n + 1] end
    end)
    if out.current == nil then
        local actor = G.weaponActor(pawnForWeapon)
        if actor then out.current, out.via = actor, "actor"
        end
    end
    out.ok = (out.current ~= nil)
    cache.weapon = out
    return out
end

local DUAL_CLASSES = {
    "BP_Weapon_Hun_DualHook_R_C",
    "BP_Weapon_Hun_DualHook_L_C",
    "BP_Weapon_Hun_DualHook_C",
}

local function attachOwnerMatches(actor, addr)
    local okP, parent = pcall(function() return actor:GetAttachParentActor() end)
    if okP and valid(parent) and addressOf(parent) == addr then return true end
    local okO, own = pcall(function() return actor.Owner end)
    if okO and valid(own) and addressOf(own) == addr then return true end
    return false
end

-- 找「别离残钩的武器实例」：先按已知类名，找不到再低频全扫（每 3 秒最多一次）
function G.weaponActor(pawn)
    pawn = pawn or G.pawn()
    if not valid(pawn) then return nil end
    local t = G.now()
    if cache.weaponActor and t - cache.weaponActorAt < 1.0 then return cache.weaponActor end
    cache.weaponActorAt = t
    cache.weaponActor = nil
    local addr = addressOf(pawn)

    local classes = DUAL_CLASSES
    local cfgAuto = Cfg and Cfg.instant_counter
    if cfgAuto and type(cfgAuto.weapon_classes) == "table" and #cfgAuto.weapon_classes > 0 then
        classes = cfgAuto.weapon_classes
    end
    for _, cls in ipairs(classes) do
        local ok, all = pcall(FindAllOf, cls)
        if ok and type(all) == "table" then
            for _, a in ipairs(all) do
                if valid(a) and attachOwnerMatches(a, addr) then
                    cache.weaponActor = shortName(a) or cls
                    return cache.weaponActor
                end
            end
        end
    end

    if t - cache.weaponScanAt > 3 then
        cache.weaponScanAt = t
        local ok, all = pcall(FindAllOf, "Actor")
        if ok and type(all) == "table" then
            for _, a in ipairs(all) do
                if valid(a) then
                    local okN, full = pcall(function() return a:GetFullName() end)
                    if okN and type(full) == "string" and full:find("DualHook", 1, true) then
                        if attachOwnerMatches(a, addr) then
                            cache.weaponActor = shortName(a) or full
                            return cache.weaponActor
                        end
                    end
                end
            end
        end
    end
    return nil
end

function G.holdsHook(weapon)
    weapon = weapon or G.weapon()
    if not weapon or not weapon.current then return false end
    local patterns = Cfg and Cfg.instant_counter and Cfg.instant_counter.weapon_match or { "DualHook" }
    local low = tostring(weapon.current):lower()
    for _, w in ipairs(patterns) do
        if type(w) == "string" and low:find(w:lower(), 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------- 判定帧（来袭攻击）
local DEFLECT_PROPS = { "DeflectComponent", "PBZDeflectComponent", "DeflectComp", "PBZDeflectComp" }

function G.deflect(pawn)
    pawn = pawn or G.pawn()
    if not valid(pawn) then return nil end
    local t = G.now()
    if valid(cache.deflect) and t - cache.deflectAt < 2 then return cache.deflect end
    cache.deflectAt = t
    cache.deflect, cache.deflectSrc = nil, nil
    local addr = addressOf(pawn)

    -- 1) 属性名直接取（部分构建里组件属性就叫这个）
    for _, prop in ipairs(DEFLECT_PROPS) do
        local ok, comp = pcall(function() return pawn[prop] end)
        if ok and valid(comp) then
            cache.deflect, cache.deflectSrc = comp, "pawn." .. prop
            return comp
        end
    end

    -- 2) 按类遍历，用 Outer / Owner 的地址对齐到玩家
    local ok, all = pcall(FindAllOf, "DeflectComponent")
    if ok and type(all) == "table" and #all > 0 then
        local loose = nil
        for _, comp in ipairs(all) do
            if valid(comp) then
                loose = comp
                local okO, outer = pcall(function() return comp:GetOuter() end)
                if okO and valid(outer) and addressOf(outer) == addr then
                    cache.deflect, cache.deflectSrc = comp, "FindAllOf/Outer"
                    return comp
                end
                local okP, own = pcall(function() return comp:GetOwner() end)
                if okP and valid(own) and addressOf(own) == addr then
                    cache.deflect, cache.deflectSrc = comp, "FindAllOf/Owner"
                    return comp
                end
            end
        end
        -- 单人场景里如果只有一个实例，就直接用它
        if #all == 1 and valid(loose) then
            cache.deflect, cache.deflectSrc = loose, "FindAllOf/唯一实例"
            return loose
        end
    end
    return nil
end

function G.deflectSource()
    return cache.deflectSrc
end

function G.frames(pawn)
    local deflect = G.deflect(pawn)
    if not deflect then return nil, "no_deflect_component" end
    local out = {}
    local ok, err = pcall(function()
        local frames = deflect.ReceiveFrames
        if frames == nil then return end
        frames:ForEach(function(key, value)
            local handle = num(unwrap(key:get()))
            if not handle then return end
            local data = value:get()
            if data == nil then return end
            local hit = num(data.HitGameTime)
            if hit and hit < -1e20 then hit = nil end
            local btype = nil
            pcall(function()
                local w = data.SourceAction
                local okg, src = pcall(function() return w:Get() end)
                if okg and valid(src) then
                    local okB, b = pcall(function() return src.DeflectBulletType end)
                    if okB then btype = num(unwrap(b)) end
                end
            end)
            local isDodge = nil
            pcall(function() isDodge = unwrap(data.IsDodge) end)
            out[#out + 1] = {
                handle = handle,
                type = (btype and BULLET_TYPES[btype]) or "Unknown",
                hit = hit,
                isDodge = isDodge == true,
            }
        end)
    end)
    if not ok then return nil, "frames_error:" .. tostring(err) end
    return out
end

-- ---------------------------------------------------------------- 动画（可选信号）
function G.montage(pawn)
    pawn = pawn or G.pawn()
    if not valid(pawn) then return nil end
    local ok, name = pcall(function()
        local mesh = pawn.Mesh
        if not valid(mesh) then return nil end
        local anim = mesh:GetAnimInstance()
        if not valid(anim) then return nil end
        local m = anim:GetCurrentActiveMontage()
        if not valid(m) then return nil end
        return shortName(m)
    end)
    if ok then return name end
    return nil
end

-- ---------------------------------------------------------------- 输入注入
function G.action(name)
    if type(name) ~= "string" or name == "" then return nil end
    local cached = cache.actions[name]
    if valid(cached) then return cached end
    local ok, a = pcall(StaticFindObject, "/PBZDeflectSystem/Input/" .. name .. "." .. name)
    if ok and valid(a) then
        cache.actions[name] = a
        return a
    end
    local ok2, found = pcall(FindObject, "InputAction", nil, name, false)
    if ok2 and valid(found) then
        cache.actions[name] = found
        return found
    end
    return nil
end

function G.inject(name)
    local action = G.action(name)
    if not action then return false, "action_not_found:" .. tostring(name) end
    local ctrl = G.controller()
    if not valid(ctrl) then return false, "no_controller" end
    local okL, lib = pcall(StaticFindObject, "/Script/Engine.Default__SubsystemBlueprintLibrary")
    if not (okL and valid(lib)) then return false, "no_subsystem_library" end
    local okC, cls = pcall(StaticFindObject, "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem")
    if not (okC and valid(cls)) then return false, "no_enhanced_input_class" end
    local okS, sub = pcall(function() return lib:GetLocalPlayerSubSystemFromPlayerController(ctrl, cls) end)
    if not (okS and valid(sub)) then return false, "no_input_subsystem" end
    local okI, err = pcall(function()
        sub:InjectInputVectorForAction(action, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
    end)
    if not okI then return false, "inject_error:" .. tostring(err) end
    return true
end

-- 按候选名依次尝试，返回第一个能解析到的动作名
function G.firstAction(names)
    for _, n in ipairs(names or {}) do
        if G.action(n) then return n end
    end
    return nil
end

local function actionIndex()
    local t = G.now()
    if cache.actionIndex and t - cache.actionIndexAt < 30 then return cache.actionIndex end
    local idx = {}
    local ok, all = pcall(FindAllOf, "InputAction")
    if ok and type(all) == "table" then
        for _, a in ipairs(all) do
            if valid(a) then
                local n = shortName(a)
                if n and n ~= "" and not n:find("^Default__") then
                    idx[#idx + 1] = { name = n, obj = a }
                end
            end
        end
    end
    cache.actionIndex, cache.actionIndexAt = idx, t
    return idx
end

-- 候选名全都不存在时，按关键词在全部 InputAction 里找（名字里含 AttackH / Heavy 之类）
function G.findAction(words)
    if type(words) ~= "table" then return nil end
    for _, w in ipairs(words) do
        local low = tostring(w):lower()
        for _, e in ipairs(actionIndex()) do
            if e.name:lower():find(low, 1, true) then
                cache.actions[e.name] = e.obj
                return e.name
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------- 采样
function G.state()
    local out = { now = G.now() }
    local pawn = G.pawn()
    out.pawn = valid(pawn)
    if not out.pawn then return out end
    out.addr = addressOf(pawn)

    local tags, ascOk = G.stanceTags()
    out.asc_ok = ascOk
    out.stance = #tags > 0
    out.stance_tags = tags

    local cur, max, pct = G.shachi(pawn)
    out.shachi, out.shachi_max, out.shachi_pct = cur, max, pct

    local weapon = G.weapon()
    out.weapon = weapon.current
    out.weapon_next = weapon.next
    out.weapon_ok = G.holdsHook(weapon)

    local frames, ferr = G.frames(pawn)
    out.frames = frames
    out.frames_err = ferr

    out.montage = G.montage(pawn)
    out.deflect_ok = G.deflect(pawn) ~= nil
    return out
end

-- ---------------------------------------------------------------- 诊断
-- 逐项报告「这个 mod 依赖的每个接口现在能不能拿到」，进游戏第一次就用它核对
function G.diag()
    local lines = {}
    local function add(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and s or tostring(fmt)
    end

    add("--- 接口诊断 ---")
    add("UEHelpers: %s", H and "已加载" or "未加载（mod 无法工作）")
    local pawn = G.pawn()
    add("玩家对象: %s", valid(pawn) and tostring(addressOf(pawn)) or "未找到")
    if not valid(pawn) then return lines end

    local set = G.attributeSet(pawn)
    local cur, max, pct = G.shachi(pawn)
    add("属性集 BasicAttributeSet: %s", valid(set) and "已找到" or "未找到")
    add("杀气 Shachi: %s / %s%s", tostring(cur), tostring(max),
        pct and string.format("（%.1f%%）", pct) or "")

    local asc = G.abilitySystem(pawn)
    add("AbilitySystemComponent: %s", valid(asc) and "已找到" or "未找到")
    local tags = Cfg and Cfg.detect and Cfg.detect.stance_tags or {}
    for _, t in ipairs(tags) do
        add("  标签 %-32s %s", t, valid(asc) and (G.hasTag(asc, t) and "在身" or "无") or "读不到")
    end

    local weapon = G.weapon()
    add("当前武器: %s（下一把 %s）%s", tostring(weapon.current), tostring(weapon.next),
        G.holdsHook(weapon) and " ← 别离残钩在手" or "")

    local deflect = G.deflect(pawn)
    add("DeflectComponent: %s%s", deflect and "已找到" or "未找到",
        deflect and cache.deflectSrc and ("（来源 " .. tostring(cache.deflectSrc) .. "）") or "")
    local frames, ferr = G.frames(pawn)
    if frames then
        add("来袭判定帧: %d 个", #frames)
        for _, f in ipairs(frames) do
            add("  判定#%s 类型=%s 命中时间=%s", tostring(f.handle), tostring(f.type),
                f.hit and string.format("%.2f", f.hit) or "未设置")
        end
    else
        add("来袭判定帧: 读不到（%s）", tostring(ferr))
    end

    local actions = {}
    local cfgAuto = Cfg and Cfg.instant_counter or {}
    for _, n in ipairs((cfgAuto.actions and cfgAuto.actions.stance) or {}) do
        actions[#actions + 1] = n .. "=" .. (G.action(n) and "ok" or "缺失")
    end
    for _, n in ipairs((cfgAuto.actions and cfgAuto.actions.press) or {}) do
        actions[#actions + 1] = n .. "=" .. (G.action(n) and "ok" or "缺失")
    end
    add("输入动作: %s", #actions > 0 and table.concat(actions, "  ") or "（配置里没有）")

    add("当前动画: %s", tostring(G.montage(pawn)))
    return lines
end


-- ---------------------------------------------------------------- 屏幕菜单
-- 用引擎自带的 KismetSystemLibrary.PrintString 把文字画到屏幕左上角（左上角叠加，不需要 UMG 资源）
-- 不同 UE 版本的参数顺序不一样，这里逐种尝试，全部失败就返回 false 由调用方退回日志
local hudState = { supported = nil, target = nil }

local function hudTargets()
    local out = {}
    local okC, cls = pcall(function() return StaticFindObject("/Script/Engine.KismetSystemLibrary") end)
    if okC and cls then out[#out + 1] = cls end
    -- 蓝图函数库真正的可调用对象是 CDO，有时类对象调不动
    local okD, cdo = pcall(function() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    if okD and cdo then out[#out + 1] = cdo end
    return out
end

-- 把一行字画到屏幕左上角（PrintString）。不同构建的参数编组不一样，这里逐个试，全失败返回 false
function G.hud(text, duration)
    if type(text) ~= "string" or text == "" then return false end
    local pawn = G.pawn()
    if not valid(pawn) then return false end
    local dur = tonumber(duration) or 2.0

    for _, obj in ipairs(hudTargets()) do
        if valid(obj) then
            local variants = {
                function() obj:PrintString(pawn, text, true, false, { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }, dur) end,
                function() obj:PrintString(pawn, text, true, false, { 1.0, 1.0, 1.0, 1.0 }, dur) end,
                function() obj:PrintString(pawn, text, true, false, dur, { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }) end,
                function() obj:PrintString(pawn, text, true, false, dur) end,
                function() obj:PrintString(pawn, text, true, false) end,
            }
            for _, fn in ipairs(variants) do
                local ok = pcall(fn)
                if ok then
                    hudState.supported, hudState.target = true, obj
                    return true
                end
            end
        end
    end
    hudState.supported = false
    return false
end

function G.hudSupported()
    return hudState.supported
end

-- ---------------------------------------------------------------- 深度探测
-- pbzkg probe 用：把「我要的符号在你机器上到底叫什么」全部列出来
function G.probe()
    local lines = {}
    local function add(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and s or tostring(fmt)
    end

    add("--- 深度探测（把这段发给作者即可定位缺失的名字）---")
    local pawn = G.pawn()
    add("玩家对象: %s", valid(pawn) and (tostring(addressOf(pawn)) .. " / " .. tostring(shortName(pawn))) or "未找到")
    if not valid(pawn) then return lines end

    -- 判定帧组件
    local okAll, all = pcall(FindAllOf, "DeflectComponent")
    if okAll and type(all) == "table" then
        add("DeflectComponent 实例: %d 个", #all)
        for i, comp in ipairs(all) do
            if i > 8 then add("  …其余 %d 个省略", #all - 8) break end
            local name, outerName, outerAddr = shortName(comp), nil, nil
            pcall(function()
                local o = comp:GetOuter()
                outerName, outerAddr = shortName(o), addressOf(o)
            end)
            local n = 0
            pcall(function()
                local fr = comp.ReceiveFrames
                if fr ~= nil then fr:ForEach(function() n = n + 1 end) end
            end)
            add("  [%d] %s  Outer=%s(%s)  判定帧=%d", i, tostring(name), tostring(outerName), tostring(outerAddr), n)
        end
    else
        add("DeflectComponent 实例: 遍历失败")
    end

    -- 输入动作
    local idx = actionIndex()
    add("InputAction 总数: %d", #idx)
    local hit = {}
    for _, e in ipairs(idx) do
        local low = e.name:lower()
        if low:find("attack", 1, true) or low:find("stance", 1, true)
            or low:find("deflect", 1, true) or low:find("heavy", 1, true) then
            hit[#hit + 1] = e.name
        end
    end
    add("  其中含 Attack/Stance/Deflect/Heavy 的: %d 个", #hit)
    for i, n in ipairs(hit) do
        if i > 40 then add("  …其余 %d 个省略", #hit - 40) break end
        add("    %s", n)
    end

    -- 武器实例
    local okA, actors = pcall(FindAllOf, "Actor")
    if okA and type(actors) == "table" then
        local n = 0
        for _, a in ipairs(actors) do
            if valid(a) then
                local okN, full = pcall(function() return a:GetFullName() end)
                if okN and type(full) == "string" and full:find("DualHook", 1, true) then
                    n = n + 1
                    local parent, owner = nil, nil
                    pcall(function() local p = a:GetAttachParentActor(); parent = shortName(p) end)
                    pcall(function() local o = a.Owner; owner = shortName(o) end)
                    if n <= 6 then
                        add("  武器 %s  AttachParent=%s Owner=%s", tostring(shortName(a)), tostring(parent), tostring(owner))
                    end
                end
            end
        end
        add("含 DualHook 的 Actor: %d 个", n)
    end

    -- 背包子系统
    local okB, bags = pcall(FindAllOf, "PBZBackPackSubsystem")
    if okB and type(bags) == "table" then
        add("PBZBackPackSubsystem: %d 个", #bags)
        for i, bp in ipairs(bags) do
            if i <= 2 and valid(bp) then
                local names = {}
                pcall(function()
                    local list = bp.MainWeapons
                    if list ~= nil then
                        pcall(function() list:ForEach(function(_, v) names[#names + 1] = tostring(textOf(v)) end) end)
                        if #names == 0 then
                            pcall(function() for k = 1, 8 do if list[k] ~= nil then names[#names + 1] = tostring(textOf(list[k])) end end end)
                        end
                    end
                end)
                add("  [%d] CurrentWeaponIndex=%s CurrentMainWeaponID=%s",
                    i, tostring(unwrap(bp.CurrentWeaponIndex)), tostring(textOf(bp.CurrentMainWeaponID)))
                add("      MainWeapons(%d): %s", #names, table.concat(names, " | "))
            end
        end
    end

    add("--- 探测结束 ---")
    return lines
end

return G
