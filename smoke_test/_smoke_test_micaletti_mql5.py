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
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

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


def verify_reference(selftest: Path, vwap: Path, prefix: Path) -> None:
    """Ensure changes to Lab rules/formulas invalidate captured MQL buffers."""
    def must_fail(path: Path) -> None:
        try:
            parity.check(path)
        except (AssertionError, ValueError):
            return
        raise AssertionError("The parity gate accepted stale or pending buffers")

    preset = parity.presets.get_preset("micaletti_mtsi_h1")
    for side, field, value in (("entries", "rhs", 0.5), ("short_entries", "rhs", 0.5),
                               ("entries", "lhs", 7)):
        changed = deepcopy(preset)
        changed[side][0][field]["value" if field == "rhs" else "window"] = value
        with patch.object(parity.presets, "get_preset", return_value=changed):
            must_fail(selftest)
    original = parity.rules._ps_mtsi

    def changed_mtsi(frame: pd.DataFrame, params: list, *, vwap: pd.Series | None = None) -> pd.Series:
        return original(frame, params, vwap=vwap) + 1

    with patch.object(parity.rules, "_ps_mtsi", side_effect=changed_mtsi):
        must_fail(vwap)
    frame = pd.read_csv(prefix, float_precision="round_trip")
    first = int(np.flatnonzero(frame["vwap"].notna().to_numpy())[0])
    missing = frame.copy()
    missing.loc[first + 1, "vwap"] = np.nan
    with patch.object(parity.pd, "read_csv", return_value=missing):
        must_fail(prefix)
    pending = frame.copy()
    pending.loc[first + 1, "long_exit"] = np.nan
    with patch.object(parity.pd, "read_csv", return_value=pending):
        must_fail(prefix)
    print("Reference drift (both thresholds, rank window, MTSI formula), interior holes and pending exports rejected", flush=True)


