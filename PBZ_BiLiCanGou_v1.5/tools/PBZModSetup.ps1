param(
    [Parameter(Position = 0)]
    [Alias('GamePath')]
    [string]$GameRoot = '',
    [switch]$Uninstall,
    [switch]$Verify,
    [switch]$Force,
    [switch]$PurgeBackups
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ModName = 'PBZBiLiCanGou'
$ModVersion = '1.5'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $ScriptDir
$SourceDir = Join-Path $PackageDir $ModName
$LastPathFile = Join-Path $PackageDir '.pbz_game_path'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

function Join-Sub([string]$base, [string]$rel) {
    $p = $base
    foreach ($seg in ($rel -split '[\\/]')) {
        if ($seg) { $p = Join-Path $p $seg }
    }
    return $p
}

function Write-Head($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "  [ !] $t" -ForegroundColor Yellow }
function Write-Bad($t)  { Write-Host "  [ X] $t" -ForegroundColor Red }

function Confirm([string]$msg) {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        $ans = Read-Host "      $msg"
        return ($ans -match '^[Yy]')
    } catch { return $false }
}

function Read-Answer([string]$msg) {
    try {
        if ([Console]::IsInputRedirected) { return $null }
        return (Read-Host "      $msg")
    } catch { return $null }
}

# ---------------------------------------------------------------- 路径处理
function Clean-Path([string]$p) {
    if (-not $p) { return '' }
    $p = $p.Trim()
    $p = $p.Trim('"').Trim("'")
    if ($p.StartsWith('& ')) { $p = $p.Substring(2) }
    $p = $p -replace '\\\\', '\'
    $p = $p.TrimEnd('\').TrimEnd('/')
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
    return $p
}

# 从玩家给的任意层级路径里找出 PBZ.exe 所在目录（ue4ss 就在这里）
function Get-ExeDir([string]$root) {
    $p = Clean-Path $root
    if (-not $p -or -not (Test-Path $p)) { return '' }

    if (Test-Path (Join-Sub $p 'PBZ.exe')) { return $p }
    $c2 = Join-Sub $p 'platform\steam'
    if (Test-Path (Join-Sub $c2 'PBZ.exe')) { return $c2 }

    # 玩家可能直接选了 ue4ss / Mods / platform 这一层
    $leaf = Split-Path $p -Leaf
    if ($leaf -eq 'Mods') { $p = Split-Path (Split-Path $p -Parent) -Parent }
    elseif ($leaf -eq 'ue4ss') { $p = Split-Path $p -Parent }
    if (Test-Path (Join-Sub $p 'PBZ.exe')) { return $p }
    $c3 = Join-Sub $p 'platform\steam'
    if (Test-Path (Join-Sub $c3 'PBZ.exe')) { return $c3 }

    # 最后在下面两层里找
    $hit = Get-ChildItem -Path $p -Filter 'PBZ.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { return $hit.DirectoryName }
    return ''
}

function Read-LastPath {
    if (Test-Path $LastPathFile) {
        try {
            $v = (Get-Content $LastPathFile -Raw).Trim()
            if ($v) { return $v }
        } catch { }
    }
    return ''
}

function Save-LastPath([string]$exeDir) {
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($LastPathFile, $exeDir, $enc)
    } catch { }
}

function Pick-Folder {
    if (-not $IsWin) { return '' }
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '请选择《影之刃零》的游戏根目录（例如 ...\steamapps\common\PBZ）'
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    } catch { }
    return ''
}

