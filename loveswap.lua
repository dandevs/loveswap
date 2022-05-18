local realcache = {}
local hotcache = {}
local ignoreKeysMap = {}
local trueRequire = _G.require
local filewatcher = trueRequire("filewatcher")()
local errorState = nil
local inError = false
local errorCapturer
local varCache = {}

local loveswap = {
    internal = {
        realcache = realcache,
        hotcache = hotcache,
        filewatcher = filewatcher,
    },

    enabled = true,
    initRun = true,
}

local loveFuncNames = {
    update = true,
    load = true,
    draw = true,
    mousepressed = true,
    mousereleased = true,
    keyreleased = true,
    keypressed = true,
    focus = true,
    quit = true,
}

local function getModnameFromFile(file)
    return string.gsub(string.sub(file.path, 1, -5), "[/]", ".")
end

local function getFilepathFromModname(modname)
    return string.gsub(modname, "[.]", "/") .. ".lua"
end

local function pairCount(tbl)
    local count = 0
    for _, _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

local function firstValueInPair(tbl)
    for _, v in pairs(tbl) do
        return v
    end
end

local function tableContains(tbl, value)
    for _, v in pairs(tbl) do
        if v == value then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------------------------


local function onLoveFuncError(err)
    errorCapturer.capture(err, debug.traceback(), "main")
end

local function swapProtectLoveFuncs()
    for k, fn in pairs(love) do
        if loveFuncNames[k] then
            local _fn = fn

            love[k] = function(...)
                local ok, result = xpcall(_fn, onLoveFuncError, ...)
                
                if ok then 
                    return result 
                end
            end
        end
    end
end

local function updateHotModule(modname, ignoreKeys)
    package.loaded[modname] = nil
    ignoreKeys = ignoreKeys or ignoreKeysMap[modname]
    ignoreKeysMap[modname] = ignoreKeys
    local module

    local ok = xpcall(function()
        module = trueRequire(modname)
    end, function(err)
        errorCapturer.capture(err, debug.traceback(), modname)
    end)

    if not ok then
        return
    end

    realcache[modname] = module

    if type(module) ~= type(hotcache[modname]) then
        hotcache[modname] = nil
    end

    if type(module) == "table" and hotcache[modname] == nil then
        hotcache[modname] = {}

        if ignoreKeys then 
            for _, k in ipairs(ignoreKeys) do
            hotcache[modname][k] = realcache[modname][k]
            end
        end
    end

    if type(module) == "table" and type(hotcache[modname]) == "table" then
        for k, v in pairs(module) do
            if (not ignoreKeys) or (ignoreKeys and not tableContains(ignoreKeys, k)) then
                -- retain equality for func == func
                if type(v) == "function" and type(hotcache[modname][k]) ~= "function" then
                    local _m = modname
                    local _k = k
    
                    hotcache[_m][_k] = function(...)
                        return realcache[_m][_k](...)
                    end
                else
                    hotcache[modname][k] = v
                end
            end
        end

        setmetatable(hotcache[modname], getmetatable(module))
    end
    
    if type(module) == "function" then
        if not hotcache[modname] or type(hotcache[modname]) ~= "function" then
            hotcache[modname] = function(...)
                return realcache[modname](...)
            end
        end
    end

    if modname == "main" then
        swapProtectLoveFuncs()
    end

    return hotcache[modname]
end

local function hotRequire(modname, ignoreKeys)
    if loveswap.enabled == false or string.match(modname, "loveswap") then
        return trueRequire(modname)
    end

    local filepath = getFilepathFromModname(modname)
    local fileinfo = love.filesystem.getInfo(filepath)
    if not fileinfo then error("no file:", filepath) end

    local module = hotcache[modname]

    if module == nil then
        filewatcher.addFile(filepath)
        return updateHotModule(modname, ignoreKeys)
    else
        return module
    end

    return trueRequire(modname)
end

------------------------------------------------------------------------------------------

local function createErrorCapturer()
    local this = { errors = {} }
    local errors = this.errors
    local prevLoveFuncs = {}
    local inErrorState = false
    local isRuntimeError = false
    
    function this.onFileChanged(file)
        local modname = getModnameFromFile(file)

        local ok = xpcall(updateHotModule, function(err)
            for _, e in ipairs(errors) do
                if e.modname == modname then
                    e.err = err
                    e.stackTrace = debug.traceback()
                    print(e.err)
                    print(e.stackTrace)
                    break
                end
            end
        end, modname)

        if ok then
            if modname == "main" then
                prevLoveFuncs.update = love.update
                prevLoveFuncs.draw = love.draw
                love.update = this.updateErrors
                love.draw = this.drawErrors
            end

            for i, e in ipairs(errors) do
                if e.modname == modname then
                    table.remove(errors, i)
                    this.errorCountChanged()
                    break
                end
            end

            if modname ~= "main" and #errors == 1 then
                errors[1] = nil
                this.errorCountChanged()
            end
        end
    end

    function this.updateErrors()
        filewatcher.update(this.onFileChanged)
    end

    function this.drawErrors()
        local e = errors[#errors]
        if not e then return end
        
        love.graphics.setColor(255, 255, 255)
        love.graphics.print("(" .. e.modname .. ") " .. (e.err or "error"), 80, 80)
        love.graphics.print(e.stackTrace or "no stack trace", 80, 100)
    end

    function this.restorePrevLoveFuncs()
        for k, _ in pairs(loveFuncNames) do love[k] = nil end
        for k, fn in pairs(prevLoveFuncs) do love[k] = fn end
        prevLoveFuncs = {}
    end

    function this.onErrorStateEnter()
        prevLoveFuncs = {}
        for k, _ in pairs(loveFuncNames) do prevLoveFuncs[k] = love[k]; love[k] = nil end
        love.update = this.updateErrors
        love.draw = this.drawErrors
    end

    function this.onErrrorStateExit()
        this.restorePrevLoveFuncs()
    end

    function this.errorCountChanged()
        if not inErrorState and #errors > 0 then
            inErrorState = true
            this.onErrorStateEnter()

        elseif inErrorState and #errors == 0 then
            inErrorState = false
            this.onErrrorStateExit()
        end
    end

    function this.capture(err, stackTrace, modname)
        print(err)
        print(stackTrace)

        local e = {
            err        = err,
            stackTrace = stackTrace,
            modname    = modname,
        }

        table.insert(errors, e)
        this.errorCountChanged()
    end

    return this
end

errorCapturer = createErrorCapturer()

--------------------------------------------------------------------------------------------

local function onFileChanged(file)
    local modname = getModnameFromFile(file)
    updateHotModule(modname)
end

filewatcher.addFile("main.lua")
loveswap.require = hotRequire

function loveswap.update()
    if loveswap.initRun == true then
        loveswap.initRun = false
        swapProtectLoveFuncs()

        if loveswap.firstRun ~= nil then
            loveswap.firstRun()
        end
    else
        filewatcher.update(onFileChanged)
    end
end

---@generic T
---@param name string
---@param seed T
---@return T
function loveswap.cached(name, seed)
    local value = varCache[name]

    if value == nil then
        value = seed
        varCache[name] = value
    end

    return value
end

return loveswap