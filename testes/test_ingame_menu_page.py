"""Drive the in-game page script against a fake Mod Menu and a temporary coop/ folder."""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

DEVELOPMENT = Path(__file__).resolve().parents[1]
SOURCE = DEVELOPMENT / "source"
SCRIPTS = DEVELOPMENT / "lua/scripts"
sys.path.insert(0, str(SOURCE))

import controller_bindings as controls  # noqa: E402
import coop_roster  # noqa: E402
import launcher_core  # noqa: E402
import menu_themes  # noqa: E402
import session_state  # noqa: E402

try:
    from lupa.lua55 import LuaRuntime
except ImportError:  # pragma: no cover - depends on the test environment
    LuaRuntime = None

FAKE_GAME = r"""
pages, shown, active, callbacks, timers, printed, dialogs = {}, {}, {}, {}, {}, {}, {}
addTableResults = addTableResults or {}
modmenu = {
  addTable = function(page)
    -- The real plugin caps a toggle at six options (ff12-modmenu.lua.dll).
    for _, row in ipairs(page.schema) do
      if row.type == "toggle" and #row.options > 6 then
        printed[#printed + 1] = "Mod Menu: Rejected: Too many options for control: " .. row.id
        return false
      end
    end
    local result = table.remove(addTableResults, 1)
    if result == nil then result = true end
    if result then pages[#pages + 1] = page end
    return result
  end,
  setValue = function(mod, id, value)
    -- Setting the row being changed from its own callback crashed the game.
    if id == inCallback then error("setValue on " .. id .. " inside its own callback") end
    shown[id] = value
  end,
  setActive = function(mod, id, value) active[id] = value end,
  registerCallback = function(mod, id, fn) callbacks[id] = fn end,
}
inits = {}
event = {executeAfterMs = function(ms, fn) timers[#timers + 1] = fn end,
  registerEventAsync = function(name, fn) if name == "onInitDone" then inits[#inits + 1] = fn end end}
dialog = {show = function(options) dialogs[#dialogs + 1] = options end}
print = function(text) printed[#printed + 1] = text end
-- Like the real menu: the row shows the pick, the callback runs, then the
-- frame's timers fire (each pending timer once).
function choose(id, value)
  shown[id] = value
  inCallback = id
  local ok, err = pcall(callbacks[id], "IvaliceTogether", id, value)
  inCallback = nil
  if not ok then error(err) end
  local pending = timers
  timers = {}
  for _, fn in ipairs(pending) do fn() end
end
function tick() local fn = table.remove(timers, 1); if fn then fn() end end
function initDone() for _, fn in ipairs(inits) do fn() end end
function press(id) for _, row in ipairs(pages[#pages].schema) do if row.id == id then row.callback() end end end
"""


