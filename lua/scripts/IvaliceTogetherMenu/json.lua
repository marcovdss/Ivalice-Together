-- Order-preserving JSON for Ivalice Together's config files.
-- Encoding matches Python's json.dumps(indent=2, ensure_ascii=False) + "\n",
-- so an untouched file round-trips byte for byte and JSON null survives.
local M = {}

M.null = setmetatable({}, {__tostring = function() return "null" end})

local OBJECT, ARRAY = {}, {}

function M.object()
  return setmetatable({}, {__jsontype = OBJECT, __keys = {}})
end

function M.array()
  return setmetatable({}, {__jsontype = ARRAY})
end

function M.isObject(value)
  local mt = getmetatable(value)
  return mt ~= nil and mt.__jsontype == OBJECT
end

function M.isArray(value)
  local mt = getmetatable(value)
  return mt ~= nil and mt.__jsontype == ARRAY
end

-- Object fields must be written through set() so that key order is kept.
function M.set(object, key, value)
  assert(M.isObject(object), "json.set requires an object")
  local keys = getmetatable(object).__keys
  if object[key] == nil then keys[#keys + 1] = key end
  object[key] = value
end

function M.remove(object, key)
  assert(M.isObject(object), "json.remove requires an object")
  local keys = getmetatable(object).__keys
  for i = #keys, 1, -1 do
    if keys[i] == key then table.remove(keys, i) end
  end
  object[key] = nil
end

function M.keys(object)
  local copy = {}
  for i, key in ipairs(getmetatable(object).__keys) do copy[i] = key end
  return copy
end

local function decodeError(text, index, message)
  error(string.format("JSON error at byte %d: %s", index, message), 0)
end

local escapes = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}

local function utf8char(code)
  return utf8.char(code)
end

local function skip(text, index)
  local _, finish = text:find("^[ \t\r\n]*", index)
  return finish + 1
end

local decodeValue

