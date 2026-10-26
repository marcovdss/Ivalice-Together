-- Ivalice Together settings in the game's Mod Config menu.
-- Edits the same coop/*.json files as IvaliceTogetherConfig.exe; button
-- remapping and SDL pad pairing stay in the configurator.
local PREFIX = "Ivalice Together menu: "
local ROOT = "scripts/IvaliceTogetherMenu/"
local COOP = "coop/"

local function include(name)
  return assert(loadfile(ROOT .. name, "t", _ENV))()
end

if type(modmenu) ~= "table" then
  print(PREFIX .. "Mod Menu is unavailable; page not registered.")
  return
end

local json = include("json.lua")
local model = include("model.lua")(json, include("defaults.lua"))

local FILES = {
  launcher = COOP .. "launcher_config.json",
  roster = COOP .. "coop_roster_config.json",
  theme = COOP .. "menu_theme_config.json",
  controller = COOP .. "controller_config.json",
}
local MARKER = COOP .. model.DISABLED_MARKER

local function readText(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("a")
  file:close()
  return text
end

local function readDocument(path)
  local text = readText(path)
  if text == nil then return nil, nil end
  local ok, doc = pcall(json.decode, text)
  if not ok then return nil, text end
  return doc, text
end

-- Replace through a sibling temporary file, so a reader sees either the old
-- or the new document; the runtime's loaders retry on their next poll.
local function writeText(path, text)
  local temporary = path .. ".menu.tmp"
  local file, err = io.open(temporary, "wb")
  if not file then return false, err end
  local ok, writeError = file:write(text)
  file:close()
  if not ok then os.remove(temporary) return false, writeError end
  if os.rename(temporary, path) then return true end
  os.remove(path)
  if os.rename(temporary, path) then return true end
  local direct = io.open(path, "wb")
  if direct then
    direct:write(text)
    direct:close()
    os.remove(temporary)
    return true
  end
  os.remove(temporary)
  return false, "could not replace " .. path
end

local function writeDocument(path, doc)
  local ok, err = writeText(path, json.encode(doc))
  if not ok then error("could not save " .. path .. ": " .. tostring(err), 0) end
end

if readText(FILES.controller) == nil and readText(FILES.roster) == nil and readText(FILES.launcher) == nil then
  print(PREFIX .. "no coop/ settings folder next to the game; page not registered.")
  return
end

local ID = "IvaliceTogether"
local ON_OFF = {"On", "Off"}
local THEME_LABELS = {"Sapphire", "Gold", "Emerald", "Amethyst", "Pink", "Ruby", "Bronze"}
local ROSTER_LABELS = {}
for i, member in ipairs(model.ROSTER_MEMBERS) do ROSTER_LABELS[i] = member.name end
ROSTER_LABELS[#ROSTER_LABELS + 1] = "Nobody"
local PAD_LABELS = {"None", "Pad 1", "Pad 2", "Pad 3", "Pad 4", "Other pad"}
local DESKTOP_LABELS = {"Nobody", "Player 1", "Player 2", "Player 3"}
local NEXT_START = " Takes effect the next time you start the game."

local function indexOf(list, value)
  for i, item in ipairs(list) do
    if item == value then return i - 1 end
  end
  return 0
end

local onResetDamage

-- Toggles take at most six options; the seven colors need a carousel.
-- level 1: full page; 2: no per-character colors or help; 3: no colors at all.
local function buildSchema(level)
  local compact = level > 1
  local schema = {}
  local function row(entry)
    if compact then entry.help = nil end
    schema[#schema + 1] = entry
  end
  local function divider(label) schema[#schema + 1] = {label = label, type = "divider"} end

  divider("Co-op")
  row({id = "coopEnabled", label = "Ivalice Together", type = "toggle", options = {"Enabled", "Disabled"},
    default = 0, help = "Turns co-op on or off." .. NEXT_START})
  row({id = "rosterAll", label = "Start with all characters", type = "toggle", options = ON_OFF, default = 0,
    help = "On: Vaan starts with Party, Gambits and the five allies unlocked. Off: characters join with the story." .. NEXT_START})
  -- Six names in a row run off the screen; carousels show one at a time.
  row({id = "roster_p2", label = "Player 2 character", type = "carousel", options = ROSTER_LABELS, default = 2,
    help = "Character Player 2 controls. Picking Player 3's character leaves Player 3 empty." .. NEXT_START})
  row({id = "roster_p3", label = "Player 3 character", type = "carousel", options = ROSTER_LABELS, default = 0,
    help = "Character Player 3 controls. Picking Player 2's character leaves Player 2 empty." .. NEXT_START})

  divider("Controllers")
  for n = 1, 3 do
    row({id = "pad_p" .. n, label = "Player " .. n .. " controller", type = "carousel", options = PAD_LABELS,
      default = n == 1 and 1 or 0,
      help = n == 1 and "Change Player 1's controller in IvaliceTogetherConfig.exe, so you never lose control of this menu."
        or "Controller this player uses. Player 1's pad stays with Player 1. Other pad: a non-XInput pad paired in IvaliceTogetherConfig.exe."})
  end
  row({id = "desktop", label = "Keyboard and mouse", type = "carousel", options = DESKTOP_LABELS, default = 2,
    help = "Player who uses the keyboard and mouse. If Player 1 has them, change that in IvaliceTogetherConfig.exe. Rebind buttons there too."})

  if level < 3 then
    divider("Colors")
    row({id = "themeMode", label = "Menu colors follow", type = "toggle", options = {"Character", "Player"}, default = 0,
      help = "Character: each character keeps its own color. Player: each player keeps one color."})
    for n = 1, 3 do
      row({id = "theme_p" .. n, label = "Player " .. n .. " color", type = "carousel", options = THEME_LABELS, default = 0,
        help = "This player's color when colors follow the player."})
    end
    if level == 1 then
      for _, character in ipairs(model.MAIN_CHARACTERS) do
        row({id = "theme_" .. character.name, label = character.name .. "'s color", type = "carousel", options = THEME_LABELS,
          default = indexOf(model.PRESETS, character.theme), help = "Color used when " .. character.name .. " is controlled by a player."})
      end
    end
  end

  divider("Battle menu sounds")
  for n = 1, 3 do
    row({id = "battleSound_p" .. n, label = "Player " .. n, type = "toggle", options = ON_OFF, default = 0,
      help = "Plays or mutes this player's battle menu sounds."})
  end

  divider("Damage meter")
  row({id = "damageMeter", label = "Damage meter", type = "toggle", options = ON_OFF, default = 1,
    help = "Ranks damage dealt by the active party."})
  row({id = "damageMeterMode", label = "Totals", type = "toggle", options = {"This area", "Until reset"}, default = 0,
    help = "This area: totals restart in each area. Until reset: totals are kept per character until reset."})
  row({id = "damageMeterEffective", label = "Count", type = "toggle", options = {"Raw", "Effective"}, default = 0,
    help = "Raw: all damage dealt. Effective: only damage that lowered HP."})
  -- Buttons take their callback in the schema, as in other Mod Config pages.
  row({id = "resetDamage", label = "Reset damage totals", type = "button", help = "Starts a new damage session.",
    callback = function() if onResetDamage then onResetDamage() end end})

  return {id = ID, name = "Ivalice Together", schema = schema}
end

local function addPage(candidate)
  local ok, added = pcall(modmenu.addTable, candidate)
  return ok and added ~= false
end

local page
for level = 1, 3 do
  local candidate = buildSchema(level)
  if addPage(candidate) then
    page = candidate
    if level > 1 then print(PREFIX .. "added a reduced page (level " .. level .. ") after the menu rejected the full one.") end
    break
  end
end
if not page then
  print(PREFIX .. "couldn't add the Mod Config page.")
  return
end

local present = {}
for _, entry in ipairs(page.schema) do
  if entry.id then present[entry.id] = true end
end

local refreshing = false
local snapshot = {}

-- What each row currently shows (set by us or picked by the player), so a
-- refresh only touches rows whose value really changed.
local shownValue, shownActive = {}, {}

local function setValue(id, value)
  if present[id] and shownValue[id] ~= value then
    shownValue[id] = value
    modmenu.setValue(ID, id, value)
  end
end

local function setActive(id, active)
  if present[id] and modmenu.setActive and shownActive[id] ~= active then
    shownActive[id] = active
    modmenu.setActive(ID, id, active)
  end
end

local function rosterIndex(member)
  if member == nil then return #model.ROSTER_MEMBERS end
  for i, entry in ipairs(model.ROSTER_MEMBERS) do
    if entry.id == member then return i - 1 end
  end
  return #model.ROSTER_MEMBERS
end

local function padIndex(assignment)
  if assignment == nil then return 0 end
  if math.type(assignment) == "integer" then return assignment + 1 end
  return 5
end

local function refresh()
  refreshing = true
  local ok, err = pcall(function()
    local launcher = model.readLauncher((readDocument(FILES.launcher)))
    local roster = model.readRoster((readDocument(FILES.roster)))
    local theme = model.readTheme((readDocument(FILES.theme)))
    local controllerDoc = readDocument(FILES.controller)
    setValue("coopEnabled", readText(MARKER) == nil and 0 or 1)
    setValue("rosterAll", roster.startWithAll and 0 or 1)
    setValue("roster_p2", rosterIndex(roster.p2))
    setValue("roster_p3", rosterIndex(roster.p3))
    local editable = model.controllersEditable(controllerDoc)
    local controllers = model.readControllers(controllerDoc)
    for n = 1, 3 do
      setValue("pad_p" .. n, padIndex(controllers.devices["p" .. n]))
      setActive("pad_p" .. n, editable and n ~= 1)
    end
    setValue("desktop", controllers.desktopOwner and tonumber(controllers.desktopOwner:sub(2)) or 0)
    setActive("desktop", editable and controllers.desktopOwner ~= "p1")
    setValue("themeMode", theme.mode == "player" and 1 or 0)
    for n = 1, 3 do setValue("theme_p" .. n, indexOf(model.PRESETS, theme.players["p" .. n])) end
    for _, character in ipairs(model.MAIN_CHARACTERS) do
      setValue("theme_" .. character.name, indexOf(model.PRESETS, theme.characters[character.name]))
    end
    for n = 1, 3 do setValue("battleSound_p" .. n, launcher.battleMenuSounds["p" .. n] and 0 or 1) end
    setValue("damageMeter", launcher.damageMeter and 0 or 1)
    setValue("damageMeterMode", launcher.damageMeterMode == "indefinite" and 1 or 0)
    setValue("damageMeterEffective", launcher.damageMeterEffective and 1 or 0)
  end)
  refreshing = false
  if not ok then print(PREFIX .. "refresh failed: " .. tostring(err)) end
end

local function editLauncher(key, value)
  writeDocument(FILES.launcher, model.setLauncher((readDocument(FILES.launcher)), key, value))
end

local function editTheme(key, value)
  writeDocument(FILES.theme, model.setTheme((readDocument(FILES.theme)), key, value))
end

local function editRoster(change)
  writeDocument(FILES.roster, model.writeRoster(change(model.readRoster((readDocument(FILES.roster))))))
end

local function editControllers(change)
  local doc = readDocument(FILES.controller)
  if not model.controllersEditable(doc) then
    error("controller settings use a format this page does not edit; use IvaliceTogetherConfig.exe", 0)
  end
  change(doc)
  writeDocument(FILES.controller, doc)
end

local handlers = {}

handlers.coopEnabled = function(value)
  if value == 0 then
    os.remove(MARKER)
  elseif readText(MARKER) == nil then
    local ok, err = writeText(MARKER, model.DISABLED_MARKER_TEXT)
    if not ok then error(tostring(err), 0) end
  end
end

handlers.rosterAll = function(value)
  editRoster(function(roster) roster.startWithAll = value == 0 return roster end)
end

for _, role in ipairs({"p2", "p3"}) do
  handlers["roster_" .. role] = function(value)
    local member = model.ROSTER_MEMBERS[value + 1]
    editRoster(function(roster) return model.assignRoster(roster, role, member and member.id or nil) end)
  end
end

for n = 1, 3 do
  local player = "p" .. n
  handlers["pad_" .. player] = function(value)
    -- "Other pad" only names an SDL pairing made in the configurator.
    if value == 5 then return end
    local target = value > 0 and value - 1 or nil
    editControllers(function(doc)
      local ok, reason = model.controllerChangeKeepsP1(doc, player, target)
      if not ok then error(reason, 0) end
      model.assignController(doc, player, target)
    end)
  end
  handlers["theme_" .. player] = function(value) editTheme("player:" .. player, model.PRESETS[value + 1]) end
  handlers["battleSound_" .. player] = function(value) editLauncher("battleMenuSound:" .. player, value == 0) end
end

handlers.desktop = function(value)
  local owner = value > 0 and "p" .. value or nil
  editControllers(function(doc)
    local ok, reason = model.desktopChangeKeepsP1(doc, owner)
    if not ok then error(reason, 0) end
    model.setDesktopOwner(doc, owner)
  end)
end

handlers.themeMode = function(value) editTheme("mode", value == 1 and "player" or "character") end

for _, character in ipairs(model.MAIN_CHARACTERS) do
  handlers["theme_" .. character.name] = function(value)
    editTheme("character:" .. character.name, model.PRESETS[value + 1])
  end
end

handlers.damageMeter = function(value) editLauncher("damageMeter", value == 0) end
handlers.damageMeterMode = function(value) editLauncher("damageMeterMode", value == 1 and "indefinite" or "area") end
handlers.damageMeterEffective = function(value) editLauncher("damageMeterEffective", value == 1) end

local function resetDamage()
  local ok, err = pcall(editLauncher, "resetDamageSession")
  if not ok then print(PREFIX .. tostring(err)) end
end

onResetDamage = function()
  if type(dialog) == "table" and dialog.show then
    dialog.show({
      body = "{speed:0}Reset the damage totals?", choice = {"Yes", "No"}, cursor = 1, cancel = 1,
      closeOnCancel = true, x = 960, y = 540, align = 4, dim = true, lockInterface = true,
      onClose = function(choice) if choice == 0 then resetDamage() end end,
    })
  else
    resetDamage()
  end
end

local function refreshAndRemember()
  refresh()
  for _, path in pairs(FILES) do snapshot[path] = readText(path) end
  snapshot[MARKER] = readText(MARKER)
end

-- Setting a control's value from inside its own change callback crashed the
-- game (a refused pad choice snapped the carousel back mid-callback), so
-- callbacks only save; the page catches up from a timer afterwards.
local REFRESH_DELAY_MS = 100
local refreshPending = false
local function scheduleRefresh()
  if type(event) ~= "table" or not event.executeAfterMs then return refreshAndRemember() end
  if refreshPending then return end
  refreshPending = true
  event.executeAfterMs(REFRESH_DELAY_MS, function()
    refreshPending = false
    refreshAndRemember()
  end)
end

for id, handler in pairs(handlers) do
  if present[id] then
    modmenu.registerCallback(ID, id, function(_, _, value)
      if refreshing then return end
      shownValue[id] = value
      local ok, err = pcall(handler, value)
      if not ok then print(PREFIX .. tostring(err)) end
      scheduleRefresh()
    end)
  end
end

refreshAndRemember()

-- Follow edits made by IvaliceTogetherConfig.exe while the game runs.
local POLL_MS = 1500
local function poll()
  local changed = false
  for _, path in pairs(FILES) do
    local text = readText(path)
    if text ~= snapshot[path] then snapshot[path], changed = text, true end
  end
  local marker = readText(MARKER)
  if marker ~= snapshot[MARKER] then snapshot[MARKER], changed = marker, true end
  if changed then refresh() end
  event.executeAfterMs(POLL_MS, poll)
end
if type(event) == "table" and event.executeAfterMs then
  if event.registerEventAsync then
    event.registerEventAsync("onInitDone", function() event.executeAfterMs(POLL_MS, poll) end)
  else
    event.executeAfterMs(POLL_MS, poll)
  end
end

print(PREFIX .. "page ready.")
