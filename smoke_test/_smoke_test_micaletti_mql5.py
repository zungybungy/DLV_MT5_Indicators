"""Execute Micaletti in an isolated, non-trading portable MT5 terminal.

Windows-only integration test. Uses the installed MetaEditor/terminal and VWAP.
No account credentials, live terminal settings, orders or file deletions.
Retains its generated terminal, logs and CSVs for inspection.

python smoke_test/_smoke_test_micaletti_mql5.py
Optional --history-dir points at a broker's cached EURUSD history for real-bar
buffer parity and native diagnostics (e.g. .../bases/NCMFinancialUK-Real/history/EURUSD).
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("micaletti_parity", ROOT / "mql5/check_micaletti_parity.py")
parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parity)


def hidden_run(command: list[str] | str, timeout: int = 90) -> subprocess.CompletedProcess:
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    return subprocess.run(command, startupinfo=startup, timeout=timeout, capture_output=True)


def compile_mql(source: Path, editor: Path, work: Path) -> Path:
    log = work / f"{source.stem}_compile.log"
    # MetaEditor parses option:value itself; quote the VALUE (not the option)
    # in the raw Windows command line. subprocess still runs without a shell.
    hidden_run(f'"{editor}" /compile:"{source}" /inc:"{ROOT / "mql5"}" /log:"{log}"')
    result = log.read_text(encoding="utf-16")
    if "0 errors, 0 warnings" not in result:
        raise AssertionError(result)
    print(f"Compiled {source.name}: 0 errors, 0 warnings", flush=True)
    return source.with_suffix(".ex5")


def execute(terminal: Path, work: Path, script: str, settings: list[str]) -> None:
    preset = work / "MQL5/Presets" / f"{script}.set"
    preset.parent.mkdir(parents=True, exist_ok=True)
    preset.write_text("\n".join(settings), encoding="ascii")
    config = work / f"{script}.ini"
    config.write_text("\n".join([
        "[Experts]", "Enabled=0", "AllowLiveTrading=0", "AllowDllImport=0",
        "[StartUp]", "Symbol=EURUSD", "Period=D1", f"Script={script}",
        f"ScriptParameters={preset.name}", "ShutdownTerminal=1",
    ]), encoding="ascii")
    # The MT5 startup-script process exit code is not a reliable script result.
    # Validate the CSVs and their contents below instead.
    hidden_run(f'"{terminal}" /portable /config:"{config}"', timeout=90)


def compare(common: Path, prefix: str, files: int) -> list[Path]:
    paths = sorted(common.glob(f"{prefix}_*.csv"))
    if len(paths) != files:
        raise AssertionError(f"{prefix}: expected {files} CSVs, found {len(paths)}")
    presets = set()
    for path in paths:
        pid, _ = parity.check(path, report_natives=files == 22)
        presets.add(pid)
    assert len(presets) == 22
    print(f"Passed {files} CSVs across 22 presets: {prefix}", flush=True)
    return paths


def integration_source(mode: int, prefix: str) -> str:
    """Reuse the production exporter against an isolated synthetic M1 symbol."""
    source = (ROOT / "mql5/Scripts/DLV_Micaletti_Export.mq5").read_text()
    source = source.replace("#property script_show_inputs", "")
    source = source.replace("void OnStart()", "void ExportTask()")
    source = source.replace("_Symbol", '"DLVMicalVWAP"').replace("_Period", "PERIOD_D1")
    source = source.replace("InpVWAPMode=MICAL_LAB_PROXY", f"InpVWAPMode={'MICAL_EXISTING_VWAP' if mode == 1 else 'MICAL_M1_SESSION_VWAP'}")
    source = source.replace('InpFilePrefix="DLV_Micaletti"', f'InpFilePrefix="{prefix}"')
    return source + '''
void OnStart()
{
   if(!SymbolInfoInteger("DLVMicalVWAP",SYMBOL_EXIST)) CustomSymbolCreate("DLVMicalVWAP","DLVParity");
   CustomSymbolSetInteger("DLVMicalVWAP",SYMBOL_DIGITS,5);
   CustomSymbolSetDouble("DLVMicalVWAP",SYMBOL_POINT,0.00001);
   MqlRates minutes[];
   ArrayResize(minutes,2550);
   for(int i=0;i<2550;i++)
   {
      int day=i/3,minute=i%3;
      double mid=100+0.01*day+2*MathSin(0.71*day)+3*MathCos(0.13*day)+0.15*minute;
      minutes[i].time=D'2020.01.01'+day*86400+9*3600+30*60+minute*60;
      minutes[i].open=mid; minutes[i].high=mid+1+(day%7)*0.1;
      minutes[i].low=mid-1-(day%5)*0.1;
      minutes[i].close=minutes[i].low+(minutes[i].high-minutes[i].low)*(0.05+(day%19)*0.05);
      minutes[i].tick_volume=1000+(day%23)*317+minute*117;
      minutes[i].real_volume=minutes[i].tick_volume;
      minutes[i].spread=0;
   }
   if(CustomRatesUpdate("DLVMicalVWAP",minutes)!=2550) { Print("CustomRatesUpdate failed"); return; }
   SymbolSelect("DLVMicalVWAP",true);
   // Synchronize offline custom M1 history before creating dependent handles.
   MqlRates loaded[];
   if(CopyRates("DLVMicalVWAP",PERIOD_M1,0,2550,loaded)!=2550) return;
   int vh=iCustom("DLVMicalVWAP",PERIOD_M1,"VWAP","",false,0,PRICE_TYPICAL,VOLUME_TICK,0);
   double values[];
   if(vh==INVALID_HANDLE || CopyBuffer(vh,6,0,2550,values)!=2550) return;
   ExportTask();
   IndicatorRelease(vh);
}
'''


def verify_vwap(paths: list[Path], mode: int) -> None:
    frame = pd.read_csv(next(p for p in paths if p.name.endswith("_micaletti_mtsi_h1.csv")),
                        float_precision="round_trip")
    if mode == 1:
        want = (frame["High"] + frame["Low"] + frame["Close"]) / 3
    else:
        days = np.arange(849)[:, None]
        minute = np.arange(3)[None, :]
        mid = 100 + .01*days + 2*np.sin(.71*days) + 3*np.cos(.13*days) + .15*minute
        hi, lo = mid + 1 + (days % 7)*.1, mid - 1 - (days % 5)*.1
        cl = lo + (hi-lo)*(.05+(days % 19)*.05)
        volume = 1000 + (days % 23)*317 + minute*117
        want = (((hi+lo+cl)/3)*volume).sum(axis=1)/volume.sum(axis=1)
        proxy = (frame["High"] + frame["Low"] + frame["Close"]) / 3
        assert np.max(np.abs(want-proxy)) > 1e-3, "M1 fixture must distinguish VWAP from the daily proxy"
    np.testing.assert_allclose(frame["vwap"], want, rtol=0, atol=1e-10)
    print(f"VWAP mode {mode}: independent aggregation passed", flush=True)


def coverage_source(result_name: str) -> str:
    """Exercise the production callback with a fixed D1 feed and evolving M1."""
    indicator = (ROOT / "mql5/Indicators/DLV_Micaletti.mq5").read_text()
    declarations = indicator[indicator.index("#include"):indicator.index("int OnInit()")]
    callback = indicator[indicator.index("bool MicalLoadDailyVWAP"):]
    source = declarations + callback.replace("int OnCalculate(", "int CalculateIndicator(")
    source = source.replace("_Symbol", '"DLVMicalCoverage"')
    source = source.replace("InpVWAPMode=MICAL_LAB_PROXY", "InpVWAPMode=MICAL_M1_SESSION_VWAP")
    # Reuse the same known complete late-opening session fixture.
    setup = integration_source(2, "unused").split("void OnStart()\n{", 1)[1].split("   ExportTask();", 1)[0]
    setup = setup.replace("DLVMicalVWAP", "DLVMicalCoverage")
    setup = setup.replace('   if(CustomRatesUpdate("DLVMicalCoverage",minutes)!=2550)', '''
   MqlRates partial[];
   ArrayResize(partial,2549);
   int at=0;
   for(int i=0;i<2550;i++) if(i!=902) partial[at++]=minutes[i];
   if(CustomRatesUpdate("DLVMicalCoverage",partial)!=2549)''')
    setup = setup.replace("PERIOD_M1,0,2550,loaded)!=2550", "PERIOD_M1,0,2549,loaded)!=2549")
    setup = setup.replace("CopyBuffer(vh,6,0,2550,values)!=2550", "CopyBuffer(vh,6,0,2549,values)!=2549")
    return source + "\nvoid OnStart()\n{" + setup + '''
   VWAPHandle=vh;
   const int n=850;
   datetime times[];
   double opens[],highs[],lows[],closes[];
   long ticks[],volumes[];
   int spreads[];
   ArrayResize(times,n); ArrayResize(opens,n); ArrayResize(highs,n); ArrayResize(lows,n);
   ArrayResize(closes,n); ArrayResize(ticks,n); ArrayResize(volumes,n); ArrayResize(spreads,n);
   ArrayResize(RankBuffer,n); ArrayResize(RawBuffer,n); ArrayResize(VWAPBuffer,n);
   ArrayResize(LongEntry,n); ArrayResize(LongExit,n); ArrayResize(ShortEntry,n); ArrayResize(ShortExit,n);
   ArrayResize(LongDue,n); ArrayResize(ShortDue,n);
   for(int i=0;i<n;i++)
   {
      int first=i*3,last=first+2;
      times[i]=D'2020.01.01'+i*86400;
      opens[i]=minutes[first].open; closes[i]=minutes[last].close;
      highs[i]=MathMax(minutes[first].high,MathMax(minutes[first+1].high,minutes[last].high));
      lows[i]=MathMin(minutes[first].low,MathMin(minutes[first+1].low,minutes[last].low));
      ticks[i]=minutes[first].tick_volume+minutes[first+1].tick_volume+minutes[last].tick_volume;
      volumes[i]=ticks[i]; spreads[i]=0;
   }
   if(CalculateIndicator(n,0,times,opens,highs,lows,closes,ticks,volumes,spreads)!=0) { Print("Truncated day accepted"); return; }
   for(int i=0;i<n;i++) if(RawBuffer[i]!=EMPTY_VALUE || RankBuffer[i]!=EMPTY_VALUE ||
      LongEntry[i]!=0 || LongExit[i]!=0 || ShortEntry[i]!=0 || ShortExit[i]!=0) { Print("Failed dependency emitted masks"); return; }
   MqlRates patch[];
   ArrayResize(patch,1); patch[0]=minutes[902];
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1) return;
   if(!CoverageReady(vh)) return;
   if(CalculateIndicator(n,0,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n) { Print("Late-opening complete/backfilled session rejected"); return; }
   double before=VWAPBuffer[300];
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n || VWAPBuffer[300]!=before) return;
   // A same-count volume correction must invalidate the previous calculation.
   patch[0]=minutes[901]; patch[0].tick_volume++; patch[0].real_volume++;
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1 || !CoverageReady(vh)) return;
   LastM1Check=0; // simulate the periodic check after a same-count correction
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=0) { Print("Same-count incomplete session accepted"); return; }
   patch[0]=minutes[901];
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1 || !CoverageReady(vh)) return;
   if(CalculateIndicator(n,0,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n) return;
   // A correction within existing daily high/low changes VWAP, not D1 bars.
   patch[0].close+=0.1;
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1 || !CoverageReady(vh)) return;
   LastM1Check=0;
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n || VWAPBuffer[300]==before)
      { Print("Same-count VWAP correction was frozen"); return; }
   double want=0,total=0;
   for(int j=900;j<=902;j++)
   {
      double price=(minutes[j].high+minutes[j].low+minutes[j].close+(j==901?0.1:0))/3;
      want+=price*(double)minutes[j].tick_volume; total+=(double)minutes[j].tick_volume;
   }
   if(MathAbs(VWAPBuffer[300]-want/total)>1e-10) { Print("Corrected VWAP aggregate differs"); return; }
   IndicatorRelease(vh);
   int file=FileOpen("RESULT_NAME",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(file==INVALID_HANDLE) return;
   FileWrite(file,"passed"); FileClose(file);
   Print("Coverage/backfill/correction regression passed");
}
bool CoverageReady(const int handle)
{
   MqlRates loaded[];
   double values[];
   for(int attempt=0;attempt<100;attempt++)
   {
      if(CopyRates("DLVMicalCoverage",PERIOD_M1,0,2550,loaded)==2550 && CopyBuffer(handle,6,0,2550,values)==2550) return true;
      Sleep(100);
   }
   Print("Coverage history did not synchronize"); return false;
}
'''.replace("RESULT_NAME", result_name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=Path("C:/Program Files/Pepperstone MetaTrader 5/MetaEditor64.exe"))
    parser.add_argument("--terminal-data", type=Path)
    parser.add_argument("--history-dir", type=Path)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This test executes the Windows MT5 runtime")
    base = Path(os.environ["APPDATA"]) / "MetaQuotes/Terminal"
    candidates = [p for p in base.iterdir() if (p / "MQL5/Indicators/VWAP.ex5").is_file()]
    data = args.terminal_data or (candidates[0] if len(candidates) == 1 else None)
    if data is None:
        parser.error("Choose --terminal-data (must contain the existing VWAP)")
    (ROOT / "scratch").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="micaletti_mt5_", dir=ROOT / "scratch"))
    print(f"Retained test artifacts: {work}", flush=True)
    runid = uuid.uuid4().hex[:10]
    terminal = work / "terminal64.exe"
    shutil.copy2(args.editor.parent / "terminal64.exe", terminal)
    for folder in ("Scripts", "Indicators"):
        (work / "MQL5" / folder).mkdir(parents=True)
    shutil.copytree(data / "bases/Default/Symbols", work / "bases/Default/Symbols")
    history = args.history_dir or data / "bases/Default/History/EURUSD"
    shutil.copytree(history, work / "bases/Default/History/EURUSD")
    shutil.copy2(data / "MQL5/Indicators/VWAP.ex5", work / "MQL5/Indicators/VWAP.ex5")
    for name in ("Indicators/DLV_Micaletti", "Scripts/DLV_Micaletti_Export", "Scripts/DLV_Micaletti_SelfTest"):
        binary = compile_mql(ROOT / f"mql5/{name}.mq5", args.editor, work)
        shutil.copy2(binary, work / f"MQL5/{name}.ex5")
    common = base / "Common/Files"
    prefix = f"DLV_Micaletti_selftest_{runid}"
    execute(terminal, work, "DLV_Micaletti_SelfTest", [f"InpFilePrefix={prefix}"])
    compare(common, prefix, 308)
    for mode in (1, 2):
        prefix = f"DLV_Micaletti_vwap{mode}_{runid}"
        name = f"DLV_Micaletti_Integration{mode}"
        source = work / f"{name}.mq5"
        source.write_text(integration_source(mode, prefix))
        shutil.copy2(compile_mql(source, args.editor, work), work / "MQL5/Scripts" / f"{name}.ex5")
        execute(terminal, work, name, [])
        verify_vwap(compare(common, prefix, 22), mode)
    name = "DLV_Micaletti_Coverage"
    result_name = f"DLV_Micaletti_coverage_{runid}.txt"
    source = work / f"{name}.mq5"
    source.write_text(coverage_source(result_name))
    shutil.copy2(compile_mql(source, args.editor, work), work / "MQL5/Scripts" / f"{name}.ex5")
    execute(terminal, work, name, [])
    assert (common / result_name).read_text().strip() == "passed"
    print("M1 coverage, late open, backfill and same-count corrections passed", flush=True)
    if args.history_dir:
        prefix = f"DLV_Micaletti_native_{runid}"
        execute(terminal, work, "DLV_Micaletti_Export", [f"InpFilePrefix={prefix}"])
        compare(common, prefix, 22)
    print("All MQL5 parity gates passed", flush=True)


if __name__ == "__main__":
    main()
