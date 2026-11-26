#!/usr/bin/env python3
"""Unit tests for tablet-display/bin/make-edid.py.

Verifies EDID header/block checksums and edge cases: high/single/reversed
refresh rates, 4+ refresh rates, >=4096px DTD overflow, high-refresh RB2
v_front DTD overflow, invalid/zero refresh rates, non-ASCII names, and large
physical sizes.
"""

import importlib.util
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
MAKE_EDID = HERE.parent / "tablet-display" / "bin" / "make-edid.py"

spec = importlib.util.spec_from_file_location("make_edid", MAKE_EDID)
edid_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(edid_mod)


def assert_valid_edid(data: bytes, label: str):
    assert 128 <= len(data) <= 1024 and len(data) % 128 == 0, f"{label}: bad size {len(data)}"
    assert data[:8] == b"\x00\xff\xff\xff\xff\xff\xff\x00", f"{label}: bad header"
    blocks = len(data) // 128
    assert data[126] == blocks - 1, f"{label}: extension count mismatch ({data[126]} != {blocks - 1})"
    for i in range(blocks):
        blk = data[i * 128:(i + 1) * 128]
        assert sum(blk) % 256 == 0, f"{label}: block {i} bad checksum"


def test_default():
    modes = edid_mod.default_modes((2960, 1848), [60.0, 90.0, 120.0], [(2560, 1600), (1920, 1200), (1920, 1080)])
    data, planned = edid_mod.build("Tab S9 Ultra", (315, 196), modes)
    assert_valid_edid(data, "default")
    assert len(planned) == 12


def test_reversed_and_single_high_refresh():
    extras = [(2560, 1600), (1920, 1200), (1920, 1080)]
    # Reversed order (fastest first)
    modes = edid_mod.default_modes((2960, 1848), [120.0, 90.0, 60.0], extras)
    data, planned = edid_mod.build("Tab S9 Ultra", (315, 196), modes)
    assert_valid_edid(data, "reversed-rates")
    assert any(t["h"] == 2960 and t["v"] == 1848 and t["where"] == "displayid" for t in planned)

    # Single 120 Hz rate on 2960x1848 (needs DisplayID) with no extras
    modes = edid_mod.default_modes((2960, 1848), [120.0], [])
    data, planned = edid_mod.build("Tab S9 Ultra", (315, 196), modes)
    assert_valid_edid(data, "single-120hz")
    assert any(t["where"] == "dtd" and t["h"] == 2960 and t["v"] == 1848 for t in planned)
    assert any(t["where"] == "displayid" and t["h"] == 2960 and t["v"] == 1848 for t in planned)


def test_four_plus_refresh_rates():
    extras = [(2560, 1600), (1920, 1200), (1920, 1080)]
    modes = edid_mod.default_modes((2960, 1848), [60.0, 75.0, 90.0, 120.0], extras)
    data, planned = edid_mod.build("Tab S9 Ultra", (315, 196), modes)
    assert_valid_edid(data, "4-rates")
    assert len(planned) == 14
    # All 4 native rates must be preserved.
    native_count = sum(1 for t in planned if t["h"] == 2960 and t["v"] == 1848)
    assert native_count == 4, f"expected 4 native modes, got {native_count}"

    # 8 refresh rates including >5 DisplayID-only rates
    modes2 = edid_mod.default_modes((2960, 1848), [60.0, 90.0, 120.0, 144.0, 165.0, 180.0, 200.0, 240.0], extras)
    data2, planned2 = edid_mod.build("Tab S9 Ultra", (315, 196), modes2)
    assert_valid_edid(data2, "many-high-rates")
    assert len(planned2) <= 14


def test_4096_and_5k_routed_to_displayid():
    # 4096x2160@60 fits <655.35 MHz, but 4096 exceeds 12-bit DTD max (4095).
    t = edid_mod.plan_mode(4096, 2160, 60.0)
    assert t["where"] == "displayid", f"expected displayid for 4096x2160@60, got {t}"

    modes = edid_mod.default_modes((5120, 2880), [60.0], [])
    data, planned = edid_mod.build("5K Display", (600, 340), modes)
    assert_valid_edid(data, "5k-no-extras")
    assert any(t["h"] == 5120 and t["v"] == 2880 and t["where"] == "displayid" for t in planned)
    assert any(t["where"] == "dtd" for t in planned)


def test_rb2_vfront_dtd_overflow():
    # 1920x1200@240 exceeds DTD_MAX_KHZ in RB1 (674 MHz), falls back to RB2
    # (648 MHz <= 655.35 MHz), where v_front is 136 > 63 (6-bit DTD limit).
    t = edid_mod.plan_mode(1920, 1200, 240.0)
    assert t["pclk_khz"] <= edid_mod.DTD_MAX_KHZ and t["v_front"] > 63
    assert t["where"] == "displayid", f"expected displayid for 1920x1200@240, got {t}"
    modes = edid_mod.default_modes((1920, 1200), [60.0, 240.0], [])
    data, _ = edid_mod.build("Fast 1200p", (300, 188), modes)
    assert_valid_edid(data, "1200p-240hz")


def test_invalid_inputs_and_sanitization():
    for bad_hz in (0.0, -60.0, 5.0, 1000.0, float("nan"), float("inf")):
        try:
            edid_mod.plan_mode(2560, 1600, bad_hz)
            raise AssertionError(f"should reject {bad_hz}")
        except ValueError:
            pass

    # Non-ASCII name and huge physical size should not crash.
    modes = edid_mod.default_modes((2560, 1600), [60.0], [])
    data, _ = edid_mod.build("Tab S9×Ultra™", (5000, 3000), modes)
    assert_valid_edid(data, "non-ascii-huge-mm")

    # Explicit --mode with DisplayID-only mode fails with ValueError.
    try:
        edid_mod.build("Tab", (315, 196), [(2960, 1848, 120.0)])
        raise AssertionError("should require at least one DTD mode")
    except ValueError:
        pass

    # CLI smoke test with --refresh 120 (single high rate)
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "out.bin"
        res = subprocess.run(
            [sys.executable, "-I", str(MAKE_EDID), "-o", str(out), "--native", "2960x1848", "--refresh", "120"],
            capture_output=True, text=True, check=True,
        )
        assert_valid_edid(out.read_bytes(), "cli-120")
        assert "wrote" in res.stdout


if __name__ == "__main__":
    for fn in (
        test_default,
        test_reversed_and_single_high_refresh,
        test_four_plus_refresh_rates,
        test_4096_and_5k_routed_to_displayid,
        test_rb2_vfront_dtd_overflow,
        test_invalid_inputs_and_sanitization,
    ):
        fn()
        print(f"ok   {fn.__name__}")
    print("all passed")
