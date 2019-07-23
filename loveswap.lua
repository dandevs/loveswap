local trueRequire = require
local loveswap    = {}
local filewatcher = (require "lib.loveswap.filewatcher")()
local createHot   = require "lib.loveswap.hot"
local function noop() end

loveswap.global = {}

---------------------------------------------------------

local loveFuncNames = {
  "update",
  "load",
  "draw",
  "mousepressed",
  "mousereleased",
  "keypressed",
  "keyreleased",
  "focus",
  "quit",
}

---------------------------------------------------------

local defaultIgnorePatterns = { "lib[.]loveswap" }

local internal = {
  hots        = {},
  hotStack    = {},
  errors      = {},
  require     = require,
  enabled     = false,
  cache       = cache,
  filewatcher = filewatcher,
  currentHot  = nil,
  state       = "normal",
  firstRun    = true,

  ignoreModulePatterns      = { unpack(defaultIgnorePatterns) },
  currentModulePath         = nil,
  errorTraceStack           = {},
  beforeSwapModuleCallbacks = {},
  afterSwapModuleCallbacks  = {},
  hotLoveFuncs              = {},
}

internal.global = {
  beforeSwapModuleCallback = noop,
  afterSwapModuleCallback  = noop
}

loveswap.internal = internal
filewatcher.addFile("main.lua")

---------------------------------------------------------

filewatcher.onFileChanged(function(file)
  local modulepath = string.gsub(string.sub(file.path, 1, -5), "[/]", ".")
  loveswap.updateModule(modulepath)
end)

---------------------------------------------------------------------------------

function internal.wrapAndUpdateLoveFuncs() -- TODO: Love functions outside main?
  if internal.state == "error" then return end

  local onError = function(err)
    internal.errorTraceStack["main"] = debug.traceback()
    internal.errors["main"] = err
    loveswap.error()
  end

  for i, name in ipairs(loveFuncNames) do
    local loveFunc = love[name]

    if loveFunc then
      local hot = internal.hotLoveFuncs[name] or createHot()

      if loveFunc ~= hot.wrapper then
        print("swapped", name, loveFunc)
        hot.update(function(...) xpcall(loveFunc, onError, ...) end)
      end

      internal.hotLoveFuncs[name] = hot
      love[name] = hot.wrapper
    end
  end
end

function internal.onUpdateMain()
  if internal.state ~= "error" then
    internal.wrapAndUpdateLoveFuncs()
  end
end


---------------------------------------------------------------------------------

function loveswap.setEnabled(enabled) internal.enabled = enabled end
function loveswap.setFileScanInterval(t) internal.filewatcher.setScanInterval(t) end

function loveswap.ignoreModules(patterns)
  loveswap.internal.ignoreModulePatterns = { unpack(defaultIgnorePatterns), unpack(patterns) }
end

function loveswap.getHasErrors()
  for k, v in pairs(internal.errors) do return true end
end

---------------------------------------------------------------------------------

function loveswap.update()
  if not internal.enabled then return end

  if internal.firstRun then
    internal.firstRun = false
    internal.wrapAndUpdateLoveFuncs()
  end

  internal.filewatcher.update()
end

---------------------------------------------------------------------------------

function loveswap.updateModule(modulepath)
  local hotModule, moduleValue = internal.hots[modulepath]
  if not hotModule then
    hotModule = createHot()
    internal.hots[modulepath] = hotModule
  end

  internal.currentModulePath = modulepath
  ;(internal.beforeSwapModuleCallbacks[modulepath] or noop)(modulepath);
  internal.global.beforeSwapModuleCallback(modulepath)

  local loadedBackup = package.loaded[modulepath]
  package.loaded[modulepath] = nil
  internal.currentHot = hotModule

  local ok = xpcall(function()
    moduleValue = trueRequire(modulepath)
  end, function(err)
    internal.errorTraceStack[modulepath] = debug.traceback()
    internal.errors[modulepath] = err
    loveswap.error()
  end)

  if not ok then
    package.loaded[modulepath] = loadedBackup
    internal.currentHot = nil
    internal.currentModulePath = nil
    return hotModule
  end


  internal.errors[modulepath] = nil
  if not loveswap.getHasErrors() then
    internal.state = "normal"
    if modulepath == "main" then internal.wrapAndUpdateLoveFuncs() end
  end

  hotModule.update(moduleValue)
  for name, hot in pairs(internal.hotStack) do hotModule.addChild(name, hot) end

  -- if not loveswap.getHasErrors() then
  --   internal.state = "normal"
  --   loveswap.revertLoveFuncsFromError()
  -- end

  ---------------------------------------------------------------------------

  internal.hotStack = {}
  internal.currentHot = nil
  internal.currentModulePath = nil
  ;(internal.afterSwapModuleCallbacks[modulepath] or noop)(modulepath);
  internal.global.afterSwapModuleCallback(modulepath)
  return hotModule
