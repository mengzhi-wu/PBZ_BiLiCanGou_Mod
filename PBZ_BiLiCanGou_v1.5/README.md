# 影之刃零「别离残钩」机制优化 Mod

> 基于 UE4SS 的 Lua mod（单人游戏用），版本 v1.5（正式版）
> 功能：**瞬时反制** + **架势反制成功后的杀气返还**

---

## 一、这个 mod 改了什么

| 架势周期内发生的事 | 是否算成功反制 | 杀气返还 |
|---|---|---|
| 成功反制**普通攻击** | 是 | **当场**返还本次架势消耗的 **35%**，每个周期只返一次 |
| 成功反制**黑光 / 蓝光** | 是 | **判定帧被吃掉的那一刻把杀气恢复到 100%（满条）**；架子已经收起、甚至本周期已结算，照样回满 |
| **未成功反制**（反制失败 或 空放） | 否 | **架势动作一结束就返还 50%**（按当时已扣的消耗），随后观察到的延迟消耗再补差到 50% |
| 任何情况 | — | **没有额外惩罚**（不扣更多气、不加伤、不加硬直） |

附加两条保护（防止刷资源）：

- 每个架势周期**累计返还上限 = 本次消耗的 100%**（配置里可关，默认开）。
- 普通攻击的 35% **每周期只返一次**，连续反制多个普通攻击不会叠加。

**返还的时机**：反制成功的那一刻就生效——普通攻击当场返 35%，黑光/蓝光当场把整条杀气填满。
只有「整个架势周期一次反制都没成功」时，才在**架势动作结束的那一刻**按 50% 返还；真实游戏里部分消耗会在标签消失后 1~3 秒才扣，
所以先返一笔，尾部观察窗里再补差，最终仍是本次消耗的 50%，但你在架势收招时就能看到杀气回来了。

另外 **瞬时反制**：检测到可反制的来袭攻击（普通 / 黑光 / 蓝光）时，自动「按住格挡 + 按重击」起架，
判定帧**一出现就按键**（0 帧等待，配置 `trigger_frames` 可调）；
让反制判定在攻击出现的**第一帧**就开着，不再依赖人手提前量。

---

## 二、规则落到游戏里是哪几个信号

| 规则要素 | 运行时信号 | 说明 |
|---|---|---|
| 架势是否开着 | GameplayTag `Ability.Action.Stance`（备选 `CharacterState.Stance`） | 架势能力带这个标签，整把武器通用 |
| 本次架势消耗了多少杀气 | `BasicAttributeSet.Shachi` / `Shachi_Max` 的 `CurrentValue` | 每帧采样，**只累加下降**；自己返还造成的上升会被忽略 |
| 有可反制的攻击来袭 | `pawn.DeflectComponent.ReceiveFrames` 判定帧 | 帧里的 `SourceAction.DeflectBulletType` 给出攻击类型 |
| 攻击类型 | `Normal` / `BlueEye`(蓝光) / `PowerAttack`(黑光) / `RedEye`(红光，不可反制) | 红光与 CantDeflect 直接排除 |
| 反制成功 | 架势期间该判定帧从 `ReceiveFrames` 中消失 | 默认信号，见「已知边界」 |
| 手里是不是别离残钩 | `PBZBackPackSubsystem` 的 `MainWeapons` / `CurrentWeaponIndex` | 武器 ID 里含 `DualHook` |
| 起架按键 | 输入动作 `IA_Stance`(或 `IA_Deflect`) + `IA_AttackH_Press` | 经 EnhancedInput 子系统注入 |

---

## 三、安装

### 一键安装（推荐）

