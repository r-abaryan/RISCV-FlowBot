#!/usr/bin/env python3
"""Tests for scripts/check_rom_mapped.py using ROM-cell excerpts of the saved CI artifact (run 38646347121).
Run: python3 tests/rom_check/test_check_rom_mapped.py"""
import os, re, subprocess, sys, tempfile, unittest
R = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(os.path.dirname(R))
SCRIPT = os.path.join(ROOT, "scripts", "check_rom_mapped.py"); HEX = os.path.join(ROOT, "sw/firmware/robot_nav.hex")
REF = os.path.join(R, "fixtures/rom_ref_trimmed.il"); TOP = os.path.join(R, "fixtures/soc_top_rom_trimmed.il") + ":u_rom."

def run(hexf, *specs):
    p = subprocess.run([sys.executable, SCRIPT, hexf, *specs], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def mutated(path, fn):
    s = fn(open(path).read()); f = tempfile.NamedTemporaryFile("w", suffix=".il", delete=False); f.write(s); f.close()
    return f.name

class T(unittest.TestCase):
    def test_positive_both(self):
        rc, o = run(HEX, REF, TOP); self.assertEqual(rc, 0, o); self.assertIn("ROM_MAPPED_CONTENT_MATCH", o)
    def test_firmware_has_531_words(self):
        self.assertEqual(len(open(HEX).read().split()), 531)
    def test_regression_last_cell_not_polluted_by_module_defaults(self):
        # ref ROM cell 0.1 is the last cell before 'module \DP16KD'; scoping must keep it correct
        rc, o = run(HEX, REF); self.assertEqual(rc, 0, o)
    def test_neg_flipped_bit(self):
        def f(s):  # flip lowest bit of first INITVAL_00 of cell rom_mem.0.0
            i = s.index("INITVAL_00 320'", s.index("\\rom_mem.0.0")); j = s.index("\n", i)
            line = s[i:j]; return s[:i] + line[:-1] + ("1" if line[-1] == "0" else "0") + s[j:]
        rc, o = run(HEX, mutated(REF, f)); self.assertNotEqual(rc, 0); self.assertIn("rom_mem.0.0", o)
    def test_neg_zeroed_cell(self):  # the original symptom: a cell whose INITVALs are all zero
        def f(s):
            a = s.index("cell \\DP16KD \\u_rom.rom_mem.0.1"); b = s.index("  end", a)
            return s[:a] + re.sub(r"(INITVAL_[0-9A-F]+ 320')[01]+", lambda m: m.group(1) + "0" * 320, s[a:b]) + s[b:]
        rc, o = run(HEX, mutated(TOP.split(":")[0], f) + ":u_rom."); self.assertNotEqual(rc, 0); self.assertIn("rom_mem.0.1", o)
    def test_neg_missing_cell(self):
        def f(s):
            a = s.index("cell \\DP16KD \\rom_mem.0.2"); b = s.index("  end", a) + 5
            return s[:a] + s[b:]
        rc, o = run(HEX, mutated(REF, f)); self.assertNotEqual(rc, 0); self.assertIn("expected cells", o)
    def test_neg_wrong_firmware(self):
        w = open(HEX).read().split(); w[100] = "deadbeef"
        f = tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False); f.write("\n".join(w) + "\n"); f.close()
        rc, o = run(f.name, REF, TOP); self.assertNotEqual(rc, 0); self.assertIn("addr 100", o)
    def test_neg_nonzero_tail(self):  # firmware shorter than ROM image: remaining mapped words must be zero
        w = open(HEX).read().split()[:500]
        f = tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False); f.write("\n".join(w) + "\n"); f.close()
        rc, o = run(f.name, REF); self.assertNotEqual(rc, 0)
if __name__ == "__main__": unittest.main()
