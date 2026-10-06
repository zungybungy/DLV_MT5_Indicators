"""Live (incremental) vs full-recompute parity of the TD indicators in an isolated MT5.

Windows-only integration test. Builds a portable, non-trading terminal under
scratch/ (cached bars copied read-only from the live terminal, as
_smoke_test_td_mql5.py does) and runs mql5/Scripts/DLV_TD_LiveReplay.mq5 in it.
The Strategy Tester refuses to start without an account, so the replay drives
the live path itself: an offline custom clone of each symbol receives its cached
bars as ticks (CustomTicksAdd, four per --feed bar), and the indicator handles
update in the symbol thread exactly as on a live chart. Per indicator / input
set of Scripts/DLV_TD_Export.mq5, per period and every buffer:

  a_close  handle A at shift 1 on the new bar's first tick (what a live EA reads)
  a_end    handle A re-read over the window at the end (a closed bar rewritten later)
  b        handle B created at the end: a full recompute over the same bars

a_close == b and a_end == b must hold exactly (EMPTY == EMPTY). Negative
control: A at shift 0 on the new bar's first tick (the forming bar) must differ
from b. No account, orders or file deletions; artifacts are retained.

python smoke_test/_smoke_test_td_live_mql5.py
"""
from __future__ import annotations

import argparse
import math
import importlib.util
import os
import shutil
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
from dateutil.easter import easter

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("td_smoke", ROOT / "smoke_test/_smoke_test_td_mql5.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)

SYMBOLS = {k: smoke.SYMBOLS[k] for k in ("EURUSD", "US500.a")}
PERIODS = ("H4", "D1")
# History before the window (A's starting state), and the replayed live window.
PRELOAD, START, STOP = "2022-09-01", "2024-09-01", "2026-09-01"
INDICATORS = {n: m for n, m in smoke.INDICATORS.items() if m}  # DEMARKER is native: not ours
SCRIPT = "DLV_TD_LiveReplay"
# Per-bar OnCalculate counter riding in the same symbol thread: proves forming
# bars were recalculated (buffer 0) and paces the replay (buffer 1, the running
# total of calls: a per-bar count can read the same across a new bar). Buffer 1
# needs its own plot: with indicator_plots 0, CopyBuffer of buffer 1 returns -1.
COUNTER = """#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots 2
#property indicator_type1 DRAW_NONE
#property indicator_type2 DRAW_NONE
double C[],T[];
double total=0;
int OnInit() { SetIndexBuffer(0,C,INDICATOR_DATA); SetIndexBuffer(1,T,INDICATOR_DATA); return INIT_SUCCEEDED; }
int OnCalculate(const int rates_total,const int prev_calculated,const int begin,const double &price[])
{
   total++;
   if(prev_calculated==0) { ArrayInitialize(C,0); ArrayInitialize(T,0); C[rates_total-1]=1; T[rates_total-1]=total; return rates_total; }
   for(int i=prev_calculated;i<rates_total;i++) { C[i]=0; T[i]=0; }
   C[rates_total-1]+=1;
   T[rates_total-1]=total;
   return rates_total;
}
"""


def epoch(day: str) -> int:
    return int(datetime.fromisoformat(day).replace(tzinfo=timezone.utc).timestamp())


def replay(terminal: Path, work: Path, symbol: str, only: tuple[str, ...], days: tuple[str, str, str],
           feed: str) -> None:
    preset = work / "MQL5/Presets" / f"{SCRIPT}.set"
    preset.parent.mkdir(parents=True, exist_ok=True)
    custom = "DLVLIVE_" + symbol.replace(".", "_")
    preload, start, stop = (epoch(d) for d in days)
    preset.write_text("\n".join([
        f"InpSource={symbol}", f"InpCustom={custom}", f"InpPreload={preload}", f"InpFrom={start}",
        f"InpTo={stop}", f"InpPeriods={','.join(PERIODS)}", f"InpOnly={','.join(only)}", f"InpFeed={feed}",
    ]), encoding="ascii")
    config = work / f"{SCRIPT}.ini"
    config.write_text("\n".join([
        "[Experts]", "Enabled=0", "AllowLiveTrading=0", "AllowDllImport=0",
        "[StartUp]", f"Symbol={symbol}", "Period=H1", f"Script={SCRIPT}",
        f"ScriptParameters={preset.name}", "ShutdownTerminal=1",
    ]), encoding="ascii")
    smoke.hidden_run(f'"{terminal}" /portable /config:"{config}"', timeout=4 * 3600)


def declared_buffers(name: str) -> int:
    """`#property indicator_buffers` of the indicator's source: the contract the CSV's #calc must match."""
    for line in (ROOT / f"{INDICATORS[name]}.mq5").read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("#property indicator_buffers"):
            return int(line.split()[2])
    raise AssertionError(f"{INDICATORS[name]}.mq5 declares no indicator_buffers")


def check_coverage(name: str, times: list[str], days: tuple[str, str, str]) -> None:
    """Every trading weekday of the window has a recorded bar, judged by the calendar
    rather than by what CopyRates returned (a partial feed would shrink the window)."""
    start, stop = pd.Timestamp(days[1]), pd.Timestamp(days[2])
    weekdays = pd.bdate_range(start, stop - pd.Timedelta(days=1))[:-1]  # the last bar is still forming at the end
    closed = {d for d in weekdays if (d.month, d.day) in ((12, 25), (1, 1))
              or d.date() == easter(d.year) - pd.Timedelta(days=2)}  # Christmas, New Year, Good Friday
    seen = set(pd.to_datetime([int(t) for t in times], unit="s").normalize())
    if missing := [d.strftime("%Y-%m-%d") for d in weekdays if d not in seen and d not in closed]:
        raise AssertionError(f"{name}: no recorded bar on {len(missing)} trading weekdays of {days[1]}..{days[2]} "
                             f"(first {missing[:5]}); the replayed feed did not cover the window")


def load(path: Path, days: tuple[str, str, str]) -> tuple[dict, pd.DataFrame]:
    lines = path.read_text(encoding="ascii").splitlines()
    if lines[-1] != "#done":
        raise AssertionError(f"{path.name} incomplete ({lines[-1]}); see the terminal's MQL5/Logs")
    meta = dict(kv.split("=", 1) for kv in lines[0].split(",")[1:])
    if int(meta["copy_failures"]):
        raise AssertionError(f"{path.name}: {meta['copy_failures']} CopyBuffer calls on handle A failed")
    if int(meta["timeouts"]):
        raise AssertionError(f"{path.name}: {meta['timeouts']} timeouts (a new bar read before every A handle "
                             "had counted it, or a tick batch never calculated)")
    if float(meta["calls_min"]) < 2:
        raise AssertionError(f"{path.name}: a closed bar was calculated only {meta['calls_min']}x while forming")
    if meta["init_oldest"] != meta["end_oldest"]:
        raise AssertionError(f"{path.name}: the oldest bar moved ({meta}); A and B saw different history")
    calc = [dict(kv.split("=", 1) for kv in l.split(",")[1:]) for l in lines if l.startswith("#calc")]
    for c in calc:
        if c["a"] != c["b"] or c["handle_a"] == c["handle_b"]:
            raise AssertionError(f"{path.name}: A and B not comparable {c}")
        if int(c["buffers"]) != declared_buffers(c["indicator"]):
            raise AssertionError(f"{path.name}: {c['indicator']} exported {c['buffers']} buffers, its source "
                                 f"declares {declared_buffers(c['indicator'])}")
    frame = pd.read_csv(path, comment="#", dtype=str, keep_default_na=False)
    # The rows must be the complete grid: every #calc indicator x each of its
    # declared buffers x every recorded bar, exactly once. A dropped buffer or bar
    # would otherwise shrink the comparison and still pass.
    times = [l.split(",")[1] for l in lines if l.startswith("#calls,")]
    if len(times) != int(meta["recorded"]) or len(set(times)) != len(times):
        raise AssertionError(f"{path.name}: {len(times)} #calls bars for recorded={meta['recorded']}")
    check_coverage(path.name, times, days)
    want = {(c["indicator"], str(b), t) for c in calc for b in range(int(c["buffers"])) for t in times}
    got = list(zip(frame["indicator"], frame["buffer"], frame["time"]))
    if len(got) != len(want) or set(got) != want:
        raise AssertionError(f"{path.name}: rows are not the indicator x buffer x bar grid "
                             f"({len(got)} rows, {len(set(got) & want)} of {len(want)} expected cells)")
    return meta, frame


def nonzero(col: pd.Series) -> int:
    """Values that carry a signal: neither EMPTY_VALUE ('') nor 0."""
    return int(((col != "") & (pd.to_numeric(col, errors="coerce").fillna(1.0) != 0.0)).sum())


def compare(frame: pd.DataFrame, label: str) -> tuple[int, int, int]:
    """Exact string comparison (%.17g round-trips a double); prints per indicator."""
    bad_close = bad_end = bad_form = 0
    for name, g in frame.groupby("indicator", sort=False):
        mc, me, mf = g["a_close"] != g["b"], g["a_end"] != g["b"], g["a_forming"] != g["b"]
        bars = g["time"].nunique()
        signals = {int(b): nonzero(x["b"]) for b, x in g.groupby(g["buffer"].astype(int))}
        live = sum(1 for v in signals.values() if v)
        print(f"  {label:18s} {name:19s} {bars:>5} bars  A-vs-B={int(mc.sum()):<5} end-vs-B={int(me.sum()):<5} "
              f"forming-vs-B={int(mf.sum()):<6} buffers with signal {live}/{len(signals)}  "
              f"non-empty/non-zero per buffer {list(signals.values())}", flush=True)
        for kind, mask, col in (("A-vs-B", mc, "a_close"), ("end-vs-B", me, "a_end")):
            if mask.any():
                first = g[mask].assign(t=lambda d: d["time"].astype(int)).sort_values("t").iloc[0]
                print(f"    FIRST {kind} mismatch: buffer {first['buffer']} bar "
                      f"{pd.Timestamp(int(first['time']), unit='s')} {col}={first[col]!r} b={first['b']!r}; "
                      f"buffers {sorted(set(g[mask]['buffer'].astype(int)))}", flush=True)
        bad_close += int(mc.sum())
        bad_end += int(me.sum())
        bad_form += int(mf.sum())
    return bad_close, bad_end, bad_form


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=Path("C:/Program Files/Pepperstone MetaTrader 5/MetaEditor64.exe"))
    parser.add_argument("--terminal-data", type=Path,
                        default=Path(os.environ["APPDATA"]) / "MetaQuotes/Terminal/73B7A2420D6397DFF9014A20F1201F97")
    parser.add_argument("--only", default="", help="comma-separated indicator names (keys of INDICATORS); default all")
    parser.add_argument("--symbols", default=",".join(SYMBOLS))
    parser.add_argument("--days", default=f"{PRELOAD},{START},{STOP}", help="preload,start,stop (ISO dates)")
    # M15 = 16 ticks per H4 bar, 96 per D1 bar: every forming bar recalculated many
    # times at ~1/15 of an M1 feed's run time (M1 mirrors the tester's "1 minute OHLC").
    parser.add_argument("--feed", default="M15", choices=("M1", "M5", "M15"), help="bars replayed as 4 ticks each")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This test executes the Windows MT5 runtime")
    only = tuple(n for n in args.only.split(",") if n) or tuple(INDICATORS)
    if unknown := set(only) - set(INDICATORS):
        parser.error(f"unknown --only names {sorted(unknown)}; choose from {list(INDICATORS)}")
    symbols, days = args.symbols.split(","), tuple(args.days.split(","))
    (ROOT / "scratch").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="td_live_", dir=ROOT / "scratch"))
    print(f"Retained test artifacts: {work}", flush=True)
    terminal = work / "terminal64.exe"
    shutil.copy2(args.editor.parent / "terminal64.exe", terminal)
    # CopyRates stops at "Max bars in chart" (100000 by default: ~3 months of M1);
    # the feed must reach back to the preload date.
    (work / "config").mkdir()
    (work / "config/common.ini").write_text("[Charts]\nMaxBars=3000000\n", encoding="utf-16")
    for folder in ("Scripts", "Indicators/LiveB"):
        (work / "MQL5" / folder).mkdir(parents=True)
    shutil.copytree(args.terminal_data / "bases/Default/Symbols", work / "bases/Default/Symbols")
    for symbol in symbols:
        smoke.install_history(args.terminal_data / "bases" / SYMBOLS[symbol], work / "bases/Default/History" / symbol)
    # Handle B loads a byte-identical copy from Indicators/LiveB so the terminal
    # cannot share A's instance (identical iCustom parameters share one calculation).
    for name in dict.fromkeys(INDICATORS[n] for n in only):
        ex5 = smoke.compile_mql(ROOT / f"{name}.mq5", args.editor, work)
        shutil.copy2(ex5, work / f"MQL5/Indicators/{name}.ex5")
        shutil.copy2(ex5, work / f"MQL5/Indicators/LiveB/{name}.ex5")
    counter = work / "DLV_CalcCounter.mq5"
    counter.write_text(COUNTER, encoding="ascii")
    shutil.copy2(smoke.compile_mql(counter, args.editor, work), work / "MQL5/Indicators/DLV_CalcCounter.ex5")
    shutil.copy2(smoke.compile_mql(ROOT / f"mql5/Scripts/{SCRIPT}.mq5", args.editor, work),
                 work / f"MQL5/Scripts/{SCRIPT}.ex5")

    totals, failed, forming, perturbed = [0, 0, 0], [], {}, False
    for symbol in symbols:
        began = time.perf_counter()
        replay(terminal, work, symbol, only, days, args.feed)
        print(f"{symbol} replay {days[1]}..{days[2]} (preload from {days[0]}, {args.feed} feed): "
              f"{time.perf_counter() - began:.0f}s", flush=True)
        for period in PERIODS:
            path = work / "MQL5/Files" / f"DLV_TD_Live_{symbol}_{period}.csv"
            if not path.exists():
                raise AssertionError(f"{symbol} {period}: no {path.name}; see {work / 'MQL5/Logs'}")
            meta, frame = load(path, days)
            print(f"{symbol} {period}: {meta['recorded']} closed bars recorded; forming recomputes per bar "
                  f"min {meta['calls_min']} median {meta['calls_median']}", flush=True)
            names = list(dict.fromkeys(frame["indicator"]))
            if names != list(only):
                raise AssertionError(f"{symbol} {period}: expected {only}, CSV has {names}")
            close, end, form = compare(frame, f"{symbol} {period}")
            if not perturbed:
                # Negative control 2: one closed-bar value moved by one ulp must be
                # caught by the A-vs-B comparison itself.
                row = frame.index[(frame["b"] != "") & (frame["b"] != "0") & (frame["a_close"] == frame["b"])][0]
                sub = frame[frame["indicator"] == frame.loc[row, "indicator"]].copy()
                base = compare(sub, "unperturbed")[0]
                sub.loc[row, "a_close"] = "%.17g" % math.nextafter(float(sub.loc[row, "b"]), math.inf)
                if compare(sub, "perturbed")[0] != base + 1:
                    raise AssertionError("Negative control failed: a one-ulp closed-bar change was not caught")
                print(f"Negative control: {sub.loc[row, 'indicator']} buffer {sub.loc[row, 'buffer']} a_close "
                      f"{sub.loc[row, 'b']} -> {sub.loc[row, 'a_close']} (one ulp) caught", flush=True)
                perturbed = True
            for k, v in enumerate((close, end, form)):
                totals[k] += v
            forming[f"{symbol} {period}"] = form
            if close or end:
                failed.append(f"{symbol} {period}")
    # Negative control: the comparison must be able to fail. A's forming bar after
    # its first tick is not its closed value, so it must differ from B somewhere.
    if totals[2] == 0:
        raise AssertionError("Negative control failed: A's forming bar matched B everywhere; the comparison is vacuous")
    print(f"Negative control: forming bar (A shift 0, first tick) vs B -> {forming}", flush=True)
    if failed:
        raise SystemExit(f"FAIL: live != history on {failed} (A-vs-B {totals[0]:,}, end-vs-B {totals[1]:,})")
    print(f"All live closed-bar values equal the full recompute ({len(symbols)} symbols x {len(PERIODS)} periods)",
          flush=True)


if __name__ == "__main__":
    main()
