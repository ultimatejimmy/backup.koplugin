import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT_PATH = pathlib.Path(__file__).parents[1] / "tools" / "sync_translations.py"
SPEC = importlib.util.spec_from_file_location("sync_translations", SCRIPT_PATH)
sync_translations = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync_translations)

class SyncTranslationTests(unittest.TestCase):
    def test_po_round_trip_is_byte_stable(self):
        translations = {
            "btn_create": "Létrehozás",
        }
        en_final = {
            "btn_create": "Create",
        }
        with tempfile.TemporaryDirectory(dir=SCRIPT_PATH.parent) as directory:
            path = pathlib.Path(directory) / "hu.po"
            sync_translations.save_po(
                path, "Hungarian", "hu", translations.keys(), translations, {}, en_final
            )
            first = path.read_bytes()
            parsed = {
                entry["msgid"]: entry["msgstr"]
                for entry in sync_translations.parse_po(path)
                if entry["msgid"]
            }
            sync_translations.save_po(
                path, "Hungarian", "hu", parsed.keys(), parsed, {}, en_final
            )
            self.assertEqual(first, path.read_bytes())

    def test_provider_validation_rejects_english_fallback(self):
        requested = {
            "btn_restore": "Restore",
        }
        errors = sync_translations.validate_translations(
            "hu", requested, {"btn_restore": "Restore"}
        )
        self.assertTrue(errors)

    def test_provider_validation_rejects_changed_format_specifier(self):
        requested = {
            "msg_source_dir_missing": "Source directory does not exist: %s",
        }
        errors = sync_translations.validate_translations(
            "hu",
            requested,
            {"msg_source_dir_missing": "A forráskönyvtár nem létezik."},
        )
        self.assertTrue(errors)

    def test_fallback_scraper_unescapes_lua_quotes(self):
        val = 'Created backup \\"%s\\".'
        unescaped = val.replace('\\"', '"').replace('\\\\', '\\')
        self.assertEqual(unescaped, 'Created backup "%s".')
        encoded = sync_translations.encode_po_string(unescaped)
        self.assertEqual(encoded, 'Created backup \\"%s\\".')

if __name__ == "__main__":
    unittest.main()
