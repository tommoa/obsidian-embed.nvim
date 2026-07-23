-- Owns the public, provider-facing extension boundary for embed renderers.
local M = {}

---@class ObsidianEmbedsProvider
---@field name string
---@field match fun(ref: ObsidianEmbedsRef, ctx: table): boolean
---Successful completion requires a result with project(width); nil is reserved
---for completions that also provide an error.
---@field render_async fun(ref: ObsidianEmbedsRef, ctx: table, done: fun(result?: table, err?: string)): (fun()|nil)

local providers, provider_order, active = {}, {}, {}

local function validate(provider)
  if type(provider) ~= "table" then error("embed provider must be a table", 3) end
  if type(provider.name) ~= "string" or provider.name == "" then
    error("embed provider name must be a non-empty string", 3)
  end
  if type(provider.match) ~= "function" then error("embed provider " .. provider.name .. " requires match", 3) end
  if type(provider.render_async) ~= "function" then
    error("embed provider " .. provider.name .. " requires render_async", 3)
  end
end

---@param provider ObsidianEmbedsProvider
---@return fun()
function M.register(provider)
  validate(provider)
  if providers[provider.name] then error("embed provider already registered: " .. provider.name, 2) end
  providers[provider.name] = provider
  provider_order[#provider_order + 1] = provider.name
  local removed = false
  return function()
    if removed then return end
    removed = true
    if providers[provider.name] == provider then
      providers[provider.name] = nil
      for index, name in ipairs(provider_order) do
        if name == provider.name then table.remove(provider_order, index); break end
      end
    end
  end
end

---@param ref ObsidianEmbedsRef
---@param ctx table
---@return ObsidianEmbedsProvider?
function M.match(ref, ctx)
  -- Registration order is precedence. It keeps overlapping providers
  -- predictable without adding a separate priority API.
  for _, name in ipairs(provider_order) do
    local provider = providers[name]
    local ok, matches = pcall(provider.match, ref, ctx)
    if not ok then return provider, tostring(matches) end
    if matches then return provider end
  end
end

local function remove_active(owner, entry)
  local entries = owner and active[owner]
  if not entries then return end
  entries[entry] = nil
  if not next(entries) then active[owner] = nil end
end

---@param provider ObsidianEmbedsProvider
---@param ref ObsidianEmbedsRef
---@param ctx table
---@param done fun(result?: table, err?: string)
---@param owner? table Internal render-generation cancellation owner.
function M.render_async(provider, ref, ctx, done, owner)
  local entry = { cancelled = false }
  if owner then
    active[owner] = active[owner] or {}
    active[owner][entry] = true
  end
  local completed = false
  local function finish(result, err)
    if completed or entry.cancelled then return end
    completed = true
    remove_active(owner, entry)
    if result == nil and err == nil then
      done(nil, "embed provider " .. provider.name .. " returned no result")
      return
    elseif result ~= nil then
      if type(result) ~= "table" or type(result.project) ~= "function" then
        done(nil, "embed provider " .. provider.name .. " returned no project(width) function")
        return
      end
      if result.dependencies ~= nil and type(result.dependencies) ~= "table" then
        done(nil, "embed provider " .. provider.name .. " returned invalid dependencies")
        return
      end
      for _, path in ipairs(result.dependencies or {}) do
        if type(path) ~= "string" or path == "" then
          done(nil, "embed provider " .. provider.name .. " returned an invalid dependency")
          return
        end
      end
    end
    done(result, err)
  end
  local ok, cancellation = pcall(provider.render_async, ref, ctx, finish)
  if not ok then finish(nil, tostring(cancellation)); return end
  if type(cancellation) == "function" then entry.cancel = cancellation end
end

---Cancel every still-running provider request for one embed render owner.
---@param owner? table
function M.cancel_owner(owner)
  local entries = owner and active[owner]
  if not entries then return end
  active[owner] = nil
  for entry in pairs(entries) do
    entry.cancelled = true
    if entry.cancel then pcall(entry.cancel) end
  end
end

return M
