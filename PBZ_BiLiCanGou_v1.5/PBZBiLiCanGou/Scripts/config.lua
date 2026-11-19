-- config.lua —— 全部可调参数。改完保存，重启游戏生效（或在控制台输 pbzkg reload）
local C = {}

C.mod_name = "PBZBiLiCanGou"
C.verbose = true       -- 日志详细程度：检测/返还过程逐条写日志
C.tick_ms = 50         -- 采样间隔（毫秒）。50 = 每秒 20 次，判定帧窗口短，采样越密越不容易漏
C.log_to_file = true   -- 额外写一份 PBZBiLiCanGou.log 到 mod 目录（UE4SS.log 每次启动会被覆盖）

-- ============================ 杀气返还 ============================
C.refund = {
    enabled = true,                 -- 总开关：false = 完全不写煞气
    dry_run = false,                -- true = 只打印「本该返多少」，不真的写。首次进游戏建议先 true 看一轮
    normal_pct = 0.35,              -- 成功反制普通攻击：返本次消耗的 35%（v1.1.2 起由 15% 上调）
    black_blue_fill_max = true,     -- 成功反制黑光/蓝光：直接把杀气恢复满（100%），优先于下面的比例
    black_blue_pct = 1.00,          -- 备用：若关掉 fill_max，则按「补足到本次消耗的 X 倍」返还
    unsuccessful_pct = 0.50,        -- 未成功反制（失败或空放）：返 50%（v1.1.1 起由 20% 上调）
    normal_once_per_stance = true,  -- 普通反制每个架势周期只返一次
    cap_at_base = true,             -- 每周期累计返还不超过本次消耗（防刷）
    base_mode = "drain",            -- "drain" 架势期间实际消耗（推荐）/ "upfront" 只算起手瞬间消耗
    max_stance_seconds = 8.0,       -- 单周期最长时长，超时强制结算，防止基数滚太大
    min_write = 0.5,                -- 小于该值不写煞气（避免每帧抖动）
    seed_cap = 500,                 -- 起手补记的上限：架势刚起时补记的「那一口」消耗超过这个值就忽略（防复活/换人误算）
    tail_seconds = 4.0,             -- 架势标签消失后继续观察计量的秒数。真实游戏里消耗常在标签消失后 1~3 秒才扣，
                                    -- 日志实测：806.8 起手，标签 0.5 秒就灭，几秒后直接掉到 570（236 的消耗没被计到）
                                    -- 设 0 可退回旧版「标签一灭就结算」的行为
    write_base_value = true,        -- 写杀气时同时同步 BaseValue（部分 HUD 读它）
}

-- ============================ 瞬时反制 ============================
-- 含义：不用自己按键。一旦检测到「可反制的来袭攻击」，立刻自动「按住格挡 + 按重击」起架，
-- 让反制判定在第一帧就开着（这就是「瞬时」），不再依赖人手提前量。
C.instant_counter = {
    enabled = true,
    lead = 0.05,        -- 命中前多少秒起架。0.05 ≈ 判定一出现就打出去（瞬时）
    scan_window = 0.8,  -- 只处理这么多秒内会命中的攻击
    hold_extra = 0.18,  -- 命中之后再按住架招多久，让反制动作播完
    shachi_min_pct = 37,-- 煞气低于这个百分比不硬放（跟参考 mod 的 37% 门槛一致）
    require_weapon = true,
    weapon_match = { "DualHook", "别离残钩", "別離殘鉤", "BiLiCanGou" },
    cooldown = 0.6,     -- 两次自动起架之间至少间隔
    trigger_frames = 0, -- 触发前要等几帧：0 / 1 = 判定帧一出现就按键（瞬时）；2 = 看到第 2 帧再打

    -- 按键动作：按顺序找第一个能解析到的。别离残钩反制 = 按住格挡 + 按重击
    actions = {
        stance = { "IA_Stance", "IA_Deflect", "IA_HoldDeflect" },
        press  = { "IA_AttackH_Press", "IA_AttackH_Hold", "IA_AttackH_PressLong", "IA_AttackH" },
    },
    -- 上面这些名字都解析不到时，按关键词在全部 InputAction 里扫（v1.1 加的兜底）
    stance_fallback = { "Stance", "Deflect", "HoldDeflect" },
    press_fallback  = { "AttackH", "AttackHeavy", "HeavyAttack", "StrongAttack" },

    -- 判定「手里是不是别离残钩」用的武器 Actor 类名（背包子系统读不到时的兜底）
    weapon_classes = {
        "BP_Weapon_Hun_DualHook_R_C",
        "BP_Weapon_Hun_DualHook_L_C",
        "BP_Weapon_Hun_DualHook_C",
    },
}

-- ============================ 检测口径 ============================
C.detect = {
    -- 架势状态标签：命中任意一个即视为「架势中」
    stance_tags = {
        "Ability.Action.Stance",
        "CharacterState.Stance",
        "CharacterState.HoldDeflect",
    },

    -- 成功反制信号：frame（判定帧消失=被反制）/ montage（出现反制动画）
    success_signal = "frame",
    montage_keywords = { "Counter", "FanZhi", "BLG", "DualHook", "Hook_", "CanGou" },

    -- DeflectBulletType 枚举 → 本 mod 的攻击类型
    -- 游戏里的枚举顺序：0=CantDeflect 1=Normal 2=BlueEye 3=RedEye 4=PowerAttack 5=HoldDeflect
    counter_types = {
        Normal      = "normal",
        BlueEye     = "blue",     -- 蓝光
        PowerAttack = "black",    -- 黑光
        HoldDeflect = "normal",
    },
    frame_types_ignore = { RedEye = true, CantDeflect = true }, -- 红光只能闪、不可反制
    unknown_type = "skip",       -- 读不到类型的帧怎么算：skip = 不计数
}

-- ============================ 快捷键 / 命令 ============================
C.keys = {
    refund = "F1",   -- 杀气返还开/关（按下时屏幕提示当前状态）
    auto   = "F2",   -- 瞬时反制开/关（按下时屏幕提示当前状态）
    status = "F7",   -- 只把详细状态写进日志（不弹菜单）
    panic  = "F9",   -- 紧急停止（立刻停写，直到再按一次或重载）
}
C.command = "pbzkg"  -- 控制台命令：pbzkg status / on / off / panic / dryrun / reload

return C
