-- stance.lua —— 架势周期状态机（纯逻辑：只吃采样数据，不碰游戏接口，可单测）
--
-- 它负责三件事：
--   1) 识别「进入架势 / 退出架势」的边沿，开/结一个返还周期
--   2) 在架势期间累计煞气实际下降量，作为「本次架势消耗」的基数
--   3) 从 Deflect 帧里识别「成功反制」以及被反制的攻击类型（普通 / 黑光 / 蓝光）
--
-- 成功反制的判定信号有两种，配置里选一种：
--   success_signal = "frame"   —— 架势期间某个来袭判定帧消失 = 该下被反制（默认，最省事）
--   success_signal = "montage" —— 玩家播放含关键词的动画（如 Counter）= 反制成功，
--                                 攻击类型取最近一次出现的判定帧类型
local Stance = {}

function Stance.new(opts)
    opts = type(opts) == "table" and opts or {}
    local o = {
        rules  = assert(opts.rules, "stance.lua needs a rules engine"),
        detect = type(opts.detect) == "table" and opts.detect or {},
        max_seconds = tonumber(opts.max_seconds) or 8.0,
        log = type(opts.log) == "function" and opts.log or function() end,
    }

    o.active = false
    o.startedAt = 0
    o.lastShachi = nil
    o.prevShachi = nil    -- 上一帧的煞气（跨架势保留，用来补「起手那一口」）
    o.seedCap = tonumber(opts.seed_cap) or 500  -- 起手补记的上限，防止切角色/复活被算成巨额消耗
