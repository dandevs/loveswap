local trueRequire = require
local loveswap    = {}
local filewatcher = (require "lib.loveswap.filewatcher")()
local createHot   = require "lib.loveswap.hot"
local function noop() end

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

local hotLoveFuncs = {}

---------------------------------------------------------

local internal = {
  hots        = {},
  hotStack    = {},
  require     = require,
  enabled     = false,
  cache       = cache,
  filewatcher = filewatcher,
  currentHot  = nil,
  state       = "initial",

  ignoreModulePatterns      = { "lib.loveswap" },
  currentModulePath         = nil,
  beforeSwapModuleCallbacks = {},
  afterSwapModuleCallbacks  = {},
}
loveswap.internal = internal

local onUpdateMain
filewatcher.onFileChanged(function(file)
  local modulepath = string.gsub(string.sub(file.path, 1, -5), "[/]", ".")
  loveswap.updateModule(modulepath)

  if modulepath == "main" then
    internal.onUpdateMain()
  end
end)

---------------------------------------------------------------------------------
-- 1. When starting, wrap all love[callbacks] in hot wrapper
-- 2. When update, update all love[callbacks] wrapper source values

function internal.wrapAndUpdateLoveFuncs()
  for i, name in ipairs(loveFuncNames) do
    if love[name] then
      local hot = hotLoveFuncs[name] or createHot()
      hot.update(love[name])
      hotLoveFuncs[name] = hot
      love[name] = hot.wrapper
      print("hi")
    end
  end
end

function internal.onUpdateMain()
  internal.wrapAndUpdateLoveFuncs()
end

local function onInitiate()
  internal.wrapAndUpdateLoveFuncs()
  internal.filewatcher.addFile("main.lua")
end

---------------------------------------------------------------------------------

function loveswap.setEnabled(enabled) internal.enabled = enabled end
function loveswap.setFileScanInterval(t) internal.filewatcher.setScanInterval(t) end

function loveswap.ignoreModules(patterns)
  loveswap.internal.ignoreModulePatterns = { unpack(internal.ignoreModulePatterns), unpack(patterns) }
end

---------------------------------------------------------------------------------

function loveswap.update()
  if not internal.enabled then return end
  if internal.state == "initial" then
    internal.state = "normal"
    onInitiate()
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

  package.loaded[modulepath] = nil
  internal.currentHot = hotModule
  moduleValue = trueRequire(modulepath)

  hotModule.update(moduleValue)
  for name, hot in pairs(internal.hotStack) do hotModule.addChild(name, hot) end

  ---------------------------------------------------------------------------

  internal.hotStack = {}
  internal.currentHot = nil
  internal.currentModulePath = nil
  ;(internal.afterSwapModuleCallbacks[modulepath] or noop)(modulepath);

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

do
  love.global = {
    beforeModuleSwapListeners = {},
    afterModuleSwapListeners  = {}
  }

  local function removeValue(tbl, value)
    for i, v in ipairs(tbl) do
      if value == v then
        tbl.removeValue(tbl, i)
        break
      end
    end
  end

  function love.global.beforeModuleSwap(callback)
    table.insert(love.global.beforeModuleSwapListeners, callback)
    return function()
      removeValue(love.global.beforeModuleSwapListeners, callback)
    end
  end

  function love.global.afterModuleSwap(callback)
    table.insert(love.global.afterModuleSwapListeners, callback)
    return function()
      removeValue(love.global.afterModuleSwapListeners, callback)
    end
  end
end

--------------------------------------------------------------------------------

return loveswap