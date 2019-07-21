local hotWeakMap = setmetatable({}, { __mode = "kv" })

function isHotSwapFriendly(value)
  if type(value) == "function" or type(value) == "table" then
    return true
  end
  return false
end

local function createHot()
  local hot = {
    children    = {},
    flags       = {},
    wrapper     = nil,
    sourceValue = nil,
  }

  hotWeakMap[hot] = hot

  --------------------------------------------------------------------------

  function hot.addChild(childName, child)
    hot.children[childName] = child
  end

  function hot.setFlags(flags)
    flags = flags or {}
    for flag, value in pairs(flags) do hot.flags[flag] = value end
  end

  --------------------------------------------------------------------------

  -- TODO: return false if value type changed, cause full reload on module
  function hot.update(value, forceUpdate)
    if not isHotSwapFriendly(value) then
      hot.sourceValue = value
      hot.wrapper = value
      return hot
    end

    if not hot.wrapper then
      if type(value) == "function" then
        hot.wrapper = function(...) return hot.sourceValue(...) end

      elseif type(value) == "table" then
        hot.wrapper = setmetatable({}, { __getmetatable = getmetatable(value) })
      end
    end

    if type(value) ~= type(hot.wrapper) then
      error("wrong module wrapper type: " .. type(value) .. " ~= " .. type(hot.wrapper))
    end

    if not forceUpdate and hot.flags.skip then return hot end

    if type(value) == "table" then
      -- for k, v in pairs(hot.wrapper) do hot.wrapper[k] = nil end
      for k, v in pairs(value) do
        if true then
          local child = hotWeakMap[v] or hot.children[k] or createHot()
          hot.addChild(k, child)
          child.update(v)
          hot.wrapper[k] = child.wrapper
        else
          hot.wrapper[k] = v
        end
      end
    end

    hot.sourceValue = value
    return hot
  end

  --------------------------------------------------------------------------

  return hot
end


return createHot