def integration_source(mode: int, prefix: str) -> str:
    """Reuse the production exporter against an isolated synthetic M1 symbol."""
    source = (ROOT / "mql5/Scripts/DLV_Micaletti_Export.mq5").read_text()
    source = source.replace("|FILE_COMMON", "")
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
    source = source.replace("CopyBuffer(VWAPHandle,", "CoverageCopyBuffer(VWAPHandle,")
    source = source.replace("CopyRates(_Symbol,PERIOD_M1,oldest,1,boundary)",
                            "CoverageBoundary(_Symbol,PERIOD_M1,oldest,1,boundary)")
    source = source.replace("_Symbol", '"DLVMicalCoverage"')
    source = source.replace("InpVWAPMode=MICAL_LAB_PROXY", "InpVWAPMode=MICAL_M1_SESSION_VWAP")
    source = source.replace("InpDirection=MICAL_LONG", "InpDirection=MICAL_BOTH")
    # Reuse the same known complete late-opening session fixture.
    setup = integration_source(2, "unused").split("void OnStart()\n{", 1)[1].split("   ExportTask();", 1)[0]
    setup = setup.replace("DLVMicalVWAP", "DLVMicalCoverage")
    setup = setup.replace('   if(CustomRatesUpdate("DLVMicalCoverage",minutes)!=2550)', '''
   MqlRates partial[];
   ArrayResize(partial,2548);
   int at=0;
   for(int i=0;i<2550;i++) if(i!=0 && i!=902) partial[at++]=minutes[i];
   if(CustomRatesUpdate("DLVMicalCoverage",partial)!=2548)''')
    setup = setup.replace("PERIOD_M1,0,2550,loaded)!=2550", "PERIOD_M1,0,2548,loaded)!=2548")
    setup = setup.replace("CopyBuffer(vh,6,0,2550,values)!=2550", "CopyBuffer(vh,6,0,2548,values)!=2548")
    return source + "\nvoid OnStart()\n{" + setup + '''
   VWAPHandle=vh;
   const int n=1150,prefix=300;
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
      int day=i-prefix;
      times[i]=D'2020.01.01'+day*86400;
      if(day<0)
      { opens[i]=highs[i]=lows[i]=closes[i]=100; ticks[i]=volumes[i]=1000; spreads[i]=0; continue; }
      int first=day*3,last=first+2;
      opens[i]=minutes[first].open; closes[i]=minutes[last].close;
      highs[i]=MathMax(minutes[first].high,MathMax(minutes[first+1].high,minutes[last].high));
      lows[i]=MathMin(minutes[first].low,MathMin(minutes[first+1].low,minutes[last].low));
      ticks[i]=minutes[first].tick_volume+minutes[first+1].tick_volume+minutes[last].tick_volume;
      volumes[i]=ticks[i]; spreads[i]=0;
   }
   if(CalculateIndicator(n,0,times,opens,highs,lows,closes,ticks,volumes,spreads)!=0) { Print("Truncated day accepted"); return; }
   for(int i=0;i<n;i++) if(RawBuffer[i]!=EMPTY_VALUE || RankBuffer[i]!=EMPTY_VALUE ||
      LongEntry[i]!=EMPTY_VALUE || LongExit[i]!=EMPTY_VALUE ||
      ShortEntry[i]!=EMPTY_VALUE || ShortExit[i]!=EMPTY_VALUE) { Print("Failed dependency emitted masks"); return; }
   MqlRates patch[];
   ArrayResize(patch,1); patch[0]=minutes[902];
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1) return;
   if(!CoverageReady(vh)) return;
   if(CalculateIndicator(n,0,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n) { Print("Late-opening complete/backfilled session rejected"); return; }
   for(int i=0;i<=prefix;i++) if(VWAPBuffer[i]!=EMPTY_VALUE || LongEntry[i]!=EMPTY_VALUE || LongExit[i]!=EMPTY_VALUE)
      { Print("Unavailable prefix was exposed as computed"); return; }
   if(!MicalValid(VWAPBuffer[prefix+1])) { Print("Oldest partial session blocked complete history"); return; }
   double before=VWAPBuffer[600];
   int copies=CoverageCopies;
   LastM1Check=0;
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n ||
      VWAPBuffer[600]!=before || CoverageCopies-copies!=1) { Print("Ordinary tick swept full history"); return; }
   // M1 appends inside the forming D1 session also reuse cached sessions.
   ArrayResize(patch,1); patch[0]=minutes[2549]; patch[0].time+=60;
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1 || !CoverageReady(vh)) return;
   copies=CoverageCopies;
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n || CoverageCopies-copies!=1)
      { Print("M1 append swept full history"); return; }
   // A delayed dependent buffer remains pending, then the same close recovers.
   CoveragePending=true; LastM1Check=0;
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=0 || LongExit[n-2]!=EMPTY_VALUE)
      { Print("Pending M1 dependency looked like no signal"); return; }
   CoveragePending=false;
   if(CalculateIndicator(n,0,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n) return;
   // A same-count volume correction must invalidate the previous calculation.
   patch[0]=minutes[901]; patch[0].tick_volume++; patch[0].real_volume++;
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1 || !CoverageReady(vh)) return;
   LastM1Check=LastM1Sweep=0; // simulate the hourly history sweep
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=0) { Print("Same-count incomplete session accepted"); return; }
   patch[0]=minutes[901];
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1 || !CoverageReady(vh)) return;
   if(CalculateIndicator(n,0,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n) return;
   // A correction within existing daily high/low changes VWAP, not D1 bars.
   patch[0].close+=0.1;
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1 || !CoverageReady(vh)) return;
   LastM1Check=LastM1Sweep=0;
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n || VWAPBuffer[600]==before)
      { Print("Same-count VWAP correction was frozen"); return; }
   double want=0,total=0;
   for(int j=900;j<=902;j++)
   {
      double price=(minutes[j].high+minutes[j].low+minutes[j].close+(j==901?0.1:0))/3;
      want+=price*(double)minutes[j].tick_volume; total+=(double)minutes[j].tick_volume;
   }
   if(MathAbs(VWAPBuffer[600]-want/total)>1e-10) { Print("Corrected VWAP aggregate differs"); return; }
   int csv=FileOpen("RESULT_NAME.csv",FILE_WRITE|FILE_CSV|FILE_ANSI,',',CP_UTF8);
   if(csv==INVALID_HANDLE) return;
   FileWrite(csv,"preset","vwap_mode","time","Open","High","Low","Close","Volume","vwap","raw","rank","long_entry","long_exit","short_entry","short_exit");
   for(int i=0;i<n-1;i++)
      FileWrite(csv,MicalName(InpPreset),2,(long)times[i],Cell(opens[i]),Cell(highs[i]),Cell(lows[i]),Cell(closes[i]),ticks[i],
         Cell(VWAPBuffer[i]),Cell(RawBuffer[i]),Cell(RankBuffer[i]),
         Cell(LongEntry[i]),Cell(LongExit[i]),Cell(ShortEntry[i]),Cell(ShortExit[i]));
   FileClose(csv);
   // Older backfill extends the usable prefix immediately, without a D1 reset.
   patch[0]=minutes[0];
   if(CustomRatesUpdate("DLVMicalCoverage",patch)!=1 || !CoverageReady(vh)) return;
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n ||
      !MicalValid(VWAPBuffer[prefix]) || !MicalValid(RawBuffer[prefix]))
      { Print("Older backfill did not extend the cached history"); return; }
   // Simulate expiry without deleting rates. A failed read and retry must
   // preserve the VWAP seed, every closed-bar mask, and all ranks/raw values.
   CoverageAvailableFirst=times[n-1-69];
   double saved_vwap[],saved_raw[],saved_rank[],saved_le[],saved_lx[],saved_se[],saved_sx[];
   ArrayCopy(saved_vwap,VWAPBuffer); ArrayCopy(saved_raw,RawBuffer); ArrayCopy(saved_rank,RankBuffer);
   ArrayCopy(saved_le,LongEntry); ArrayCopy(saved_lx,LongExit);
   ArrayCopy(saved_se,ShortEntry); ArrayCopy(saved_sx,ShortExit);
   LastM1Check=LastM1Sweep=0;
   if(CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n) return;
   CoveragePending=true; LastM1Check=0;
   int pending=CalculateIndicator(n,n,times,opens,highs,lows,closes,ticks,volumes,spreads);
   if(pending!=0 || LongExit[n-2]!=EMPTY_VALUE) return;
   CoveragePending=false;
   if(CalculateIndicator(n,pending,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n) return;
   for(int i=0;i<n;i++) if(saved_vwap[i]!=VWAPBuffer[i] || saved_raw[i]!=RawBuffer[i] || saved_rank[i]!=RankBuffer[i] ||
      saved_le[i]!=LongEntry[i] || saved_lx[i]!=LongExit[i] || saved_se[i]!=ShortEntry[i] || saved_sx[i]!=ShortExit[i])
      { PrintFormat("Expiry/pending retry changed bar %d",i); return; }
   // A chart prefix can move while minute history stays expired. Preserve the
   // overlapping cached sessions by timestamp instead of by array position.
   const int drop=100;
   ArrayRemove(times,0,drop); ArrayRemove(opens,0,drop); ArrayRemove(highs,0,drop); ArrayRemove(lows,0,drop);
   ArrayRemove(closes,0,drop); ArrayRemove(ticks,0,drop); ArrayRemove(volumes,0,drop); ArrayRemove(spreads,0,drop);
   if(CalculateIndicator(n-drop,0,times,opens,highs,lows,closes,ticks,volumes,spreads)!=n-drop) return;
   for(int i=0;i<n-drop-1;i++) if(VWAPBuffer[i]!=saved_vwap[i+drop])
      { Print("Chart shift lost timestamp-matched cache"); return; }
   Print("Expired-session retry preserved raw/rank/masks; chart shift preserved cached VWAP");
   IndicatorRelease(vh);
   int file=FileOpen("RESULT_NAME",FILE_WRITE|FILE_TXT|FILE_ANSI);
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
      int count=Bars("DLVMicalCoverage",PERIOD_M1);
      if(count>=2549 && CopyRates("DLVMicalCoverage",PERIOD_M1,0,count,loaded)==count &&
         CopyBuffer(handle,6,0,count,values)==count) return true;
      Sleep(100);
   }
   Print("Coverage history did not synchronize"); return false;
}
int CoverageCopies=0;
bool CoveragePending=false;
datetime CoverageAvailableFirst=0;
int CoverageBoundary(const string symbol,const ENUM_TIMEFRAMES timeframe,const int start,const int count,MqlRates &rates[])
{
   int copied=CopyRates(symbol,timeframe,start,count,rates);
   if(copied==1 && CoverageAvailableFirst>0) rates[0].time=CoverageAvailableFirst;
   return copied;
}
int CoverageCopyBuffer(const int handle,const int buffer,const datetime start,const datetime end,double &values[])
{
   CoverageCopies++;
   if(CoveragePending) return -1;
   return CopyBuffer(handle,buffer,start,end,values);
}
int CoverageCopyBuffer(const int handle,const int buffer,const int start,const int count,double &values[])
{
   if(CoveragePending) return -1;
   return CopyBuffer(handle,buffer,start,count,values);
}
string Cell(const double x) { return MicalValid(x)?StringFormat("%.17g",x):""; }
'''.replace("RESULT_NAME", result_name)


