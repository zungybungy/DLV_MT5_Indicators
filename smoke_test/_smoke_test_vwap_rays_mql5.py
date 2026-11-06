"""VWAP.mq5 rays in an isolated, non-trading portable MT5 terminal.

Windows-only integration test. Compiles ./VWAP.mq5, attaches it through chart
templates (as a user would) to an offline custom symbol, grows the history bar
by bar so the incremental path runs, and checks every ray object against the
Lab chart's chartVwapRays (../DLV_Quant_Lab/static/app.js), fed VWAP values
recomputed here from the exported bars. One chart carries two session VWAPs
(typical and high source) whose rays must not collide; ray colours follow the
VWAP line unless InpRayColor is set; an iCustom-only instance draws nothing.
No account credentials, live terminal settings, orders or file deletions; the
generated terminal is retained under scratch/ for inspection.

python smoke_test/_smoke_test_vwap_rays_mql5.py
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pandas as pd

from _smoke_test_micaletti_mql5 import compile_mql, execute

ROOT = Path(__file__).resolve().parent.parent
LAB_JS = ROOT.parent / "DLV_Quant_Lab" / "static" / "app.js"
SYMBOL = "DLVVwapRay"
LINE_COLOR = 65535        # template VWAP line colour; rays follow it by default
# Per chart: (anchor, source, InpRayColor or None). Session and month anchors
# have the same period keys as the Lab. ENUM_APPLIED_PRICE: 3 high, 6 typical.
CHARTS = [[(0, 6, None), (0, 3, 16711680)], [(2, 6, 255)]]
ICUSTOM_ANCHOR = 1

SCRIPT = r'''
string Sym = "%(sym)s";

MqlRates Bar(const int i)
  {
   MqlRates r;
   double mid = 1.1 + 0.00002 * i + 0.004 * MathSin(0.021 * i) + 0.0015 * MathSin(0.37 * i);
   r.time = D'2024.01.01' + i * 3600;
   r.open = mid;
   r.close = mid + 0.0004 * MathSin(1.3 * i);
   r.high = MathMax(r.open, r.close) + 0.0003 + 0.0002 * MathAbs(MathSin(0.9 * i));
   r.low = MathMin(r.open, r.close) - 0.0003 - 0.0002 * MathAbs(MathCos(0.7 * i));
   r.tick_volume = 100 + (i %% 17) * 13;
   r.real_volume = 0;
   r.spread = 0;
   return(r);
  }

int Count(const long chart)
  {
   int n = 0;
   for(int k = ObjectsTotal(chart, 0, -1) - 1; k >= 0; k--)
      if(StringFind(ObjectName(chart, k, 0, -1), "VWAP ray ") == 0) n++;
   return(n);
  }

// Templates are applied from the chart's queue and occasionally not at all:
// re-apply until the chart lists the template's indicators.
bool Apply(const long chart, const string file, const int indicators)
  {
   for(int attempt = 0; attempt < 4; attempt++)
     {
      if(!ChartApplyTemplate(chart, "\\Profiles\\Templates\\" + file)) return(false);
      for(int t = 0; t < 40; t++)
        {
         ChartRedraw(chart);
         Sleep(250);
         if(ChartIndicatorsTotal(chart, 0) == indicators) return(true);
        }
     }
   return(false);
  }

// Settled: every bar loaded and the ray count unchanged for 2 s. (Two VWAPs
// share the short name, and ChartIndicatorGet's handle then reports no
// BarsCalculated.) Settling early cannot pass: the rays are compared exactly.
bool Settle(const long chart, const int bars)
  {
   int last = -1, same = 0, loaded = 0;
   for(int t = 0; t < 240; t++)
     {
      Sleep(250);
      ChartRedraw(chart);
      loaded = Bars(Sym, PERIOD_M1);
      int n = Count(chart);
      if(loaded == bars && n == last && ++same >= 8) return(true);
      if(n != last) same = 0;
      last = n;
     }
   PrintFormat("VWAPRAY settle: indicators=%%d bars=%%d/%%d objects=%%d",
               ChartIndicatorsTotal(chart, 0), loaded, bars, last);
   return(false);
  }

void OnStart()
  {
   int total = %(total)d, first = %(first)d;
   int counts[] = {%(counts)s};
   if(!SymbolInfoInteger(Sym, SYMBOL_EXIST)) CustomSymbolCreate(Sym, "DLVParity");
   CustomSymbolSetInteger(Sym, SYMBOL_DIGITS, 5);
   CustomSymbolSetDouble(Sym, SYMBOL_POINT, 0.00001);
   MqlRates rates[];
   ArrayResize(rates, first);
   for(int i = 0; i < first; i++) rates[i] = Bar(i);
   if(CustomRatesUpdate(Sym, rates) != first) { Print("VWAPRAY rates failed"); return; }
   SymbolSelect(Sym, true);
   MqlRates loaded[];
   if(CopyRates(Sym, PERIOD_M1, 0, first, loaded) != first) { Print("VWAPRAY sync failed"); return; }

   long charts[];
   ArrayResize(charts, ArraySize(counts));
   for(int a = 0; a < ArraySize(counts); a++)
     {
      charts[a] = ChartOpen(Sym, PERIOD_M1);
      if(charts[a] == 0 || !Apply(charts[a], StringFormat("vwapray%%d.tpl", a), counts[a]))
        { PrintFormat("VWAPRAY template %%d failed: indicators=%%d err=%%d", a, ChartIndicatorsTotal(charts[a], 0), GetLastError()); return; }
      if(!Settle(charts[a], first)) { Print("VWAPRAY initial settle failed ", a); return; }
     }
   // Live growth: append bars one at a time (incremental OnCalculate).
   for(int i = first; i < total; i++)
     {
      MqlRates one[1];
      one[0] = Bar(i);
      if(CustomRatesUpdate(Sym, one) != 1) { Print("VWAPRAY append failed"); return; }
      Sleep(20);
     }
   int ih = iCustom(Sym, PERIOD_M1, "VWAP", "", false, %(icustom)d, PRICE_TYPICAL, VOLUME_TICK, 0);
   for(int t = 0; t < 120 && (ih == INVALID_HANDLE || BarsCalculated(ih) != total); t++) Sleep(250);

   int f = FileOpen("vwapray_result.csv", FILE_WRITE | FILE_ANSI | FILE_TXT);
   MqlRates r[];
   if(CopyRates(Sym, PERIOD_M1, 0, total, r) != total) { Print("VWAPRAY copy failed"); return; }
   for(int i = 0; i < total; i++)
      FileWriteString(f, StringFormat("bar,%%I64d,%%.17g,%%.17g,%%.17g,%%I64d\n", (long)r[i].time,
                      r[i].high, r[i].low, r[i].close, r[i].tick_volume));
   for(int a = 0; a < ArraySize(charts); a++)
     {
      long c = charts[a];
      if(!Settle(c, total)) { Print("VWAPRAY final settle failed ", a); return; }
      for(int k = 0; k < ObjectsTotal(c, 0, -1); k++)
        {
         string name = ObjectName(c, k, 0, -1);
         if(StringFind(name, "VWAP ray ") != 0) continue;
         FileWriteString(f, StringFormat("ray,%%d,%%s,%%I64d,%%I64d,%%.17g,%%.17g,%%I64d,%%I64d,%%I64d,%%I64d\n", a, name,
                         ObjectGetInteger(c, name, OBJPROP_TIME, 0), ObjectGetInteger(c, name, OBJPROP_TIME, 1),
                         ObjectGetDouble(c, name, OBJPROP_PRICE, 0), ObjectGetDouble(c, name, OBJPROP_PRICE, 1),
                         ObjectGetInteger(c, name, OBJPROP_RAY_RIGHT), ObjectGetInteger(c, name, OBJPROP_COLOR),
                         ObjectGetInteger(c, name, OBJPROP_STYLE), ObjectGetInteger(c, name, OBJPROP_TYPE)));
        }
     }
   // Ray objects on any other chart (the script's own) can only be strays.
   int stray = 0;
   for(long c = ChartFirst(); c >= 0; c = ChartNext(c))
     {
      bool mine = false;
      for(int a = 0; a < ArraySize(charts); a++) mine |= c == charts[a];
      if(!mine) stray += Count(c);
     }
   FileWriteString(f, StringFormat("icustom,%%d,%%d\n", ih != INVALID_HANDLE && BarsCalculated(ih) == total, stray));
   FileClose(f);
   Print("VWAPRAY done");
  }
'''


def template(source: Path, instances: list[tuple]) -> str:
    text = source.read_text(encoding="utf-16").replace("\r\n", "\n")
    head = text[:text.index("<window>")]
    head = "\n".join(f"symbol={SYMBOL}" if line.startswith("symbol=") else
                     "period_type=0" if line.startswith("period_type=") else
                     "period_size=1" if line.startswith("period_size=") else line
                     for line in head.split("\n") if not line.startswith(("id=", "description=")))
    path = text.index("path=Indicators\\VWAP.ex5")
    block = text[text.rindex("<indicator>", 0, path):text.index("</indicator>", path) + len("</indicator>")]
    blocks = []
    for anchor, src, ray_color in instances:
        one = "\n".join(f"InpAnchor={anchor}" if line.startswith("InpAnchor=") else
                        f"InpSource={src}" if line.startswith("InpSource=") else
                        f"color={LINE_COLOR}" if line.startswith("color=") and "," not in line else line
                        for line in block.split("\n"))
        if ray_color is not None:
            one = one.replace("</inputs>", f"Rays Settings=\nInpRayColor={ray_color}\n</inputs>")
        blocks.append(one)
    main = text[text.index("<indicator>\nname=Main"):]
    main = main[:main.index("</indicator>") + len("</indicator>")]
    body = "\n\n".join([main] + blocks)
    return f"{head}<window>\nheight=100.000000\n\n{body}\n</window>\n</chart>\n"


def lab_rays(bars: list[dict], values: list, anchor: int) -> list[dict]:
    src = LAB_JS.read_text(encoding="utf-8")
    start = src.index("function chartVwapRays(")
    script = src[start:src.index("\n}\n", start) + 2] + """
