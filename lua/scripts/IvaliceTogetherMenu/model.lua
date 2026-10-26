-- Pure rules for the in-game configuration page.  No game or file access here.
-- Each reader mirrors the Python loader's normalization for the values shown;
-- each writer edits only the touched fields of the decoded document, so the
-- runtime's own loader still normalizes everything else.
return function(json, defaults)
  local M = {}

  M.PLAYERS = {"p1", "p2", "p3"}
  M.CONTROLLER_CONFIG_VERSION = 11
  M.LAUNCHER_CONFIG_VERSION = 6
  M.ROSTER_CONFIG_VERSION = 2
  M.THEME_CONFIG_VERSION = 3
  M.PRESETS = {"sapphire", "gold", "emerald", "amethyst", "pink", "ruby", "bronze"}
  M.THEME_ALIASES = defaults.themeAliases
  M.MAIN_CHARACTERS = {
    {id = 0, name = "Vaan", theme = "sapphire"},
    {id = 1, name = "Ashe", theme = "pink"},
    {id = 2, name = "Fran", theme = "amethyst"},
    {id = 3, name = "Balthier", theme = "bronze"},
    {id = 4, name = "Basch", theme = "emerald"},
    {id = 5, name = "Penelo", theme = "gold"},
  }
  -- coop_roster.SELECTABLE_MEMBERS, in the configurator's order.
  M.ROSTER_MEMBERS = {
    {id = 3, name = "Balthier"},
    {id = 2, name = "Fran"},
    {id = 4, name = "Basch"},
    {id = 1, name = "Ashe"},
    {id = 5, name = "Penelo"},
  }
  M.PARTY_MEMBER_IDS = defaults.partyMemberIds
  M.DISABLED_MARKER = "ivalice-together.disabled"
  M.DISABLED_MARKER_TEXT = "Ivalice Together is disabled. Re-enable it from IvaliceTogetherConfig.exe.\n"

  local function isInteger(value)
    return math.type(value) == "integer"
  end

  local function field(object, key)
    if json.isObject(object) then return object[key] end
    return nil
  end

  local function ensureObject(parent, key)
    local value = parent[key]
    if not json.isObject(value) then
      value = json.object()
      json.set(parent, key, value)
    end
    return value
  end

  -- Python bool(x) for decoded JSON values.
  local function truthy(value)
    if value == nil or value == json.null or value == false then return false end
    if type(value) == "number" then return value ~= 0 end
    if type(value) == "string" then return value ~= "" end
    if json.isObject(value) then return #json.keys(value) > 0 end
    if json.isArray(value) then return #value > 0 end
    return true
  end

  local function strip(text)
    return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
  end

  -- " ".join(text.split())
  local function collapse(text)
    local words = {}
    for word in tostring(text):gmatch("%S+") do words[#words + 1] = word end
    return table.concat(words, " ")
  end

  local function pythonStr(value)
    if value == true then return "True" end
    if value == false then return "False" end
    if type(value) == "number" then
      return math.type(value) == "integer" and string.format("%d", value) or tostring(value)
    end
    if type(value) == "string" then return value end
    return "?"
  end

  ---------------------------------------------------------------------------
  -- launcher_config.json (launcher_core.normalize_launcher_config)

  -- Only the settings the running co-op reads; language, configurator sounds,
  -- volume and minimizing belong to IvaliceTogetherConfig.exe itself.
  local SESSION_LIMIT = 0x7FFFFFFF

  local function pythonInt(value)
    if type(value) == "boolean" then return value and 1 or 0 end
    if type(value) == "number" then
      if value ~= value or value == math.huge or value == -math.huge then return nil end
      return math.tointeger(value >= 0 and math.floor(value) or math.ceil(value))
    end
    if type(value) == "string" then
      local text = strip(value)
      if text:match("^[-+]?%d+$") then return math.tointeger(tonumber(text)) end
    end
    return nil
  end

  function M.readLauncher(doc)
    local result = {
      battleMenuSounds = {p1 = true, p2 = true, p3 = true},
      damageMeter = false, damageMeterMode = "area", damageMeterEffective = false, sessionId = 1,
    }
    if not json.isObject(doc) then return result end
    local battle = field(doc, "battle_menu_sounds")
    for _, player in ipairs(M.PLAYERS) do
      local value = field(battle, player)
      if value ~= nil then result.battleMenuSounds[player] = truthy(value) end
    end
    result.damageMeter = truthy(doc.damage_meter_enabled)
    local mode = doc.damage_meter_mode
    if mode == nil then mode = "area" end
    mode = string.lower(strip(pythonStr(mode)))
    if mode == "area" or mode == "indefinite" then result.damageMeterMode = mode end
    result.damageMeterEffective = truthy(doc.damage_meter_effective)
    local session = doc.damage_meter_session_id
    if session == nil then session = 1 end
    session = pythonInt(session) or 1
    result.sessionId = math.min(SESSION_LIMIT, math.max(1, session))
    return result
  end

  local function launcherDocument(doc)
    if json.isObject(doc) then return doc end
    doc = json.object()
    json.set(doc, "version", M.LAUNCHER_CONFIG_VERSION)
    json.set(doc, "language", "en")
    json.set(doc, "menu_sounds", true)
    local battle = json.object()
    for _, player in ipairs(M.PLAYERS) do json.set(battle, player, true) end
    json.set(doc, "battle_menu_sounds", battle)
    json.set(doc, "sound_volume", 1.0)
    json.set(doc, "minimize_when_ready", true)
    json.set(doc, "damage_meter_enabled", false)
    json.set(doc, "damage_meter_mode", "area")
    json.set(doc, "damage_meter_effective", false)
    json.set(doc, "damage_meter_session_id", 1)
    return doc
  end

  -- key: battleMenuSound:<player> | damageMeter | damageMeterMode |
  --      damageMeterEffective | resetDamageSession
  function M.setLauncher(doc, key, value)
    doc = launcherDocument(doc)
    if key:match("^battleMenuSound:") then
      local player = key:sub(#"battleMenuSound:" + 1)
      assert(player == "p1" or player == "p2" or player == "p3", "unknown player")
      local battle = ensureObject(doc, "battle_menu_sounds")
      json.set(battle, player, value == true)
    elseif key == "damageMeter" then
      json.set(doc, "damage_meter_enabled", value == true)
    elseif key == "damageMeterMode" then
      assert(value == "area" or value == "indefinite", "unsupported damage meter mode")
      json.set(doc, "damage_meter_mode", value)
    elseif key == "damageMeterEffective" then
      json.set(doc, "damage_meter_effective", value == true)
    elseif key == "resetDamageSession" then
      -- Same step as the configurator's Reset button.
      local current = M.readLauncher(doc).sessionId
      json.set(doc, "damage_meter_session_id", current >= SESSION_LIMIT and 1 or current + 1)
    else
      error("unknown launcher setting: " .. tostring(key))
    end
    return doc
  end

  ---------------------------------------------------------------------------
  -- coop_roster_config.json (coop_roster.normalize / save)

  local DEFAULT_P2, DEFAULT_P3 = 4, 3
  local rosterNames = {}
  for _, member in ipairs(M.ROSTER_MEMBERS) do rosterNames[member.id] = member.name end

  local function cleanMember(value)
    local number
    if type(value) == "number" then
      if value ~= value or value == math.huge or value == -math.huge then return nil end
      number = value >= 0 and math.floor(value) or math.ceil(value)
    elseif type(value) == "string" then
      local text = value:gsub("^%s+", ""):gsub("%s+$", "")
      if text:match("^[-+]?%d+$") then number = tonumber(text) end
    elseif value == true then
      number = 1
    elseif value == false then
      number = 0
    end
    number = number and math.tointeger(number)
    if number and rosterNames[number] then return number end
    return nil
  end

  function M.readRoster(doc)
    local roster = {p2 = DEFAULT_P2, p3 = DEFAULT_P3, startWithAll = true}
    if not json.isObject(doc) then return roster end
    local players = doc.players
    if not json.isObject(players) then return roster end
    roster.p2 = players.p2 ~= nil and cleanMember(players.p2) or (players.p2 == nil and DEFAULT_P2 or nil)
    roster.p3 = players.p3 ~= nil and cleanMember(players.p3) or (players.p3 == nil and DEFAULT_P3 or nil)
    roster.startWithAll = doc.start_with_all == true
    if roster.p2 ~= nil and roster.p2 == roster.p3 then roster.p3 = nil end
    return roster
  end

  -- CoopRoster.assign: taking a member from the other role leaves it empty.
  function M.assignRoster(roster, role, member)
    assert(role == "p2" or role == "p3", "role must be 'p2' or 'p3'")
    local result = {p2 = roster.p2, p3 = roster.p3, startWithAll = roster.startWithAll}
    if member == nil then
      result[role] = nil
      return result
    end
    assert(rosterNames[member], "member is not selectable")
    local other = role == "p2" and "p3" or "p2"
    if result[other] == member then result[other] = nil end
    result[role] = member
    return result
  end

  -- Taking the other player's character swaps the two seats, so neither is
  -- left empty (the configurator empties the other seat instead).
  function M.swapRoster(roster, role, member)
    local other = role == "p2" and "p3" or "p2"
    local previous = roster[role]
    local result = M.assignRoster(roster, role, member)
    if member ~= nil and roster[other] == member and previous ~= nil then
      result[other] = previous
    end
    return result
  end

  ---------------------------------------------------------------------------
  -- session_config.json: the running co-op's live seats. The runtime polls it
  -- and reconciles it with the active party, so only seats that already exist
  -- are edited, and Player 1's character is never moved.

  M.SESSION_CONFIG_VERSION = 1

  function M.sessionSeats(doc)
    if not json.isObject(doc) or doc.version ~= M.SESSION_CONFIG_VERSION or not json.isObject(doc.players) then
      return nil
    end
    local seats = {}
    for _, player in ipairs(M.PLAYERS) do
      local seat = doc.players[player]
      local id = json.isObject(seat) and seat.party_member_id or nil
      seats[player] = isInteger(id) and id or nil
    end
    return seats
  end

  -- Returns true when the live seat was changed, or false and a reason.
  function M.seatLive(doc, role, member)
    assert(role == "p2" or role == "p3", "role must be 'p2' or 'p3'")
    local seats = M.sessionSeats(doc)
    if not seats then return false, "no running co-op session file" end
    if member == nil then return false, "an empty seat applies from the next start" end
    if seats.p1 == member then return false, "Player 1 is controlling that character" end
    if seats[role] == nil or not json.isObject(doc.players[role]) then
      return false, "that seat is not part of the running session"
    end
    if seats[role] == member then return true end
    local other = role == "p2" and "p3" or "p2"
    if seats[other] == member then
      json.set(doc.players[other], "party_member_id", seats[role])
    end
    json.set(doc.players[role], "party_member_id", member)
    return true
  end

  function M.writeRoster(roster)
    local doc = json.object()
    json.set(doc, "version", M.ROSTER_CONFIG_VERSION)
    json.set(doc, "start_with_all", roster.startWithAll == true)
    local players = json.object()
    json.set(players, "p2", roster.p2 == nil and json.null or roster.p2)
    json.set(players, "p3", roster.p3 == nil and json.null or roster.p3)
    json.set(doc, "players", players)
    local names = json.object()
    for _, role in ipairs({"p2", "p3"}) do
      if roster[role] ~= nil then json.set(names, role, rosterNames[roster[role]]) end
    end
    json.set(doc, "names", names)
    return doc
  end

  ---------------------------------------------------------------------------
  -- menu_theme_config.json (menu_themes._selection_from_payload)

  local presetSet = {}
  for _, name in ipairs(M.PRESETS) do presetSet[name] = true end

  function M.normalizeThemeName(value, fallback)
    fallback = fallback or "gold"
    if value == nil or value == json.null or value == false or value == "" or value == 0 then
      value = ""
    end
    local name = string.lower((pythonStr(value):gsub("^%s+", ""):gsub("%s+$", ""))):gsub("-", "_")
    name = M.THEME_ALIASES[name] or name
    if presetSet[name] then return name end
    return fallback
  end

  local function partyMemberId(label)
    local text = string.lower((pythonStr(label):gsub("^%s+", ""):gsub("%s+$", "")))
    if M.PARTY_MEMBER_IDS[text] ~= nil then return M.PARTY_MEMBER_IDS[text] end
    local number
    if text:match("^0[xX]%x+$") then number = tonumber(text:sub(3), 16)
    elseif text:match("^0[oO][0-7]+$") then number = tonumber(text:sub(3), 8)
    elseif text:match("^0[bB][01]+$") then number = tonumber(text:sub(3), 2)
    elseif text:match("^[-+]?[1-9]%d*$") or text:match("^[-+]?0+$") then number = tonumber(text)
    end
    if number and number >= 0 and number <= 255 then return math.tointeger(number) end
    return nil
  end

  local function defaultTheme()
    local result = {mode = "character", players = {p1 = "sapphire", p2 = "emerald", p3 = "bronze"}, characters = {}}
    for _, character in ipairs(M.MAIN_CHARACTERS) do result.characters[character.name] = character.theme end
    return result
  end

  -- normalize_assignment_mode; nil means the loader rejects the whole file.
  local function themeMode(doc)
    if not json.isObject(doc) then return nil end
    local mode = doc.assignment_mode
    if mode == nil then return "character" end
    if mode == json.null or mode == false or mode == 0 then mode = "" end
    mode = string.lower(strip(pythonStr(mode))):gsub("-", "_")
    if mode == "character" or mode == "player" then return mode end
    return nil
  end

  function M.readTheme(doc)
    local mode = themeMode(doc)
    if mode == nil then return defaultTheme() end
    local defaultsObject = field(doc, "defaults")
    local function raw(key)
      local value = field(defaultsObject, key)
      if value == nil then value = doc[key] end
      return value
    end
    local result = {mode = mode, players = {}, characters = {}}
    result.players.p1 = M.normalizeThemeName(raw("player_1"), "sapphire")
    result.players.p2 = M.normalizeThemeName(raw("player_2"), "gold")
    local rawP3 = field(defaultsObject, "player_3")
    if rawP3 == nil then rawP3 = doc.player_3 end
    if rawP3 == nil then rawP3 = raw("player_2") end
    result.players.p3 = M.normalizeThemeName(rawP3, result.players.p2)
    local overrides = {}
    local characters = doc.characters
    if json.isObject(characters) then
      for _, label in ipairs(json.keys(characters)) do
        local id = partyMemberId(label)
        if id ~= nil then overrides[id] = M.normalizeThemeName(characters[label]) end
      end
    end
    for _, character in ipairs(M.MAIN_CHARACTERS) do
      result.characters[character.name] = overrides[character.id] or character.theme
    end
    return result
  end

  local function themeDocument(doc)
    if themeMode(doc) ~= nil then return doc end
    local fresh = json.object()
    local current = defaultTheme()
    json.set(fresh, "version", M.THEME_CONFIG_VERSION)
    json.set(fresh, "assignment_mode", current.mode)
    local defaultsObject = json.object()
    json.set(defaultsObject, "player_1", current.players.p1)
    json.set(defaultsObject, "player_2", current.players.p2)
    json.set(defaultsObject, "player_3", current.players.p3)
    json.set(fresh, "defaults", defaultsObject)
    local characters = json.object()
    for _, character in ipairs(M.MAIN_CHARACTERS) do json.set(characters, character.name, character.theme) end
    json.set(fresh, "characters", characters)
    local presets = json.array()
    for i, name in ipairs(M.PRESETS) do presets[i] = name end
    json.set(fresh, "available_presets", presets)
    return fresh
  end

  -- key: mode | player:<p1|p2|p3> | character:<Name>
  function M.setTheme(doc, key, value)
    doc = themeDocument(doc)
    if key == "mode" then
      assert(value == "character" or value == "player", "unsupported theme assignment mode")
      json.set(doc, "assignment_mode", value)
      return doc
    end
    assert(presetSet[value], "unknown theme preset")
    local player = key:match("^player:(p[123])$")
    if player then
      -- The value under "defaults" wins over a legacy top-level key.
      local defaultsObject = ensureObject(doc, "defaults")
      local current = M.readTheme(doc)
      if player == "p2" and field(defaultsObject, "player_3") == nil and doc.player_3 == nil then
        json.set(defaultsObject, "player_3", current.players.p3)
      end
      json.set(defaultsObject, "player_" .. player:sub(2), value)
      return doc
    end
    local name = key:match("^character:(.+)$")
    local target
    for _, character in ipairs(M.MAIN_CHARACTERS) do
      if character.name == name then target = character end
    end
    assert(target, "unknown character")
    local characters = ensureObject(doc, "characters")
    for _, label in ipairs(json.keys(characters)) do
      if label ~= target.name and partyMemberId(label) == target.id then json.remove(characters, label) end
    end
    json.set(characters, target.name, value)
    return doc
  end

  ---------------------------------------------------------------------------
  -- controller_config.json device ownership (controller_bindings / ControlEditor)

  -- normalize_device_assignment: nil | integer slot | sdl table
  function M.normalizeAssignment(value)
    if value == nil or value == json.null or type(value) == "boolean" then return nil end
    if isInteger(value) then
      if value >= 0 and value <= 3 then return value end
      return nil
    end
    if not json.isObject(value) or value.backend ~= "sdl" then return nil end
    local guid = value.guid
    if guid == nil then guid = "" end
    guid = string.lower(strip(pythonStr(guid)))
    if guid == "" then return nil end
    local ordinal = value.ordinal
    if ordinal == nil then ordinal = 0 end
    if type(ordinal) == "string" then
      local text = strip(ordinal)
      ordinal = text:match("^[-+]?%d+$") and tonumber(text) or nil
    elseif type(ordinal) == "number" then
      ordinal = ordinal >= 0 and math.floor(ordinal) or math.ceil(ordinal)
    elseif type(ordinal) == "boolean" then
      ordinal = ordinal and 1 or 0
    else
      ordinal = nil
    end
    if ordinal == nil or ordinal < 0 then return nil end
    local name = value.name
    if name == nil then name = "SDL controller" end
    local assignment = {backend = "sdl", guid = guid, ordinal = math.tointeger(ordinal), name = collapse(pythonStr(name))}
    if assignment.name == "" then assignment.name = "SDL controller" end
    local uid = value.uid
    if uid == nil then uid = "" end
    uid = string.lower(strip(pythonStr(uid)))
    if uid ~= "" then assignment.uid = uid:sub(1, 64) end
    return assignment
  end

  local function assignmentKey(assignment)
    if assignment == nil then return nil end
    if isInteger(assignment) then return "xinput:" .. assignment end
    if assignment.uid then return "sdl-uid:" .. assignment.uid end
    return "sdl:" .. assignment.guid .. ":" .. assignment.ordinal
  end

  local function sdlMatch(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    if left.uid and right.uid then return left.uid == right.uid end
    return left.guid == right.guid and left.ordinal == right.ordinal
  end

  local function aliases(doc)
    local result, claimed = {}, {}
    local list = field(doc, "device_aliases")
    if not json.isArray(list) then return result end
    for _, candidate in ipairs(list) do
      if json.isObject(candidate) and isInteger(candidate.xinput)
        and candidate.xinput >= 0 and candidate.xinput <= 3 then
        local sdl = M.normalizeAssignment(candidate.sdl)
        if type(sdl) == "table" then
          local duplicate = false
          for _, other in ipairs(claimed) do if sdlMatch(sdl, other) then duplicate = true end end
          if not duplicate then
            result[#result + 1] = {xinput = candidate.xinput, sdl = sdl}
            claimed[#claimed + 1] = sdl
          end
        end
      end
    end
    return result
  end

  local function identityKeys(doc, assignment)
    local key = assignmentKey(assignment)
    local keys = {}
    if key == nil then return keys end
    keys[key] = true
    for _, alias in ipairs(aliases(doc)) do
      local xinputKey = "xinput:" .. alias.xinput
      if key == xinputKey then
        keys[assignmentKey(alias.sdl)] = true
      elseif type(assignment) == "table" and sdlMatch(assignment, alias.sdl) then
        keys[xinputKey] = true
      end
    end
    return keys
  end

  function M.assignmentsOverlap(doc, left, right)
    if type(left) == "table" and type(right) == "table" and sdlMatch(left, right) then return true end
    local leftKeys = identityKeys(doc, left)
    for key in pairs(identityKeys(doc, right)) do
      if leftKeys[key] then return true end
    end
    return false
  end

  function M.controllersEditable(doc)
    return json.isObject(doc) and isInteger(doc.version) and doc.version == M.CONTROLLER_CONFIG_VERSION
      and json.isObject(doc.devices) and json.isObject(doc.players)
  end

  -- Display view after the loader's duplicate repair.
  function M.readControllers(doc)
    local devices = {p1 = 0, p2 = nil, p3 = nil}
    local supplied = field(doc, "devices")
    if json.isObject(supplied) then
      -- The loader's extra "p3 missing" repair can only ever restore p3's
      -- default (None), which a missing key already yields here.
      for _, player in ipairs(M.PLAYERS) do
        if supplied[player] ~= nil then devices[player] = M.normalizeAssignment(supplied[player]) end
      end
    end
    local claimed = {}
    for _, player in ipairs(M.PLAYERS) do
      local assignment = devices[player]
      if assignment ~= nil then
        for _, current in ipairs(claimed) do
          if M.assignmentsOverlap(doc, assignment, current) then assignment = nil break end
        end
        devices[player] = assignment
        if assignment ~= nil then claimed[#claimed + 1] = assignment end
      end
    end
    local desktop = field(doc, "desktop")
    local owner
    if json.isObject(desktop) then
      for _, player in ipairs(M.PLAYERS) do
        if owner == nil and desktop[player] == true then owner = player end
      end
    end
    return {devices = devices, desktopOwner = owner}
  end

  local function assignmentValue(assignment)
    if assignment == nil then return json.null end
    if isInteger(assignment) then return assignment end
    local object = json.object()
    json.set(object, "backend", "sdl")
    json.set(object, "guid", assignment.guid)
    json.set(object, "ordinal", assignment.ordinal)
    json.set(object, "name", assignment.name)
    if assignment.uid then json.set(object, "uid", assignment.uid) end
    return object
  end

  local function rewriteBindingIndices(doc, player, assignment)
    if assignment == nil then return end
    local index = isInteger(assignment) and assignment or 0
    local actions = doc.players[player]
    if not json.isObject(actions) then return end
    for _, action in ipairs(json.keys(actions)) do
      local values = actions[action]
      if json.isArray(values) then
        local hasPad = false
        for _, binding in ipairs(values) do
          if json.isObject(binding) and binding.device == "xinput" then
            json.set(binding, "index", index)
            hasPad = true
          end
        end
        local control = defaults.padControls[player] and defaults.padControls[player][action]
        if not hasPad and control ~= nil then
          for i = #values, 3, -1 do values[i] = nil end
          local binding = json.object()
          json.set(binding, "device", "xinput")
          json.set(binding, "index", index)
          json.set(binding, "control", control)
          values[#values + 1] = binding
        end
      end
    end
  end

  -- ControlEditor.assign_controller; returns the displaced role, if any.
  function M.assignController(doc, player, assignment)
    assert(M.controllersEditable(doc), "controller config is not editable")
    assert(player == "p1" or player == "p2" or player == "p3", "unknown player")
    local devices = doc.devices
    local previous = M.normalizeAssignment(devices[player])
    local displaced = previous
    if M.assignmentsOverlap(doc, previous, assignment) then displaced = nil end
    local displacedRole
    if assignment ~= nil then
      for _, role in ipairs(M.PLAYERS) do
        if role ~= player and M.assignmentsOverlap(doc, M.normalizeAssignment(devices[role]), assignment) then
          if displacedRole == nil then
            displacedRole = role
            json.set(devices, role, assignmentValue(displaced))
            rewriteBindingIndices(doc, role, displaced)
          else
            json.set(devices, role, json.null)
          end
        end
      end
    end
    json.set(devices, player, assignmentValue(assignment))
    rewriteBindingIndices(doc, player, assignment)
    return displacedRole
  end

  ---------------------------------------------------------------------------
  -- Live co-op on/off. The runtime gives Player 2/3 manual control only while
  -- they own a pad or the keyboard (configured_follower_control_mask) and
  -- follows controller_config.json live; with neither follower playing it
  -- drops follower movement and the shared camera (coop_lifecycle_flags).

  M.AWAY_VERSION = 1

  function M.followersPlaying(doc)
    local view = M.readControllers(doc)
    local playing = {}
    for _, player in ipairs({"p2", "p3"}) do
      playing[player] = view.devices[player] ~= nil or view.desktopOwner == player
    end
    return playing
  end

  -- Removes Player 2/3 input sources; returns the record needed to bring them
  -- back, or nil when nobody was playing.
  function M.sendFollowersAway(doc)
    local view = M.readControllers(doc)
    local playing = M.followersPlaying(doc)
    if not playing.p2 and not playing.p3 then return nil end
    local away = json.object()
    json.set(away, "version", M.AWAY_VERSION)
    for _, player in ipairs({"p2", "p3"}) do
      json.set(away, player, assignmentValue(view.devices[player]))
      if view.devices[player] ~= nil then M.assignController(doc, player, nil) end
    end
    local desktop = (view.desktopOwner == "p2" or view.desktopOwner == "p3") and view.desktopOwner or nil
    json.set(away, "desktop", desktop or json.null)
    if desktop then M.setDesktopOwner(doc, nil) end
    return away
  end

  -- Restores a record from sendFollowersAway. Returns the players restored and
  -- the reasons for any that could not be (Player 1's input is never taken).
  function M.bringFollowersBack(doc, away)
    if not json.isObject(away) or away.version ~= M.AWAY_VERSION then return {}, {"no saved co-op players"} end
    local restored, skipped = {}, {}
    for _, player in ipairs({"p2", "p3"}) do
      local assignment = M.normalizeAssignment(away[player])
      if assignment ~= nil then
        local ok, reason = M.controllerChangeKeepsP1(doc, player, assignment)
        if ok then
          for _, other in ipairs(M.PLAYERS) do
            if other ~= player and M.assignmentsOverlap(doc, M.normalizeAssignment(doc.devices[other]), assignment) then
              ok, reason = false, "that pad is now used by Player " .. other:sub(2)
            end
          end
        end
        if ok then
          -- Going away left the bindings untouched, so putting the device
          -- back restores exactly what was there (no index rewrite).
          json.set(doc.devices, player, assignmentValue(assignment))
          restored[#restored + 1] = player
        else
          skipped[#skipped + 1] = "Player " .. player:sub(2) .. ": " .. reason
        end
      end
    end
    local desktop = away.desktop
    if desktop == "p2" or desktop == "p3" then
      local ok, reason = M.desktopChangeKeepsP1(doc, desktop)
      if ok then
        M.setDesktopOwner(doc, desktop)
        restored[#restored + 1] = desktop .. " keyboard"
      else
        skipped[#skipped + 1] = reason
      end
    end
    return restored, skipped
  end

  function M.setDesktopOwner(doc, owner)
    assert(M.controllersEditable(doc), "controller config is not editable")
    assert(owner == nil or owner == "p1" or owner == "p2" or owner == "p3", "unknown player")
    local desktop = json.object()
    for _, player in ipairs(M.PLAYERS) do json.set(desktop, player, player == owner) end
    json.set(doc, "desktop", desktop)
  end

  -- The person using the Mod Menu is Player 1; a live change that takes
  -- their pad or keyboard away leaves nobody able to undo it.
  function M.controllerChangeKeepsP1(doc, player, assignment)
    if player == "p1" then return false, "Player 1's controller can only be changed in IvaliceTogetherConfig.exe" end
    local p1 = M.normalizeAssignment(field(field(doc, "devices"), "p1"))
    if assignment ~= nil and M.assignmentsOverlap(doc, p1, assignment) then
      return false, "that pad belongs to Player 1; change it in IvaliceTogetherConfig.exe"
    end
    return true
  end

  function M.desktopChangeKeepsP1(doc, owner)
    if M.readControllers(doc).desktopOwner == "p1" and owner ~= "p1" then
      return false, "Player 1 uses the keyboard and mouse; change that in IvaliceTogetherConfig.exe"
    end
    return true
  end

  return M
end
