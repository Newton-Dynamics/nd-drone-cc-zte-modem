#!/usr/bin/env python3
# Unit tests for nd-modem-registry (lookup + mutation + validation).
# Run: python3 tests/test_registry.py     (stdlib unittest, no deps)
import importlib.util
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("reg", os.path.join(ROOT, "nd-modem-registry.py"))
reg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reg)


class RegistryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.tmp.close()
        os.unlink(self.tmp.name)  # start with a non-existent file
        self.path = self.tmp.name

    def tearDown(self):
        if os.path.exists(self.path):
            os.unlink(self.path)

    def test_missing_file_is_empty(self):
        data = reg.load(self.path)
        self.assertEqual(data["sticks"], [])
        self.assertEqual(data["sims"], [])

    def test_add_and_lookup_stick(self):
        reg.add_stick("350000000000001", "pw1", "A", self.path)
        self.assertEqual(reg.lookup_stick_password("350000000000001", self.path), "pw1")
        self.assertIsNone(reg.lookup_stick_password("999", self.path))

    def test_add_and_lookup_sim(self):
        reg.add_sim("262011234567890", "1234", "vf", self.path)
        self.assertEqual(reg.lookup_sim_pin("262011234567890", self.path), "1234")
        self.assertIsNone(reg.lookup_sim_pin("000", self.path))

    def test_update_overwrites_password(self):
        reg.add_stick("350000000000001", "old", path=self.path)
        reg.add_stick("350000000000001", "new", path=self.path)
        self.assertEqual(reg.lookup_stick_password("350000000000001", self.path), "new")
        self.assertEqual(len(reg.load(self.path)["sticks"]), 1)

    def test_invalid_imei_rejected(self):
        with self.assertRaises(reg.RegistryError):
            reg.add_stick("not-a-number", "pw", path=self.path)

    def test_invalid_pin_rejected(self):
        with self.assertRaises(reg.RegistryError):
            reg.add_sim("262011234567890", "12", path=self.path)   # too short
        with self.assertRaises(reg.RegistryError):
            reg.add_sim("262011234567890", "abcd", path=self.path)  # not numeric

    def test_empty_password_rejected(self):
        with self.assertRaises(reg.RegistryError):
            reg.add_stick("350000000000001", "", path=self.path)

    def test_remove(self):
        reg.add_stick("350000000000001", "pw", path=self.path)
        self.assertEqual(reg.rm_stick("350000000000001", self.path), 1)
        self.assertEqual(reg.rm_stick("350000000000001", self.path), 0)

    def test_record_login_and_last_imei(self):
        reg.add_stick("350000000000002", "pw2", path=self.path)
        reg.record_login("192.168.0.1", "350000000000002", "2026-06-18T22:00:00+00:00", self.path)
        self.assertEqual(reg.last_imei_for_host("192.168.0.1", self.path), "350000000000002")
        self.assertIsNone(reg.last_imei_for_host("10.0.0.1", self.path))
        # last_seen propagated onto the stick row
        row = [s for s in reg.load(self.path)["sticks"] if s["imei"] == "350000000000002"][0]
        self.assertEqual(row["last_seen"], "2026-06-18T22:00:00+00:00")

    def test_seen_sim_updates_last_seen(self):
        reg.add_sim("262011234567890", "1234", path=self.path)
        reg.seen_sim("262011234567890", "2026-06-18T23:00:00+00:00", self.path)
        row = reg.load(self.path)["sims"][0]
        self.assertEqual(row["last_seen"], "2026-06-18T23:00:00+00:00")

    def test_file_is_0600(self):
        reg.add_stick("350000000000001", "pw", path=self.path)
        mode = os.stat(self.path).st_mode & 0o777
        self.assertEqual(mode, 0o600, f"expected 0600, got {oct(mode)}")

    def test_public_view_masks_secrets(self):
        reg.add_stick("350000000000001", "supersecret", path=self.path)
        reg.add_sim("262011234567890", "1234", path=self.path)
        masked = reg.public_view(self.path, reveal=False)
        self.assertNotEqual(masked["sticks"][0]["password"], "supersecret")
        self.assertNotEqual(masked["sims"][0]["pin"], "1234")
        revealed = reg.public_view(self.path, reveal=True)
        self.assertEqual(revealed["sticks"][0]["password"], "supersecret")
        self.assertEqual(revealed["sims"][0]["pin"], "1234")


if __name__ == "__main__":
    unittest.main(verbosity=2)
