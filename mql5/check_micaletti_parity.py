"""Compare MQL5 CSV buffers with the Lab on the identical exported OHLCV.

    python mql5/check_micaletti_parity.py "C:/.../Common/Files/DLV_Micaletti_*.csv"

Requires raw, rank, validity and all four signal masks to agree, INCLUDING warmup.
No network, terminal attachment or trading. Exit status 1 means a failed gate.
"""
from __future__ import annotations

import argparse
import glob
import sys
from pathlib import Path

import numpy as np
import pandas as pd

LAB_ROOT = Path(__file__).resolve().parents[2] / "DLV_Quant_Lab"
sys.path.insert(0, str(LAB_ROOT))
import presets
import rules
import time_stops


def expected(frame: pd.DataFrame, preset_id: str, vwap_mode: int) -> pd.DataFrame:
    """Use production Lab operands/stops; change only MTSI's explicit VWAP input."""
    preset = presets.get_preset(preset_id)
    if preset is None or not preset_id.startswith("micaletti_"):
        raise ValueError(f"Unknown preset {preset_id}")
    if vwap_mode not in (0, 1, 2):
        raise ValueError(f"Unknown VWAP mode {vwap_mode}")
    operand = preset["entries"][0]["lhs"]["operand"]
    # The rule grammar names are intentionally taken from the actual preset.
    raw = rules.operand_to_series(operand, frame)
    if operand.get("name") == "MTSI" and vwap_mode != 0:
        m, n = operand["params"]
        if frame["vwap"].isna().any() or (frame["vwap"] <= 0).any():
            raise ValueError("MTSI VWAP mode requires every exported VWAP to be positive")
        r = np.log(frame["Close"] / frame["vwap"])
        num = r.ewm(span=m, adjust=False).mean().ewm(span=n, adjust=False).mean()
        den = r.abs().ewm(span=m, adjust=False).mean().ewm(span=n, adjust=False).mean()
        raw = 100 * num / den.replace(0, np.nan)
    rank = pd.Series(rules._njit_percent_rank(raw.to_numpy(dtype=float), 252), index=frame.index)
    le, se = rank < 0.10, rank > 0.90
    no_exit = pd.Series(False, index=frame.index)
    hold = preset["params"]["hold_bars"]
    lx = time_stops.apply_bar_stop(le, no_exit, hold)
    sx = time_stops.apply_bar_stop(se, no_exit, hold)
    return pd.DataFrame({"raw": raw, "rank": rank, "long_entry": le, "long_exit": lx,
                         "short_entry": se, "short_exit": sx}, index=frame.index)


def check(path: Path, report_natives: bool = False) -> tuple[str, int]:
    frame = pd.read_csv(path, float_precision="round_trip")
    needed = {"preset", "vwap_mode", "time", "Open", "High", "Low", "Close", "Volume",
              "vwap", "raw", "rank", "long_entry", "long_exit", "short_entry", "short_exit"}
    if not needed.issubset(frame.columns) or frame.empty:
        raise ValueError("Empty CSV or missing required columns")
    if frame["preset"].nunique() != 1 or frame["vwap_mode"].nunique() != 1:
        raise ValueError("Mixed presets or VWAP modes")
    if not frame["time"].is_monotonic_increasing or frame["time"].duplicated().any():
        raise ValueError("Bar times must be strictly increasing")
    frame.index = pd.to_datetime(frame["time"], unit="s")  # retain broker clock; no feed reload
    frame[["Open", "High", "Low", "Close", "Volume", "vwap"]] = frame[
        ["Open", "High", "Low", "Close", "Volume", "vwap"]].astype(float)
    pid, mode = str(frame["preset"].iloc[0]), int(frame["vwap_mode"].iloc[0])
    target = expected(frame, pid, mode)
    # Roundoff tolerance only for the oscillator; ranks and trade masks are exact.
    for column in target:
        actual = frame[column].to_numpy(dtype=float)
        want = target[column].to_numpy(dtype=float)
        tolerance = (dict(rtol=1e-9, atol=1e-8) if column == "raw" else
                     dict(rtol=0, atol=5e-15 if column == "rank" else 0))
        match = np.isclose(actual, want, equal_nan=True, **tolerance)
        if not match.all():
            i = int(np.flatnonzero(~match)[0])
            raise AssertionError(f"{pid} {column}: {int((~match).sum())} mismatches; first at "
                                 f"bar {i} ({frame.index[i]}): MQL5={actual[i]!r}, Lab={want[i]!r}")
    if report_natives and "native_raw" in frame and frame["native_raw"].notna().any():
        native = frame["native_raw"].to_numpy(dtype=float)
        native_rank = rules._njit_percent_rank(native, 252)
        valid = np.isfinite(native) & np.isfinite(target["raw"].to_numpy())
        max_delta = np.max(np.abs(native[valid] - target["raw"].to_numpy()[valid]))
        long_diff = np.count_nonzero((native_rank < .10) != target["long_entry"].to_numpy())
        short_diff = np.count_nonzero((native_rank > .90) != target["short_entry"].to_numpy())
        print(f"NATIVE {pid}: max raw delta={max_delta:.9g}; threshold differences long={long_diff}, short={short_diff}")
    return pid, len(frame)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", nargs="+", help="CSV files or wildcard patterns")
    parser.add_argument("--require-all", action="store_true", help="Require all 22 presets in the supplied files")
    parser.add_argument("--report-natives", action="store_true", help="Report native MT5 mapping differences without changing the parity gate")
    args = parser.parse_args()
    paths = sorted({Path(p) for pattern in args.csv for p in glob.glob(pattern)})
    if not paths:
        parser.error("No CSVs matched")
    failed, checked, bars = 0, set(), 0
    for path in paths:
        try:
            pid, n = check(path, args.report_natives)
            checked.add(pid)
            bars += n
        except (AssertionError, ValueError, KeyError) as exc:
            failed += 1
            print(f"FAIL {path.name}: {exc}")
    coverage_failed = args.require_all and len(checked) != 22
    if coverage_failed:
        print(f"FAIL required 22 presets, passed {len(checked)}")
    print(f"{len(paths)-failed}/{len(paths)} files passed; {len(checked)} presets; {bars:,} bars checked")
    return 1 if failed or coverage_failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
