"""The in-game Lua configuration page must agree with the Python loaders.

Every reader is compared with the matching Python normalizer, and every
writer's output is loaded back through Python.  The Lua code runs in Lua 5.5,
the version embedded in the game's Lua loader.
"""

from __future__ import annotations

import copy
import itertools
import json
import random
import sys
import tempfile
import unittest
from pathlib import Path

DEVELOPMENT = Path(__file__).resolve().parents[1]
SOURCE = DEVELOPMENT / "source"
MENU = DEVELOPMENT / "lua/scripts/IvaliceTogetherMenu"
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(DEVELOPMENT / "ferramentas"))

import controller_bindings as controls  # noqa: E402
import coop_roster  # noqa: E402
import launcher_core  # noqa: E402
import menu_themes  # noqa: E402
import session_state  # noqa: E402

try:
    from lupa.lua55 import LuaRuntime
except ImportError:  # pragma: no cover - depends on the test environment
    LuaRuntime = None


def dumps(payload) -> str:
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


@unittest.skipIf(LuaRuntime is None, "requires lupa with Lua 5.5")
class InGameMenuLuaTests(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        load = self.lua.eval(
            "function(path) return assert(loadfile(path, 't'))() end"
        )
        self.json = load(str(MENU / "json.lua"))
        self.model = load(str(MENU / "model.lua"))(
            self.json, load(str(MENU / "defaults.lua"))
        )
        # The Python sources in this checkout define the controller format.
        self.model.CONTROLLER_CONFIG_VERSION = controls.CONFIG_VERSION
        self.encode = self.lua.eval("function(json, doc) return json.encode(doc) end")
        self.decode = self.lua.eval("function(json, text) return json.decode(text) end")

    def doc(self, payload):
        return self.decode(self.json, json.dumps(payload))

    def text(self, doc) -> str:
        return self.encode(self.json, doc)

    # -- JSON -------------------------------------------------------------

    def test_python_formatted_files_round_trip_byte_for_byte(self) -> None:
        samples = [
            controls.default_config(),
            launcher_core.DEFAULT_LAUNCHER_CONFIG,
            {"empty_object": {}, "empty_list": [], "null": None, "nested": [[], {}, [None]]},
            {"text": 'quote " slash \\ tab \t line \n bell \x07 del \x7f', "utf8": "Português ção 日本"},
            {"floats": [1.0, 0.5, 0.35, 1e-05, 1.5e-07, 1e16, 123456.789, -0.0, 0.1 + 0.2], "ints": [0, -7, 2**40]},
            {"bools": [True, False], "keys": {"z": 1, "a": 2, "m": 3}},
        ]
        for payload in samples:
            text = dumps(payload)
            self.assertEqual(self.text(self.decode(self.json, text)), text)

    def test_decoder_reads_escapes_and_rejects_garbage(self) -> None:
        doc = self.decode(self.json, '{"a": "\\u00e7\\ud83d\\ude00\\n", "b": [1, 2.5e3]}')
        self.assertEqual(json.loads(self.text(doc)), {"a": "ç😀\n", "b": [1, 2500.0]})
        bad = self.lua.eval("function(json, t) return pcall(json.decode, t) end")
        for text in ("", "{", '{"a" 1}', "[1,]", "nul", '{"a": 1} x', '"\x01"'):
            ok, _ = bad(self.json, text)
            self.assertFalse(ok, text)

    def test_generated_defaults_are_current(self) -> None:
        import gerar_padroes_menu_lua as generator

        self.assertEqual(
            (MENU / "defaults.lua").read_text(encoding="utf-8"), generator.render()
        )

    # -- launcher_config.json --------------------------------------------

    def launcher_view(self, payload):
        view = self.model.readLauncher(self.doc(payload) if payload is not None else None)
        return {
            "battle_menu_sounds": {p: bool(view.battleMenuSounds[p]) for p in ("p1", "p2", "p3")},
            "damage_meter_enabled": bool(view.damageMeter),
            "damage_meter_mode": view.damageMeterMode,
            "damage_meter_effective": bool(view.damageMeterEffective),
            "damage_meter_session_id": int(view.sessionId),
        }

    @staticmethod
    def python_launcher_view(payload):
        normalized = launcher_core.normalize_launcher_config(payload)
        return {key: normalized[key] for key in (
            "battle_menu_sounds", "damage_meter_enabled", "damage_meter_mode",
            "damage_meter_effective", "damage_meter_session_id")}

    def test_launcher_reader_matches_python(self) -> None:
        cases = [
            None, [], {},
            launcher_core.DEFAULT_LAUNCHER_CONFIG,
            {"battle_menu_sounds": {"p1": False, "p2": 0, "p3": "x"}, "damage_meter_enabled": 1},
            {"battle_menu_sounds": [], "damage_meter_mode": " Indefinite ", "damage_meter_effective": "yes"},
            {"damage_meter_mode": "nope", "damage_meter_session_id": "12"},
            {"damage_meter_session_id": 0}, {"damage_meter_session_id": 2**40},
            {"damage_meter_session_id": 7.9}, {"damage_meter_session_id": True},
            {"damage_meter_session_id": "1.5"}, {"damage_meter_session_id": None},
            {"damage_meter_enabled": None, "damage_meter_mode": None},
        ]
        for payload in cases:
            self.assertEqual(self.launcher_view(payload), self.python_launcher_view(payload), payload)

    def test_launcher_writer_changes_only_the_setting(self) -> None:
        base = dict(launcher_core.DEFAULT_LAUNCHER_CONFIG, language="pt", sound_volume=0.35)
        base["battle_menu_sounds"] = {"p1": True, "p2": True, "p3": True}
        operations = [
            ("battleMenuSound:p2", False, lambda c: c["battle_menu_sounds"].__setitem__("p2", False)),
            ("damageMeter", True, lambda c: c.__setitem__("damage_meter_enabled", True)),
            ("damageMeterMode", "indefinite", lambda c: c.__setitem__("damage_meter_mode", "indefinite")),
            ("damageMeterEffective", True, lambda c: c.__setitem__("damage_meter_effective", True)),
            ("resetDamageSession", None, lambda c: c.__setitem__("damage_meter_session_id", c["damage_meter_session_id"] + 1)),
        ]
        for key, value, change in operations:
            doc = self.model.setLauncher(self.doc(base), key, value)
            expected = copy.deepcopy(base)
            change(expected)
            self.assertEqual(json.loads(self.text(doc)), expected, key)
        doc = self.model.setLauncher(self.doc(dict(base, damage_meter_session_id=0x7FFFFFFF)), "resetDamageSession", None)
        self.assertEqual(json.loads(self.text(doc))["damage_meter_session_id"], 1)
        # An unreadable file is replaced by the Python defaults plus the change.
        doc = self.model.setLauncher(None, "damageMeter", True)
        self.assertEqual(json.loads(self.text(doc)), dict(launcher_core.DEFAULT_LAUNCHER_CONFIG, damage_meter_enabled=True))

    # -- coop_roster_config.json -----------------------------------------

    def roster_view(self, payload):
        view = self.model.readRoster(self.doc(payload) if payload is not None else None)
        return view.p2, view.p3, bool(view.startWithAll)

    def test_roster_reader_matches_python(self) -> None:
        values = [None, 0, 1, 2, 3, 4, 5, 6, -1, 3.9, "4", " 2 ", "x", True, False, [], {}]
        cases = [None, [], {}, {"players": []}, {"players": {}}]
        for p2, p3 in itertools.product(values, repeat=2):
            cases.append({"players": {"p2": p2, "p3": p3}, "start_with_all": True})
        cases += [{"players": {"p3": 4}}, {"players": {"p2": 3}, "start_with_all": 1}]
        for payload in cases:
            roster = coop_roster.normalize(payload)
            self.assertEqual(self.roster_view(payload), (roster.p2, roster.p3, roster.start_with_all), payload)

    def test_roster_writer_matches_python_save_byte_for_byte(self) -> None:
        options = [None, *coop_roster.SELECTABLE_MEMBER_IDS]
        write = self.lua.eval(
            "function(model, p2, p3, all, role, member) "
            "return model.writeRoster(model.assignRoster({p2=p2, p3=p3, startWithAll=all}, role, member)) end"
        )
        tmp = self.scratch / "roster.json"
        try:
            for p2, p3, all_, role, member in itertools.product(options, options, (True, False), ("p2", "p3"), options):
                if p2 is not None and p2 == p3:
                    continue
                expected = coop_roster.CoopRoster(p2, p3, all_).assign(role, member)
                coop_roster.save(expected, tmp)
                self.assertEqual(self.text(write(self.model, p2, p3, all_, role, member)), tmp.read_text(encoding="utf-8"))
        finally:
            tmp.unlink(missing_ok=True)

    def test_roster_swap_keeps_both_seats(self) -> None:
        swap = self.lua.eval(
            "function(model, p2, p3, role, member) local r = model.swapRoster({p2=p2, p3=p3, startWithAll=true}, role, member) return r.p2, r.p3 end")
        self.assertEqual(swap(self.model, 4, 3, "p3", 4), (3, 4))
        self.assertEqual(swap(self.model, 4, 3, "p2", 2), (2, 3))
        self.assertEqual(swap(self.model, None, 3, "p2", 3), (3, None))
        self.assertEqual(swap(self.model, 4, 3, "p2", None), (None, 3))

    # -- session_config.json ---------------------------------------------

    def test_live_seat_edits_load_through_python(self) -> None:
        seat = self.lua.eval(
            "function(model, doc, role, member) local ok, why = model.seatLive(doc, role, member) return ok, why end")
        tmp = self.scratch / "session_config.json"
        cases = [((0, 4, 3, 3), "p2", 3, (0, 3, 4)), ((0, 4, 3, 3), "p3", 2, (0, 4, 2)),
                 ((0, 4, 3, 3), "p2", 4, (0, 4, 3)), ((4, 2, 3, 3), "p3", 4, None),
                 ((0, 4, 3, 3), "p3", None, None), ((0, 4, None, 2), "p3", 2, None)]
        for (p1, p2, p3, count), role, member, expected in cases:
            session_state.save_identity(session_state.SessionIdentity(p1, p2, p3, count), tmp)
            doc = self.decode(self.json, tmp.read_text(encoding="utf-8"))
            ok, _ = seat(self.model, doc, role, member)
            identity = session_state.SessionIdentity.from_config(session_state.normalize_config(json.loads(self.text(doc))))
            seats = (identity.p1_party_member_id, identity.p2_party_member_id, identity.p3_party_member_id)
            if expected is None:
                self.assertFalse(ok, (p1, p2, p3, role, member))
                self.assertEqual(seats, (p1, p2, p3))
            else:
                self.assertTrue(ok)
                self.assertEqual(seats, expected)
        ok, _ = seat(self.model, self.doc({"version": 2, "players": {}}), "p2", 3)
        self.assertFalse(ok)

    # -- menu_theme_config.json ------------------------------------------

    def theme_view(self, payload):
        view = self.model.readTheme(self.doc(payload) if payload is not None else None)
        return (view.mode, view.players.p1, view.players.p2, view.players.p3,
                tuple(view.characters[c.name] for c in menu_themes.MAIN_CHARACTER_PROFILES))

    @staticmethod
    def python_theme_view(payload):
        try:
            selection = menu_themes._selection_from_payload(payload)
        except (TypeError, ValueError):
            selection = menu_themes.default_selection()
        return (selection.assignment_mode, selection.player_1, selection.player_2, selection.player_theme(3),
                tuple(selection.for_character(c.member_id) for c in menu_themes.MAIN_CHARACTER_PROFILES))

    def test_theme_reader_matches_python(self) -> None:
        saved = json.loads(dumps({
            "version": 3, "assignment_mode": "character",
            "defaults": {"player_1": "sapphire", "player_2": "emerald", "player_3": "bronze"},
            "characters": {"Vaan": "sapphire", "Basch": "emerald"},
        }))
        cases = [None, [], {}, saved,
                 {"assignment_mode": "Player"}, {"assignment_mode": "bad"}, {"assignment_mode": None},
                 {"assignment_mode": 3}, {"assignment_mode": "  character "},
                 {"player_1": "Rosa", "player_2": "dourado"}, {"defaults": {"player_2": "ruby"}},
                 {"defaults": {"player_1": "ruby"}, "player_1": "gold"},
                 {"defaults": {"player_3": None}}, {"defaults": [], "player_3": "pink"},
                 {"characters": {"vaan": "ruby", "0": "gold"}}, {"characters": {"0x3": "pink", "Fran": "nope"}},
                 {"characters": {"BASCH": "Esmeralda", "4": "ruby", "x": "gold", "300": "ruby"}},
                 {"characters": {"Ashe": None, "Penelo": 0, "Fran": ""}}, {"characters": []}]
        for payload in cases:
            self.assertEqual(self.theme_view(payload), self.python_theme_view(payload), payload)

    def test_theme_writer_round_trips_through_python(self) -> None:
        base = json.loads(dumps({
            "version": 3, "assignment_mode": "character",
            "defaults": {"player_1": "sapphire", "player_2": "emerald"},
            "characters": {"Vaan": "sapphire", "0": "gold", "Reks": "ruby"},
            "available_presets": list(menu_themes.PRESETS),
        }))
        for key, value in [("mode", "player"), ("player:p1", "ruby"), ("player:p2", "gold"),
                           ("player:p3", "pink"), ("character:Vaan", "bronze"), ("character:Penelo", "ruby")]:
            before = self.python_theme_view(base)
            after = self.python_theme_view(json.loads(self.text(self.model.setTheme(self.doc(base), key, value))))
            expected = list(before)
            characters = list(before[4])
            if key == "mode":
                expected[0] = value
            elif key.startswith("player:"):
                expected[int(key[-1])] = value
            else:
                name = key.split(":", 1)[1]
                index = [c.name for c in menu_themes.MAIN_CHARACTER_PROFILES].index(name)
                characters[index] = value
            expected[4] = tuple(characters)
            self.assertEqual(after, tuple(expected), key)
        # Guests and unknown keys survive an edit.
        edited = json.loads(self.text(self.model.setTheme(self.doc(base), "character:Vaan", "ruby")))
        self.assertEqual(edited["characters"].get("Reks"), "ruby")
        self.assertNotIn("0", edited["characters"])
        fresh = json.loads(self.text(self.model.setTheme(self.doc({"assignment_mode": "bad"}), "player:p1", "gold")))
        self.assertEqual(self.python_theme_view(fresh)[1], "gold")

    # -- controller_config.json ------------------------------------------

    def controller_fixtures(self):
        base = controls.default_config()
        sdl_a = controls.sdl_assignment("030003f05e0400008e02000000007200", 0, "Xbox 360  Controller", "1B49950E")
        sdl_b = controls.sdl_assignment("03000000c82d00000000000000000000", 1, "8BitDo", "")
        fixtures = [base]
        combinations = list(itertools.product([0, 1, 2, 3, None, "a", "b"], repeat=3))
        for devices in random.Random(12).sample(combinations, 40):
            config = copy.deepcopy(base)
            config["device_aliases"] = [{"xinput": 1, "sdl": sdl_a}, {"xinput": 2, "sdl": sdl_b}]
            config["devices"] = {p: (sdl_a if d == "a" else sdl_b if d == "b" else d) for p, d in zip(("p1", "p2", "p3"), devices)}
            fixtures.append(controls.normalize_config(config))
        stripped = copy.deepcopy(base)
        stripped["players"]["p2"]["confirm"] = [controls.key_binding(0x20), controls.key_binding(0x0D), controls.key_binding(0x01)]
        stripped["players"]["p3"]["menu_up"] = []
        fixtures.append(controls.normalize_config(stripped))
        return fixtures

    def test_controller_reader_matches_python(self) -> None:
        for config in self.controller_fixtures():
            normalized = controls.normalize_config(config)
            view = self.model.readControllers(self.doc(config))
            devices = {}
            for player in ("p1", "p2", "p3"):
                value = view.devices[player]
                devices[player] = None if value is None else value if isinstance(value, int) else dict(value)
            self.assertEqual(devices, normalized["devices"])
            self.assertEqual(view.desktopOwner, controls.desktop_owner(normalized))

    def test_controller_assignment_matches_control_editor(self) -> None:
        tmp = self.scratch / "controllers.json"
        try:
            for config in self.controller_fixtures():
                for player, target in itertools.product(("p1", "p2", "p3"), (None, 0, 1, 2, 3)):
                    controls.save_config(config, tmp)
                    editor = launcher_core.ControlEditor(tmp)
                    editor.assign_controller(player, target)
                    expected = controls.normalize_config(editor.config)
                    doc = self.doc(json.loads(tmp.read_text(encoding="utf-8")))
                    self.model.assignController(doc, player, target)
                    actual = controls.normalize_config(json.loads(self.text(doc)))
                    self.assertEqual(actual, expected, (config["devices"], player, target))
        finally:
            tmp.unlink(missing_ok=True)

    def test_desktop_owner_matches_python(self) -> None:
        for owner in (None, "p1", "p2", "p3"):
            config = controls.default_config()
            doc = self.doc(config)
            self.model.setDesktopOwner(doc, owner)
            controls.set_desktop_owner(config, owner)
            self.assertEqual(controls.normalize_config(json.loads(self.text(doc))), controls.normalize_config(config))

    def test_controller_edits_refuse_other_format_versions(self) -> None:
        config = controls.default_config()
        for version in (controls.CONFIG_VERSION - 1, controls.CONFIG_VERSION + 1, "x"):
            config["version"] = version
            self.assertFalse(self.model.controllersEditable(self.doc(config)))
        ok, _ = self.lua.eval("function(m, d) return pcall(m.assignController, d, 'p1', 1) end")(self.model, self.doc(config))
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
