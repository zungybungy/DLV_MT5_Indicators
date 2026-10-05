"""Compare TD_DLV_v3.6 / DLV_TD_MA CSV buffers with the Lab's TD_SEQ / TD_MA1.

    python mql5/check_td_parity.py "C:/.../Common/Files/DLV_TD_*.csv"

The Lab pseudos run on the identical exported OHLC with broker timestamps. Each
MQL5 buffer is compared with the Lab output re-encoded in the buffer's own
convention (mapping in TD_PARITY.md). Counts/flags must be equal; price levels
use rtol 1e-12. No network, terminal attachment or trading. Exit 1 = failed gate.
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
import rules

MA_PARAMS = [5, 12, 4]  # DLV_TD_MA inputs passed by DLV_TD_Export
# Lab TD_MA1 reads bar 0's True Low/High from the raw Low/High (no prior close);
# DLV_TD_MA waits for one. Only a qualification on bar `lookback` can differ, and
# it extends `extend` bars. Excluded and reported, never silently dropped.
MA_WARMUP = MA_PARAMS[1] + MA_PARAMS[2]
UNMAPPED = {
    "TD_SEQ": ["MQL5 buffers 5-12 (Setup/Countdown risk lines A/B): no Lab counterpart, not compared",
               "Lab outputs 2/3 parked levels (-n): MQL5 publishes 0 (or 14 for a bar-13 deferral)",
               "Lab outputs 4/5 parked levels (-n): MQL5 publishes 0"],
    "TD_MA1": [f"first {MA_WARMUP} bars: warm-up convention differs (bar-0 True Low/High), reported only"],
}


def lab_outputs(frame: pd.DataFrame, name: str, params: list) -> list[np.ndarray]:
    """The Lab's own pseudo dispatch and output selection."""
    result = rules._pseudo_indicator(name, frame, params)
    return [rules._select_pseudo_output(name, result, k).to_numpy(dtype=float) for k in range(len(result))]


def expected_seq(frame: pd.DataFrame) -> dict[str, tuple[str, np.ndarray]]:
    out = lab_outputs(frame, "TD_SEQ", [])
    c, h, l = (frame[k].to_numpy() for k in ("Close", "High", "Low"))
    # Standard countdown: +n counted; a parked 12 on a bar whose close qualifies
    # was deferred by the bar-13 qualifier, which v3.6 labels 14 ("+").
    raw_buy = np.r_[False, False, c[2:] <= l[:-2]]
    raw_sell = np.r_[False, False, c[2:] >= h[:-2]]
    def standard(v: np.ndarray, raw: np.ndarray) -> np.ndarray:
        return np.where(v > 0, v, np.where((v == -12) & raw, 14.0, 0.0))
    buy, sell = standard(out[2], raw_buy), standard(out[3], raw_sell)
    countdown = np.where(buy > 0, buy, -sell)
    # Perl's R: a run reaching 18 closes. v3.6 marks it +-15 over that bar's count
    # (its own Setup's countdown is always live on bar 18). Run length follows the
    # Lab's flips (Setup 1) and the four-bar close comparison.
    brun = np.zeros(len(c), dtype=int)
    srun = np.zeros(len(c), dtype=int)
    for t in range(4, len(c)):
        brun[t] = 1 if out[0][t] == 1 else (brun[t - 1] + 1 if brun[t - 1] and c[t] < c[t - 4] else 0)
        srun[t] = 1 if out[1][t] == 1 else (srun[t - 1] + 1 if srun[t - 1] and c[t] > c[t - 4] else 0)
    countdown = np.where(brun == 18, 15.0, np.where(srun == 18, -15.0, countdown))
    aggressive = np.where(out[4] > 0, out[4], np.where(out[5] > 0, -out[5], 0.0))
    return {
        "tdst_resistance": ("buffer 0 <- Lab 7", out[7]),
        "tdst_support": ("buffer 1 <- Lab 6", out[6]),
        "setup": ("buffer 2 <- Lab 0 - Lab 1", out[0] - out[1]),
        "countdown": ("buffer 3 <- Lab 2 / -Lab 3, R=+-15", countdown),
        # v3.6 writes sell (-1) after buy (+1), so a same-bar pair reads -1.
        "perfection": ("buffer 4 <- Lab 8 / -Lab 9", np.where(out[9] == 1, -1.0, out[8])),
        "aggressive_countdown": ("buffer 13 <- Lab 4 / -Lab 5", aggressive),
    }