# ---------------------------------------------------------------- 取得游戏目录
function Resolve-GameRoot {
    Write-Head '指定游戏目录'

    if ($GameRoot) {
        $exe = Get-ExeDir $GameRoot
        if ($exe) {
            Write-Ok "找到 PBZ.exe：$(Join-Sub $exe 'PBZ.exe')"
            Save-LastPath $exe
            return $exe
        }
        Write-Bad "这个路径里没找到 PBZ.exe：$GameRoot"
        Write-Host '      应该是游戏的安装根目录，例如：D:\SteamLibrary\steamapps\common\PBZ' -ForegroundColor Gray
        return ''
    }

    $last = Read-LastPath
    if ($last -and (Test-Path (Join-Sub $last 'PBZ.exe'))) {
        if ($Force -or $Uninstall -or [Console]::IsInputRedirected) {
            Write-Ok "沿用上次的目录：$last"
            return $last
        }
        Write-Host "      上次用的游戏目录：$last" -ForegroundColor Gray
        if (Confirm '直接用这个？(Y/N)') {
            Write-Ok "使用：$last"
            return $last
        }
    }

    for ($i = 1; $i -le 3; $i++) {
        Write-Host '      请把《影之刃零》的游戏根目录拖到这个窗口后回车（例如 D:\SteamLibrary\steamapps\common\PBZ）' -ForegroundColor Gray
        Write-Host '      直接回车会打开文件夹选择框；输入 Q 退出' -ForegroundColor Gray
        $ans = Read-Answer '游戏根目录：'
        if ($null -eq $ans) { break }

        if ($ans -match '^[Qq]$') { return '' }

        if (-not $ans.Trim()) {
            $picked = Pick-Folder
            if (-not $picked) {
                Write-Warn2 '没有选择文件夹'
                continue
            }
            $ans = $picked
        }

        $exe = Get-ExeDir $ans
        if ($exe) {
            Write-Ok "找到 PBZ.exe：$(Join-Sub $exe 'PBZ.exe')"
            Save-LastPath $exe
            return $exe
        }
        Write-Bad "这里没找到 PBZ.exe：$ans"
        Write-Host '      如果游戏装在 Steam 里，通常是 ...\steamapps\common\PBZ' -ForegroundColor Gray
    }
    return ''
}

# ---------------------------------------------------------------- mods.txt
function Read-TextFile([string]$path) { return [System.IO.File]::ReadAllText($path) }

