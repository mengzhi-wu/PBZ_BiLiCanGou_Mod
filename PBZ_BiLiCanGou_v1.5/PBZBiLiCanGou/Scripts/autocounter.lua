-- autocounter.lua —— 瞬时反制：检测到可反制的来袭攻击，立刻自动「按住格挡 + 按重击」起架
--
-- 为什么是「按格挡 + 重击」：
--   别离残钩的反制就是「格挡 + 重击」摆出架势，架势期间格挡敌方近战招式并顺势反制。
--   原版需要人提前按键，判定窗口只有很短一瞬；这里盯判定帧，判定一出现（0 帧等待）就按住格挡 + 重击，
--   把「瞬时反制」做成可用的形状（config.instant_counter.trigger_frames 可调，2 = 等第 2 帧再打）。
--
-- 本模块只做决策与节奏，所有按键都通过注入层 api.inject(动作名) 发出，方便脱机单测。
local Auto = {}

function Auto.new(opts)
    opts = type(opts) == "table" and opts or {}
    local o = {
        cfg = type(opts.config) == "table" and opts.config or {},
        log = type(opts.log) == "function" and opts.log or function() end,
        counterTypes = type(opts.counter_types) == "table" and opts.counter_types or {},
        ignoreTypes = type(opts.ignore_types) == "table" and opts.ignore_types or {},
    }
    o.hold = nil          -- { untilT = 秒, type = 攻击类型, started = 秒 }
    o.pending = nil       -- { handle = , count = } 判定帧已连续观察到的帧数（2 帧触发用）
    o.lastPress = -1e9
    o.stanceAction = nil
    o.pressAction = nil
    o.stats = { presses = 0, held = 0, skipped = 0 }
    return setmetatable(o, { __index = Auto })
end

local function cfgNumber(cfg, key, default)
    local v = tonumber(cfg[key])
    if v == nil or v ~= v then return default end
    return v
end

-- 决定这一帧该不该起架；返回 { hit, type } 或 nil
function Auto:plan(state, now)
    local cfg = self.cfg
    if cfg.enabled == false then return nil end
    if state.deflect_ok == false then return nil end
    if state.stance then return nil end                       -- 已经在架势里，不重复起
    if now - self.lastPress < cfgNumber(cfg, "cooldown", 0.6) then return nil end
    if cfg.require_weapon ~= false and state.weapon_ok ~= true then return nil end
    local minPct = cfgNumber(cfg, "shachi_min_pct", 37)
    if minPct > 0 then
        local pct = tonumber(state.shachi_pct)
        if pct == nil or pct < minPct then return nil end
    end

    local window = cfgNumber(cfg, "scan_window", 0.8)
    local best = nil
    for _, f in ipairs(state.frames or {}) do
        if f.type and not self.ignoreTypes[f.type] then
            local kind = self.counterTypes[f.type]
            local hit = tonumber(f.hit)
            if kind and hit and hit >= now - 0.05 and (hit - now) <= window then
                if not best or hit < best.hit then
                    best = { hit = hit, type = f.type, kind = kind, handle = f.handle }
                end
            end
        end
    end
    return best
end

-- 每帧调用：返回本帧要注入的动作（0~2 个）
function Auto:tick(state, now, api)
    local cfg = self.cfg
    if cfg.enabled == false then return {} end

    -- 动作名只解析一次
    if not self.stanceAction then
        self.stanceAction = api.firstAction(cfg.actions and cfg.actions.stance or {})
        if not self.stanceAction and api.findAction then
            self.stanceAction = api.findAction(cfg.stance_fallback or { "Stance", "Deflect" })
        end
        if self.stanceAction then
            self.log("瞬时反制：格挡动作 = %s", self.stanceAction)
        else
            self.log("瞬时反制：找不到格挡动作（IA_Stance / IA_Deflect），该功能停用")
            cfg.enabled = false
            return {}
        end
    end
    if not self.pressAction then
        self.pressAction = api.firstAction(cfg.actions and cfg.actions.press or {})
        if not self.pressAction and api.findAction then
            self.pressAction = api.findAction(cfg.press_fallback or { "AttackH", "AttackHeavy", "HeavyAttack", "StrongAttack" })
        end
        if self.pressAction then
            self.log("瞬时反制：重击动作 = %s", self.pressAction)
        else
            self.log("瞬时反制：找不到重击动作（IA_AttackH_*），该功能停用")
            cfg.enabled = false
            return {}
        end
    end

    local actions = {}

    -- 已经在按住
    if self.hold then
        if now >= self.hold.untilT then
            self.log("瞬时反制：架势收招（%s）", tostring(self.hold.type))
            self.hold = nil
            return actions
        end
        self.stats.held = self.stats.held + 1
        actions[#actions + 1] = self.stanceAction
        return actions
    end

    local plan = self:plan(state, now)
    if not plan then
        self.pending = nil
        return actions
    end

    -- 触发帧数：判定帧要连续存在 N 帧（N 次采样）才出手；0/1 = 判定一出现就打（默认），2 = 等到第 2 帧
    local need = cfgNumber(cfg, "trigger_frames", 0)
    if need > 1 then
        local p = self.pending
        if p and p.handle == plan.handle then
            p.count = p.count + 1
        else
            self.pending = { handle = plan.handle, count = 1 }
        end
        if self.pending.count < need then
            return actions
        end
    end
    self.pending = nil

    -- 起架：本帧按住格挡 + 打一次重击
    local lead = cfgNumber(cfg, "lead", 0.05)
    local holdExtra = cfgNumber(cfg, "hold_extra", 0.18)
    self.hold = { untilT = plan.hit + holdExtra, type = plan.type, started = now, handle = plan.handle }
    self.lastPress = now
    self.stats.presses = self.stats.presses + 1

    actions[#actions + 1] = self.stanceAction
    actions[#actions + 1] = self.pressAction
    self.log("瞬时反制：判定#%s 类型=%s，命中 %.2fs 后，提前量 %.2fs 起架",
        tostring(plan.handle), tostring(plan.type), plan.hit - now, lead)
    return actions
end

function Auto:status()
    return {
        enabled = self.cfg.enabled ~= false,
        holding = self.hold ~= nil,
        stance = self.stanceAction,
        press = self.pressAction,
        presses = self.stats.presses,
    }
end

return Auto