def check(path: Path, verbose: bool = True) -> tuple[str, int, dict[str, int]]:
    frame = pd.read_csv(path, float_precision="round_trip")
    if frame.empty or "indicator" not in frame or frame["indicator"].nunique() != 1:
        raise ValueError("Empty CSV or mixed/missing indicator column")
    if not frame["time"].is_monotonic_increasing or frame["time"].duplicated().any():
        raise ValueError("Bar times must be strictly increasing")
    name = str(frame["indicator"].iloc[0])
    frame.index = pd.to_datetime(frame["time"], unit="s")  # broker clock; no feed reload
    frame[["Open", "High", "Low", "Close"]] = frame[["Open", "High", "Low", "Close"]].astype(float)
    if name == "TD_SEQ":
        want = expected_seq(frame)
        start = 0
    elif name == "TD_MA1":
        out = lab_outputs(frame, "TD_MA1", MA_PARAMS)
        want = {"bullish": ("buffer 0 <- Lab 0", out[0]), "bearish": ("buffer 1 <- Lab 1", out[1])}
        start = MA_WARMUP
    else:
        raise ValueError(f"Unknown indicator {name}")
    lines, counts = [f"{name} {path.name}: {len(frame) - start:,} bars compared"], {}
    for column, (mapping, target) in want.items():
        actual = frame[column].to_numpy(dtype=float)
        # Price levels are copied prices or a 5-term SMA (summation order only).
        tolerance = dict(rtol=1e-12, atol=0) if column in ("tdst_resistance", "tdst_support", "bullish", "bearish") \
            else dict(rtol=0, atol=0)
        match = np.isclose(actual, target, equal_nan=True, **tolerance)
        bad = np.flatnonzero(~match[start:]) + start
        counts[column] = len(bad)
        if start:
            lines.append(f"  warm-up {column}: {int((~match[:start]).sum())} of {start} excluded bars differ")
        if not len(bad):
            lines.append(f"  PASS {column} ({mapping})")
            continue
        i = int(bad[0])
        lines.append(f"  FAIL {column} ({mapping}): {len(bad)} mismatches; first at bar {i} "
                     f"({frame.index[i]}): MQL5={float(actual[i])!r}, Lab={float(target[i])!r}")
        for j in range(max(0, i - 2), i + 1):
            o, h, l, c = (float(frame[k].iloc[j]) for k in ("Open", "High", "Low", "Close"))
            lines.append(f"       bar {j} {frame.index[j]} O={o!r} H={h!r} L={l!r} C={c!r}")
    lines += [f"  not compared: {note}" for note in UNMAPPED[name]]
    if verbose:
        print("\n".join(lines), flush=True)
    return name, len(frame) - start, counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", nargs="+", help="CSV files or wildcard patterns")
    args = parser.parse_args()
    paths = sorted({Path(p) for pattern in args.csv for p in glob.glob(pattern)})
    if not paths:
        parser.error("No CSVs matched")
    failed, bars = 0, 0
    for path in paths:
        try:
            _, n, counts = check(path)
            bars += n
            failed += any(counts.values())
        except (ValueError, KeyError) as exc:
            failed += 1
            print(f"FAIL {path.name}: {exc}")
    print(f"{len(paths) - failed}/{len(paths)} files passed; {bars:,} bars compared")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