let input = ""; process.stdin.on("data", d => input += d).on("end", () => {
  const {bars, values, anchor} = JSON.parse(input);
  process.stdout.write(JSON.stringify(chartVwapRays(bars, new Map(values), anchor)));
});"""
    done = subprocess.run(["node", "-e", script], input=json.dumps(
        {"bars": bars, "values": values, "anchor": anchor}), capture_output=True,
        text=True, encoding="utf-8", check=True)
    return json.loads(done.stdout)


def vwap(bars: pd.DataFrame, anchor: int, src: int) -> pd.Series:
    """VWAP.mq5's running sums, sequential like its loop."""
    price = bars["high"] if src == 3 else (bars["high"] + bars["low"] + bars["close"]) / 3.0
    stamp = pd.to_datetime(bars["time"], unit="s")
    key = bars["time"] // 86400 if anchor == 0 else stamp.dt.year * 12 + stamp.dt.month
    return (price * bars["volume"]).groupby(key).cumsum() / bars["volume"].groupby(key).cumsum()


def check(result: Path, total: int) -> None:
    rows = [line.split(",") for line in result.read_text(encoding="ascii").splitlines()]
    icustom = [r for r in rows if r[0] == "icustom"]
    assert icustom == [["icustom", "1", "0"]], f"iCustom instance drew rays or did not calculate: {icustom}"
    print("PASS - iCustom-only instance calculated and drew no rays", flush=True)
    bars = pd.DataFrame([[int(r[1]), float(r[2]), float(r[3]), float(r[4]), float(r[5])]
                         for r in rows if r[0] == "bar"], columns=["time", "high", "low", "close", "volume"])
    assert len(bars) == total, len(bars)
    times = bars["time"].tolist()
    chart_bars = bars[["time", "high", "low"]].to_dict("records")
    prefixes = set()
    for chart, instances in enumerate(CHARTS):
        objs = [r for r in rows if r[0] == "ray" and r[1] == str(chart)]
        expected = 0
        for anchor, src, ray_color in instances:
            color = LINE_COLOR if ray_color is None else ray_color
            got = sorted((r for r in objs if int(r[8]) == color), key=lambda r: int(r[3]))
            want = lab_rays(chart_bars, [[t, v] for t, v in zip(times, vwap(bars, anchor, src))], anchor)
            expected += len(want)
            assert len(got) == len(want) >= 3, (chart, anchor, src, len(got), len(want))
            # One instance-specific prefix per instance: "VWAP ray <token> <start>".
            prefix = {r[2].rsplit(" ", 1)[0] for r in got}
            assert len(prefix) == 1 and not prefix & prefixes, (chart, prefix, prefixes)
            prefixes |= prefix
            for g, w in zip(got, want):
                t1, t2, p1, p2, ray, style, kind = (int(g[3]), int(g[4]), float(g[5]), float(g[6]),
                                                    int(g[7]), int(g[9]), int(g[10]))
                assert t1 == times[w["from"]] and p1 == p2, (chart, g, w)
                assert np.isclose(p1, w["price"], rtol=0, atol=1e-12), (chart, g, w)
                assert (ray == 1) if w["to"] is None else (ray == 0 and t2 == times[w["to"]]), (chart, g, w)
                assert (kind, style) == (2, 1), (chart, g)   # OBJ_TREND, STYLE_DASH
            print(f"PASS - chart {chart} anchor {anchor} source {src}: {len(got)} rays == Lab chartVwapRays "
                  f"({sum(w['to'] is None for w in want)} untouched), colour {color}, dashed", flush=True)
        assert len(objs) == expected, (chart, len(objs), expected)   # nothing extra (e.g. an iCustom stray)
    print("PASS - same-anchor instances keep separate rays; no extra objects on any chart", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=Path("C:/Program Files/Pepperstone MetaTrader 5/MetaEditor64.exe"))
    parser.add_argument("--terminal-data", type=Path)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This test executes the Windows MT5 runtime")
    base = Path(os.environ["APPDATA"]) / "MetaQuotes/Terminal"
    candidates = [p for p in base.iterdir() if (p / "MQL5/Profiles/Templates/Demark_VWAP.tpl").is_file()]
    data = args.terminal_data or (candidates[0] if len(candidates) == 1 else None)
    if data is None:
        parser.error("Choose --terminal-data (must hold Profiles/Templates/Demark_VWAP.tpl)")
    (ROOT / "scratch").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="vwapray_mt5_", dir=ROOT / "scratch"))
    print(f"Retained test artifacts: {work}", flush=True)
    terminal = work / "terminal64.exe"
    shutil.copy2(args.editor.parent / "terminal64.exe", terminal)
    for folder in ("Scripts", "Indicators", "Profiles/Templates", "Files"):
        (work / "MQL5" / folder).mkdir(parents=True)
    shutil.copytree(data / "bases/Default/Symbols", work / "bases/Default/Symbols")
    shutil.copytree(data / "bases/Default/History/EURUSD", work / "bases/Default/History/EURUSD")
    source = work / "VWAP.mq5"
    shutil.copy2(ROOT / "VWAP.mq5", source)
    shutil.copy2(compile_mql(source, args.editor, work), work / "MQL5/Indicators/VWAP.ex5")
    for chart, instances in enumerate(CHARTS):
        (work / f"MQL5/Profiles/Templates/vwapray{chart}.tpl").write_text(
            template(data / "MQL5/Profiles/Templates/Demark_VWAP.tpl", instances), encoding="utf-16")
    total, first = 24 * 120, 24 * 100
    script = work / "DLV_VwapRay_Test.mq5"
    script.write_text(SCRIPT % dict(sym=SYMBOL, total=total, first=first, icustom=ICUSTOM_ANCHOR,
                                    counts=", ".join(str(len(i)) for i in CHARTS)), encoding="ascii")
    shutil.copy2(compile_mql(script, args.editor, work), work / "MQL5/Scripts/DLV_VwapRay_Test.ex5")
    execute(terminal, work, "DLV_VwapRay_Test", [])
    result = work / "MQL5/Files/vwapray_result.csv"
    if not result.is_file():
        logs = sorted((work / "MQL5/Logs").glob("*.log"))
        tail = logs[-1].read_text(encoding="utf-16", errors="replace")[-1500:] if logs else "no log"
        raise AssertionError(f"No result file; MQL5 log tail:\n{tail}")
    check(result, total)
    print("ALL VWAP RAY MQL5 CHECKS PASS", flush=True)


if __name__ == "__main__":
    main()