local function decodeString(text, index)
  local parts, i = {}, index + 1
  while true do
    local c = text:sub(i, i)
    if c == "" then decodeError(text, i, "unterminated string") end
    if c == '"' then return table.concat(parts), i + 1 end
    if c == "\\" then
      local e = text:sub(i + 1, i + 1)
      if escapes[e] then
        parts[#parts + 1] = escapes[e]
        i = i + 2
      elseif e == "u" then
        local hex = text:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then decodeError(text, i, "bad \\u escape") end
        local code = tonumber(hex, 16)
        i = i + 6
        if code >= 0xD800 and code <= 0xDBFF and text:sub(i, i + 1) == "\\u" then
          local low = tonumber(text:sub(i + 2, i + 5), 16)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            i = i + 6
          end
        end
        parts[#parts + 1] = utf8char(code)
      else
        decodeError(text, i, "bad escape")
      end
    elseif c:byte() < 0x20 then
      decodeError(text, i, "control character in string")
    else
      -- JSON control characters are only 0x00-0x1F; Lua's %c also has DEL.
      local finish = text:find('[\0-\31"\\]', i) or (#text + 1)
      parts[#parts + 1] = text:sub(i, finish - 1)
      i = finish
    end
  end
end

local function decodeNumber(text, index)
  local raw = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", index)
  if not raw or raw == "" or raw == "-" then decodeError(text, index, "bad number") end
  local value
  -- tonumber already yields a float here; adding 0.0 would turn -0.0 into 0.0.
  if raw:find("[.eE]") then value = tonumber(raw) else value = math.tointeger(tonumber(raw)) or tonumber(raw) end
  if value == nil then decodeError(text, index, "bad number") end
  return value, index + #raw
end

function decodeValue(text, index)
  index = skip(text, index)
  local c = text:sub(index, index)
  if c == "{" then
    local object = M.object()
    index = skip(text, index + 1)
    if text:sub(index, index) == "}" then return object, index + 1 end
    while true do
      if text:sub(index, index) ~= '"' then decodeError(text, index, "expected key") end
      local key
      key, index = decodeString(text, index)
      index = skip(text, index)
      if text:sub(index, index) ~= ":" then decodeError(text, index, "expected ':'") end
      local value
      value, index = decodeValue(text, index + 1)
      M.set(object, key, value)
      index = skip(text, index)
      local d = text:sub(index, index)
      if d == "}" then return object, index + 1 end
      if d ~= "," then decodeError(text, index, "expected ',' or '}'") end
      index = skip(text, index + 1)
    end
  elseif c == "[" then
    local array = M.array()
    index = skip(text, index + 1)
    if text:sub(index, index) == "]" then return array, index + 1 end
    while true do
      local value
      value, index = decodeValue(text, index)
      array[#array + 1] = value
      index = skip(text, index)
      local d = text:sub(index, index)
      if d == "]" then return array, index + 1 end
      if d ~= "," then decodeError(text, index, "expected ',' or ']'") end
      index = index + 1
    end
  elseif c == '"' then
    return decodeString(text, index)
  elseif text:sub(index, index + 3) == "true" then
    return true, index + 4
  elseif text:sub(index, index + 4) == "false" then
    return false, index + 5
  elseif text:sub(index, index + 3) == "null" then
    return M.null, index + 4
  elseif c:match("[-%d]") then
    return decodeNumber(text, index)
  end
  decodeError(text, index, "unexpected character")
end

function M.decode(text)
  if type(text) ~= "string" then error("JSON input must be a string", 0) end
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
  local value, index = decodeValue(text, 1)
  index = skip(text, index)
  if index <= #text then decodeError(text, index, "trailing data") end
  return value
end

local function encodeString(value)
  return '"' .. value:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    if c == "\b" then return "\\b" end
    if c == "\f" then return "\\f" end
    if c == "\127" then return c end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

-- Python's repr(float): the shortest form that reads back to the same value.
local function encodeFloat(value)
  if value ~= value or value == math.huge or value == -math.huge then
    error("JSON cannot encode non-finite numbers", 0)
  end
  for digits = 1, 17 do
    local text = string.format("%." .. digits .. "g", value)
    if tonumber(text) == value then
      local mantissa, exponent = text:match("^([^e]+)e([-+]%d+)$")
      if mantissa then
        local power = tonumber(exponent)
        if power >= -4 and power < 16 then
          text = string.format("%." .. math.max(0, digits - 1 - power) .. "f", value)
        else
          return mantissa .. "e" .. (power < 0 and "-" or "+") .. string.format("%02d", math.abs(power))
        end
      end
      if not text:find("[.e]") then text = text .. ".0" end
      return text
    end
  end
end

local function encodeValue(value, indent, out)
  local kind = type(value)
  if value == M.null then
    out[#out + 1] = "null"
  elseif kind == "boolean" then
    out[#out + 1] = value and "true" or "false"
  elseif kind == "number" then
    if math.type(value) == "integer" then out[#out + 1] = string.format("%d", value) else out[#out + 1] = encodeFloat(value) end
  elseif kind == "string" then
    out[#out + 1] = encodeString(value)
  elseif M.isObject(value) then
    local keys = getmetatable(value).__keys
    local present = {}
    for _, key in ipairs(keys) do if value[key] ~= nil then present[#present + 1] = key end end
    if #present == 0 then out[#out + 1] = "{}" return end
    local inner = indent .. "  "
    out[#out + 1] = "{\n"
    for i, key in ipairs(present) do
      out[#out + 1] = inner .. encodeString(key) .. ": "
      encodeValue(value[key], inner, out)
      out[#out + 1] = i < #present and ",\n" or "\n"
    end
    out[#out + 1] = indent .. "}"
  elseif M.isArray(value) then
    if #value == 0 then out[#out + 1] = "[]" return end
    local inner = indent .. "  "
    out[#out + 1] = "[\n"
    for i = 1, #value do
      out[#out + 1] = inner
      encodeValue(value[i], inner, out)
      out[#out + 1] = i < #value and ",\n" or "\n"
    end
    out[#out + 1] = indent .. "]"
  else
    error("JSON cannot encode a plain " .. kind .. "; use json.object() or json.array()", 0)
  end
end

function M.encode(value)
  local out = {}
  encodeValue(value, "", out)
  return table.concat(out) .. "\n"
end

return M
