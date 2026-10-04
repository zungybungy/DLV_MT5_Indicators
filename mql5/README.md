# Micaletti indicators for MT5

`DLV_Micaletti.mq5` ports the **22 shipped `micaletti_*` Lab presets** identified
by commit `02df5b2`. Select a preset in the indicator inputs. The underlying
oscillators, 252-bar rolling percent rank, strict .10/.90 thresholds, and h-bar
hold masks are included. Long is the default; short and both are selectable.
There is no order execution or position sizing in these files.

Sources live in this repository's `mql5/` tree; the Windows verification runner
is in `smoke_test/`. Its Python reference is the sibling `../DLV_Quant_Lab`
repository, so keep that checkout alongside `MT5 Indicators` when running parity.

## Installation and EA buffers

Copy `Include/DLV_Micaletti.mqh` to the terminal's `MQL5/Include`,
`Indicators/DLV_Micaletti.mq5` to `MQL5/Indicators`, and the two scripts to
`MQL5/Scripts`. Compile them in MetaEditor. The existing `VWAP.ex5` is required
only for the two explicit VWAP modes. It remains a separate dependency.

| Buffer | Meaning |
| --- | --- |
| 0 | Rolling percent rank, plotted on [0,1] |
| 1 | Raw oscillator, including DVO/DVI's internal rank |
| 2 / 3 | Long entry / hold exit masks, 0 or 1 |
| 4 / 5 | Short entry / hold exit masks, 0 or 1 |
| 6 | VWAP input used by MTSI; typical price otherwise |

All buffers use normal MT5 `CopyBuffer` shifts: **read shift 1 once on each new
bar**. The forming bar has empty raw/rank/VWAP and zero signal masks. Historical
buffers retain the Lab's unshifted close-based signal timestamps. In a live EA,
the prior close's signal can only be executed after that close has occurred.
`InpLogSignals=true` logs new closed-bar masks to the terminal journal.

```cpp
int h = iCustom(_Symbol, _Period, "DLV_Micaletti",
                MICAL_MTSI_H1, MICAL_LONG, VOLUME_TICK, MICAL_LAB_PROXY,
                "VWAP", false);
double entry[], exit[];
// Check h != INVALID_HANDLE and check both returned counts before use.
CopyBuffer(h, 2, 1, 1, entry);
CopyBuffer(h, 3, 1, 1, exit);
// Include <DLV_Micaletti.mqh> for the enums; release h in OnDeinit.
```

Entries are the **raw threshold masks**. Repeated entries during a position do
not extend its hold. Exits reproduce `time_stops.apply_bar_stop`: an accepted
entry at t schedules the exit at t+h; that exit suppresses a same-side entry on
the deadline bar. Both exposes the two independently researched legs. It does
not simulate the Lab/vectorbt combined portfolio's opposite-entry conflict
policy. An EA must choose that policy and track its actual fills, rejected
orders, early stops and position deadlines.

Periods are in **chart bars**, so the presets work on any chart timeframe.
The paper's day-based interpretation corresponds to D1. Tick volume is the
default for CFDs. `VOLUME_REAL` uses real volume exactly as supplied, including
zero values; there is no silent tick-volume substitution.

## Preset mapping

Enum order is part of the `iCustom` input contract. Parameters are deliberately
fixed to the shipped presets, rather than introducing a second parameter registry.

| Enum value | `micaletti_` suffix | Oscillator parameters | Hold |
| --- | --- | --- | --- |
| 0 | mtsi_h1 | MTSI(2,3) | 1 |
| 1 | mtsi_h3 | MTSI(2,3) | 3 |
| 2 | mtsi22_h1 | MTSI(2,2) | 1 |
| 3 | mtsi22_h3 | MTSI(2,2) | 3 |
| 4 | mrsi_h1 | MRSI(2,1) | 1 |
| 5 | vwmrsi_h5 | VWMRSI(2,1,21) | 5 |
| 6 | vwmrsi_h1 | VWMRSI(2,1,21) | 1 |
| 7 / 8 | stodd_h3 / stodd_h5 | STODD(1,2), fixed outer SMA(2) | 3 / 5 |
| 9 | chiosc_h1 | ADOSC(2,3) | 1 |
| 10 | uo_h1 | ULTOSC(2,3,4) | 1 |
| 11 | stok_h1 | STOCHF(1,3,SMA), fast K | 1 |
| 12 | stod_h3 | STOCHF(1,2,SMA), fast D | 3 |
| 13 | dvo_h1 | DVO(4,21) | 1 |
| 14 | rsi_h1 | RSI(2) | 1 |
| 15 | tsi_h1 | TSI(2,1) | 1 |
| 16 | bbi_h1 | PERCENT_B(5,2) | 1 |
| 17 | cci_h1 | CCI(3), typical price | 1 |
| 18 | mfi_h1 | MFI(3) | 1 |
| 19 | kcr_h1 | KCI(2) | 1 |
| 20 | ppo_h1 | PPO_MICALETTI(3,5,5) | 1 |
| 21 | dvi_h1 | DVI(2,252,5,10,3,5,.8) | 1 |

