"""Bar-for-bar TD_SEQ / TD_MA1 / TD_POINT parity in an isolated, non-trading portable MT5.

Windows-only integration test. Compiles TD_DLV_v3.6, DLV_TD_MA, DLV_TD_Point and
the export script, copies terminal64.exe, symbol definitions and cached broker bars from
the live terminal (read-only) into scratch/, exports every indicator's buffers
(DLV_TD_Point at Levels 1 and 3)
on every SYMBOL x PERIOD, then gates them with mql5/check_td_parity.py.
No account credentials, orders or file deletions; artifacts are retained.

python smoke_test/_smoke_test_td_mql5.py
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("td_parity", ROOT / "mql5/check_td_parity.py")
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)

# Default-server symbol name -> cached broker history (one per asset class).
SYMBOLS = {
    "EURUSD": "ICMarketsSC-Demo/history/EURUSD",
    "XAUUSD.a": "Pepperstone-MT5-Live01/history/XAUUSD.a",
    "US500.a": "Pepperstone-MT5-Live01/history/US500.a",
    "BTCUSD.a": "Pepperstone-MT5-Live01/history/BTCUSD.a",
}
PERIODS = ("D1", "H4", "H1", "M15")
# Exported CSV name -> the root-level .mq5 indicator that produces it (None = a
# native terminal indicator: nothing to compile).
INDICATORS = {
    "TD_SEQ": "TD_DLV_v3.6",
    "TD_MA1": "DLV_TD_MA",
    "TD_POINT_L1": "DLV_TD_Point",
    "TD_POINT_L3": "DLV_TD_Point",
    "TD_REI": "DLV_TD_REI",
    "DEMARKER": None,  # native iDeMarker matches the Lab's DEMARKER; no DLV port
    "TD_COMBO_P1": "DLV_TD_Combo",
    "TD_COMBO_P2": "DLV_TD_Combo",
    "TD_DWAVE": "DLV_TD_DWave",
    "TD_PATTERNS": "DLV_TD_Patterns",
    "TD_PATTERNS_ALT": "DLV_TD_Patterns",
    "TD_WALDO": "DLV_TD_Waldo",
    "TD_WALDO_ALT": "DLV_TD_Waldo",
    "TD_TREND_FACTOR": "DLV_TD_TrendFactor",
    "TD_TREND_FACTOR_L1": "DLV_TD_TrendFactor",
    "TD_RETRACEMENT": "DLV_TD_Retracement",
    "TD_RETRACEMENT_L3": "DLV_TD_Retracement",
    "TD_LINES_L1": "DLV_TD_Lines",
    "TD_LINES_L3": "DLV_TD_Lines",
}


def hidden_run(command: str, timeout: int) -> None:
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    subprocess.run(command, startupinfo=startup, timeout=timeout, capture_output=True)


def compile_mql(source: Path, editor: Path, work: Path) -> Path:
    log = work / f"{source.stem}_compile.log"
    hidden_run(f'"{editor}" /compile:"{source}" /log:"{log}"', timeout=90)
    result = log.read_text(encoding="utf-16")
    # Anchored: a bare substring test also accepts "100 errors, 0 warnings".
    if not re.search(r"^Result: 0 errors, 0 warnings", result, re.M):
        raise AssertionError(result)
    print(f"Compiled {source.name}: 0 errors, 0 warnings", flush=True)
    return source.with_suffix(".ex5")


def install_history(source: Path, target: Path) -> None:
    """Copy cached bars file by file. The live terminal holds its open charts'
    current-year file exclusively; only that newest year may be skipped."""
    target.mkdir(parents=True)
    years = sorted(source.glob("*.hcc"))
    for path in years:
        try:
            shutil.copy2(path, target / path.name)
        except PermissionError:
            if path != years[-1]:
                raise AssertionError(f"{path} is locked; history would have a hole")
            print(f"Skipped locked {path.parent.name}/{path.name}: history ends at {years[-2].stem}", flush=True)


def execute(terminal: Path, work: Path, symbol: str, period: str, prefix: str, only: tuple[str, ...]) -> None:
    preset = work / "MQL5/Presets/DLV_TD_Export.set"
    preset.parent.mkdir(parents=True, exist_ok=True)
    preset.write_text(f"InpFilePrefix={prefix}\nInpOnly={','.join(only)}", encoding="ascii")
    config = work / "DLV_TD_Export.ini"
    config.write_text("\n".join([
        "[Experts]", "Enabled=0", "AllowLiveTrading=0", "AllowDllImport=0",
        "[StartUp]", f"Symbol={symbol}", f"Period={period}", "Script=DLV_TD_Export",
        f"ScriptParameters={preset.name}", "ShutdownTerminal=1",
    ]), encoding="ascii")
    # The startup-script exit code is not a reliable result; the CSVs are checked.
    hidden_run(f'"{terminal}" /portable /config:"{config}"', timeout=600)


def must_worsen(path: Path, column: str, name: str, fn) -> None:
    """A vacuous checker must be impossible: a perturbed Lab reference must
    strictly increase the targeted column's mismatches ("still fails" alone
    would prove nothing where a column already fails)."""
    before = parity.check(path, verbose=False)[2][column]
    with patch.dict(parity.rules.PSEUDO_REGISTRY, {name: fn}):
        after = parity.check(path, verbose=False)[2][column]
    if after <= before:
        raise AssertionError(f"Perturbed Lab {name} left {column} at {after} mismatches ({before} before)")
    print(f"  drift {name} -> {column}: {before} -> {after} mismatches", flush=True)


def drift_seq(seq: Path) -> None:
    seq_fn = parity.rules.PSEUDO_REGISTRY["TD_SEQ"]

    def no_buy_nine(df: pd.DataFrame, params: list) -> tuple:
        out = list(seq_fn(df, params))
        out[0] = out[0].where(out[0] != 9, 8)
        return tuple(out)

    def tdst_ppb(df: pd.DataFrame, params: list) -> tuple:
        out = list(seq_fn(df, params))
        out[7] = out[7] * (1 + 1e-9)
        return tuple(out)

    def countdown_plus_one(df: pd.DataFrame, params: list) -> tuple:
        out = list(seq_fn(df, params))
        out[4] = out[4].where(out[4] <= 0, out[4] + 1)
        return tuple(out)

    must_worsen(seq, "setup", "TD_SEQ", no_buy_nine)
    must_worsen(seq, "tdst_resistance", "TD_SEQ", tdst_ppb)
    must_worsen(seq, "aggressive_countdown", "TD_SEQ", countdown_plus_one)


def drift_ma(ma: Path) -> None:
    ma_fn = parity.rules.PSEUDO_REGISTRY["TD_MA1"]
    must_worsen(ma, "bullish", "TD_MA1", lambda df, params: ma_fn(df, [5, 12, 3]))
    must_worsen(ma, "bearish", "TD_MA1", lambda df, params: ma_fn(df, [6, 12, 4]))
    # A file lying wholly inside the warm-up compares nothing, so it must FAIL
    # even when every buffer is garbage rather than pass with "0 bars compared".
    stub = pd.read_csv(ma).head(parity.MA_WARMUP)
    stub[["bullish", "bearish"]] = 999999.0
    stub_path = ma.with_name("warmup_only_TD_MA1.csv")
    stub.to_csv(stub_path, index=False)
    try:
        parity.check(stub_path, verbose=False)
    except ValueError:
        print("  warm-up-only TD_MA1 file rejected (nothing compared)", flush=True)
    else:
        raise AssertionError("A file with no post-warm-up bars passed the parity gate")


def drift_point(point: Path) -> None:
    # The confirmation lag is the deliverable: a reference publishing every TD
    # Point ONE bar early (one bar of hindsight) must fail on price and flag.
    point_fn = parity.rules.PSEUDO_REGISTRY["TD_POINT"]

    def one_bar_early(df: pd.DataFrame, params: list) -> tuple:
        return tuple(s.shift(-1) for s in point_fn(df, params))

    must_worsen(point, "demand", "TD_POINT", one_bar_early)
    must_worsen(point, "supply_confirmed", "TD_POINT", one_bar_early)


def drift_rei(rei: Path) -> None:
    # The A-or-B overlap qualifier is the point of TD REI: a reference that
    # drops qualifier B (A alone gates the numerator) must fail.
    def a_only(df: pd.DataFrame, params: list) -> pd.Series:
        h, l = df["High"], df["Low"]
        f, g = h - h.shift(2), l - l.shift(2)
        cond_a = ((h >= l.shift(5)) | (h >= l.shift(6))) & ((l <= h.shift(5)) | (l <= h.shift(6)))
        valid = df["Close"].shift(8).notna() & l.shift(6).notna()
        num = (f + g).where(cond_a, 0.0).where(valid).rolling(5).sum()
        den = (f.abs() + g.abs()).where(valid).rolling(5).sum()
        return (100.0 * num / den.where(den > 1e-12)).clip(-100.0, 100.0)

    rei_fn = parity.rules.PSEUDO_REGISTRY["TD_REI"]
    must_worsen(rei, "rei", "TD_REI", a_only)
    must_worsen(rei, "rei", "TD_REI", lambda df, params: rei_fn(df, [6]))


def drift_demarker(dem: Path) -> None:
    # Perl's TD DeMarker I uses 13 bars; the native export is 14 like the Lab.
    dem_fn = parity.rules.PSEUDO_REGISTRY["DEMARKER"]
    must_worsen(dem, "demarker", "DEMARKER", lambda df, params: dem_fn(df, [13]))
    # The absolute tolerance must not swallow a real difference: 1e-9 must fail.
    must_worsen(dem, "demarker", "DEMARKER", lambda df, params: dem_fn(df, params) + 1e-9)


def drift_combo_v1(combo: Path) -> None:
    combo_fn = parity.rules.PSEUDO_REGISTRY["TD_COMBO"]
    # The conservative mode must differ from the less-strict one.
    must_worsen(combo, "buy_countdown", "TD_COMBO", lambda df, params: combo_fn(df, [2]))
    # No hindsight: a countdown published one bar early must fail.
    must_worsen(combo, "sell_countdown", "TD_COMBO",
                lambda df, params: tuple(s.shift(-1) for s in combo_fn(df, params)))
    # Risk levels are compared exactly: one part per trillion must fail.
    must_worsen(combo, "buy_risk", "TD_COMBO",
                lambda df, params: tuple(s * (1 + 1e-12) if k == 4 else s
                                         for k, s in enumerate(combo_fn(df, params))))


def drift_combo_v2(combo: Path) -> None:
    # Version II's relaxed bars 11-13 must matter: the strict reference must fail.
    combo_fn = parity.rules.PSEUDO_REGISTRY["TD_COMBO"]
    must_worsen(combo, "buy_countdown", "TD_COMBO", lambda df, params: combo_fn(df, [1]))
    must_worsen(combo, "sell_risk", "TD_COMBO", lambda df, params: combo_fn(df, [1]))


def drift_dwave(dwave: Path) -> None:
    # Output 2 == 1 (bullish Wave 1 start) drives td_dwave_wave1_long.
    dwave_fn = parity.rules.PSEUDO_REGISTRY["TD_DWAVE"]

    def one_bar_early(df: pd.DataFrame, params: list) -> tuple:
        return tuple(s.shift(-1) for s in dwave_fn(df, params))

    def no_fresh_wave1_after_lock(df: pd.DataFrame, params: list) -> tuple:
        # Drops rule 7: a break of a locked Wave 5 starts a fresh Wave 1.
        out = list(dwave_fn(df, params))
        out[2] = out[2].where(~((out[2] == 1) & (out[0].shift(1) == 8)), 0.0)
        return tuple(out)

    must_worsen(dwave, "bull_event", "TD_DWAVE", one_bar_early)
    must_worsen(dwave, "bull_event", "TD_DWAVE", no_fresh_wave1_after_lock)
    must_worsen(dwave, "bear_w5", "TD_DWAVE",
                lambda df, params: tuple(s * (1 + 1e-12) if k == 7 else s
                                         for k, s in enumerate(dwave_fn(df, params))))


def drift_waldo(waldo: Path) -> None:
    reg = parity.rules.PSEUDO_REGISTRY
    w2, w4, w7 = reg["TD_WALDO2"], reg["TD_WALDO4"], reg["TD_WALDO7"]
    # WALDO4 (traded by td_waldo4_long): the age boundary `t - X >= min_age`
    # made strict is exactly min_age + 1.
    must_worsen(waldo, "w4_bottom", "TD_WALDO4", lambda df, params: w4(df, [int(params[0]) + 1]))
    must_worsen(waldo, "w4_top", "TD_WALDO4", lambda df, params: w4(df, [int(params[0]) + 1]))

    def w4_bottom(df: pd.DataFrame, min_age: int, consume: bool) -> pd.Series:
        # Minimal WALDO4 bottom replica; consume=True must equal the Lab (asserted).
        l, c = df["Low"].to_numpy(float), df["Close"].to_numpy(float)
        out, records, used, record = parity.np.zeros(len(l)), [], set(), float("inf")
        for t in range(len(l)):
            if l[t] < record:
                record = l[t]
                records.append(t)
            aged = [x for x in records if t - x >= min_age]
            if t >= 2 and aged and aged[-1] not in used and l[t - 1] < l[aged[-1]] and l[t] < l[aged[-1]] \
                    and c[t - 1] < c[t - 2] and c[t] < c[t - 1]:
                out[t] = 1.0
                if consume:
                    used.add(aged[-1])
        return pd.Series(out, index=df.index)

    frame = pd.read_csv(waldo)
    assert (w4_bottom(frame, 10, True).to_numpy() == w4(frame, [10])[0].to_numpy()).all(), "WALDO4 replica drifted"
    # Each aged record fires once: a reference that re-fires on a consumed record must fail.
    must_worsen(waldo, "w4_bottom", "TD_WALDO4",
                lambda df, params: (w4_bottom(df, int(params[0]), False), w4(df, params)[1]))
    # WALDO7's TD Point is known on p+1: flags one bar early must fail.
    must_worsen(waldo, "w7_bottom", "TD_WALDO7", lambda df, params: tuple(b3_early(s) for s in w7(df, params)))
    # WALDO2 freshness window off by one bar.
    must_worsen(waldo, "w2_top", "TD_WALDO2", lambda df, params: w2(df, [int(params[0]) + 1]))


def b3_early(s: pd.Series) -> pd.Series:
    """Every value one bar early (one bar of hindsight); the last bar keeps its own
    value so the shift cannot add a trivial final-bar mismatch."""
    v = s.to_numpy(dtype=float).copy()
    v[:-1] = v[1:]
    return pd.Series(v, index=s.index)


def drift_trend_factor(tf: Path) -> None:
    fn = parity.rules.PSEUDO_REGISTRY["TD_TREND_FACTOR"]

    def arithmetic_downside(df: pd.DataFrame, params: list) -> tuple:
        # Downside ladder made ARITHMETIC like the upside: High*(1-2r), not High*(1-r)^2.
        out = list(fn(df, params))
        r = float(params[1])
        out[1] = out[1] * (1.0 - 2 * r) / (1.0 - r) ** 2
        return tuple(out)

    must_worsen(tf, "dn2", "TD_TREND_FACTOR", arithmetic_downside)
    # The ladder appears on the pivot's confirmation bar: one bar early must fail.
    must_worsen(tf, "up1", "TD_TREND_FACTOR", lambda df, params: tuple(b3_early(s) for s in fn(df, params)))


def drift_retracement(ret: Path) -> None:
    rel = parity.rules.PSEUDO_REGISTRY["TD_REL_RETRACEMENT"]
    ab = parity.rules.PSEUDO_REGISTRY["TD_ABS_RETRACEMENT"]
    must_worsen(ret, "rel_upside", "TD_REL_RETRACEMENT", lambda df, params: tuple(b3_early(s) for s in rel(df, params)))

    def every_break(df: pd.DataFrame, params: list) -> tuple:
        # The fresh-break gate dropped: every bar beyond the level is an event.
        out = list(rel(df, params))
        out[4] = parity.rules._td_breakout_qualifiers(df, out[0], "upper")[3].astype(float)
        return tuple(out)

    must_worsen(ret, "rel_upper_ok", "TD_REL_RETRACEMENT", every_break)
    # ABS anchored on the record bar's Low (Perl's p.110 text) instead of its Close.
    must_worsen(ret, "abs_upside", "TD_ABS_RETRACEMENT",
                lambda df, params: (ab(df.assign(Close=df["Low"]), params)[0], ab(df, params)[1]))


def drift_lines(lines: Path) -> None:
    fn = parity.rules.PSEUDO_REGISTRY["TD_LINES"]
    # The TD Point lag is the deliverable: everything one bar early must fail.
    must_worsen(lines, "demand", "TD_LINES", lambda df, params: tuple(b3_early(s) for s in fn(df, params)))
    must_worsen(lines, "supply_ok", "TD_LINES", lambda df, params: tuple(b3_early(s) for s in fn(df, params)))


def drift_lines_lookback(lines: Path) -> None:
    fn = parity.rules.PSEUDO_REGISTRY["TD_LINES"]
    # Pivot pruning boundary (pivot >= i - lookback + 1) off by one bar.
    must_worsen(lines, "demand", "TD_LINES", lambda df, params: fn(df, [params[0], int(params[1]) + 1, params[2]]))
    must_worsen(lines, "supply", "TD_LINES", lambda df, params: fn(df, [params[0], int(params[1]) + 1, params[2]]))


def b2_early(s: pd.Series) -> pd.Series:
    """Every value one bar early (one bar of hindsight); the last bar keeps its own
    value so the shift cannot add a trivial final-bar mismatch."""
    v = s.to_numpy(dtype=float).copy()
    v[:-1] = v[1:]
    return pd.Series(v, index=s.index)


def b2_flat_bar_file(path: Path) -> Path:
    """The first export of this run whose bars include a flat one (High == Low),
    which TD_PRESSURE must score 0, not NaN; EURUSD D1 has none."""
    run = path.name.split("_EURUSD_")[0]
    for other in sorted(path.parent.glob(f"{run}_*_TD_PATTERNS.csv")):
        frame = pd.read_csv(other, usecols=["High", "Low"])
        if (frame["High"] == frame["Low"]).any():
            print(f"  flat-bar control on {other.name}", flush=True)
            return other
    raise AssertionError("no TD_PATTERNS export with a flat bar; the flat-bar control cannot run")


def drift_patterns(path: Path) -> None:
    rules = parity.rules
    reg = rules.PSEUDO_REGISTRY

    def two_closes(df: pd.DataFrame) -> tuple[pd.Series, pd.Series]:
        c = df["Close"]
        return (c < c.shift(1)) & (c.shift(1) < c.shift(2)), (c > c.shift(1)) & (c.shift(1) > c.shift(2))

    # Differential family: Perl's literal selling pressure (Close - trueHigh, <= 0)
    # instead of the Lab's magnitude reading flips every SP comparison.
    def diff_literal_sp(df: pd.DataFrame, params: list) -> tuple:
        bp, sp = rules._td_pressures(df)
        sp, (down2, up2) = -sp, two_closes(df)
        return ((down2 & (bp > bp.shift(1)) & (sp < sp.shift(1))).astype(float),
                (up2 & (sp > sp.shift(1)) & (bp < bp.shift(1))).astype(float))

    def rev_diff_literal_sp(df: pd.DataFrame, params: list) -> tuple:
        bp, sp = rules._td_pressures(df)
        sp, (down2, up2) = -sp, two_closes(df)
        return ((up2 & (bp > bp.shift(1)) & (sp < sp.shift(1))).astype(float),
                (down2 & (bp < bp.shift(1)) & (sp > sp.shift(1))).astype(float))

    def anti_diff_three_closes(df: pd.DataFrame, params: list) -> tuple:
        # The leading close change dropped: down, UP, down (four closes, not five).
        d = df["Close"].diff()
        return (((d.shift(2) < 0) & (d.shift(1) > 0) & (d < 0)).astype(float),
                ((d.shift(2) > 0) & (d.shift(1) < 0) & (d > 0)).astype(float))

    must_worsen(path, "diff_up", "TD_DIFF", diff_literal_sp)
    must_worsen(path, "revdiff_down", "TD_REV_DIFF", rev_diff_literal_sp)
    must_worsen(path, "antidiff_up", "TD_ANTI_DIFF", anti_diff_three_closes)

    # Ch.1 patterns: each one's reference level or boundary moved.
    def open_vs_close(df: pd.DataFrame, params: list) -> tuple:
        c1 = df["Close"].shift(1)   # prior close instead of prior low/high
        return (((df["Open"] < c1) & (df["High"] > c1)).astype(float),
                ((df["Open"] > c1) & (df["Low"] < c1)).astype(float))

    def clop_vs_range(df: pd.DataFrame, params: list) -> tuple:
        lo, hi = df["Low"].shift(1), df["High"].shift(1)   # prior range instead of body
        return (((df["Open"] < lo) & (df["High"] > hi)).astype(float),
                ((df["Open"] > hi) & (df["Low"] < lo)).astype(float))

    def clopwin_exclusive(df: pd.DataFrame, params: list) -> tuple:
        lo, hi = rules._td_prev_body(df)
        o, c = df["Open"], df["Close"]
        inside = (o > lo) & (o < hi) & (c > lo) & (c < hi)   # strict containment
        return (inside & (c > c.shift(1))).astype(float), (inside & (c < c.shift(1))).astype(float)

    def camouflage_one_back(df: pd.DataFrame, params: list) -> tuple:
        o, h, l, c = df["Open"], df["High"], df["Low"], df["Close"]
        tl1, th1 = rules._emin(l.shift(1), c.shift(2)), rules._emax(h.shift(1), c.shift(2))
        return (((c < c.shift(1)) & (c > o) & (l < tl1)).astype(float),
                ((c > c.shift(1)) & (c < o) & (h > th1)).astype(float))

    def trap_body(df: pd.DataFrame, params: list) -> tuple:
        lo, hi = rules._td_prev_body(df)   # open inside the prior body instead of its range
        inside = (df["Open"] >= lo) & (df["Open"] <= hi)
        return ((inside & (df["High"] > df["High"].shift(1))).astype(float),
                (inside & (df["Low"] < df["Low"].shift(1))).astype(float))

    must_worsen(path, "open_buy", "TD_OPEN", open_vs_close)
    must_worsen(path, "clop_sell", "TD_CLOP", clop_vs_range)
    must_worsen(path, "clopwin_buy", "TD_CLOPWIN", clopwin_exclusive)
    must_worsen(path, "clopwin_sell", "TD_CLOPWIN", clopwin_exclusive)
    must_worsen(path, "camo_buy", "TD_CAMOUFLAGE", camouflage_one_back)
    must_worsen(path, "trap_buy", "TD_TRAP", trap_body)

    # Oscillators: TD Pressure without its volume weight; a zero-centred ROC.
    pressure, roc = reg["TD_PRESSURE"], reg["TD_ROC"]
    must_worsen(path, "pressure", "TD_PRESSURE", lambda df, params: pressure(df.assign(Volume=1.0), params))
    must_worsen(path, "roc", "TD_ROC", lambda df, params: roc(df, params) - 100.0)

    # Levels: Channel I un-crossed; REBO/Range Projection off the CURRENT bar's
    # range (look-ahead); REBO Q3 projected off the raw low instead of the true low.
    channel, rebo, proj = reg["TD_CHANNEL1"], reg["TD_REBO"], reg["TD_RANGE_PROJ"]
    must_worsen(path, "chan1_upper", "TD_CHANNEL1",
                lambda df, params: channel(df.assign(Low=df["High"], High=df["Low"]), params))

    def rebo_current_range(df: pd.DataFrame, params: list) -> tuple:
        out = list(rebo(df, params))
        tr = rules._td_true_range(df, shift=0)
        out[0] = df["Open"] + tr * float(params[0])
        return tuple(out)

    def rebo_raw_low_q3(df: pd.DataFrame, params: list) -> tuple:
        out = list(rebo(df, params))
        c, upper1 = df["Close"], out[0]
        q3 = (df["High"] > upper1) & (2.0 * c.shift(1) - df["Low"].shift(1) < upper1) & c.shift(2).notna()
        out[5] = q3.astype(float)
        return tuple(out)

    must_worsen(path, "rebo_upper1", "TD_REBO", rebo_current_range)
    must_worsen(path, "rebo_upper_q3", "TD_REBO", rebo_raw_low_q3)
    must_worsen(path, "rp_high", "TD_RANGE_PROJ", lambda df, params: tuple(b2_early(s) for s in proj(df, params)))

    # Propulsion: the Z pivot's confirmation lag; one bar early must fail.
    prop = reg["TD_PROPULSION"]
    must_worsen(path, "prop_up_threshold", "TD_PROPULSION",
                lambda df, params: tuple(b2_early(s) for s in prop(df, params)))
    must_worsen(path, "prop_down_target", "TD_PROPULSION",
                lambda df, params: tuple(b2_early(s) for s in prop(df, params)))

    # TD Pressure's flat bar contributes 0; a reference that blanks it (NaN) must
    # fail on an export that has flat bars.
    def pressure_flat_nan(df: pd.DataFrame, params: list) -> pd.Series:
        return pressure(df.assign(High=df["High"].where(df["High"] != df["Low"])), params)

    must_worsen(b2_flat_bar_file(path), "pressure", "TD_PRESSURE", pressure_flat_nan)


def drift_patterns_alt(path: Path) -> None:
    # Level-1 Propulsion: the one-bar confirmation lag; one bar early must fail.
    prop = parity.rules.PSEUDO_REGISTRY["TD_PROPULSION"]
    must_worsen(path, "prop_up_threshold", "TD_PROPULSION",
                lambda df, params: tuple(b2_early(s) for s in prop(df, params)))
    must_worsen(path, "prop_down_threshold", "TD_PROPULSION",
                lambda df, params: tuple(b2_early(s) for s in prop(df, params)))


# CSV name -> drift controls run on its EURUSD D1 export (each must raise mismatches).
DRIFT = {
    "TD_SEQ": drift_seq,
    "TD_MA1": drift_ma,
    "TD_POINT_L3": drift_point,
    "TD_REI": drift_rei,
    "DEMARKER": drift_demarker,
    "TD_COMBO_P1": drift_combo_v1,
    "TD_COMBO_P2": drift_combo_v2,
    "TD_DWAVE": drift_dwave,
    "TD_PATTERNS": drift_patterns,
    "TD_PATTERNS_ALT": drift_patterns_alt,
    "TD_WALDO": drift_waldo,
    "TD_TREND_FACTOR": drift_trend_factor,
    "TD_RETRACEMENT": drift_retracement,
    "TD_LINES_L1": drift_lines,
    "TD_LINES_L3": drift_lines_lookback,
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=Path("C:/Program Files/Pepperstone MetaTrader 5/MetaEditor64.exe"))
    parser.add_argument("--terminal-data", type=Path,
                        default=Path(os.environ["APPDATA"]) / "MetaQuotes/Terminal/73B7A2420D6397DFF9014A20F1201F97")
    parser.add_argument("--only", default="", help="comma-separated CSV names (keys of INDICATORS); default all")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This test executes the Windows MT5 runtime")
    only = tuple(n for n in args.only.split(",") if n) or tuple(INDICATORS)
    if unknown := set(only) - set(INDICATORS):
        parser.error(f"unknown --only names {sorted(unknown)}; choose from {list(INDICATORS)}")
    (ROOT / "scratch").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="td_mt5_", dir=ROOT / "scratch"))
    print(f"Retained test artifacts: {work}", flush=True)
    runid = uuid.uuid4().hex[:10]
    terminal = work / "terminal64.exe"
    shutil.copy2(args.editor.parent / "terminal64.exe", terminal)
    for folder in ("Scripts", "Indicators"):
        (work / "MQL5" / folder).mkdir(parents=True)
    shutil.copytree(args.terminal_data / "bases/Default/Symbols", work / "bases/Default/Symbols")
    for symbol, history in SYMBOLS.items():
        install_history(args.terminal_data / "bases" / history, work / "bases/Default/History" / symbol)
    for name in dict.fromkeys(INDICATORS[n] for n in only if INDICATORS[n]):
        shutil.copy2(compile_mql(ROOT / f"{name}.mq5", args.editor, work), work / f"MQL5/Indicators/{name}.ex5")
    compile_mql(ROOT / "mql5/Scripts/DLV_TD_Export.mq5", args.editor, work)
    # Only the runner-owned copy writes to the portable terminal's local Files.
    source = work / "DLV_TD_Export.mq5"
    source.write_text((ROOT / "mql5/Scripts/DLV_TD_Export.mq5").read_text().replace("|FILE_COMMON", ""))
    shutil.copy2(compile_mql(source, args.editor, work), work / "MQL5/Scripts/DLV_TD_Export.ex5")
    files = work / "MQL5/Files"
    paths = []
    for symbol in SYMBOLS:
        for period in PERIODS:
            prefix = f"DLV_TD_{runid}"
            execute(terminal, work, symbol, period, prefix, only)
            found = sorted(files.glob(f"{prefix}_{symbol}_PERIOD_{period}_*.csv"))
            names = sorted(n for p in found for n in only if p.name.endswith(f"_{n}.csv"))
            if len(found) != len(only) or names != sorted(only):
                raise AssertionError(f"{symbol} {period}: expected {only}, found {[p.name for p in found]}")
            paths += found
    print(f"Exported {len(paths)} CSVs ({len(SYMBOLS)} symbols x {len(PERIODS)} periods x "
          f"{len(only)} indicators)", flush=True)
    failed, bars, summary = [], 0, []
    for path in paths:
        name, n, counts = parity.check(path)
        # The checker picks its reference from the CSV's own indicator column; it
        # must be the variant the filename (and the --only selection) asked for.
        expected = [k for k in only if path.name.endswith(f"_{k}.csv")]
        if expected != [name]:
            raise AssertionError(f"{path.name} declares indicator {name!r}, expected {expected}")
        bars += n
        summary.append(f"  {name} {path.name.split('_', 3)[3].rsplit('_', 3)[0]:22s} {n:>7,} bars  "
                       + "  ".join(f"{k}={v}" for k, v in counts.items()))
        if any(counts.values()):
            failed.append(path.name)
    print("Summary (mismatches per mapped column):", *summary, sep="\n", flush=True)
    print("Reference drift controls:", flush=True)
    for name, control in DRIFT.items():
        if name in only:
            control(next(p for p in paths if "_EURUSD_PERIOD_D1_" in p.name and p.name.endswith(f"_{name}.csv")))
    if failed:
        raise SystemExit(f"FAIL: {len(failed)}/{len(paths)} CSVs differ from the Lab ({bars:,} bars compared)")
    print(f"All {len(paths)} TD parity CSVs passed ({bars:,} bars compared)", flush=True)


if __name__ == "__main__":
    main()