1. **完全关闭游戏**（脚本会检测进程，游戏在跑会直接拒装）。
2. 先装前置 **UE4SS for Phantom Blade Zero**（Nexus：`phantombladezero/mods/14`），
   解压到 `...\steamapps\common\PBZ\platform\steam\`（和 `PBZ.exe` 同级，不是游戏根目录）。
3. **双击 `install.bat`**，窗口会提示你把**游戏根目录**拖进去（也可以直接回车，会弹出文件夹选择框）。
   只要路径对，脚本自己往上/往下摸到 `PBZ.exe`，然后完成这些事：
   - 校验这个目录里确实有 `PBZ.exe`（找不到会明确告诉你哪儿不对，并允许重试三次）；
   - 检查同级的 `ue4ss` 是否已装（没装会提示，可现场决定继续或取消）；
   - 把 mod 复制到 `ue4ss\Mods\PBZBiLiCanGou\`；
   - **旧版本自动备份**成 `PBZBiLiCanGou.bak-<时间戳>`，不会覆盖丢失；
   - 生成 `enabled.txt`，并在 `mods.txt` 里写入/修正 `PBZBiLiCanGou : 1`（改前先备份 `mods.txt`）；
   - 把这次选的游戏目录记下来（`tools\..\.pbz_game_path`），下次 `check.bat` / `uninstall.bat` 不用再输。
4. **双击 `check.bat`** 体检，应逐项 `[OK]`：安装包完整 / 游戏目录 / UE4SS / mod 已安装 / 7 个 .lua /
   `enabled.txt` / `mods.txt` 状态（还会顺带打印日志最后几行）。
5. 启动游戏，在 `ue4ss\UE4SS.log` 或 mod 目录的 `PBZBiLiCanGou.log` 里搜 `[PBZBiLiCanGou]`，
   应看到 `v1.1 已加载`。

**三种给路径的方式**（任选一种）

```
直接把游戏文件夹拖到 install.bat 上
双击 install.bat，把路径粘进窗口后回车
install.bat "D:\SteamLibrary\steamapps\common\PBZ"     （写死在快捷方式里也行）
```

根目录 / `platform\steam` 目录 / `ue4ss` 目录**给哪一层都能认**，脚本会自己往下找 `PBZ.exe`。

**可选开关**

```
install.bat -Force   （未检测到 UE4SS 也先放文件，之后补装 UE4SS 即可）
```

> 脚本只做三件事：复制/删除 mod 目录、改 `mods.txt` 的一行、生成 `enabled.txt`。
> 不碰游戏本体文件、不碰存档；所有被改动的文件都留 `.bak-时间戳` 备份。

**脚本跑不起来时**

- 提示 *running scripts is disabled on this system*：在解压目录里按住 Shift 右键 → 在此处打开 PowerShell，
  执行 `powershell -ExecutionPolicy Bypass -File .\tools\PBZModSetup.ps1`（路径可直接跟在这一行后面）。
- 提示「这个路径里没找到 PBZ.exe」：说明选的是上一级或别的盘，选到游戏安装目录（Steam 版通常是
  `...\steamapps\common\PBZ`）再试。
- 杀毒软件报「脚本修改文件」：属于正常行为（它要复制 mod 并改 `mods.txt`），可放行或改用手动安装。

### 手动安装（不想跑脚本时）

1. 完全关闭游戏。
2. 把 `PBZBiLiCanGou` 文件夹整个复制到 `...\platform\steam\ue4ss\Mods\PBZBiLiCanGou\`。
3. 确认里面同时有 `enabled.txt` 和 `Scripts\main.lua`。
4. 若没加载，打开 `ue4ss\Mods\mods.txt` 加一行 `PBZBiLiCanGou : 1`。

### 卸载

双击 `uninstall.bat`：它会沿用上次安装时记下的游戏目录（没记录就问你一次），确认一次后执行：

- 删除 `ue4ss\Mods\PBZBiLiCanGou`（含日志）；
- 从 `mods.txt` 移除本 mod 的记录（改前备份）；
- 游戏本体、存档、其他 mod 都不动。

也可以手动删掉 `ue4ss\Mods\PBZBiLiCanGou` 文件夹并去掉 `mods.txt` 里那一行。

## 四、第一次进游戏：先验证，再开写

mod 默认**会真的写杀气**，但第一次建议按下面四步确认检测口径对不对（2 分钟）：

1. **按 F7** 把详细状态写进日志：玩家对象、属性集、杀气值、标签、当前武器、
   DeflectComponent、每个来袭判定帧的类型与命中时间、输入动作是否解析到。
   → 如果「属性集 / DeflectComponent / 输入动作」有「未找到」，先按第五节排查。
2. **控制台输入 `pbzkg probe`**：把判定帧组件的候选实例、全部可用输入动作名、DualHook 武器实例、
   背包字段一次性写进日志。F7 里凡是「未找到 / 缺失 / nil」的项，用这段就能直接对上真实名字。
3. **控制台输入 `pbzkg dryrun`**（或改 `config.lua` 里 `dry_run = true`），打一场。
   日志会打印 `[DRY-RUN] 本该返还 X 杀气（原因）`，但不动你的数值。
4. 对着日志核对三条：架势是否被正确识别为「开始/结束」、反制是否被计数、返还数值是否合理。
   都对得上，再 `pbzkg dryrun` 关掉 dry-run，正式生效。

**快捷键**

| 键 | 作用 |
|---|---|
| **F1** | 杀气返还开 / 关，按下时屏幕提示「杀气返还：开启 / 关闭」 |
| **F2** | 瞬时反制开 / 关，按下时屏幕提示「瞬时反制：开启 / 关闭」 |
| F7 | 只把完整诊断写进日志（不弹任何界面） |
| F9 | 紧急停止：立刻停写，不影响游戏本身；再按一次解除 |

按键提示用引擎的 `PrintString` 画在屏幕左上角，持续 2 秒；如果你的构建不认这条调用，
同样的文字会写进 `UE4SS.log`（搜 `杀气返还：` / `瞬时反制：`），键位功能不受影响。

**控制台命令**（`pbzkg`）

```
pbzkg status      打印状态
pbzkg on/off      杀气返还开/关
pbzkg auto on/off 瞬时反制开/关
pbzkg dryrun      dry-run 切换
pbzkg panic       紧急停止切换
pbzkg probe        深度探测：列出判定帧组件/输入动作/武器/背包的真实名字
pbzkg reload      重读 config.lua（检测口径的改动需重启游戏）
```

---

## 五、配置（`Scripts/config.lua`）

改完保存，重启游戏（或控制台 `pbzkg reload`，但检测口径类改动仍需重启）。

| 配置 | 默认 | 说明 |
|---|---|---|
| `refund.normal_pct` | `0.35` | 普通反制返还比例 |
| `refund.black_blue_fill_max` | `true` | 黑光/蓝光反制成功：直接把杀气恢复满（100%） |
| `refund.black_blue_pct` | `1.00` | 黑光/蓝光补足目标（1.0 = 100%） |
| `refund.unsuccessful_pct` | `0.50` | 未成功反制返还比例（失败+空放统一） |
| `refund.normal_once_per_stance` | `true` | 普通 35% 每周期只返一次 |
| `refund.cap_at_base` | `true` | 每周期累计不超过本次消耗的 100% |
| `refund.base_mode` | `"drain"` | `drain`=本次架势实际消耗（推荐）；`upfront`=只算起手瞬间消耗 |
| `refund.max_stance_seconds` | `8.0` | 单周期最长时长，超时强制结算，防止基数滚太大 |
| `refund.dry_run` | `false` | 只记录不写 |
| `refund.min_write` | `0.5` | 小于该值不写，避免抖动 |
| `instant_counter.enabled` | `true` | 瞬时反制总开关 |
| `instant_counter.trigger_frames` | `0` | 判定帧出现后等几帧才按键；0/1 = 出现即按，2 = 等第 2 帧 |
| `instant_counter.lead` | `0.05` | 命中前多少秒起架（0.05≈判定一出现就打出去） |
| `instant_counter.hold_extra` | `0.18` | 命中后继续按住架招的时长 |
| `instant_counter.shachi_min_pct` | `37` | 杀气低于该百分比不硬放 |
| `instant_counter.cooldown` | `0.6` | 两次自动起架最短间隔 |
| `detect.success_signal` | `"frame"` | 反制成功信号：`frame`（判定帧消失）/ `montage`（出现反制动画） |
| `detect.unknown_type` | `"skip"` | 读不到攻击类型的帧不计数（改成 `normal` 会放宽） |

---

## 六、版本修复记录（v1.0 → v1.2）

v1.0 在真实游戏里跑出过三个问题（日志可查）：`DeflectComponent: 未找到`、重击动作名全缺、
`当前武器: nil`，另外多个架势周期「基数 0.00」。v1.1 针对性处理：

| 问题 | v1.1 的处理 |
|---|---|
| 判定帧组件读不到 | 三种查找方式逐级兜底：属性名 → `FindAllOf('DeflectComponent')` 按 Outer/Owner 地址对齐玩家 → 单人唯一实例 |
| 武器识别 nil | 背包子系统之外，再扫「挂在玩家身上的 `BP_Weapon_*DualHook*` 武器 Actor」 |
| 重击动作名缺失 | 候选名都失败时，扫描全部 `InputAction` 按关键词（`AttackH` / `AttackHeavy` / `HeavyAttack`）匹配 |
| 起手那一口消耗没算进去 | 进架势时用「上一帧煞气 − 本帧煞气」补记（上限 `seed_cap=500`，防复活/换人误算） |
| 不知道真实符号叫什么 | 新增 `pbzkg probe`，一次性把组件/动作/武器/背包的真实名字写进日志 |
| **消耗在架势结束后才扣，返还几乎为 0**（v1.2 修复） | 架势标签消失后不再立刻结算，而是继续观察 `tail_seconds`（默认 4 秒）内的煞气下降，把延迟扣掉的那一口算进本周期 |
| 想要随手开关 | **F1 杀气返还**、**F2 瞬时反制**，按下时屏幕提示当前状态；F9 紧急停止 |

新装或升级都只要重跑一次 `install.bat`（旧版会自动备份成 `PBZBiLiCanGou.bak-时间戳`，
备份里的 `enabled.txt` 已改名，不会在 mod 菜单里多出一条）。

## 七、已知边界（请务必看这一段）

这个 mod 是在**没有官方 mod API**的前提下，用社区 mod 已验证的运行时符号做的。
下面几条是「设计上的取舍」，不是 bug，但决定了它能不能在你的机器上完全达到预期：

1. **尾部观察窗会把「结束后 4 秒内的任何煞气下降」都算进本周期。**
   这是为了抓住延迟扣除的架势消耗（日志实测：806.8 起手、标签 0.5 秒就灭、几秒后才掉 236）。
   如果你在架势刚结束的 4 秒里刚好放了另一个耗气技能，那部分也会被算进去；把 `refund.tail_seconds` 调小
   （例如 2.0）或多个周期分开记录就能规避。

2. **「成功反制」是推断，不是官方事件。**
   默认用「架势期间该判定帧从 `ReceiveFrames` 消失」来推断这一下被反制了。
   v1.1 起，判定帧组件会依次尝试「角色属性 `DeflectComponent` → 按类遍历 `FindAllOf('DeflectComponent')` 并用
   Outer/Owner 地址对齐玩家 → 单人场景唯一实例」，比 v1.0 只认属性名稳得多。
   这在绝大多数情况成立（架势会把来袭招式格挡并顺势反制），但理论上「敌人自己收招导致帧消失」
   会被误算成一次反制。缓解办法：
   - 按 F7 看每次判定与反制的日志是否对得上；
   - 若发现误判，把 `detect.success_signal` 改成 `"montage"`，用「出现反制动画」作为成功信号
     （更严格，但需要动画名里确实带 `Counter`/`CanGou` 之类的关键词，可在 `montage_keywords` 里补）。
3. **「瞬时反制」是自动按键，不是改判定窗口本身。**
   真正改「架势判定窗口的起始帧」需要改蓝图/动画资源，Lua 层做不到。本 mod 的做法是
   判定帧一出现就把架势举起来（`instant_counter.trigger_frames` 可改，2 = 等第 2 帧再出手）——实际效果就是你要的「瞬时反制」，但它会替你按键。
   如果你只想手动打、只想要杀气返还，把 `instant_counter.enabled` 设 `false`。
4. **按键动作名可能随游戏版本变。v1.1 起会先按候选名找，找不到再扫全部 `InputAction` 按关键词匹配（`AttackH` / `Stance` 等）。**
   用到的动作名：`IA_Stance` / `IA_Deflect` / `IA_AttackH_Press` 等。改名后日志会明确打印
   「找不到格挡动作 / 找不到重击动作」，此时按 F7 的日志把实际动作名补进 `config.lua` 的
   `instant_counter.actions` 即可。
5. **写杀气是直接改属性。**
   写入后会读回校验，读回对不上就记一次失败；**连续 5 次失败会自动停写**（不会反复污染你的数值），
   按 F8 或 `pbzkg on` 可重开。HUD 可能在返还瞬间有一次小跳变，属正常。
6. **和「自动防御 / 自动格挡」类 mod 会抢按键。**
   本 mod 与非反制类自动防御同时开，可能出现互相打断架势。建议：
   - 只留一个负责按键；
   - 或在对方 mod 里把「别离残钩反制」相关选项关掉。
7. **游戏更新后**：先确认 UE4SS 还能加载（日志里要有 `GUObjectArray address`），
   UE4SS 失效时本 mod 自然不工作，等新适配包。

---

## 八、符号来源与致谢

本 mod 用到的运行时符号（属性集 `BasicAttributeSet.Shachi`、`PBZBackPackSubsystem`、
`Ability.Action.Stance`、`PBZDeflectSystem.DeflectComponent`、EnhancedInput 注入、
`/Script/ProjectPBZ.*`）均来自本游戏社区已公开的其他 UE4SS Lua mod 的实践：

- **Auto Perfect Defense**（Nexus `phantombladezero/mods/389`）——别离残钩反制的按键方式
  （按住格挡 + 三角形）、37% 杀气门槛、`BasicAttributeSet.Shachi` 读取。
- **PBZPerfectFlow**（3DM 论坛）——完美格挡窗口由时间戳接管、杀气分档保护的思路。
- **phantom-blade-zero-free-parkour**（GitHub 开源）——UE4SS 模块加载方式、`RegisterHook` 写法、
  `/Script/ProjectPBZ.*` 路径形式。
- **PBZ UE4SS**（Nexus `phantombladezero/mods/14`）——本游戏专用 UE4SS 与 Mods 目录约定。

规则引擎、架势状态机、瞬时反制模块、诊断与测试为本次新写；未复制上述 mod 的代码。

---

## 九、目录与卸载

```
install.bat            一键安装（你指定游戏根目录，脚本负责校验/备份/改 mods.txt）
check.bat              一键体检（沿用上次的目录，逐项报告安装状态）
uninstall.bat          一键卸载（删目录、清 mods.txt 记录）
.pbz_game_path         记录上次使用的游戏目录（删掉就重新问一次）
tools\PBZModSetup.ps1  三个 bat 的实际实现（PowerShell）
PBZBiLiCanGou\
├─ enabled.txt
└─ Scripts\
   ├─ main.lua        入口：装配、热键、控制台命令、主循环
   ├─ config.lua      全部可调参数
   ├─ rules.lua       纯规则引擎（35% / 50% / 100% 补足 / 上限）
   ├─ stance.lua      架势周期状态机（纯逻辑，可单测）
   ├─ autocounter.lua 瞬时反制决策（纯逻辑，可单测）
   ├─ gameapi.lua     唯一碰游戏的一层
   └─ log.lua         日志
tests\
└─ run_tests.lua      68 项脱机单测
```

**卸载**：双击 `uninstall.bat`，或手动删掉 `ue4ss\Mods\PBZBiLiCanGou` 整个文件夹（不写存档、不改游戏文件）。
日志文件 `PBZBiLiCanGou.log` 同在 mod 目录内，一并删除。

---

## 十、单测

`tests/run_tests.lua` 是纯 Lua 的脱机测试（不需要游戏），覆盖：

- 35% / 50% / 100% 补足 / 每周期一次 / 100% 上限 / 小数基数 / 坏配置回落；
- 架势进入、消耗累计（含「自己返还的上升不能被当成消耗」）、判定帧消失=反制、
  红光不反制、超时结算、动画信号；
- 瞬时反制的起架条件、煞气门槛、武器门槛、在架势中不动手、扫描窗口、冷却。

运行：

```
lua tests/run_tests.lua
```

当前结果：**通过 58，失败 0**。
