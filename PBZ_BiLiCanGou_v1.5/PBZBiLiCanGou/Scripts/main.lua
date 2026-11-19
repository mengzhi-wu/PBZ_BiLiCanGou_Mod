-- main.lua —— 入口：装配规则引擎、架势跟踪、瞬时反制、杀气返还，并挂热键 / 控制台命令
--
-- 模块划分：
--   rules.lua       纯规则（35% / 50% / 100% 补足 / 100% 上限）
--   stance.lua      架势周期状态机（进入/退出/消耗/反制识别）——纯逻辑，可单测
--   autocounter.lua 瞬时反制（自动架招）——纯决策，可单测
--   gameapi.lua     唯一碰游戏的一层（属性集/标签/判定帧/输入注入）
--   log.lua、config.lua
if PBZBILICANGOU then return end
PBZBILICANGOU = true

local dir = debug.getinfo(1, "S").source:match("^@(.+[\\/])[^\\/]+$") or ".\\"
local function load(name) return assert(loadfile(dir .. name))() end

local Log    = load("log.lua")
local Config = load("config.lua")
local Rules  = load("rules.lua")
local Stance = load("stance.lua")
local Game   = load("gameapi.lua")
local Auto   = load("autocounter.lua")

Log.init(dir, Config.verbose, Config.log_to_file)

local okInit, initMsg = Game.init(Log, Config)
if not okInit then Log.warn("游戏接口初始化失败：%s", tostring(initMsg)) end

-- 装配
local rules   = Rules.new(Config.refund)
local stance  = Stance.new{
    rules = rules,
    detect = Config.detect,
    max_seconds = Config.refund.max_stance_seconds,
    seed_cap = Config.refund.seed_cap,
    tail_seconds = Config.refund.tail_seconds,
    log = Log.log,
}
local auto = Auto.new{
    config = Config.instant_counter,
    counter_types = Config.detect.counter_types,
    ignore_types = Config.detect.frame_types_ignore,
    log = Log.log,
}

-- 运行状态
local stopped = false        -- F9 紧急停止：只停写，不再返还
local refundDisabled = false -- 连续写失败后自动停写
local failCount = 0
local tickCount = 0
local diagDone = false
local tickErrors = 0

-- ---------------------------------------------------------------- 返还落地
local function applyRefund(amount, reason)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    if stopped then
        Log.log("已紧急停止，跳过返还 %.2f（%s）", amount, tostring(reason))
        return
    end
    if refundDisabled then
        Log.log("写入已停用，跳过返还 %.2f（%s）", amount, tostring(reason))
        return
    end
    if Config.refund.enabled == false then
        Log.log("杀气返还关闭，跳过 %.2f（%s）", amount, tostring(reason))
        return
    end
    if Config.refund.dry_run then
        Log.log("[DRY-RUN] 本该返还 %.2f 杀气（%s）", amount, tostring(reason))
        return
    end
    local minWrite = tonumber(Config.refund.min_write) or 0
    if amount < minWrite then
        Log.detail("返还 %.2f 低于阈值 %.2f，跳过（%s）", amount, minWrite, tostring(reason))
        return
    end

    local okW, res = Game.addShachi(amount)
    if okW and type(res) == "table" then
        failCount = 0
        Log.log("返还 %.2f 杀气（%s）：%.2f → %.2f", res.delta or amount, tostring(reason),
            res.before or -1, res.after or -1)
    else
        failCount = failCount + 1
        Log.warn("返还失败（%s），连续第 %d 次", tostring(res), failCount)
        if failCount >= 5 then
            refundDisabled = true
            Log.warn("连续 5 次写入失败，已停用杀气返还（按 F8 两次或 pbzkg on 可重开）")
        end
    end
end