@unittest.skipIf(LuaRuntime is None, "requires lupa with Lua 5.5")
class InGameMenuPageTests(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        shutil.copytree(SCRIPTS, self.root / "scripts")
        self.coop = self.root / "coop"
        self.coop.mkdir()
        # The page edits only the controller format of the installed runtime.
        version = LuaRuntime().execute(
            'local json = dofile(...) return dofile(select(2, ...))(json, dofile(select(3, ...))).CONTROLLER_CONFIG_VERSION',
            str(SCRIPTS / "IvaliceTogetherMenu/json.lua"), str(SCRIPTS / "IvaliceTogetherMenu/model.lua"),
            str(SCRIPTS / "IvaliceTogetherMenu/defaults.lua"))
        controller = controls.normalize_config(controls.default_config())
        controller["version"] = version
        (self.coop / "controller_config.json").write_text(json.dumps(controller, indent=2) + "\n", encoding="utf-8")
        coop_roster.save(coop_roster.default_roster(), self.coop / "coop_roster_config.json")
        # A running session: P1 Vaan, P2 Basch, P3 Balthier (the roster defaults).
        session_state.save_identity(session_state.SessionIdentity(0, 4, 3, 3), self.coop / "session_config.json")
        launcher_core.save_launcher_config(dict(launcher_core.DEFAULT_LAUNCHER_CONFIG), self.coop / "launcher_config.json")
        menu_themes.save_selection(menu_themes.default_selection(), self.coop / "menu_theme_config.json")
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)

    def start(self, add_results=()):
        lua = LuaRuntime(unpack_returned_tuples=True)
        table = lua.table_from(list(add_results))
        lua.globals().addTableResults = table
        lua.execute(FAKE_GAME)
        source = (self.root / "scripts/IvaliceTogetherMenu.lua").read_text(encoding="utf-8")
        lua.execute(source)
        return lua

    def read(self, name):
        return json.loads((self.coop / name).read_text(encoding="utf-8"))

    def test_page_registers_and_shows_current_settings(self) -> None:
        lua = self.start()
        g = lua.globals()
        self.assertEqual(len(g.pages), 1)
        ids = [row.id for row in g.pages[1].schema.values() if row.id]
        self.assertIn("theme_Vaan", ids)
        self.assertEqual(g.shown["roster_p2"], 2)  # Basch
        self.assertEqual(g.shown["roster_p3"], 0)  # Balthier
        self.assertEqual(g.shown["pad_p1"], 1)  # Pad 1
        self.assertEqual(g.shown["desktop"], 2)  # Player 2
        self.assertEqual(g.shown["theme_p2"], menu_themes.PRESETS and list(menu_themes.PRESETS).index("emerald"))
        self.assertEqual(g.shown["coopEnabled"], 0)
        self.assertFalse(g.active["pad_p1"])
        self.assertTrue(g.active["pad_p2"])
        self.assertIn("Ivalice Together menu: page ready.", list(g.printed.values()))

    def test_choices_write_files_the_runtime_reads(self) -> None:
        lua = self.start()
        g = lua.globals()
        g.choose("roster_p3", 2)  # Basch moves from P2 to P3: the seats swap
        roster = coop_roster.load(self.coop / "coop_roster_config.json")
        self.assertEqual((roster.p2, roster.p3), (coop_roster.BALTHIER_ID, coop_roster.BASCH_ID))
        self.assertEqual(g.shown["roster_p2"], 0)  # refreshed: Balthier
        live = session_state.load_config(self.coop / "session_config.json")["players"]
        self.assertEqual((live["p2"]["party_member_id"], live["p3"]["party_member_id"]), (3, 4))

        g.choose("pad_p2", 3)  # P2 takes the free Pad 3
        devices = controls.load_config(self.coop / "controller_config.json")["devices"]
        self.assertEqual((devices["p1"], devices["p2"]), (0, 2))
        g.choose("pad_p3", 3)  # P3 takes Pad 3; P2 gets P3's previous (none)
        devices = controls.load_config(self.coop / "controller_config.json")["devices"]
        self.assertEqual((devices["p2"], devices["p3"]), (None, 2))
        self.assertEqual(g.shown["pad_p2"], 0)

        g.choose("desktop", 3)
        self.assertEqual(controls.desktop_owner(controls.load_config(self.coop / "controller_config.json")), "p3")

        g.choose("themeMode", 1)
        g.choose("theme_Vaan", list(menu_themes.PRESETS).index("ruby"))
        selection = menu_themes.load_selection(self.coop / "menu_theme_config.json")
        self.assertEqual(selection.assignment_mode, "player")
        self.assertEqual(selection.for_character(0), "ruby")

        g.choose("battleSound_p3", 1)
        g.choose("damageMeter", 0)
        g.choose("damageMeterMode", 1)
        config = launcher_core.load_launcher_config(self.coop / "launcher_config.json")
        self.assertFalse(config["battle_menu_sounds"]["p3"])
        self.assertTrue(config["damage_meter_enabled"])
        self.assertEqual(config["damage_meter_mode"], "indefinite")

        g.press("resetDamage")
        self.assertEqual(len(g.dialogs), 1)
        g.dialogs[1].onClose(0)
        self.assertEqual(launcher_core.load_launcher_config(self.coop / "launcher_config.json")["damage_meter_session_id"], 2)
        self.assertFalse(list(self.coop.glob("*.menu.tmp")))

    def test_character_seats_change_live_where_possible(self) -> None:
        lua = self.start()
        g = lua.globals()
        path = self.coop / "session_config.json"
        def seats():
            players = session_state.load_config(path)["players"]
            return tuple(players[p]["party_member_id"] for p in ("p1", "p2", "p3"))
        g.choose("roster_p2", 1)  # Fran into P2's seat, live
        self.assertEqual(seats(), (0, 2, 3))
        self.assertEqual(coop_roster.load(self.coop / "coop_roster_config.json").p2, coop_roster.FRAN_ID)
        g.choose("roster_p2", 5)  # Nobody: next start only
        self.assertEqual(seats(), (0, 2, 3))
        self.assertIsNone(coop_roster.load(self.coop / "coop_roster_config.json").p2)
        self.assertTrue(any("saved for the next start" in t for t in g.printed.values()))
        session_state.save_identity(session_state.SessionIdentity(4, 2, 3, 3), path)  # P1 now leads as Basch
        g.choose("roster_p3", 2)  # Basch is Player 1's character: roster only
        self.assertEqual(seats(), (4, 2, 3))
        self.assertTrue(any("Player 1 is controlling" in t for t in g.printed.values()))
        path.unlink()  # no running session: roster still saved
        g.choose("roster_p3", 4)
        self.assertEqual(coop_roster.load(self.coop / "coop_roster_config.json").p3, coop_roster.PENELO_ID)
        self.assertFalse(path.exists())

    def test_player_one_never_loses_their_input(self) -> None:
        lua = self.start()
        g = lua.globals()
        path = self.coop / "controller_config.json"
        self.assertFalse(g.active["pad_p1"])
        before = path.read_bytes()
        g.choose("pad_p1", 2)  # P1 moving to Pad 2
        g.choose("pad_p1", 0)  # P1 to no pad
        g.choose("pad_p2", 1)  # P2 taking P1's Pad 1
        g.choose("pad_p3", 1)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(g.shown["pad_p1"], 1)
        self.assertEqual(g.shown["pad_p2"], 0)  # display reverted
        self.assertEqual(sum("belongs to Player 1" in text or "only be changed" in text for text in g.printed.values()), 4)
        g.choose("desktop", 1)  # giving the keyboard to P1 is fine
        self.assertEqual(controls.desktop_owner(controls.load_config(path)), "p1")
        self.assertFalse(g.active["desktop"])
        after = path.read_bytes()
        g.choose("desktop", 2)  # but taking it from P1 is refused
        g.choose("desktop", 0)
        self.assertEqual(path.read_bytes(), after)
        self.assertEqual(g.shown["desktop"], 1)
        # Snapping a refused row back from its own callback crashed the game.
        self.assertFalse([t for t in g.printed.values() if "refresh failed" in t])

    def test_wide_rows_are_carousels(self) -> None:
        lua = self.start()
        rows = {row.id: row for row in lua.globals().pages[1].schema.values() if row.id}
        for row_id in ("roster_p2", "roster_p3", "pad_p1", "pad_p2", "pad_p3", "desktop"):
            self.assertEqual(rows[row_id].type, "carousel", row_id)

    def test_coop_switch_uses_the_runtime_marker(self) -> None:
        lua = self.start()
        g = lua.globals()
        marker = self.coop / "ivalice-together.disabled"
        g.choose("coopEnabled", 1)
        self.assertTrue(marker.is_file())
        self.assertEqual(lua.globals().shown["coopEnabled"], 1)
        g.choose("coopEnabled", 0)
        self.assertFalse(marker.exists())

    def test_other_pad_choice_changes_nothing(self) -> None:
        lua = self.start()
        before = (self.coop / "controller_config.json").read_bytes()
        lua.globals().choose("pad_p1", 5)
        self.assertEqual((self.coop / "controller_config.json").read_bytes(), before)
        self.assertEqual(lua.globals().shown["pad_p1"], 1)

    def test_unsupported_controller_format_disables_those_rows(self) -> None:
        path = self.coop / "controller_config.json"
        config = self.read("controller_config.json")
        config["version"] = config["version"] + 1
        path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        before = path.read_bytes()
        lua = self.start()
        g = lua.globals()
        self.assertFalse(g.active["pad_p1"])
        self.assertFalse(g.active["desktop"])
        g.choose("pad_p2", 2)
        self.assertEqual(path.read_bytes(), before)
        self.assertTrue(any("format this page does not edit" in text for text in g.printed.values()))

    def test_external_edits_are_picked_up_by_polling(self) -> None:
        lua = self.start()
        g = lua.globals()
        roster = coop_roster.CoopRoster(coop_roster.ASHE_ID, coop_roster.FRAN_ID, True)
        coop_roster.save(roster, self.coop / "coop_roster_config.json")
        self.assertEqual(len(g.timers), 0)  # polling waits for the game to finish starting
        g.initDone()
        g.tick()
        self.assertEqual(g.shown["roster_p2"], 3)  # Ashe
        self.assertEqual(g.shown["roster_p3"], 1)  # Fran
        self.assertEqual(len(g.timers), 1)  # polling continues

    def test_compact_page_when_the_full_page_does_not_fit(self) -> None:
        lua = self.start(add_results=(False,))
        g = lua.globals()
        self.assertEqual(len(g.pages), 1)
        ids = [row.id for row in g.pages[1].schema.values() if row.id]
        self.assertNotIn("theme_Vaan", ids)
        self.assertTrue(all(row.help is None for row in g.pages[1].schema.values()))
        g.choose("roster_p2", 0)
        self.assertEqual(coop_roster.load(self.coop / "coop_roster_config.json").p2, coop_roster.BALTHIER_ID)

    def test_minimal_page_when_colors_do_not_fit(self) -> None:
        lua = self.start(add_results=(False, False))
        ids = [row.id for row in lua.globals().pages[1].schema.values() if row.id]
        self.assertFalse([i for i in ids if i.startswith("theme")])
        self.assertIn("pad_p1", ids)

    def test_color_rows_use_carousels(self) -> None:
        lua = self.start()
        rows = {row.id: row for row in lua.globals().pages[1].schema.values() if row.id}
        self.assertEqual(rows["theme_p1"].type, "carousel")
        self.assertEqual(rows["theme_Vaan"].type, "carousel")
        self.assertTrue(all(len(row.options) <= 6 for row in rows.values() if row.type == "toggle"))
        self.assertFalse(any("Rejected" in text for text in lua.globals().printed.values()))

    def test_no_coop_folder_registers_nothing(self) -> None:
        shutil.rmtree(self.coop)
        lua = self.start()
        self.assertEqual(len(lua.globals().pages), 0)


if __name__ == "__main__":
    unittest.main()