function Write-TextFile([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Get-LineStatus([string]$text) {
    $esc = [regex]::Escape($ModName)
    if ($text -match "(?m)^\s*$esc\s*:\s*1\s*$") { return 'on' }
    if ($text -match "(?m)^\s*$esc\s*:") { return 'off' }
    return 'none'
}

function Enable-InModsTxt([string]$modsTxt) {
    if (-not (Test-Path $modsTxt)) {
        Write-Warn2 '没有找到 mods.txt（部分 UE4SS 版本不需要它，可忽略）'
        return $true
    }
    $text = Read-TextFile $modsTxt
    if ((Get-LineStatus $text) -eq 'on') {
        Write-Ok 'mods.txt 里已是 PBZBiLiCanGou : 1，无需修改'
        return $true
    }

    Copy-Item $modsTxt "$modsTxt.bak-$Stamp" -Force
    $esc = [regex]::Escape($ModName)
    $lines = $text -split "\r?\n"
    $found = $false
    $out = @()
    foreach ($ln in $lines) {
        if ($ln -match "^\s*$esc\s*:") {
            $found = $true
            $out += "$ModName : 1"
        } else {
            $out += $ln
        }
    }
    if (-not $found) {
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out = $out[0..($out.Count - 2)] }
        $out += "$ModName : 1"
        if ($text.EndsWith("`n")) { $out += '' }
    }
    Write-TextFile $modsTxt ($out -join "`r`n")
    Write-Ok 'mods.txt 已启用 PBZBiLiCanGou : 1（原文件已备份）'
    return $true
}

function Disable-InModsTxt([string]$modsTxt) {
    if (-not (Test-Path $modsTxt)) { return $true }
    $text = Read-TextFile $modsTxt
    $esc = [regex]::Escape($ModName)
    if ($text -notmatch "(?m)^\s*$esc\s*:") {
        Write-Ok 'mods.txt 里本来就没有本 mod 的记录'
        return $true
    }
    Copy-Item $modsTxt "$modsTxt.bak-$Stamp" -Force
    $lines = $text -split "\r?\n"
    $out = @()
    foreach ($ln in $lines) {
        if ($ln -match "^\s*$esc\s*:") { continue }
        $out += $ln
    }
    Write-TextFile $modsTxt ($out -join "`r`n")
    Write-Ok 'mods.txt 里的本 mod 记录已移除（原文件已备份）'
    return $true
}

function Get-InstalledVersion([string]$target) {
    $vf = Join-Path $target 'VERSION.txt'
    if (Test-Path $vf) {
        try { return (Get-Content -Path $vf -TotalCount 1).Trim() } catch { return $null }
    }
    return $null
}

# 老版本备份目录里若还留着 enabled.txt，PBZModsMenuBridge 之类会把备份当成第二个 mod 索引到；
# 这里统一改名成 enabled.txt.bak（不删数据），让备份彻底退出加载列表。
function Repair-LegacyBackups([string]$modsDir) {
    if (-not (Test-Path $modsDir)) { return 0 }
    $fixed = 0
    Get-ChildItem -Path $modsDir -Directory -Filter "$ModName.bak-*" -ErrorAction SilentlyContinue | ForEach-Object {
        $e = Join-Path $_.FullName 'enabled.txt'
        if (Test-Path $e) {
            try { Rename-Item -Path $e -NewName 'enabled.txt.bak' -ErrorAction Stop; $fixed++ } catch { }
        }
    }
    return $fixed
}

function Test-GameRunning {
    if (-not $IsWin) { return $false }
    foreach ($n in @('PBZ', 'PBZ-Win64-Shipping')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- 安装
function Invoke-Install {
    Write-Head "影之刃零「别离残钩」Mod —— 安装（v$ModVersion）"

    if (-not (Test-Path $SourceDir)) {
        Write-Bad "找不到要安装的文件：$SourceDir"
        Write-Host '      请确认压缩包已完整解压（不要在压缩软件预览窗口里直接运行）' -ForegroundColor Gray
        return 1
    }

    if (Test-GameRunning) {
        Write-Bad '检测到游戏正在运行，请先完全退出游戏再安装'
        return 1
    }

    $game = Resolve-GameRoot
    if (-not $game) { Write-Warn2 '已取消安装'; return 1 }

    $ue4ss = Join-Sub $game 'ue4ss'
    $modsDir = Join-Sub $ue4ss 'Mods'

    Write-Head '检查前置（UE4SS）'
    if (-not (Test-Path $ue4ss)) {
        Write-Bad "没有找到 $ue4ss"
        Write-Host '      需要先装本游戏专用的 UE4SS（Nexus: phantombladezero/mods/14），' -ForegroundColor Gray
        Write-Host "      解压到：$game" -ForegroundColor Gray
        if (-not $Force) {
            if (-not (Confirm '仍然要把 mod 文件放进去吗？(Y/N)')) {
                Write-Warn2 '已取消安装'
                return 1
            }
        }
    } else {
        Write-Ok "UE4SS 目录：$ue4ss"
    }

    $target = Join-Path $modsDir $ModName

    Write-Head "安装到 $modsDir"
    if (-not (Test-Path $modsDir)) { New-Item -ItemType Directory -Path $modsDir -Force | Out-Null }

    if (Test-Path $target) {
        $bak = "$target.bak-$Stamp"
        Move-Item -Path $target -Destination $bak -Force
        # 备份里的 enabled.txt 改名，避免 UE4SS / 菜单桥把它当成一个还在启用的 mod
        $bakEnabled = Join-Path $bak 'enabled.txt'
        if (Test-Path $bakEnabled) { Rename-Item -Path $bakEnabled -NewName 'enabled.txt.bak' -ErrorAction SilentlyContinue }
        Write-Ok "旧版本已备份为 $(Split-Path $bak -Leaf)（里面的 enabled.txt 已改名，不会重复加载）"
    }

    Copy-Item -Path $SourceDir -Destination $modsDir -Recurse -Force
    Write-Ok '文件已复制'

    $enabled = Join-Path $target 'enabled.txt'
    if (-not (Test-Path $enabled)) { New-Item -ItemType File -Path $enabled | Out-Null }
    Write-Ok 'enabled.txt 已就绪'

    Enable-InModsTxt (Join-Path $modsDir 'mods.txt') | Out-Null

    $backups = Repair-LegacyBackups $modsDir
    if ($backups -gt 0) { Write-Ok "旧的 .bak 备份里有 $backups 个 enabled.txt 已改名，不会被当成第二个 mod 加载" }

    Write-Head '安装完成'
    Write-Host "  位置：$target" -ForegroundColor Gray
    Write-Host "  版本：v$(Get-InstalledVersion $target)" -ForegroundColor Gray
    Write-Host '  下一步：'
    Write-Host '    1) 启动游戏，进到主菜单'
    Write-Host '    2) 按 F7 把接口诊断写进日志，确认「属性集 / DeflectComponent / 输入动作」都是已找到'
    Write-Host '    3) 控制台输入 pbzkg probe，把真实符号名（组件/动作/武器/背包）写进日志'
    Write-Host '       哪项显示未找到/缺失/nil，就把 probe 那段发给作者'
    Write-Host '    4) 控制台输入 pbzkg dryrun 打一场，核对日志里的返还数值'
    Write-Host '    5) 再输一次 pbzkg dryrun 关掉，正式生效'
    Write-Host ''
    Write-Host '  热键：F1 杀气返还开关 | F2 瞬时反制开关 | F7 状态写日志 | F9 紧急停止' -ForegroundColor Gray
    Write-Host '  卸载：运行 uninstall.bat（会记住这次的游戏目录）' -ForegroundColor Gray
    return 0
}

# ---------------------------------------------------------------- 卸载
function Invoke-Uninstall {
    Write-Head '影之刃零「别离残钩」Mod —— 卸载' 

    if (Test-GameRunning) {
        Write-Bad '检测到游戏正在运行，请先完全退出游戏再卸载'
        return 1
    }

    $game = Resolve-GameRoot
    if (-not $game) { Write-Warn2 '已取消卸载'; return 1 }

    $modsDir = Join-Sub $game 'ue4ss\Mods'
    $target = Join-Path $modsDir $ModName
    $cur = Get-InstalledVersion $target
    if ($cur) { Write-Ok "当前安装版本：v$cur" } else { Write-Warn2 '读不到 VERSION.txt（可能是旧版安装，按未知版本处理）' }

    if (-not (Test-Path $target)) {
        Write-Warn2 "没有找到已安装的 mod：$target"
        $modsTxt = Join-Path $modsDir 'mods.txt'
        if (Test-Path $modsTxt) { Disable-InModsTxt $modsTxt | Out-Null }
        Write-Ok '无需卸载'
        return 0
    }

    if (-not $Force) {
        if (-not (Confirm "确认删除 $target ？（Y/N）")) {
            Write-Warn2 '已取消卸载'
            return 1
        }
    }

    try {
        Remove-Item -Path $target -Recurse -Force
        Write-Ok 'mod 目录已删除（含日志）'
    } catch {
        Write-Bad "删除失败：$($_.Exception.Message)"
        Write-Host '      如果有文件被占用，请关闭游戏 / 杀毒软件后重试' -ForegroundColor Gray
        return 1
    }

    Disable-InModsTxt (Join-Path $modsDir 'mods.txt') | Out-Null

    $backups = Repair-LegacyBackups $modsDir
    if ($backups -gt 0) { Write-Ok "旧备份里的 $backups 个 enabled.txt 已改名，不会再被索引成第二个 mod" }

    if ($PurgeBackups) {
        $baks = @(Get-ChildItem -Path $modsDir -Directory -Filter "$ModName.bak-*" -ErrorAction SilentlyContinue)
        if ($baks.Count -gt 0) {
            if ($Force -or (Confirm "连 $($baks.Count) 个 .bak- 备份一起删除？（Y/N）")) {
                $baks | ForEach-Object { Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Ok "备份目录已删除（$($baks.Count) 个）"
            } else {
                Write-Warn2 '保留了备份目录'
            }
        } else {
            Write-Ok '没有需要清理的备份目录'
        }
    }

    Write-Head '卸载完成'
    Write-Host '  游戏本体与存档未做任何改动；想恢复旧版本可把 .bak- 备份目录改回原名' -ForegroundColor Gray
    Write-Host '  想把备份也清掉：uninstall.bat -PurgeBackups' -ForegroundColor Gray
    return 0
}

# ---------------------------------------------------------------- 体检
function Invoke-Verify {
    Write-Head '安装状态检查'

    if (Test-Path $SourceDir) { Write-Ok "安装包完整：$SourceDir" }
    else { Write-Bad "安装包不完整，找不到 $SourceDir" }

    $game = Resolve-GameRoot
    if (-not $game) { return 1 }

    $ue4ss = Join-Sub $game 'ue4ss'
    if (Test-Path $ue4ss) { Write-Ok "UE4SS：$ue4ss" } else { Write-Bad "缺少 UE4SS：$ue4ss" }

    $modsDir = Join-Sub $ue4ss 'Mods'
    $target = Join-Path $modsDir $ModName
    if (Test-Path $target) { Write-Ok "mod 已安装：$target" } else { Write-Bad "mod 未安装：$target" }

    $scripts = Join-Path $target 'Scripts'
    if (Test-Path $scripts) {
        $n = @(Get-ChildItem -Path $scripts -Filter '*.lua').Count
        if ($n -ge 7) { Write-Ok "脚本文件齐全（$n 个 .lua）" }
        else { Write-Warn2 "脚本数量偏少（$n 个，应为 7）" }
    }

    $cur = Get-InstalledVersion $target
    if ($cur) {
        if ($cur -eq $ModVersion) { Write-Ok "已安装版本：v$cur（与安装包一致）" }
        else { Write-Warn2 "已安装版本：v$cur（安装包是 v$ModVersion，可用 install.bat 覆盖更新）" }
    } else {
        Write-Warn2 '读不到 VERSION.txt（旧版安装）'
    }

    if (Test-Path (Join-Path $target 'enabled.txt')) { Write-Ok 'enabled.txt 存在' }
    else { Write-Warn2 'enabled.txt 缺失（会被 UE4SS 视为未启用）' }

    $modsTxt = Join-Path $modsDir 'mods.txt'
    if (Test-Path $modsTxt) {
        $st = Get-LineStatus (Read-TextFile $modsTxt)
        if ($st -eq 'on') { Write-Ok 'mods.txt：PBZBiLiCanGou : 1' }
        elseif ($st -eq 'off') { Write-Warn2 'mods.txt 里是关闭状态（0），改成 1 或重新运行 install.bat' }
        else { Write-Warn2 'mods.txt 里没有本 mod 的记录（部分 UE4SS 版本不需要，可忽略）' }
    }

    $log = Join-Path $target "$ModName.log"
    if (Test-Path $log) {
        $len = (Get-Item $log).Length
        Write-Ok ("日志存在（{0} 字节）：{1}" -f $len, $log)
        Write-Host '      最后 6 行：' -ForegroundColor Gray
        Get-Content $log -Tail 6 | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }
    } else {
        Write-Warn2 '还没有日志 —— 说明游戏还没用这个 mod 跑过一次'
    }
    return 0
}

# ---------------------------------------------------------------- 主流程
if ($Uninstall) { exit (Invoke-Uninstall) }
if ($Verify)    { exit (Invoke-Verify) }
exit (Invoke-Install)