-- ---------------------------------------------------------------- 单帧
local function step()
    tickCount = tickCount + 1
    local now = Game.now()
    local state = Game.state()

    -- 游戏还没进关卡（主菜单/加载）时安静等待
    if not state.pawn then
        if tickCount % 100 == 0 then
            Log.detail("等待进入游戏…（未找到玩家对象）")
        end
        return
    end

    -- 第一次进关卡 2 秒后打印一次接口诊断，方便对着日志核对
    if not diagDone and tickCount >= 20 then
        diagDone = true
        Log.log("首次进入关卡，接口诊断如下（有问题就按 README 的「验证」一节处理）")
        for _, line in ipairs(Game.diag()) do Log.log(line) end
    end

    -- 1) 架势周期与返还
    local events = stance:tick(state, now)
    for _, e in ipairs(events) do
        if e.kind == "enter" or e.kind == "settle" then
            Log.log("%s", tostring(e.text))
        elseif e.kind == "counter" then
            Log.log("%s", tostring(e.text))
        elseif e.kind == "skip" then
            Log.detail("%s", tostring(e.text))
        elseif e.kind == "frame" then
            Log.detail("%s", tostring(e.text))
        elseif e.kind == "fill_max" then
            local okF, res = Game.fillShachi()
            if okF and type(res) == "table" then
                Log.log("%s：杀气 %.2f → %.2f（上限 %.2f）", tostring(e.text),
                    res.before or -1, res.after or -1, res.target or -1)
            else
                Log.warn("%s：填满失败（%s）", tostring(e.text), tostring(res))
            end
        elseif e.kind == "refund" then
            applyRefund(e.amount, e.reason)
        end
    end

    -- 2) 瞬时反制
    local actions = auto:tick(state, now, Game)
    for _, name in ipairs(actions) do
        local okI, res = Game.inject(name)
        if not okI then
            Log.warn("注入 %s 失败：%s", tostring(name), tostring(res))
        end
    end

end

local function guardedStep()
    local ok, err = pcall(step)
    if not ok then
        tickErrors = tickErrors + 1
        if tickErrors <= 10 then
            Log.warn("tick 出错（第 %d 次）：%s", tickErrors, tostring(err))
        elseif tickErrors == 11 then
            Log.warn("tick 持续出错，后续同类错误只计数不再刷日志")
        end
    end
    return tickErrors < 200
end

-- ---------------------------------------------------------------- 状态面板
local function printStatus()
    Log.log("================ 状态 ================")
    local refundState = "关"
    if Config.refund.enabled then refundState = Config.refund.dry_run and "开（dry-run 只记录不写）" or "开" end
    Log.log("杀气返还：%s%s", refundState,
        refundDisabled and "（写入已停用）" or (stopped and "（已紧急停止）" or ""))
    Log.log("规则：普通 %.0f%% / 黑光蓝光 补足 %.0f%% / 未成功 %.0f%% / 上限 %.0f%%（基数=%s）",
        Config.refund.normal_pct * 100, Config.refund.black_blue_pct * 100,
        Config.refund.unsuccessful_pct * 100,
        Config.refund.cap_at_base and 100 or 999,
        tostring(Config.refund.base_mode))

    local st = stance:status()
    Log.log("架势：%s 周期#%d 本次消耗 %.2f 已返 %.2f 成功反制 %d 次 追踪判定 %d 个",
        st.active and "进行中" or "空闲", st.cycle, st.base, st.refunded, st.counters, st.seen)

    local at = auto:status()
    Log.log("瞬时反制：%s 起架 %s 次 格挡=%s 重击=%s",
        at.enabled and "启用" or "停用", at.presses, tostring(at.stance), tostring(at.press))

    for _, line in ipairs(Game.diag()) do Log.log("%s", line) end
    Log.log("=====================================")
end

-- ---------------------------------------------------------------- 热键
local function keyOf(name)
    if type(Key) == "table" and name and Key[name] ~= nil then return Key[name] end
    return nil
end

local function bind(name, fn, label)
    local k = keyOf(name)
    if not k then
        Log.warn("热键 %s 未能解析，%s 只能在控制台用", tostring(name), tostring(label))
        return
    end
    local ok = pcall(RegisterKeyBind, k, function()
        local okRun, err = pcall(fn)
        if not okRun then Log.warn("热键 %s 执行出错：%s", tostring(name), tostring(err)) end
    end)
    if not ok then Log.warn("热键 %s 注册失败（%s）", tostring(name), tostring(label)) end
end

-- ---------------------------------------------------------------- 屏幕提示（F1 / F2）
local function toast(text)
    Log.log("%s", text)
    Game.hud(text, 2.0)
end

bind(Config.keys.status, function() printStatus() end, "状态日志")

bind(Config.keys.refund or "F1", function()
    if refundDisabled or stopped then
        refundDisabled, stopped, failCount = false, false, 0
        Config.refund.enabled = true
    else
        Config.refund.enabled = not Config.refund.enabled
    end
    local msg = string.format("杀气返还：%s", Config.refund.enabled and "开启" or "关闭")
    toast(msg)
end, "杀气返还开关")

