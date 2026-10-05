"""Bar-for-bar TD_SEQ / TD_MA1 parity in an isolated, non-trading portable MT5.

Windows-only integration test. Compiles TD_DLV_v3.6, DLV_TD_MA and the export
script, copies terminal64.exe, symbol definitions and cached broker bars from
the live terminal (read-only) into scratch/, exports both indicators' buffers
on every SYMBOL x PERIOD, then gates them with mql5/check_td_parity.py.
No account credentials, orders or file deletions; artifacts are retained.

python smoke_test/_smoke_test_td_mql5.py
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


def hidden_run(command: str, timeout: int) -> None:
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    subprocess.run(command, startupinfo=startup, timeout=timeout, capture_output=True)


def compile_mql(source: Path, editor: Path, work: Path) -> Path:
    log = work / f"{source.stem}_compile.log"
    hidden_run(f'"{editor}" /compile:"{source}" /log:"{log}"', timeout=90)
    result = log.read_text(encoding="utf-16")
    if "0 errors, 0 warnings" not in result:
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


def execute(terminal: Path, work: Path, symbol: str, period: str, prefix: str) -> None:
    preset = work / "MQL5/Presets/DLV_TD_Export.set"
    preset.parent.mkdir(parents=True, exist_ok=True)
    preset.write_text(f"InpFilePrefix={prefix}", encoding="ascii")
    config = work / "DLV_TD_Export.ini"
    config.write_text("\n".join([
        "[Experts]", "Enabled=0", "AllowLiveTrading=0", "AllowDllImport=0",
        "[StartUp]", f"Symbol={symbol}", f"Period={period}", "Script=DLV_TD_Export",
        f"ScriptParameters={preset.name}", "ShutdownTerminal=1",
    ]), encoding="ascii")
    # The startup-script exit code is not a reliable result; the CSVs are checked.
    hidden_run(f'"{terminal}" /portable /config:"{config}"', timeout=600)


def verify_reference(seq: Path, ma: Path) -> None:
    """A vacuous checker must be impossible: each perturbed Lab reference must
    strictly increase the targeted column's mismatches (TD_SEQ already fails
    some columns, so "still fails" alone would prove nothing)."""
    def must_worsen(path: Path, column: str, name: str, fn) -> None:
        before = parity.check(path, verbose=False)[2][column]
        with patch.dict(parity.rules.PSEUDO_REGISTRY, {name: fn}):
            after = parity.check(path, verbose=False)[2][column]
        if after <= before:
            raise AssertionError(f"Perturbed Lab {name} left {column} at {after} mismatches ({before} before)")
        print(f"  drift {name} -> {column}: {before} -> {after} mismatches", flush=True)

    seq_fn = parity.rules.PSEUDO_REGISTRY["TD_SEQ"]
    ma_fn = parity.rules.PSEUDO_REGISTRY["TD_MA1"]

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
    must_worsen(ma, "bullish", "TD_MA1", lambda df, params: ma_fn(df, [5, 12, 3]))
    must_worsen(ma, "bearish", "TD_MA1", lambda df, params: ma_fn(df, [6, 12, 4]))
    print("Reference drift rejected (Setup 9, TDST 1e-9, Aggressive +1, TD_MA1 extend 3 / period 6)", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=Path("C:/Program Files/Pepperstone MetaTrader 5/MetaEditor64.exe"))
    parser.add_argument("--terminal-data", type=Path,
                        default=Path(os.environ["APPDATA"]) / "MetaQuotes/Terminal/73B7A2420D6397DFF9014A20F1201F97")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This test executes the Windows MT5 runtime")
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
    for name in ("TD_DLV_v3.6", "DLV_TD_MA"):
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
            execute(terminal, work, symbol, period, prefix)
            found = sorted(files.glob(f"{prefix}_{symbol}_PERIOD_{period}_*.csv"))
            if [p.name[-10:] for p in found] != ["TD_MA1.csv", "TD_SEQ.csv"]:
                raise AssertionError(f"{symbol} {period}: expected TD_MA1 and TD_SEQ CSVs, found {[p.name for p in found]}")
            paths += found
    print(f"Exported {len(paths)} CSVs ({len(SYMBOLS)} symbols x {len(PERIODS)} periods x 2 indicators)", flush=True)
    failed, bars, summary = [], 0, []
    for path in paths:
        name, n, counts = parity.check(path)
        bars += n
        summary.append(f"  {name} {path.name.split('_', 3)[3].rsplit('_', 3)[0]:22s} {n:>7,} bars  "
                       + "  ".join(f"{k}={v}" for k, v in counts.items()))
        if any(counts.values()):
            failed.append(path.name)
    print("Summary (mismatches per mapped column):", *summary, sep="\n", flush=True)
    verify_reference(next(p for p in paths if "_EURUSD_PERIOD_D1_" in p.name and p.name.endswith("TD_SEQ.csv")),
                     next(p for p in paths if "_EURUSD_PERIOD_D1_" in p.name and p.name.endswith("TD_MA1.csv")))
    if failed:
        raise SystemExit(f"FAIL: {len(failed)}/{len(paths)} CSVs differ from the Lab ({bars:,} bars compared)")
    print(f"All {len(paths)} TD parity CSVs passed ({bars:,} bars compared)", flush=True)


if __name__ == "__main__":
    main()
