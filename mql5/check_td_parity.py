"""Compare TD_DLV_v3.6 / DLV_TD_MA / DLV_TD_Point CSV buffers with the Lab's TD_SEQ / TD_MA1 / TD_POINT.

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
from typing import Callable

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
POINT_COLUMNS = ("demand", "supply", "demand_confirmed", "supply_confirmed", "prior_demand", "prior_supply")
UNMAPPED = {
    "TD_SEQ": ["MQL5 buffers 5-12 (Setup/Countdown risk lines A/B): no Lab counterpart, not compared",
               "Lab outputs 2/3 parked levels (-n): MQL5 publishes 0 (or 14 for a bar-13 deferral)",
               "Lab outputs 4/5 parked levels (-n): MQL5 publishes 0"],
    "TD_MA1": [f"first {MA_WARMUP} bars: warm-up convention differs (bar-0 True Low/High), reported only"],
}


def lab_outputs(frame: pd.DataFrame, name: str, params: list) -> list[np.ndarray]:
    """The Lab's own pseudo dispatch and output selection."""
    result = rules._pseudo_indicator(name, frame, params)
    if isinstance(result, pd.Series):  # single-output pseudo
        return [result.to_numpy(dtype=float)]
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


# A spec maps (frame, csv_name) -> (want, start): want = {csv column: (mapping
# note, Lab target array[, rtol[, atol]])}, exact unless given; bars before
# `start` are warm-up, reported but not gated. Lookup is by exact CSV name, then
# by the longest registered prefix (e.g. "TD_POINT_L" matches "TD_POINT_L3").
Spec = Callable[[pd.DataFrame, str], tuple[dict[str, tuple], int]]
SPECS: dict[str, Spec] = {}


