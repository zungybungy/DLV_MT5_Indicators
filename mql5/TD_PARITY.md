# TD indicator parity (all 31 Lab `TD_*` pseudos + DEMARKER)

Bar-for-bar comparison of the root-level TD indicators against the Lab's `TD_*`
pseudos (`../DLV_Quant_Lab/rules.py`), run on the terminal's own bars. Perl's
"DeMark Indicators" is the rule authority; where the Lab departs from Perl's
explicit text the port still follows the Lab (parity is against the Lab) and the
departure is listed in `../DLV_Quant_Lab/TODO.md`.

| Indicator file | Lab pseudos |
| --- | --- |
| `TD_DLV_v3.6.mq5` | TD_SEQ |
| `DLV_TD_MA.mq5` | TD_MA1 |
| `DLV_TD_Point.mq5` | TD_POINT |
| `DLV_TD_REI.mq5` | TD_REI |
| `DLV_TD_Combo.mq5` | TD_COMBO |
| `DLV_TD_DWave.mq5` | TD_DWAVE |
| `DLV_TD_Patterns.mq5` | TD_DIFF, TD_REV_DIFF, TD_ANTI_DIFF, TD_OPEN, TD_CLOP, TD_CLOPWIN, TD_CAMOUFLAGE, TD_TRAP, TD_PRESSURE, TD_ROC, TD_CHANNEL1, TD_REBO, TD_RANGE_PROJ, TD_PROPULSION |
| `DLV_TD_Waldo.mq5` | TD_WALDO2 - TD_WALDO8 |
| `DLV_TD_TrendFactor.mq5` | TD_TREND_FACTOR |
| `DLV_TD_Retracement.mq5` | TD_REL_RETRACEMENT, TD_ABS_RETRACEMENT |
| `DLV_TD_Lines.mq5` | TD_LINES |
| native `iDeMarker` | DEMARKER (no DLV port: the terminal's own matches) |

## Run

Automated (Windows; isolated portable terminal under `scratch/`, no login, no trading):

```powershell
python smoke_test/_smoke_test_td_mql5.py                       # everything
python smoke_test/_smoke_test_td_mql5.py --only TD_REI,TD_DWAVE   # CSV names (keys of INDICATORS)
```

It compiles the indicators and `Scripts/DLV_TD_Export.mq5` (0 errors / 0 warnings
required), copies cached bars read-only from the live terminal's `bases/`
(EURUSD from ICMarketsSC-Demo; XAUUSD.a, US500.a, BTCUSD.a from Pepperstone),
exports D1/H4/H1/M15 for each, runs the checker, and confirms that perturbed Lab
references raise the mismatch count (`DRIFT`). A current-year `.hcc` held open by the
live terminal is skipped with a notice. `--terminal-data` / `--editor` override
the defaults. Each run retains ~1.3 GB under `scratch/`.

Manual: run `DLV_TD_Export` on a chart (it calls every indicator at the input sets
below, `MaxBars=INT_MAX` where one exists, and writes to `Terminal/Common/Files`), then

```powershell
python mql5/check_td_parity.py "C:/Users/<you>/AppData/Roaming/MetaQuotes/Terminal/Common/Files/DLV_TD_*.csv"
```

### Live path (incremental OnCalculate == full recompute)

```powershell
python smoke_test/_smoke_test_td_live_mql5.py     # --only / --symbols / --days / --feed M1|M5|M15
```

The export above is a full recompute; an EA reads the indicators bar by bar. The
Strategy Tester will not start without an account, so `Scripts/DLV_TD_LiveReplay.mq5`
clones a symbol as a custom symbol, preloads history and then feeds each bar of the
window as ticks (default M15 bars as OHLC ticks: ~64 forming recomputes per H4 bar).
Handle A is read at shift 1 on every new bar (what an EA reads); at the end handle B,
loaded from a byte-identical copy in `Indicators/LiveB/` so MT5 cannot hand back A's
instance, is a full recompute over the same bars. A == B exactly on every buffer and
input set, and A re-read at the end == B (no closed bar rewritten). Negative controls:
A at shift 0 (the forming bar) must differ from B, and a one-ulp perturbation must be
caught. Covered: EURUSD and US500.a, H4 and D1, 2024-09 to 2026-09 (~19 min). Not
covered: the Strategy Tester's own scheduling, history gaps or rewrites mid-stream,
bid != ask.

The CSVs carry `Open,High,Low,Close,Volume` (Volume = MT5 tick_volume, which is
what the Lab's MT5 feed maps to Volume; TD_PRESSURE reads it).

## Mapping

Unless stated, buffers are the Lab outputs verbatim in the Lab's order, flags 1/0,
EMPTY = NaN, compared exactly from bar 0.

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
| Point 0-5, Levels 1 and 3 | TD_POINT 0-5 | exact; a Level-N point appears N bars after its pivot |
| REI 0 (5) | TD_REI 0 | exact (pandas rolling-sum arithmetic replayed); EMPTY in warm-up and where sum(K) <= 1e-12 |
| native iDeMarker(14) 0 | DEMARKER 0 | atol 1e-12 (native running sums drift <= 1.3e-13, incl. tiny negatives on flat windows); same warm-up |
| Combo 0-5, Versions 1 and 2 | TD_COMBO 0-5 | counts +n advanced / -n parked / 0, 13 = complete; risk only on the +13 bar |
| D-Wave 0-9 | TD_DWAVE 0-9 | codes 0-8 (6/7/8 = A/B/C), events = new wave code else 0; projections EMPTY when n/a |
| Patterns 0-15 | TD_DIFF / REV_DIFF / ANTI_DIFF / OPEN / CLOP / CLOPWIN / CAMOUFLAGE / TRAP, 0-1 each | flags |
| Patterns 16 / 17 | TD_PRESSURE / TD_ROC | exact (pandas compensated rolling sum replayed); DRAW_NONE |
| Patterns 18-19 | TD_CHANNEL1 0-1 | exact (compensated rolling mean replayed) |
| Patterns 20-31 | TD_REBO 0-11 | prices and flags |
| Patterns 32-35 | TD_RANGE_PROJ 0-3 | EMPTY on bar 0 |
| Patterns 36-39 | TD_PROPULSION 0-3 | published on Z + Level |
| Patterns 40-55 | none | arrow copies of 0-15 for drawing; not exported |
| Waldo 0-13 | TD_WALDO2..8, 0-1 each | flags; W3 levels a price on the setup bar |
| TrendFactor 0-5 | TD_TREND_FACTOR 0-5 | ladder published on the confirmation bar p + Level |
| Retracement 0-7 / 8-9 | TD_REL_RETRACEMENT 0-7 / TD_ABS_RETRACEMENT 0-1 | |
| Lines 0-13 | TD_LINES 0-13 | a line never appears before its second TD Point is confirmed |
| Waldo 14-25, Retracement 10-13, Lines 14-17 | none | display-only arrows/crosses; not exported |

Exported input sets (keep `DLV_TD_Export.mq5` and the checker's param tables in sync):
defaults (= every set the shipped presets use) plus one materially different set —
TD_POINT Levels 1/3, TD_COMBO Versions 1/2, `TD_PATTERNS_ALT` (every param changed,
Propulsion Level 1), `TD_WALDO_ALT`, `TD_TREND_FACTOR_L1`, `TD_RETRACEMENT_L3`,
`TD_LINES_L3` (Lookback 25, where pruning actually binds). TD_REI and TD_DWAVE are
default-only (a plain window / parameterless).

Every lag the Lab applies is gated by a drift control that publishes the Lab
reference one bar early and must fail (TD_POINT, TD_PROPULSION, TD_TREND_FACTOR,
TD_REL_RETRACEMENT, TD_LINES, TD_COMBO, TD_DWAVE, TD_WALDO7).