The natural MT5 mappings are RSI→`iRSI`, CCI→`iCCI`, MFI→`iMFI`,
STOCHF→`iStochastic` (slowing 1, SMA, Low/High), ADOSC→`iChaikin` (EMA).
ULTOSC has no corresponding native indicator in the
[official indicator list](https://www.mql5.com/en/docs/indicators).
This port evaluates their arithmetic in the shared core to retain the Lab's
TA-Lib seeding, warm-up masks, floating-point ties and volume choice. Do not
substitute a native handle based only on a visually similar line: ranks can
turn tiny arithmetic differences into different threshold entries. Custom
EWMs use the Lab's pandas first-observation seed and missing-observation
weights; PPO uses TA-Lib SMA-seeded EMAs and includes the outer K=5 EMA.

## Existing VWAP integration

`InpVWAPMode` affects only MTSI:

| Mode | Input | Purpose |
| --- | --- | --- |
| `MICAL_LAB_PROXY` (default) | (H+L+C)/3 | Exact current-Lab reference |
| `MICAL_EXISTING_VWAP` | Existing `VWAP` indicator, buffer 6, chart timeframe | Session VWAP sampled at each chart-bar close |
| `MICAL_M1_SESSION_VWAP` | Existing `VWAP` on M1; last observation inside each completed broker day | M1-based daily MTSI on a D1 chart |

The existing VWAP is called with Session anchor, typical price, selected volume,
hide-on-DWM false, and offset zero. Its three filling plots occupy buffers 0–5;
the actual VWAP is buffer 6. The compiled `input group` also occupies a positional
`iCustom` argument: the call includes its empty-string placeholder. Omitting it
silently shifts the anchor/price settings. On D1 the chart-timeframe VWAP degenerates to the
daily proxy. **Use the M1 mode for genuine daily intraday aggregation.**

M1 mode requires matching M1 sessions for the entire D1 calculation window,
not just the last 252 days. Each session's aggregated OHLC and selected-volume
sum must match D1 exactly; a legitimate first minute after midnight is accepted.
Missing/inconsistent history clears all signals until it recovers. The check
establishes agreement between the loaded feeds; identical aggregates cannot
prove that a broker supplied every underlying minute. Set history limits accordingly.
Minute buffers are streamed one session at a time. New D1 bars, history resets
and changes in the M1 bar count trigger immediate revalidation; same-count M1
corrections are revisited on the first chart tick after 60 seconds. The core
recalculates when the VWAP input changes.
Its session is the existing VWAP's broker-server day, and its volume is normally
CFD tick volume. The paper uses split/dividend-adjusted ETF minute data and daily
equity sessions, so broker-session M1 VWAP still differs from that dataset.
The existing VWAP's server-day reset and price/volume rules are reused unchanged.

## Full-paper cross-check (4 October 2026)

The supplied revised PDF was read and its formula pages visually inspected:
*A Comparison of Short-Term Mean-Reversion Indicators for Global Equities*,
Raymond C. Micaletti, printed pages 8–15. This is a **Lab preset port**, not a
claim to reproduce every printed equation or the paper's performance study.

| Topic | Paper | Current Lab and default MQL5 port |
| --- | --- | --- |
| MTSI, p.13 | Corrected numerator and absolute-value denominator; day VWAP from M1 typical price × volume | Same smoothing ratio; daily proxy by default, explicit M1 VWAP option |
| MRSI / VWMRSI, pp.13–14 | Numerator U uses ln(H/C); D uses ln(C/L) | Numerator uses ln(C/L), opposite polarity; preserves the Lab's documented choice |
| Wilder seed, p.8 | Initial N-period SMA | MRSI/VWMRSI use pandas first-observation seed; conventional RSI uses TA-Lib's SMA seed |
| UO, p.9 | K, M, N weights on the K-, M-, N-period ratios | TA-Lib fixed 4:2:1 weights, periods 2/3/4 |
| KCI ATR, p.11 | SMA of true range | TA-Lib Wilder-smoothed ATR |
| DVI, p.12 | Weighted **separately ranked** magnitude/stretch legs; close/SMA returns and up/down signs; period-weighted dual windows | Smoothed up-return share and close/SMA stretch, then rank of their weighted combination; a different construction |
| Normalization, p.15 | Cumulative ranks after one-year burn-in; thresholds calibrated across all 17 assets | Rolling 252-bar rank with fixed .10/.90 thresholds |
| Scales, pp.9–11 | PPO and TSI ratios; %B ×100 | PPO/TSI ×100; %B fraction. Positive scaling is rank-invariant |
| Holding protocol, p.15 | Enter at known close, hold 1/3/5 days; overlapping-position handling not specified | Close-based masks and Lab's position-aware h-bar time-stop policy |
| PPO parameter grid, pp.8–9 | K < M < N | The sweep-selected (M,N,K)=(3,5,5) preserves the Lab preset but lies outside that printed grid |

The PDF explicitly acknowledges the corrected **MTSI** typo in footnote 1 on
p.1. It does **not** establish that MRSI's printed polarity is a typo. The Lab's
explanation for flipping that polarity remains an interpretation, not a
correction confirmed by the author. Porting these prescriptions faithfully
would require separately named Lab indicators/presets and new research results;
this change does not modify existing Lab formulas or their attribution.

## Verification

1. Compile the indicator and both scripts in MetaEditor.
2. Run `DLV_Micaletti_SelfTest` on any chart. It executes the production core
   inside the MQL5 runtime and writes 308 CSVs to `Terminal/Common/Files`:
   22 presets × seven scenarios × batch/incremental calculations.
3. From the `MT5 Indicators` repository root, compare those CSVs:

   ```powershell
   python mql5/check_micaletti_parity.py "C:/Users/levie/AppData/Roaming/MetaQuotes/Terminal/Common/Files/DLV_Micaletti_selftest_*.csv" --require-all
   ```

4. Run `DLV_Micaletti_Export` on the target symbol/timeframe. It exports all
   loaded bars, including the full recursion origin and warm-up, and actual
   indicator buffers. The forming bar is excluded. Compare the **one run's**
   file pattern with the same checker and `--require-all`.
5. Repeat the export in the chosen VWAP mode before using that mode in an EA.
   For MTSI's two explicit modes the checker uses the exported VWAP as its
   Python input. That checks MTSI downstream of VWAP; independently verify M1
   aggregation/session coverage as well.

The checker uses the actual `presets.py`, `rules.py`, and `time_stops.py`.
It requires validity masks and every entry/exit mask to match, with 1e-8 absolute
/ 1e-9 relative tolerance for raw lines and 5e-15 for CSV-serialized ranks.
That rank tolerance is far below one rank step; trade masks have zero tolerance.
Warm-up is included: Lab numba ranks count valid observations using `<=` after
bar 251 even when the window has fewer than 252 valid raw values. DVO and DVI
have their own internal rank and then receive the outer rank again.

This harness covers the Micaletti family; it does not certify the existing
TD indicators. Their separate TODO parity gate remains open.

The automated Windows integration runner creates its own portable terminal,
copies only binaries, symbol definitions and cached price bars, disables trading,
and leaves its artifacts in `scratch/`. It does not copy account credentials or
modify the user's running terminal. It tests both VWAP modes on a synthetic M1
symbol and independently checks their aggregates, in addition to Lab parity.
It also exercises the production calculation callback with truncated minutes,
a late-opening session, backfill and same-count volume/VWAP corrections:

```powershell
python smoke_test/_smoke_test_micaletti_mql5.py
# Optional: also check actual indicator buffers on cached native EURUSD bars.
python smoke_test/_smoke_test_micaletti_mql5.py --history-dir "C:/Users/levie/AppData/Roaming/MetaQuotes/Terminal/73B7A2420D6397DFF9014A20F1201F97/bases/NCMFinancialUK-Real/history/EURUSD"
```

Use `--terminal-data` / `--editor` if auto-discovery or the default MetaEditor
path does not match the installation. `--report-natives` on the CSV checker
reports native raw-line and threshold differences without weakening its gate.

Validation on 4 October 2026: all three production files compiled with zero
errors/warnings; 308 deterministic MQL-VM CSVs passed; both VWAP modes passed
22 actual-buffer CSVs and independent aggregation checks; all 22 native EURUSD
D1 CSVs passed on 3,664 closed bars. Total: 374 CSVs / 379,764 bar evaluations.
M1 coverage/recovery and correction regressions passed. Sol 6.1 at xhigh found
and prompted fixes for DVO/BBANDS rolling sums, RSI/TSI/PPO operation ordering,
M1 coverage/revalidation and invalid enum inputs. The adversarial repeated-price
and rising-price fixtures now pass exact ranks and masks in the MQL5 runtime.
Python versions: pandas 2.3.3, numpy 2.3.5, TA-Lib wrapper 0.6.8 / C library 0.6.4.
The native comparison on that EURUSD sample found CCI decile differences of
348 long / 337 short bars and MFI differences of 344 long / 127 short bars,
despite very small raw-line differences. The compatibility core passed every
rank and mask in that sample. This evidence justifies retaining its arithmetic.

These checks do not validate execution, transaction costs, the paper's Sharpe
ratios, or M1 session equivalence between broker CFDs and the paper's ETFs.
Summation/seeding source notices are retained in `THIRD_PARTY_NOTICES.txt`.
