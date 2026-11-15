"""Regression tests; python -m unittest discover -s tests -v.
Set CONTEXT_SHELL=pwsh (or powershell) to exercise PowerShell instead of Bash.
All fixtures live in temporary CODEX_HOME directories.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = os.environ.get("CONTEXT_SHELL", "bash")


class UndoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "codex"
        self.home.mkdir()
        self.cfg = self.home / "config.toml"

    def run_script(self, *args, ok=True):
        if SHELL == "bash":
            command = ["bash", str(ROOT / "scripts/set-context.sh"), *args]
        else:
            mapping = {"--restore": "-Restore", "--value": "-Value",
                       "--dry-run": "-DryRun", "--status": "-Status"}
            command = [SHELL, "-NoProfile", "-File", str(ROOT / "scripts/set-context.ps1"),
                       *(mapping.get(a, a) for a in args)]
        result = subprocess.run(command, env={**os.environ, "CODEX_HOME": str(self.home)},
                                capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def records(self):
        return sorted(self.home.glob("config.toml.ctxundo-*"))

    def test_preserves_subsequent_other_settings(self):
        self.cfg.write_text('model = "test"\nmodel_context_window = 400000\nother = "old"\n')
        self.run_script()
        self.cfg.write_text(self.cfg.read_text().replace('"old"', '"new"') + 'added = true\n')
        self.run_script("--restore")
        self.assertEqual(self.cfg.read_text(), 'model = "test"\nmodel_context_window = 400000\nother = "new"\nadded = true\n')
        self.assertEqual(self.records(), [])

    def test_absent_initial_file_removed(self):
        self.run_script()
        self.run_script("--restore")
        self.assertFalse(self.cfg.exists())

    def test_absent_initial_file_preserves_new_settings(self):
        self.run_script()
        self.cfg.write_text(self.cfg.read_text() + 'other = true\n')
        self.run_script("--restore")
        self.assertEqual(self.cfg.read_text(), 'other = true\n')

    def test_original_missing_key_and_profile_unchanged(self):
        original = 'model = "test"\n[profiles.work]\nmodel_context_window = 200000\n'
        self.cfg.write_text(original)
        self.run_script()
        self.run_script("--restore")
        self.assertEqual(self.cfg.read_text(), original)

    def test_existing_empty_file_stays(self):
        self.cfg.write_text("")
        self.run_script()
        self.run_script("--restore")
        self.assertTrue(self.cfg.exists())
        self.assertEqual(self.cfg.read_text(), "")

    def test_external_target_change_conflicts(self):
        self.cfg.write_text('model_context_window = 400000\n')
        self.run_script()
        edited = 'model_context_window = 600000\nnew = true\n'
        self.cfg.write_text(edited)
        self.run_script("--restore", ok=False)
        self.assertEqual(self.cfg.read_text(), edited)
        self.assertEqual(len(self.records()), 1)

    def test_deleted_target_conflicts(self):
        self.run_script()
        self.cfg.write_text("other = true\n")
        self.run_script("--restore", ok=False)
        self.assertEqual(self.cfg.read_text(), "other = true\n")

    def test_identical_install_is_noop(self):
        self.cfg.write_text('model_context_window = 400000\n')
        self.run_script()
        records = self.records()
        self.run_script()
        self.assertEqual(self.records(), records)
        self.run_script("--restore")
        self.assertEqual(self.cfg.read_text(), 'model_context_window = 400000\n')

    def test_repeated_changes_stack_in_order(self):
        self.cfg.write_text('model_context_window = 400000\n')
        self.run_script("--value", "600000")
        self.run_script("--value", "800000")
        self.assertEqual(len(self.records()), 2)
        self.run_script("--restore")
        self.assertIn("600000", self.cfg.read_text())
        self.run_script("--restore")
        self.assertIn("400000", self.cfg.read_text())

    def test_legacy_backup_not_blindly_restored(self):
        self.cfg.write_text('model_context_window = 1000000\nother = "new"\n')
        (self.home / 'config.toml.ctxbak-20250101-010101').write_text('other = "old"\n')
        before = self.cfg.read_bytes()
        self.run_script("--restore", ok=False)
        self.assertEqual(self.cfg.read_bytes(), before)

    def test_dry_run_and_status_do_not_write(self):
        self.run_script("--dry-run")
        self.run_script("--status")
        self.assertEqual(list(self.home.iterdir()), [])
        self.run_script()
        before = self.cfg.read_bytes()
        self.run_script("--restore", "--dry-run")
        self.assertEqual(self.cfg.read_bytes(), before)
        self.assertEqual(len(self.records()), 1)

    def test_lock_refuses_without_deleting_other_lock(self):
        lock = self.home / "config.toml.ctxlock"
        lock.mkdir()
        self.run_script(ok=False)
        self.assertTrue(lock.exists())
        self.assertFalse(self.cfg.exists())

    def test_duplicate_key_refused(self):
        original = 'model_context_window = 400000\nmodel_context_window = 500000\n'
        self.cfg.write_text(original)
        self.run_script(ok=False)
        self.assertEqual(self.cfg.read_text(), original)
        self.assertEqual(self.records(), [])

    def test_corrupt_record_refused(self):
        self.run_script()
        (self.records()[0] / "applied").unlink()
        before = self.cfg.read_bytes()
        self.run_script("--restore", ok=False)
        self.assertEqual(self.cfg.read_bytes(), before)

    def test_crlf(self):
        original = b'model = "test"\r\nmodel_context_window = 400000 # old\r\nother = true\r\n'
        self.cfg.write_bytes(original)
        self.run_script()
        self.run_script("--restore")
        self.assertEqual(self.cfg.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