end

---------------------------------------------------------------------------------

local function hasIgnoredPattern(modulepath)
  for i, pattern in ipairs(internal.ignoreModulePatterns) do
    if string.match(modulepath, pattern) then return true end
  end
end

function loveswap.require(modulepath)
  if not internal.enabled then return trueRequire(modulepath) end
  if hasIgnoredPattern(modulepath) then return trueRequire(modulepath) end
  if internal.hots[modulepath] then return internal.hots[modulepath].wrapper end
  local filepath = string.gsub(modulepath, "[.]", "/") .. ".lua"
  local fileinfo = love.filesystem.getInfo(filepath)
  if not fileinfo then error("no file:", filepath) end

  internal.filewatcher.addFile(filepath)

  --------------------------------------------------------------

  local hot = internal.hots[modulepath]

  if not hot then
    hot = loveswap.updateModule(modulepath)
    internal.hots[modulepath] = hot
  end

  return hot.wrapper
end

---------------------------------------------------------------------------------

local function createHotFunction(func)
  local hot = createHot()
  hot.update(func, true)
  return hot
end

local function createHotTable(tbl)
  local hot = createHot()
  hot.update(tbl, true)
  return hot
end

--------------------------------------------------------------------------------

---@generic T
---@param name string
---@param value T
---@param flags table
---@return T
function loveswap.hot(name, value, flags)
  if not internal.enabled then return value end
  if value == nil or not name then return end
  if type(value) ~= "table" and type(value) ~= "function" then return end
  local currentHot, hotTarget = internal.currentHot
  flags = flags or { skip = false }

  if not currentHot then -- Module does not exist yet, need to initiate
    hotTarget = type(value) == "function"
      and createHotFunction(value)
      or createHotTable(value)
  else
    hotTarget = currentHot.children[name]

    if not hotTarget then
      hotTarget = type(value) == "function"
        and createHotFunction(value)
        or createHotTable(value)
    end

    hotTarget.setFlags(flags)
    hotTarget.update(value)
  end

  hotTarget.setFlags(flags)
  internal.hotStack[name] = hotTarget
  return hotTarget.wrapper
end

--------------------------------------------------------------------------------

---@generic T
---@param name string
---@param target T
---@return T
function loveswap.skip(name, target)
  return loveswap.hot(name, target, { skip = true })
end

---@generic T
---@param name string
---@param target T
---@return T
function loveswap.unskip(name, target)
  return loveswap.hot(name, target, { skip = false })
end

function loveswap.once(name, fn)
  return loveswap.hot(name, fn, { once = true })
end

--------------------------------------------------------------------------------

-- TODO: Remove callback on file when updating
do -- before/after module swap callback hook
  local function checkModulePathExists()
    if not internal.currentModulePath then error("Not called in module instantiation") end
  end

  function love.beforeModuleSwap(callback)
    checkModulePathExists()
    internal.beforeSwapModuleCallbacks[internal.currentModulePath] = callback
  end

  function love.afterModuleSwap(callback)
    checkModulePathExists()
    internal.afterSwapModuleCallbacks[internal.currentModulePath] = callback
  end
end

--------------------------------------------------------------------------------

function loveswap.global.beforeModuleSwap(callback)
  internal.global.beforeSwapModuleCallback = callback or noop
end

function loveswap.global.afterModuleSwap(callback)
  internal.global.afterSwapModuleCallback = callback or noop
end

--------------------------------------------------------------------------------


do
  local errToShow = ""
  local errModulePath = nil
  local prevModulepath = nil

  local function errUpdate()
    if not loveswap.getHasErrors() then
      internal.state = "normal"
      loveswap.revertLoveFuncsFromError()
    else
      loveswap.error()
    end

    filewatcher.update()
  end

  local errDraw = function()
    if internal.state ~= "error" then return end
    love.graphics.setColor(255, 255, 255)
    love.graphics.print(errToShow or "Error: check console", 80, 80)
    love.graphics.print(internal.errorTraceStack[errModulePath] or "", 80, 100)
  end

  function loveswap.error()
    if not loveswap.getHasErrors() then
      prevModulepath = nil
      return
    end

    if internal.state ~= "error" then
      internal.state = "error"
      prevModulepath = tostring(math.random())

      for i, name in ipairs(loveFuncNames) do love[name] = noop end
    end

    love.update = errUpdate
    love.draw = errDraw

    for modulepath, err in pairs(internal.errors) do
      errModulePath = modulepath
      errToShow = err
      if prevModulepath ~= modulepath then print(err) print(internal.errorTraceStack[modulepath]) end
      prevModulepath = modulepath
      break
    end
  end

  function loveswap.revertLoveFuncsFromError()
    prevModulepath = tostring(math.random())
    for name, hot in pairs(internal.hotLoveFuncs) do love[name] = hot.wrapper end
  end
end

--------------------------------------------------------------------------------

return loveswap