def spec_seq(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    want = {k: (m, t, 1e-12) if k.startswith("tdst_") else (m, t) for k, (m, t) in expected_seq(frame).items()}
    return want, 0


def spec_ma(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    out = lab_outputs(frame, "TD_MA1", MA_PARAMS)
    # 5-term SMA: summation order only.
    return {"bullish": ("buffer 0 <- Lab 0", out[0], 1e-12), "bearish": ("buffer 1 <- Lab 1", out[1], 1e-12)}, MA_WARMUP


def spec_point(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    # Six buffers in the Lab's output order, published N bars late on both sides;
    # prices are copied lows/highs, so exact.
    out = lab_outputs(frame, "TD_POINT", [int(name[len("TD_POINT_L"):])])
    return {column: (f"buffer {k} <- Lab {k}", out[k]) for k, column in enumerate(POINT_COLUMNS)}, 0


SPECS.update({"TD_SEQ": spec_seq, "TD_MA1": spec_ma, "TD_POINT_L": spec_point})

# --- TD_REI, native DEMARKER, TD_COMBO, TD_DWAVE ---
DEMARKER_PERIOD = 14  # native iDeMarker period passed by DLV_TD_Export (the Lab default)


def spec_rei(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    # DLV_TD_REI replays pandas' rolling-sum arithmetic, so exact.
    return {"rei": ("buffer 0 <- Lab 0", lab_outputs(frame, "TD_REI", [5])[0])}, 0


DEMARKER_ATOL = 1e-12  # absolute, on a 0..1 oscillator


def spec_demarker(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    # Same formula and warm-up (first value on bar period-1, NaN<->EMPTY agree),
    # but the native iDeMarker keeps never-reset running sums (it drifts, even to
    # -1e-15 on a flat window) where the Lab streams a compensated rolling mean.
    # Measured |diff| <= 1.3e-13 over all 16 exports, and the drift sits near 0,
    # where a relative tolerance is meaningless, hence an absolute one.
    lab = lab_outputs(frame, "DEMARKER", [DEMARKER_PERIOD])[0]
    return {"demarker": (f"native iDeMarker <- Lab 0, atol {DEMARKER_ATOL:g}", lab, 0.0, DEMARKER_ATOL)}, 0


COMBO_COLUMNS = ("buy_setup", "sell_setup", "buy_countdown", "sell_countdown", "buy_risk", "sell_risk")
DWAVE_COLUMNS = ("bull_code", "bear_code", "bull_event", "bear_event",
                 "bull_w3", "bear_w3", "bull_w5", "bear_w5", "bull_wc", "bear_wc")


def spec_combo(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    # Buffers are the Lab outputs verbatim (risk NaN <-> EMPTY_VALUE). Risk is one
    # subtraction/addition of copied true extremes, so exact.
    out = lab_outputs(frame, "TD_COMBO", [int(name[len("TD_COMBO_P"):])])
    return {column: (f"buffer {k} <- Lab {k}", out[k]) for k, column in enumerate(COMBO_COLUMNS)}, 0


def spec_dwave(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    # Verbatim; projections evaluate the Lab's own expressions in the same order, so exact.
    out = lab_outputs(frame, "TD_DWAVE", [])
    return {column: (f"buffer {k} <- Lab {k}", out[k]) for k, column in enumerate(DWAVE_COLUMNS)}, 0


SPECS.update({"TD_REI": spec_rei, "DEMARKER": spec_demarker, "TD_COMBO_P": spec_combo, "TD_DWAVE": spec_dwave})

# --- DLV_TD_Patterns (14 pseudos) ---
# DLV_TD_Patterns buffers 0-39 are the 14 Lab pseudos' outputs verbatim, in this
# order (flags 1/0, prices / oscillators with NaN<->EMPTY), compared EXACTLY from
# bar 0: the MQL5 replays the Lab's IEEE operations, including pandas' Kahan
# rolling sum/mean for TD_PRESSURE and TD_CHANNEL1. Buffers 40-55 are arrow
# drawing copies of 0-15 and are not exported.
B2_PATTERN_LAYOUT = (
    ("TD_DIFF", ("diff_up", "diff_down")),
    ("TD_REV_DIFF", ("revdiff_up", "revdiff_down")),
    ("TD_ANTI_DIFF", ("antidiff_up", "antidiff_down")),
    ("TD_OPEN", ("open_buy", "open_sell")),
    ("TD_CLOP", ("clop_buy", "clop_sell")),
    ("TD_CLOPWIN", ("clopwin_buy", "clopwin_sell")),
    ("TD_CAMOUFLAGE", ("camo_buy", "camo_sell")),
    ("TD_TRAP", ("trap_buy", "trap_sell")),
    ("TD_PRESSURE", ("pressure",)),
    ("TD_ROC", ("roc",)),
    ("TD_CHANNEL1", ("chan1_upper", "chan1_lower")),
    ("TD_REBO", ("rebo_upper1", "rebo_upper2", "rebo_lower1", "rebo_lower2",
                 "rebo_upper_q1", "rebo_upper_q3", "rebo_lower_q1", "rebo_lower_q3",
                 "rebo_upper_ok", "rebo_lower_ok", "rebo_upper_bad", "rebo_lower_bad")),
    ("TD_RANGE_PROJ", ("rp_high", "rp_low", "rp_tol_up", "rp_tol_down")),
    ("TD_PROPULSION", ("prop_up_threshold", "prop_up_target", "prop_down_threshold", "prop_down_target")),
)
# CSV name -> the params DLV_TD_Export passes (keep the two in sync). Pseudos not
# listed take no params. The presets trade the defaults; _ALT changes every param,
# notably TD_PROPULSION's pivot level (3 -> 1), which moves every level.
B2_PATTERN_PARAMS = {
    "TD_PATTERNS": {"TD_PRESSURE": [5], "TD_ROC": [12], "TD_CHANNEL1": [3, 1.03, 0.97],
                    "TD_REBO": [0.382, 0.618], "TD_PROPULSION": [3, 0.236, 0.472]},
    "TD_PATTERNS_ALT": {"TD_PRESSURE": [3], "TD_ROC": [10], "TD_CHANNEL1": [5, 1.09, 0.91],
                        "TD_REBO": [0.25, 0.5], "TD_PROPULSION": [1, 0.25, 0.5]},
}


def spec_patterns(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    params, want, b = B2_PATTERN_PARAMS[name], {}, 0
    for pseudo, columns in B2_PATTERN_LAYOUT:
        p = params.get(pseudo, [])
        out = lab_outputs(frame, pseudo, p)
        for k, column in enumerate(columns):
            want[column] = (f"buffer {b} <- {pseudo} {k}", out[k])
            b += 1
    return want, 0


SPECS.update({"TD_PATTERNS": spec_patterns})

# --- TD_WALDO2-8, TD_TREND_FACTOR, TD_REL/ABS_RETRACEMENT, TD_LINES ---
# Every buffer here is the Lab output itself (flags 1/0, prices or NaN<->EMPTY),
# compared EXACTLY from bar 0: the MQL5 replays the Lab's IEEE operations in order.
# CSV name -> the iCustom inputs DLV_TD_Export passes (keep the two in sync).
B3_WALDO = {"TD_WALDO": dict(w2=21, w3=2.0, w4=10, w6=8, w8=(7, 5)),
            "TD_WALDO_ALT": dict(w2=10, w3=1.5, w4=5, w6=4, w8=(5, 3))}
B3_TREND_FACTOR = {"TD_TREND_FACTOR": [3, 0.0556], "TD_TREND_FACTOR_L1": [1, 0.0556]}
B3_RETRACEMENT = {"TD_RETRACEMENT": ([1, 0.382], [1.382, 0.618]),
                  "TD_RETRACEMENT_L3": ([3, 0.618], [1.618, 0.5])}
B3_LINES = {"TD_LINES_L1": [1, 400, 1.0], "TD_LINES_L3": [3, 25, 1.618]}
WALDO_COLUMNS = [f"w{k}_{side}" if k != 3 else f"w3_{lvl}"
                 for k in range(2, 9) for side, lvl in (("bottom", "upside"), ("top", "downside"))]
TREND_FACTOR_COLUMNS = ("dn1", "dn2", "dn3", "up1", "up2", "up3")
RETRACEMENT_COLUMNS = ("rel_upside", "rel_downside", "rel_up_magnet", "rel_down_magnet", "rel_upper_ok",
                       "rel_lower_ok", "rel_upper_bad", "rel_lower_bad", "abs_upside", "abs_downside")
LINES_COLUMNS = ("demand", "supply", "demand_q1", "demand_q2", "demand_q3", "supply_q1", "supply_q2", "supply_q3",
                 "demand_ok", "supply_ok", "demand_bad", "supply_bad", "demand_objective", "supply_objective")


def spec_waldo(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    p = B3_WALDO[name]
    params = {2: [p["w2"]], 3: [p["w3"]], 4: [p["w4"]], 5: [], 6: [p["w6"]], 7: [], 8: list(p["w8"])}
    out = [s for k in range(2, 9) for s in lab_outputs(frame, f"TD_WALDO{k}", params[k])]
    return {c: (f"buffer {j} <- TD_WALDO{2 + j // 2} {j % 2}", out[j]) for j, c in enumerate(WALDO_COLUMNS)}, 0


def spec_trend_factor(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    out = lab_outputs(frame, "TD_TREND_FACTOR", B3_TREND_FACTOR[name])
    return {c: (f"buffer {k} <- Lab {k}", out[k]) for k, c in enumerate(TREND_FACTOR_COLUMNS)}, 0


def spec_retracement(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    rel, ab = B3_RETRACEMENT[name]
    out = lab_outputs(frame, "TD_REL_RETRACEMENT", rel) + lab_outputs(frame, "TD_ABS_RETRACEMENT", ab)
    return {c: (f"buffer {k} <- {'REL ' + str(k) if k < 8 else 'ABS ' + str(k - 8)}", out[k])
            for k, c in enumerate(RETRACEMENT_COLUMNS)}, 0


def spec_lines(frame: pd.DataFrame, name: str) -> tuple[dict[str, tuple], int]:
    out = lab_outputs(frame, "TD_LINES", B3_LINES[name])
    return {c: (f"buffer {k} <- Lab {k}", out[k]) for k, c in enumerate(LINES_COLUMNS)}, 0


SPECS.update({**{n: spec_waldo for n in B3_WALDO}, **{n: spec_trend_factor for n in B3_TREND_FACTOR},
              **{n: spec_retracement for n in B3_RETRACEMENT}, **{n: spec_lines for n in B3_LINES}})


def find_spec(name: str) -> Spec:
    if name in SPECS:
        return SPECS[name]
    prefixes = [k for k in SPECS if name.startswith(k)]
    if not prefixes:
        raise ValueError(f"Unknown indicator {name}")
    return SPECS[max(prefixes, key=len)]


def check(path: Path, verbose: bool = True) -> tuple[str, int, dict[str, int]]:
    frame = pd.read_csv(path, float_precision="round_trip")
    if frame.empty or "indicator" not in frame or frame["indicator"].nunique() != 1:
        raise ValueError("Empty CSV or mixed/missing indicator column")
    if not frame["time"].is_monotonic_increasing or frame["time"].duplicated().any():
        raise ValueError("Bar times must be strictly increasing")
    name = str(frame["indicator"].iloc[0])
    frame.index = pd.to_datetime(frame["time"], unit="s")  # broker clock; no feed reload
    price_columns = [k for k in ("Open", "High", "Low", "Close", "Volume") if k in frame]
    frame[price_columns] = frame[price_columns].astype(float)
    want, start = find_spec(name)(frame, name)
    if len(frame) <= start:
        raise ValueError(f"No bars after the {start}-bar warm-up; nothing was compared")
    lines, counts =[f"{name} {path.name}: {len(frame) - start:,} bars compared"], {}
    for column, entry in want.items():
        mapping, target, rtol, atol = (*entry, 0.0, 0.0)[:4]
        actual = frame[column].to_numpy(dtype=float)
        match = np.isclose(actual, target, equal_nan=True, rtol=rtol, atol=atol)
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
    lines += [f"  not compared: {note}" for note in UNMAPPED.get(name, [])]
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