def pending_source(result_name: str) -> str:
    """Delay a chart VWAP dependency on an actual scheduled exit bar."""
    indicator = (ROOT / "mql5/Indicators/DLV_Micaletti.mq5").read_text()
    declarations = indicator[indicator.index("#include"):indicator.index("int OnInit()")]
    callback = indicator[indicator.index("bool MicalLoadDailyVWAP"):]
    source = declarations + callback.replace("int OnCalculate(", "int CalculateIndicator(")
    source = source.replace("InpVWAPMode=MICAL_LAB_PROXY", "InpVWAPMode=MICAL_EXISTING_VWAP")
    source = source.replace("CopyBuffer(VWAPHandle,", "PendingCopyBuffer(VWAPHandle,")
    return source + '''
datetime TestTimes[];
double TestVWAP[];
bool FailReady=false,FailRange=false,EmptyRange=false;
int PendingCopyBuffer(const int handle,const int buffer,const int start,const int count,double &values[])
{
   if(FailReady) return -1;
   ArrayResize(values,count); ArrayInitialize(values,100);
   return count;
}
int PendingCopyBuffer(const int handle,const int buffer,const datetime start,const datetime end,double &values[])
{
   if(FailRange) return -1;
   int count=0;
   ArrayResize(values,ArraySize(TestTimes));
   for(int i=0;i<ArraySize(TestTimes);i++) if(TestTimes[i]>=start && TestTimes[i]<=end)
      values[count++]=EmptyRange?EMPTY_VALUE:TestVWAP[i];
   ArrayResize(values,count);
   return count;
}
void OnStart()
{
   // This decimal rounds away from itself without pandas' equality guard.
   double constant[],smoothed[];
   ArrayResize(constant,600); ArrayInitialize(constant,-6.39114775806233);
   constant[100]=EMPTY_VALUE;
   MicalEWM(constant,smoothed,600,2.0/3,0);
   for(int i=0;i<600;i++) if(smoothed[i]!=constant[0]) { Print("Constant EWM drifted"); return; }
   const int n=850;
   double opens[],highs[],lows[],closes[];
   long ticks[],volumes[];
   int spreads[];
   ArrayResize(TestTimes,n); ArrayResize(TestVWAP,n);
   ArrayResize(opens,n); ArrayResize(highs,n); ArrayResize(lows,n); ArrayResize(closes,n);
   ArrayResize(ticks,n); ArrayResize(volumes,n); ArrayResize(spreads,n);
   ArrayResize(RankBuffer,n); ArrayResize(RawBuffer,n); ArrayResize(VWAPBuffer,n);
   ArrayResize(LongEntry,n); ArrayResize(LongExit,n); ArrayResize(ShortEntry,n); ArrayResize(ShortExit,n);
   ArrayResize(LongDue,n); ArrayResize(ShortDue,n);
   for(int i=0;i<n;i++)
   {
      double mid=100+0.01*i+2*MathSin(0.71*i)+3*MathCos(0.13*i);
      TestTimes[i]=D'2020.01.01'+i*86400;
      opens[i]=mid; highs[i]=mid+1+(i%7)*0.1; lows[i]=mid-1-(i%5)*0.1;
      closes[i]=lows[i]+(highs[i]-lows[i])*(0.05+(i%19)*0.05);
      TestVWAP[i]=(highs[i]+lows[i]+closes[i])/3;
      ticks[i]=volumes[i]=1000+(i%23)*317; spreads[i]=0;
   }
   VWAPHandle=1;
   if(CalculateIndicator(n,0,TestTimes,opens,highs,lows,closes,ticks,volumes,spreads)!=n) return;
   int due=-1;
   for(int i=253;i<n-10;i++) if(LongExit[i]==1) { due=i; break; }
   if(due<0) { Print("Pending fixture has no deadline"); return; }
   LastLogged=0;
   if(CalculateIndicator(due+1,0,TestTimes,opens,highs,lows,closes,ticks,volumes,spreads)!=due+1 ||
      LastLogged!=TestTimes[due-1] || LongExit[due]!=EMPTY_VALUE) return;
   FailReady=true;
   if(CalculateIndicator(due+2,due+1,TestTimes,opens,highs,lows,closes,ticks,volumes,spreads)!=due+1 ||
      LongEntry[due]!=EMPTY_VALUE || LongExit[due]!=EMPTY_VALUE ||
      ShortEntry[due]!=EMPTY_VALUE || ShortExit[due]!=EMPTY_VALUE || LongExit[due+1]!=EMPTY_VALUE)
      { Print("Delayed VWAP erased the pending deadline"); return; }
   FailReady=false; FailRange=true; LastDependencyWarning=0;
   if(CalculateIndicator(due+2,due+1,TestTimes,opens,highs,lows,closes,ticks,volumes,spreads)!=due+1 || LongExit[due]!=EMPTY_VALUE) return;
   FailRange=false; EmptyRange=true;
   if(CalculateIndicator(due+2,due+1,TestTimes,opens,highs,lows,closes,ticks,volumes,spreads)!=due+1 || LongExit[due]!=EMPTY_VALUE) return;
   EmptyRange=false;
   if(CalculateIndicator(due+2,due+1,TestTimes,opens,highs,lows,closes,ticks,volumes,spreads)!=due+2 ||
      LongExit[due]!=1 || LastLogged!=TestTimes[due]) { Print("Retried deadline was lost"); return; }
   if(CalculateIndicator(due+7,due+2,TestTimes,opens,highs,lows,closes,ticks,volumes,spreads)!=due+7 ||
      LastLogged!=TestTimes[due+5]) { Print("Reconnect logging did not catch up"); return; }
   if(CalculateIndicator(due+8,0,TestTimes,opens,highs,lows,closes,ticks,volumes,spreads)!=due+8 ||
      LastLogged!=TestTimes[due+6]) { Print("Reset dropped the latest close"); return; }
   int file=FileOpen("RESULT_NAME",FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(file==INVALID_HANDLE) return;
   FileWrite(file,"passed"); FileClose(file);
   Print("Pending exit, reconnect/reset logging and constant EWM passed");
}
'''.replace("RESULT_NAME", result_name)