bind(Config.keys.auto or "F2", function()
    local cfgAuto = Config.instant_counter
    cfgAuto.enabled = (cfgAuto.enabled == false)
    toast(string.format("瞬时反制：%s", cfgAuto.enabled and "开启" or "关闭"))
end, "瞬时反制开关")
bind(Config.keys.panic, function()
    stopped = not stopped
    toast(string.format("紧急停止：%s", stopped and "已停止写入" or "已解除"))
end, "紧急停止")

-- ---------------------------------------------------------------- 控制台命令
local function commandHandler(full, params)
    local cmd, arg = "status", nil
    if type(params) == "table" and params[1] then
        cmd = tostring(params[1])
        arg = params[2] and tostring(params[2]) or nil
    elseif type(params) == "string" then
        local a, b = params:match("^%s*(%S*)%s*(%S*)")
        cmd, arg = a or "status", b
    elseif type(full) == "string" then
        local a, b = full:match("^%s*%S*%s+(%S*)%s*(%S*)")
        cmd, arg = a or "status", b
    end
    cmd = cmd:lower()
    arg = arg and arg:lower() or nil

    if cmd == "status" then
        printStatus()
    elseif cmd == "on" then
        Config.refund.enabled, refundDisabled, stopped, failCount = true, false, false, 0
        Log.log("杀气返还已开启")
    elseif cmd == "off" then
        Config.refund.enabled = false
        Log.log("杀气返还已关闭")
    elseif cmd == "dryrun" then
        Config.refund.dry_run = not Config.refund.dry_run
        Log.log("dry-run：%s", Config.refund.dry_run and "开（只记录不写）" or "关")
    elseif cmd == "panic" then
        stopped = not stopped
        Log.log("紧急停止：%s", stopped and "开" or "关")
    elseif cmd == "auto" then
        -- pbzkg auto / auto on / auto off
        local want
        if arg == "on" then want = true elseif arg == "off" then want = false end
        local cfgAuto = Config.instant_counter
        cfgAuto.enabled = (want ~= nil) and want or (cfgAuto.enabled == false)
        Log.log("瞬时反制：%s", cfgAuto.enabled and "开" or "关")
    elseif cmd == "probe" then
        Log.log("深度探测：把接下来这些行发给作者，用来定位缺失的名字")
        for _, line in ipairs(Game.probe()) do Log.log("%s", line) end
    elseif cmd == "reload" then
        local okC, cfg = pcall(function() return assert(loadfile(dir .. "config.lua"))() end)
        if okC and type(cfg) == "table" then
            Config.refund = cfg.refund
            Config.instant_counter = cfg.instant_counter
            Config.detect = cfg.detect
            rules.config = Rules.config(Config.refund)
            Log.log("config.lua 已重载（架势跟踪的检测口径需重启游戏才生效）")
        else
            Log.warn("config.lua 重载失败：%s", tostring(cfg))
        end
    else
        Log.log("用法：%s status | on | off | auto on/off | dryrun | panic | probe | reload", Config.command)
    end
    return true
end

local okCmd = pcall(RegisterConsoleCommandGlobalHandler, Config.command, function(full, params)
    local okRun, err = pcall(commandHandler, full, params)
    if not okRun then Log.warn("命令执行出错：%s", tostring(err)) end
end)
if not okCmd then Log.warn("控制台命令 %s 注册失败", Config.command) end

-- ---------------------------------------------------------------- 主循环
local okLoop, loopErr = pcall(function()
    return LoopInGameThreadWithDelay(Config.tick_ms, function()
        return guardedStep()
    end)
end)

Log.log("v1.5 正式版 已加载 —— 反制当场返还（普通 35%）/ 黑蓝判定帧一消失就回满杀气 / 无成效：架势一结束即返 50%")
Log.log("v1.5 正式版：判定帧全程监听 / 采样 50ms / 瞬时反制 0 帧触发 / F1 杀气返还、F2 瞬时反制")
Log.log("热键：%s 杀气返还 开/关 | %s 瞬时反制 开/关 | %s 紧急停止",
    Config.keys.refund or "F1", Config.keys.auto or "F2", Config.keys.panic)
if not okLoop then
    Log.warn("主循环启动失败：%s", tostring(loopErr))
end
