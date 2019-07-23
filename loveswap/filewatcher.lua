local getTime = love.timer.getTime
local function merge(source, other)
  for k, v in pairs(other) do source[k] = v end
  return source
end

local function noop() end

-------------------------------------------------------------

local function createFilewatcher(settings)
  local internal = {
    timeLastScanned = getTime(),
    onFileChanged   = noop,
    scanInterval    = 0.25
  }
  local watcher = { files = {}, internal = internal }

  -------------------------------------------------------------------

  function watcher.addFile(...)
    paths = { ... }

    for i, path in ipairs(paths) do
      if type(path) ~= "string" then error("path must be a string") end
      if watcher.files[path] then return end
      local info = love.filesystem.getInfo(path)
      if not info then error("File '" .. path .. "' does not exist") end

      local file = merge({ path = path }, info)
      watcher.files[path] = file
    end
  end

  function watcher.removeFile(path) table.remove(watcher.files, path) end
  function watcher.onFileChanged(callback) internal.onFileChanged = callback end
  function watcher.setScanInterval(time) internal.scanInterval = time end

  -------------------------------------------------------------------

  function watcher.scan()
    local filesChanged = {}

    for k, file in pairs(watcher.files) do
      local info = love.filesystem.getInfo(file.path)

      if not info then
        watcher.files[k] = nil
      elseif info.modtime ~= file.modtime then
        merge(file, info) -- Update file info
        internal.onFileChanged(file)
      end
    end
  end

  -------------------------------------------------------------------

  function watcher.update()
    if getTime() > internal.timeLastScanned then
      watcher.scan()
      internal.timeLastScanned = getTime() + internal.scanInterval
    end
  end

  return watcher
end

return createFilewatcher