def capped_source(result_name: str) -> str:
    """Exercise the production loader/indicator with stored bars beyond MaxBars."""
    indicator = (ROOT / "mql5/Indicators/DLV_Micaletti.mq5").read_text()
    declarations = indicator[indicator.index("#include"):indicator.index("int OnInit()")]
    callback = indicator[indicator.index("bool MicalLoadDailyVWAP"):]
    source = declarations + callback.replace("int OnCalculate(", "int CalculateIndicator(")
    source = source.replace("_Symbol", '"DLVMicalCapped"')
    source = source.replace("InpVWAPMode=MICAL_LAB_PROXY", "InpVWAPMode=MICAL_M1_SESSION_VWAP")
    setup = integration_source(2, "unused").split("void OnStart()\n{", 1)[1].split("   ExportTask();", 1)[0]
    setup = setup.replace("DLVMicalVWAP", "DLVMicalCapped").replace("2550", "6000")
    setup = setup.replace('   if(CopyRates("DLVMicalCapped",PERIOD_M1,0,6000,loaded)!=6000) return;', '''
   int copied=0;
   for(int attempt=0;attempt<100;attempt++)
   {
      copied=CopyRates("DLVMicalCapped",PERIOD_M1,0,5000,loaded);
      if(copied==5000 && SeriesInfoInteger("DLVMicalCapped",PERIOD_M1,SERIES_SYNCHRONIZED)) break;
      Sleep(100);
   }
   if(copied!=5000) { Print("Capped fixture failed to build its accessible history"); return; }''')
    setup = setup.replace('   if(vh==INVALID_HANDLE || CopyBuffer(vh,6,0,6000,values)!=6000) return;', '''
   if(vh==INVALID_HANDLE) return;
   for(int attempt=0;attempt<100;attempt++)
   {
      if(CopyBuffer(vh,6,0,1,values)==1 && MicalValid(values[0])) break;
      Sleep(100);
   }''')
    return source + "\nvoid OnStart()\n{" + setup + '''
   if(TerminalInfoInteger(TERMINAL_MAXBARS)!=5000 || Bars("DLVMicalCapped",PERIOD_M1)<=5000)
      { Print("Capped fixture did not exceed the terminal limit"); return; }
   VWAPHandle=vh;
   const int n=2000;
   datetime times[];
   double opens[],highs[],lows[],closes[];
   long ticks[],volumes[];
   int spreads[];
   ArrayResize(times,n); ArrayResize(opens,n); ArrayResize(highs,n); ArrayResize(lows,n); ArrayResize(closes,n);
   ArrayResize(ticks,n); ArrayResize(volumes,n); ArrayResize(spreads,n);
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
   int result=0;
   for(int attempt=0;attempt<100;attempt++)
   {
      result=CalculateIndicator(n,result,times,opens,highs,lows,closes,ticks,volumes,spreads);
      if(result==n) break;
      Sleep(100);
   }
   if(result!=n || VWAPBuffer[0]!=EMPTY_VALUE || LongExit[0]!=EMPTY_VALUE ||
      !MicalValid(LongExit[n-2]) || !MicalValid(RawBuffer[n-2]) || LongExit[n-1]!=EMPTY_VALUE)
      { Print("Capped history kept the calculation pending"); return; }
   int first_valid=-1;
   for(int i=0;i<n-1;i++) if(MicalValid(VWAPBuffer[i]))
   {
      if(first_valid<0) first_valid=i;
      double weighted=0,total=0;
      for(int j=i*3;j<i*3+3;j++)
      {
         weighted+=(minutes[j].high+minutes[j].low+minutes[j].close)/3*(double)minutes[j].tick_volume;
         total+=(double)minutes[j].tick_volume;
      }
      if(MathAbs(VWAPBuffer[i]-weighted/total)>1e-10) { Print("Capped VWAP differs from complete session"); return; }
   }
   if(first_valid<333 || first_valid>334) { Print("Capped boundary selected an incorrect prefix"); return; }
   // Check the compiled indicator in its own indicator thread, too.
   int handle=iCustom("DLVMicalCapped",PERIOD_D1,"DLV_Micaletti",MICAL_MTSI_H1,MICAL_LONG,
                      VOLUME_TICK,MICAL_M1_SESSION_VWAP,"VWAP",false);
   if(handle==INVALID_HANDLE) return;
   double actual_exit[],actual_raw[],actual_rank[];
   bool ready=false;
   for(int attempt=0;attempt<150;attempt++)
   {
      if(CopyBuffer(handle,3,1,1,actual_exit)==1 && MicalValid(actual_exit[0]) &&
         CopyBuffer(handle,1,1,1,actual_raw)==1 && CopyBuffer(handle,0,1,1,actual_rank)==1)
         { ready=true; break; }
      Sleep(100);
   }
   if(!ready || actual_exit[0]!=LongExit[n-2] || actual_raw[0]!=RawBuffer[n-2] || actual_rank[0]!=RankBuffer[n-2])
      { Print("Compiled indicator failed the actual MaxBars cap"); return; }
   IndicatorRelease(handle); IndicatorRelease(vh);
   int file=FileOpen("RESULT_NAME",FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(file==INVALID_HANDLE) return;
   FileWrite(file,"passed"); FileClose(file);
   PrintFormat("Actual MaxBars cap passed: limit=5000 stored=6000 first_valid_day=%d",first_valid);
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
        target = work / f"MQL5/{name}.ex5"
        if name.startswith("Scripts/"):
            # Only runner-owned copies use the portable terminal's local Files.
            source = work / f"{Path(name).name}.mq5"
            source.write_text((ROOT / f"mql5/{name}.mq5").read_text().replace("|FILE_COMMON", ""))
            binary = compile_mql(source, args.editor, work)
        shutil.copy2(binary, target)
    common = work / "MQL5/Files"
    prefix = f"DLV_Micaletti_selftest_{runid}"
    execute(terminal, work, "DLV_Micaletti_SelfTest", [f"InpFilePrefix={prefix}"])
    selftest_paths = compare(common, prefix, 308)
    for mode in (1, 2):
        prefix = f"DLV_Micaletti_vwap{mode}_{runid}"
        name = f"DLV_Micaletti_Integration{mode}"
        source = work / f"{name}.mq5"
        source.write_text(integration_source(mode, prefix))
        shutil.copy2(compile_mql(source, args.editor, work), work / "MQL5/Scripts" / f"{name}.ex5")
        execute(terminal, work, name, [])
        vwap_paths = compare(common, prefix, 22)
        verify_vwap(vwap_paths, mode)
    name = "DLV_Micaletti_Coverage"
    result_name = f"DLV_Micaletti_coverage_{runid}.txt"
    source = work / f"{name}.mq5"
    source.write_text(coverage_source(result_name))
    shutil.copy2(compile_mql(source, args.editor, work), work / "MQL5/Scripts" / f"{name}.ex5")
    execute(terminal, work, name, [])
    assert (common / result_name).read_text().strip() == "passed"
    parity.check(common / f"{result_name}.csv")
    verify_reference(next(p for p in selftest_paths if p.name.endswith("_0_0_micaletti_mtsi_h1.csv")),
                     next(p for p in vwap_paths if p.name.endswith("_micaletti_mtsi_h1.csv")),
                     common / f"{result_name}.csv")
    print("M1 coverage, late open, backfill and same-count corrections passed", flush=True)
    name = "DLV_Micaletti_Pending"
    result_name = f"DLV_Micaletti_pending_{runid}.txt"
    source = work / f"{name}.mq5"
    source.write_text(pending_source(result_name))
    shutil.copy2(compile_mql(source, args.editor, work), work / "MQL5/Scripts" / f"{name}.ex5")
    execute(terminal, work, name, [])
    assert (common / result_name).read_text().strip() == "passed"
    print("Pending exit retry, reconnect/reset logging and constant EWM passed", flush=True)
    if args.history_dir:
        prefix = f"DLV_Micaletti_native_{runid}"
        execute(terminal, work, "DLV_Micaletti_Export", [f"InpFilePrefix={prefix}"])
        compare(common, prefix, 22)
    # Settings belong only to a fresh runner-owned terminal, never the live one.
    cap_work = work / "capped_terminal"
    for folder in ("Scripts", "Indicators"):
        (cap_work / "MQL5" / folder).mkdir(parents=True)
    (cap_work / "config").mkdir()
    (cap_work / "config/common.ini").write_text("[Charts]\nMaxBars=5000\n", encoding="ascii")
    cap_terminal = cap_work / "terminal64.exe"
    shutil.copy2(terminal, cap_terminal)
    shutil.copytree(work / "bases/Default/Symbols", cap_work / "bases/Default/Symbols")
    shutil.copytree(work / "bases/Default/History/EURUSD", cap_work / "bases/Default/History/EURUSD")
    for name in ("VWAP", "DLV_Micaletti"):
        shutil.copy2(work / f"MQL5/Indicators/{name}.ex5", cap_work / f"MQL5/Indicators/{name}.ex5")
    name = "DLV_Micaletti_Capped"
    result_name = f"DLV_Micaletti_capped_{runid}.txt"
    source = cap_work / f"{name}.mq5"
    source.write_text(capped_source(result_name))
    shutil.copy2(compile_mql(source, args.editor, cap_work), cap_work / f"MQL5/Scripts/{name}.ex5")
    execute(cap_terminal, cap_work, name, [])
    assert (cap_work / "MQL5/Files" / result_name).read_text().strip() == "passed"
    print("Actual terminal MaxBars=5000 with 6000 stored M1 bars passed", flush=True)
    print("All MQL5 parity gates passed", flush=True)


if __name__ == "__main__":
    main()
