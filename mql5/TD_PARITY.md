# TD indicator parity (TD_DLV_v3.6, DLV_TD_MA, DLV_TD_Point)

Bar-for-bar comparison of the root-level TD indicators against the Lab's
`TD_SEQ`, `TD_MA1` and `TD_POINT` pseudos (`../DLV_Quant_Lab/rules.py`). Perl's
"DeMark Indicators" is the rule authority; the Lab follows it.

## Run

Automated (Windows; isolated portable terminal under `scratch/`, no login, no trading):

```powershell
python smoke_test/_smoke_test_td_mql5.py
```

It compiles the indicators and `Scripts/DLV_TD_Export.mq5` (0 errors / 0 warnings
required), copies cached bars read-only from the live terminal's `bases/`
(EURUSD from ICMarketsSC-Demo; XAUUSD.a, US500.a, BTCUSD.a from Pepperstone),
exports D1/H4/H1/M15 for each, runs the checker, and confirms that perturbed Lab
references raise the mismatch count. A current-year `.hcc` held open by the
live terminal is skipped with a notice. `--terminal-data` / `--editor` override
the defaults.

Manual: run `DLV_TD_Export` on a chart (it calls the indicators with
`MaxBars=INT_MAX` where they have one, DLV_TD_Point at Levels 1 and 3, and writes to `Terminal/Common/Files`), then

```powershell
python mql5/check_td_parity.py "C:/Users/<you>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/DLV_TD_*.csv"
```

## Mapping

| MQL5 buffer | Lab output | Encoding |
| --- | --- | --- |
| TD 0 TDST Resistance | TD_SEQ 7 | EMPTY = NaN, rtol 1e-12 |
| TD 1 TDST Support | TD_SEQ 6 | EMPTY = NaN, rtol 1e-12 |
| TD 2 Setup | 0 minus 1 | buy +n, sell -n |
| TD 3 Countdown | 2 / 3 | +n on a counted bar, sell negated, buy first; parked = 0; a parked 12 on a qualifying close = 14 ("+", bar-13 deferral); bar 18 of a run = +-15 ("R") |
| TD 4 Perfection | 8 / 9 | +1 buy, -1 sell (sell wins a same-bar pair) |
| TD 13 Aggressive | 4 / 5 | +n counted, sell negated, parked = 0 |
| TD 5-12 risk lines | none | not compared |
| MA 0 / 1 | TD_MA1 0 / 1 | rtol 1e-12; first 16 bars excluded (bar-0 True Low/High warm-up), reported |
| Point 0-5, Levels 1 and 3 | TD_POINT 0-5 | exact; EMPTY = NaN; a Level-N point appears N bars after its pivot |

Counts and flags are compared exactly. TD_MA1's largest observed difference is
4.4e-16 relative (5-term sum order). TDST levels and TD Point prices are copied prices and match exactly. A reference
publishing TD Points one bar early must fail, so the confirmation lag is gated.
