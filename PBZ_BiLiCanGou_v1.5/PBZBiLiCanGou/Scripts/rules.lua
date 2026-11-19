-- rules.lua —— 别离残钩「架势反制」杀气返还规则引擎
-- 说明：本文件是纯逻辑，不接触任何 UE4SS / 游戏接口，可以在电脑上用 lua 直接单测。
-- 规则最终版（来自需求确认）：
--   1) 成功反制普通攻击      → 返还【本次架势消耗】的 35%，每个架势周期只返一次
--   2) 成功反制黑光 / 蓝光   → 补足到【本次架势消耗】的 100%（与 35% 叠加但不超额）
--   3) 未成功反制（失败或空放）→ 返还 50%（两者不再区分）
--   4) 任何情况都不额外惩罚
--   5) 每个架势周期累计返还不超过本次消耗的 100%
local Rules = {}

local DEFAULTS = {
    normal_pct       = 0.35,
    black_blue_pct   = 1.00,
    black_blue_fill_max = true,   -- 黑光/蓝光反制成功：直接把杀气恢复满（100%）
    unsuccessful_pct = 0.50,
    normal_once      = true,
    cap_at_base      = true,
    base_mode        = "drain", -- drain = 架势期间实际消耗；upfront = 起手瞬间消耗
}

local function to_num(v, d)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return d end
    return n
end

local function to_bool(v, d)
    if type(v) == "boolean" then return v end
    if v == "on" or v == "true" or v == 1 then return true end
    if v == "off" or v == "false" or v == 0 then return false end
    return d
end

-- 配置归一化：坏值一律回落到默认值，绝不让一个错字把返还率变成 0 或无穷
function Rules.config(cfg)
    cfg = type(cfg) == "table" and cfg or {}
    local c = {}
    c.normal_pct       = math.max(0, to_num(cfg.normal_pct, DEFAULTS.normal_pct))
    c.black_blue_pct   = math.max(0, to_num(cfg.black_blue_pct, DEFAULTS.black_blue_pct))
    c.black_blue_fill_max = to_bool(cfg.black_blue_fill_max, DEFAULTS.black_blue_fill_max)
    c.unsuccessful_pct = math.max(0, to_num(cfg.unsuccessful_pct, DEFAULTS.unsuccessful_pct))
    c.normal_once      = to_bool(cfg.normal_once, DEFAULTS.normal_once)
    c.cap_at_base      = to_bool(cfg.cap_at_base, DEFAULTS.cap_at_base)
    c.base_mode        = (cfg.base_mode == "upfront") and "upfront" or "drain"
    return c
end

-- 攻击类型归一化：接受英文枚举名、中文叫法、以及本项目内部简称
function Rules.kind_of(t)
    if type(t) ~= "string" then return nil end
    local s = t:lower()
    if s == "normal" or s == "普通" or s == "普通攻击" then return "normal" end
    if s == "black" or s == "powerattack" or s == "power_attack" or s == "黑光" then return "black" end
    if s == "blue" or s == "blueeye" or s == "blue_eye" or s == "blueflash" or s == "蓝光" then return "blue" end
    return nil
end

