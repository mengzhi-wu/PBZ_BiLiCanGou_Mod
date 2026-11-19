-- log.lua —— 日志：控制台(UE4SS.log) + mod 目录里一份自留档
local M = {}

local prefix = "[PBZBiLiCanGou]"
local verbose = true
local handle = nil
local dirPath = nil
local lines = 0
local MAX_LINES = 20000 -- 单场游戏最多写这么多行，防止文件无限长大

function M.init(mod_dir, is_verbose, to_file)
    dirPath = mod_dir
    verbose = is_verbose ~= false
    if to_file then
        local ok, f = pcall(io.open, mod_dir .. "PBZBiLiCanGou.log", "a")
        if ok and f then
            handle = f
            pcall(function()
                f:write(string.format("\n===== %s 启动 =====\n", os.date("%Y-%m-%d %H:%M:%S")))
                f:flush()
            end)
        else
            handle = nil
        end
    end
    return M
end

local function writeLine(msg)
    print(prefix .. " " .. msg .. "\n")
    if handle and lines < MAX_LINES then
        lines = lines + 1
        pcall(function()
            handle:write(os.date("%H:%M:%S ") .. msg .. "\n")
            handle:flush()
        end)
    end
end

function M.log(fmt, ...)
    if select("#", ...) > 0 then
        local ok, msg = pcall(string.format, fmt, ...)
        writeLine(ok and msg or tostring(fmt))
    else
        writeLine(tostring(fmt))
    end
end

-- 只在 verbose 打开时输出，用于逐帧细节
function M.detail(fmt, ...)
    if not verbose then return end
    M.log(fmt, ...)
end

function M.warn(fmt, ...)
    if select("#", ...) > 0 then
        local ok, msg = pcall(string.format, fmt, ...)
        writeLine("[警告] " .. (ok and msg or tostring(fmt)))
    else
        writeLine("[警告] " .. tostring(fmt))
    end
end

function M.file()
    return handle
end

function M.dir()
    return dirPath
end

return M