o.tailSeconds = tonumber(opts.tail_seconds) or 0  -- 架势标签消失后继续计量的秒数（真实游戏里消耗常在标签消失后才扣）
o.tailUntil = nil
    o.known = {}          -- handle -> 攻击类型（架势中已见过的判定）
    o.watch = {}          -- handle -> {type=, isDodge=} 全程盯判定帧（不只架势中）
    o.lastFrameType = nil -- 最近一次看到的可反制类型
    o.montageMatched = false
    o.cycleIndex = 0

    local detect = o.detect
    local ignored = type(detect.frame_types_ignore) == "table" and detect.frame_types_ignore or {}
    local mapped = type(detect.counter_types) == "table" and detect.counter_types or {}
    local unknownType = detect.unknown_type or "skip"
    local signal = detect.success_signal or "frame"
    local keywords = type(detect.montage_keywords) == "table" and detect.montage_keywords or {}

    local function emit(out, kind, amount, reason, text)
        out[#out + 1] = { kind = kind, amount = amount, reason = reason, text = text }
    end

    local function montageHits(name)
        if type(name) ~= "string" or name == "" then return false end
        local low = name:lower()
        for _, kw in ipairs(keywords) do
            if type(kw) == "string" and kw ~= "" and low:find(kw:lower(), 1, true) then return true end
        end
        return false
    end

    local function takeCounter(self, attackType, out, source)
        local kind = mapped[attackType or "Unknown"] or unknownType
        if kind == nil or kind == "skip" then
            emit(out, "skip", 0, "unmapped_type",
                string.format("%s 的类型 %s 不计入反制", source or "判定", tostring(attackType)))
            return
        end
        local amount, reason = self.rules:counter(kind)
        emit(out, "counter", amount, reason,
            string.format("反制 %s（%s）→ 返还 %.2f", tostring(attackType), tostring(kind), amount))
        if reason == "black_fill" or reason == "blue_fill" then
            emit(out, "fill_max", 0, reason,
                string.format("反制 %s（%s）→ 杀气恢复 100%%", tostring(attackType), tostring(kind)))
        end
        if amount > 0 then
            emit(out, "refund", amount, reason,
                string.format("%s 返还 %.2f 杀气", reason, amount))
        end
    end

    -- sample = {
    --   stance  = true/false        架势标签是否在身
    --   shachi  = number|nil        当前煞气
    --   frames  = { {handle=, type=, hit=}, ... }   当前 Deflect 判定帧
    --   montage = "xxx_C"|nil       玩家当前动画名
    -- }
    function o:tick(sample, now)
        local out = {}
        sample = type(sample) == "table" and sample or {}
        now = tonumber(now) or os.clock()
        local active = sample.stance == true
        local tail = self.tailSeconds or 0

        local function settle(reason)
            local paid, snap = self.rules:finish()
            if paid > 0 then
                emit(out, "refund", paid, snap.why,
                    string.format("%s 返还 %.2f 杀气", snap.why, paid))
            end
            emit(out, "settle", paid, snap.why, string.format(
                "架势结束 #%d：基数 %.2f，成功反制 %d 次，合计返还 %.2f（%s）",
                self.cycleIndex, snap.base, snap.counters, snap.refunded, snap.why))
            self.active = false
            self.tailUntil = nil
            self.lastShachi = nil
            self.known = {}
            self.lastFrameType = nil
            self.lastSettleReason = reason
        end

        -- ---------------- 进入架势（上一周期还在尾部观察时，先把它结算掉）
        if active and not self.active then
            if self.tailUntil then
                self.tailUntil = nil
                settle("new_cycle")
            end
            self.active = true
            self.startedAt = now
            self.known = {}
            self.montageMatched = false
            self.lastFrameType = nil
            self.cycleIndex = self.cycleIndex + 1
            self.rules:begin(sample.shachi)

            -- 起手那一口：标签出现时煞气可能已在同一帧被扣掉，用「上一帧 - 本帧」补记
            local seed = 0
            local cur = tonumber(sample.shachi)
            local prev = self.prevShachi
            if cur and prev then
                local diff = prev - cur
                if diff > 0.01 then
                    if diff <= self.seedCap then
                        seed = diff
                        self.rules:add_spend(seed)
                    else
                        emit(out, "skip", 0, "seed_too_big",
                            string.format("起手消耗 %.1f 超过补记上限 %.1f，按 0 处理（可能是复活/换人）", diff, self.seedCap))
                    end
                end
            end
            self.lastShachi = cur
            emit(out, "enter", 0, "enter",
                string.format("架势开始 #%d（煞气 %s，起手补记 %.2f）", self.cycleIndex, tostring(sample.shachi), seed))
            for _, f in ipairs(sample.frames or {}) do
                if f.handle and not ignored[f.type] then
                    self.known[f.handle] = f.type or "Unknown"
                    self.lastFrameType = f.type or self.lastFrameType
                end
            end
        end

        -- ---------------- 标签消失：进入尾部观察窗（继续计量），或立即结算
        local justEnded = false
        if self.active and not active then
            self.active = false
            justEnded = true
            if tail > 0 then
                self.tailUntil = now + tail
                emit(out, "tail", 0, "tail", string.format(
                    "架势标签结束 #%d：继续观察 %.1fs，确认这段时间里被扣掉的消耗", self.cycleIndex, tail))
            else
                settle("stance_off")
            end
        end

        -- ---------------- 追踪期（标签在身 + 尾部观察窗）：累计实际下降
        if (self.active or (self.tailUntil and now <= self.tailUntil)) and sample.shachi ~= nil then
            local cur = tonumber(sample.shachi)
            if cur then
                if self.lastShachi then
                    local drop = self.lastShachi - cur
                    if drop > 0.01 then self.rules:add_spend(drop) end
                end
                self.lastShachi = cur
            end
        end

        -- ---------------- 全程盯判定帧（关键：真实游戏里黑/蓝光的反制常常发生在架势标签已经灭掉之后）
        local present = {}
        for _, f in ipairs(sample.frames or {}) do
            if f.handle then
                present[f.handle] = true
                local info = self.watch[f.handle]
                if not info then
                    info = { type = f.type or "Unknown", isDodge = f.isDodge == true }
                    self.watch[f.handle] = info
                    emit(out, "frame", 0, "seen", string.format(
                        "判定帧出现 #%s 类型 %s%s", tostring(f.handle), tostring(info.type),
                        info.isDodge and "（闪避）" or ""))
                else
                    if f.type and f.type ~= "Unknown" then info.type = f.type end
                    if f.isDodge == true then info.isDodge = true end
                end
                if not ignored[f.type] then self.lastFrameType = f.type or self.lastFrameType end
            end
        end

        if signal == "frame" then
            for handle, info in pairs(self.watch) do
                if not present[handle] then
                    self.watch[handle] = nil
                    local kind = mapped[info.type] or unknownType
                    local open = self.active or self.tailUntil
                    if info.isDodge then
                        emit(out, "skip", 0, "dodged",
                            string.format("判定帧 #%s（%s）是闪避掉的，不算反制", tostring(handle), tostring(info.type)))
                    elseif kind == "black" or kind == "blue" then
                        -- 黑/蓝光：判定帧被吃掉即视为反制成功；即使本周期已结算也照样回满杀气
                        if open then
                            local amount, reason = self.rules:counter(kind)
                            emit(out, "counter", amount, reason, string.format(
                                "反制 %s（%s，判定#%s）→ 杀气恢复 100%%", tostring(info.type), tostring(kind), tostring(handle)))
                        else
                            emit(out, "counter", 0, kind .. "_fill", string.format(
                                "反制 %s（%s，判定#%s）→ 杀气恢复 100%%（周期外）", tostring(info.type), tostring(kind), tostring(handle)))
                        end
                        emit(out, "fill_max", 0, kind .. "_fill", string.format(
                            "%s 反制成功 → 杀气恢复到 100%%", tostring(info.type)))
                    elseif open and kind ~= "skip" and kind ~= nil then
                        local amount, reason = self.rules:counter(kind)
                        emit(out, "counter", amount, reason, string.format(
                            "反制 %s（%s，判定#%s）→ 返还 %.2f", tostring(info.type), tostring(kind), tostring(handle), amount))
                        if amount > 0 then
                            emit(out, "refund", amount, reason, string.format("%s 返还 %.2f 杀气", reason, amount))
                        end
                    elseif kind == "normal" or kind == "black" or kind == "blue" then
                        emit(out, "skip", 0, "no_cycle",
                            string.format("判定帧 #%s（%s）在周期外被吃掉，不计数", tostring(handle), tostring(info.type)))
                    end
                end
            end
        end

        -- ---------------- 架势在身：动画信号 + 超时保护
        if self.active and signal == "montage" then
            if not self.montageMatched and montageHits(sample.montage) then
                self.montageMatched = true
                takeCounter(self, self.lastFrameType or "Normal", out, "动画")
            end
        end

        if self.active and self.max_seconds > 0 and now - self.startedAt >= self.max_seconds then
            emit(out, "skip", 0, "timeout",
                string.format("架势超过 %.1fs，强制结算", self.max_seconds))
            settle("timeout")
        end

        -- ---------------- 尾部观察窗到期：正式结算
        -- 架势动作结束的当帧：先把已经扣掉的消耗按 50% 返出来，后面观察到的再补差
        if justEnded and tail > 0 and not self.rules:peek().success then
            local paid, why = self.rules:finish_partial()
            if paid > 0 then
                emit(out, "refund", paid, why, string.format(
                    "架势结束 #%d 立即返还 %.2f 杀气（先返一半，剩余消耗观察后补）", self.cycleIndex, paid))
            end
        end

        if self.tailUntil and now > self.tailUntil then
            settle("tail_done")
        end

        -- 不在追踪期就清空判定记录，避免下次把旧帧算成反制
        if not self.active and not self.tailUntil and next(self.known) ~= nil then
            self.known = {}
        end

        -- 记住本帧煞气，供下一次「起手补记」使用（跨架势保留）
        local curForPrev = tonumber(sample.shachi)
        if curForPrev then self.prevShachi = curForPrev end

        return out
    end

    -- 状态面板
    function o:status()
        return {
            active = self.active,
            cycle = self.cycleIndex,
            base = self.rules:peek().base,
            refunded = self.rules:peek().refunded,
            counters = self.rules:peek().counters,
            seen = (function()
                local n = 0
                for _ in pairs(self.known) do n = n + 1 end
                return n
            end)(),
        }
    end

    return o
end

return Stance