function Rules.new(cfg)
    local o = { config = Rules.config(cfg) }
    o.cycle = { base = 0, refunded = 0, success = false, normal_done = false, counters = 0, black_done = false }

    -- 进入架势：开一个新的返还周期。start_shachi 只用于日志/upfront 模式参考。
    function o:begin(start_shachi)
        self.cycle = {
            base = 0, refunded = 0, success = false, normal_done = false,
            counters = 0, start_shachi = to_num(start_shachi, nil),
            black_done = false, base_locked = false, provisional = false,
        }
        return self.cycle
    end

    -- drain 模式：把这一帧观察到的杀气下降累加进「本次消耗」
    function o:add_spend(amount)
        amount = to_num(amount, 0)
        if amount > 0 then self.cycle.base = self.cycle.base + amount end
        return self.cycle.base
    end

    -- upfront 模式：直接给出起手消耗（只认第一次，后续不覆盖）
    function o:set_base(value)
        value = to_num(value, 0)
        if value < 0 then value = 0 end
        if not self.cycle.base_locked then
            self.cycle.base = value
            self.cycle.base_locked = true
        end
        return self.cycle.base
    end

    -- 本周期还能返还多少（受 cap_at_base 限制）
    local function payable(self, amount)
        local cyc = self.cycle
        amount = to_num(amount, 0)
        if amount <= 0 then return 0 end
        if self.config.cap_at_base then
            local left = cyc.base - cyc.refunded
            if left <= 0 then return 0 end
            if amount > left then amount = left end
        end
        return amount
    end

    local function pay(self, amount)
        local got = payable(self, amount)
        if got > 0 then self.cycle.refunded = self.cycle.refunded + got end
        return got
    end

    -- 记录一次成功反制，返回应返还的杀气与实际原因
    function o:counter(attack_type)
        local kind = Rules.kind_of(attack_type)
        if not kind then return 0, "unknown_type" end
        local cyc = self.cycle
        cyc.counters = cyc.counters + 1
        cyc.success = true

        if kind == "normal" then
            if self.config.normal_once and cyc.normal_done then
                return 0, "normal_already_paid"
            end
            cyc.normal_done = true
            return pay(self, cyc.base * self.config.normal_pct), "normal"
        end

        -- 黑光 / 蓝光：恢复满杀气（100%），由上层执行真正的填满；填不了才退回按比例补差
        cyc.black_done = true
        if self.config.black_blue_fill_max then
            return 0, (kind == "black" and "black_fill" or "blue_fill")
        end
        local target = cyc.base * self.config.black_blue_pct
        return pay(self, target - cyc.refunded), (kind == "black" and "black_topup" or "blue_topup")
    end

    -- 架势动作结束：先按此刻的消耗返一半（没有成功反制的周期），后面继续观察再补差
    function o:finish_partial()
        local cyc = self.cycle
        if cyc.success then return 0, nil end
        local target = cyc.base * self.config.unsuccessful_pct
        local paid = pay(self, target - cyc.refunded)
        cyc.provisional = true
        return paid, "unsuccessful_partial"
    end

    -- 退出架势：结算。没有任何成功反制（失败或空放）才返 50%
    function o:finish()
        local cyc = self.cycle
        local paid, why = 0, "settled"
        if not cyc.success then
            if cyc.provisional then
                -- 架势结束时已经先返过一笔，这里把后续新增的消耗补到 50%
                paid, why = pay(self, cyc.base * self.config.unsuccessful_pct - cyc.refunded), "unsuccessful_topup"
            else
                paid, why = pay(self, cyc.base * self.config.unsuccessful_pct), "unsuccessful"
            end
        elseif cyc.black_done and not self.config.black_blue_fill_max then
            -- 黑光/蓝光补足 100%：反制瞬间基数还没涨完，这里把后续新增的消耗也补到 100%
            local target = cyc.base * self.config.black_blue_pct
            local delta = target - cyc.refunded
            if delta > 0 then
                paid, why = pay(self, delta), "black_blue_settle"
            end
        end
        local snap = {
            base = cyc.base, refunded = cyc.refunded, success = cyc.success,
            counters = cyc.counters, paid = paid, why = why,
        }
        self.cycle = {
            base = 0, refunded = 0, success = false, normal_done = false,
            counters = 0, black_done = false, base_locked = false, provisional = false,
        }
        return paid, snap
    end

    -- 只读快照，给状态面板用
    function o:peek()
        local cyc = self.cycle
        return {
            base = cyc.base, refunded = cyc.refunded, success = cyc.success,
            counters = cyc.counters, normal_done = cyc.normal_done,
            left = math.max(0, cyc.base - cyc.refunded),
        }
    end

    return o
end

return Rules
