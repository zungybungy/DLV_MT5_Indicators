#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD pattern and level indicators (Perl ch.1, 6, 7, 9, 10):"
#property description "Differential family, Open/Clop/Clopwin/Camouflage/Trap,"
#property description "Pressure, ROC, Channel I, REBO, Range Projection, Propulsion."

// -----------------------------------------------------------------------------
// DLV TD Patterns
//
// Fourteen DLV_Quant_Lab pseudos in one chart-window file, bit-identical to the
// Lab on closed bars (mql5/check_td_parity.py, CSVs TD_PATTERNS / _ALT).
// Every rule is a port of rules.py; Perl, "DeMark Indicators", is the authority.
//
// Rules in brief (t = current bar, true low/high extend the bar to the prior close)
//   TD Differential (ch.10 p.165-166)   BP = Close - trueLow, SP = trueHigh - Close
//     (SP as a magnitude, the Lab's documented reading).
//     up:   Close[t] < Close[t-1] < Close[t-2], BP rising, SP falling
//     down: Close[t] > Close[t-1] > Close[t-2], SP rising, BP falling
//   TD Reverse Differential (p.167-169)  up: two higher closes, BP rising, SP falling;
//     down: two lower closes, BP falling, SP rising
//   TD Anti-Differential (p.169-170)     up: close changes down, down, up, down;
//     down: up, up, down, up (signal on the last bar)
//   TD Open (ch.1 p.55/67)   buy: Open < Low[t-1] and High > Low[t-1]; sell mirrors
//   TD Clop (p.54/67)        buy: Open below both prior Open and Close, High above both
//   TD Clopwin (p.55/67)     Open and Close inside the prior Open-Close body
//     (inclusive); buy if Close > Close[t-1], sell if Close < Close[t-1]
//   TD Camouflage (p.54/66)  buy: Close < Close[t-1], Close > Open,
//     Low < min(Low[t-2], Close[t-3]); sell mirrors with the true high two bars back
//   TD Trap (p.55/67)        buy: Low[t-1] <= Open <= High[t-1] and High > High[t-1];
//     sell: same containment and Low < Low[t-1]
//   TD Pressure (ch.7 p.137-139)  raw = (Close-Open)/(High-Low) * tick_volume
//     (a flat bar contributes 0); 100 * sum(raw,n) / sum(|raw|,n), clipped to
//     +-100. VOLUME IS MT5 TICK VOLUME, exactly what the Lab's Volume column holds
//     for MT5 data. Real (exchange) volume is not used.
//   TD ROC (p.140)           100 * Close / Close[t-n]  (a ratio around 100)
//   TD Channel I (ch.9 p.161-162)  upper = SMA(Low,n) * up, lower = SMA(High,n) * lo
//   TD REBO (p.157-160)      levels Open +- trueRange[t-1] * m1 / m2. On a strict
//     break of level 1 (High > upper 1 / Low < lower 1) the TD Line qualifiers:
//     Q1 prior close down (up) vs the close before it, Q3 the pressure projection
//     2*Close[t-1] - trueLow[t-1] < level (mirror: - trueHigh, > level), Q2 open
//     beyond the level (never true here, not published). Qualified = Q1|Q2|Q3,
//     disqualified = the break with none of them.
//   TD Range Projection (p.153-157)  X from bar t-1: Close>Open (2H+L+C)/2,
//     Close<Open (H+2L+C)/2, else (H+L+2C)/2; projected high X-Low, low X-High,
//     published on bar t. Tolerance: Open[t] +- 0.15 * trueRange[t-1].
//   TD Propulsion (ch.6 p.121-124)  pivots are Level-N TD Points (DLV_TD_Point
//     logic). Up setup: pivot tail Supply, Demand X, Supply Y, Demand Z with
//     Close[prior supply] - Low[X] >= thrust*R and Close[Y] - Low[Z] >= thrust*R,
//     R = High[Y] - Low[X] > 0: threshold Low[Z] + thrust*R, target Low[Z] +
//     target*R. Down mirrors. Published on Z's confirmation bar (Z + N), held
//     until replaced.
//
// Inputs (Lab defaults; the presets trade the defaults):
//   TD Pressure    PressurePeriod 5
//   TD ROC         ROCPeriod 12
//   TD Channel I   ChannelPeriod 3, ChannelUpperMult 1.03, ChannelLowerMult 0.97
//                  (DeMark's single-stock setting is 1.09 / 0.91)
//   TD REBO        REBOMult1 0.382, REBOMult2 0.618 (need 0 < m1 < m2)
//   TD Propulsion  PropulsionLevel 3, PropulsionThrust 0.236, PropulsionTarget 0.472
//                  (Bloomberg's default is 0.25 / 0.50)
//   Each input group is one "" placeholder in iCustom's positional arguments:
//   iCustom(sym, tf, "DLV_TD_Patterns", "",5, "",12, "",3,1.03,0.97,
//           "",0.382,0.618, "",3,0.236,0.472)
//
// Buffers (EA-readable through iCustom / CopyBuffer; 0-39 are the Lab outputs
// verbatim, in the Lab's output order; EMPTY_VALUE where the Lab is NaN):
//    0 Diff up            1 Diff down          flags 1/0
//    2 Rev Diff up        3 Rev Diff down      flags 1/0
//    4 Anti Diff up       5 Anti Diff down     flags 1/0
//    6 Open buy           7 Open sell          flags 1/0
//    8 Clop buy           9 Clop sell          flags 1/0
//   10 Clopwin buy       11 Clopwin sell       flags 1/0
//   12 Camouflage buy    13 Camouflage sell    flags 1/0
//   14 Trap buy          15 Trap sell          flags 1/0
//   16 Pressure (-100..100)                    oscillator, not drawn
//   17 ROC (around 100)                        oscillator, not drawn
//   18 Channel I upper   19 Channel I lower    price
//   20 REBO upper 1  21 upper 2  22 lower 1  23 lower 2            price
//   24 REBO upper Q1  25 upper Q3  26 lower Q1  27 lower Q3        flags 1/0
//   28 REBO qualified upper  29 qualified lower                    flags 1/0
//   30 REBO disqualified upper  31 disqualified lower              flags 1/0
//   32 Range Proj high  33 low  34 Tolerance up  35 Tolerance down price
//   36 Propulsion up threshold  37 up target                       price
//   38 Propulsion down threshold  39 down target                   price
//   40-55 arrow drawing copies of flags 0-15 (buy/up at the bar's Low, sell/down
//         at its High, else EMPTY_VALUE). Display only; read 0-15 instead.
//
// Display: price levels are drawn from the bar on which they are known (Channel I
// as lines, the other levels as dots, so a held Propulsion level reads as a step);
// pattern signals are arrows below the low (buy/up) or above the high (sell/down).
// Pressure, ROC and the REBO qualifier flags are DRAW_NONE: not drawn, shown in
// the Data Window and readable by an EA. (They are plotted DRAW_NONE rather than
// INDICATOR_CALCULATIONS because calculation buffers must follow every plotted
// buffer, which would break the Lab output order.) Hide any plot in the Colors tab.
//
// Causality: every value on bar t uses bars <= t only. Channel I, Pressure, ROC
// and all patterns use bar t's own High/Low/Close, so on the forming bar they can
// still change; REBO / Range Projection / Tolerance levels are fixed from bar t's
// open, but the REBO break flags are not. A Propulsion level appears PropulsionLevel
// bars after its Z pivot (the TD Point confirmation lag) and is never back-dated.
// An EA should read shift 1 for final values. Uses the chart's symbol and
// timeframe; nothing is hardcoded.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 56
#property indicator_plots   56

#property indicator_label1  "TD Diff up"
#property indicator_type1   DRAW_NONE
#property indicator_label2  "TD Diff down"
#property indicator_type2   DRAW_NONE
#property indicator_label3  "TD Rev Diff up"
#property indicator_type3   DRAW_NONE
#property indicator_label4  "TD Rev Diff down"
#property indicator_type4   DRAW_NONE
#property indicator_label5  "TD Anti Diff up"
#property indicator_type5   DRAW_NONE
#property indicator_label6  "TD Anti Diff down"
#property indicator_type6   DRAW_NONE
#property indicator_label7  "TD Open buy"
#property indicator_type7   DRAW_NONE
#property indicator_label8  "TD Open sell"
#property indicator_type8   DRAW_NONE
#property indicator_label9  "TD Clop buy"
#property indicator_type9   DRAW_NONE
#property indicator_label10  "TD Clop sell"
#property indicator_type10   DRAW_NONE
#property indicator_label11  "TD Clopwin buy"
#property indicator_type11   DRAW_NONE
#property indicator_label12  "TD Clopwin sell"
#property indicator_type12   DRAW_NONE
#property indicator_label13  "TD Camouflage buy"
#property indicator_type13   DRAW_NONE
#property indicator_label14  "TD Camouflage sell"
#property indicator_type14   DRAW_NONE
#property indicator_label15  "TD Trap buy"
#property indicator_type15   DRAW_NONE
#property indicator_label16  "TD Trap sell"
#property indicator_type16   DRAW_NONE
#property indicator_label17  "TD Pressure"
#property indicator_type17   DRAW_NONE
#property indicator_label18  "TD ROC"
#property indicator_type18   DRAW_NONE
#property indicator_label19  "TD Channel I upper"
#property indicator_type19   DRAW_LINE
#property indicator_color19  clrSilver
#property indicator_label20  "TD Channel I lower"
#property indicator_type20   DRAW_LINE
#property indicator_color20  clrSilver
#property indicator_label21  "TD REBO upper 1"
#property indicator_type21   DRAW_ARROW
#property indicator_color21  clrDodgerBlue
#property indicator_label22  "TD REBO upper 2"
#property indicator_type22   DRAW_ARROW
#property indicator_color22  clrRoyalBlue
#property indicator_label23  "TD REBO lower 1"
#property indicator_type23   DRAW_ARROW
#property indicator_color23  clrOrchid
#property indicator_label24  "TD REBO lower 2"
#property indicator_type24   DRAW_ARROW
#property indicator_color24  clrDarkOrchid
#property indicator_label25  "TD REBO upper Q1"
#property indicator_type25   DRAW_NONE
#property indicator_label26  "TD REBO upper Q3"
#property indicator_type26   DRAW_NONE
#property indicator_label27  "TD REBO lower Q1"
#property indicator_type27   DRAW_NONE
#property indicator_label28  "TD REBO lower Q3"
#property indicator_type28   DRAW_NONE
#property indicator_label29  "TD REBO qualified upper"
#property indicator_type29   DRAW_NONE
#property indicator_label30  "TD REBO qualified lower"
#property indicator_type30   DRAW_NONE
#property indicator_label31  "TD REBO disqualified upper"
#property indicator_type31   DRAW_NONE
#property indicator_label32  "TD REBO disqualified lower"
#property indicator_type32   DRAW_NONE
#property indicator_label33  "TD Range Proj high"
#property indicator_type33   DRAW_ARROW
#property indicator_color33  clrTeal
#property indicator_label34  "TD Range Proj low"
#property indicator_type34   DRAW_ARROW
#property indicator_color34  clrTeal
#property indicator_label35  "TD Tolerance up"
#property indicator_type35   DRAW_ARROW
#property indicator_color35  clrKhaki
#property indicator_label36  "TD Tolerance down"
#property indicator_type36   DRAW_ARROW
#property indicator_color36  clrKhaki
#property indicator_label37  "TD Propulsion up threshold"
#property indicator_type37   DRAW_ARROW
#property indicator_color37  clrLimeGreen
#property indicator_label38  "TD Propulsion up target"
#property indicator_type38   DRAW_ARROW
#property indicator_color38  clrGreen
#property indicator_label39  "TD Propulsion down threshold"
#property indicator_type39   DRAW_ARROW
#property indicator_color39  clrTomato
#property indicator_label40  "TD Propulsion down target"
#property indicator_type40   DRAW_ARROW
#property indicator_color40  clrFireBrick
#property indicator_label41  "TD Diff up arrow"
#property indicator_type41   DRAW_ARROW
#property indicator_color41  clrDeepSkyBlue
#property indicator_label42  "TD Diff down arrow"
#property indicator_type42   DRAW_ARROW
#property indicator_color42  clrDeepSkyBlue
#property indicator_label43  "TD Rev Diff up arrow"
#property indicator_type43   DRAW_ARROW
#property indicator_color43  clrMediumPurple
#property indicator_label44  "TD Rev Diff down arrow"
#property indicator_type44   DRAW_ARROW
#property indicator_color44  clrMediumPurple
#property indicator_label45  "TD Anti Diff up arrow"
#property indicator_type45   DRAW_ARROW
#property indicator_color45  clrGold
#property indicator_label46  "TD Anti Diff down arrow"
#property indicator_type46   DRAW_ARROW
#property indicator_color46  clrGold
#property indicator_label47  "TD Open buy arrow"
#property indicator_type47   DRAW_ARROW
#property indicator_color47  clrLimeGreen
#property indicator_label48  "TD Open sell arrow"
#property indicator_type48   DRAW_ARROW
#property indicator_color48  clrLimeGreen
#property indicator_label49  "TD Clop buy arrow"
#property indicator_type49   DRAW_ARROW
#property indicator_color49  clrAqua
#property indicator_label50  "TD Clop sell arrow"
#property indicator_type50   DRAW_ARROW
#property indicator_color50  clrAqua
#property indicator_label51  "TD Clopwin buy arrow"
#property indicator_type51   DRAW_ARROW
#property indicator_color51  clrWhite
#property indicator_label52  "TD Clopwin sell arrow"
#property indicator_type52   DRAW_ARROW
#property indicator_color52  clrWhite
#property indicator_label53  "TD Camouflage buy arrow"
#property indicator_type53   DRAW_ARROW
#property indicator_color53  clrHotPink
#property indicator_label54  "TD Camouflage sell arrow"
#property indicator_type54   DRAW_ARROW
#property indicator_color54  clrHotPink
#property indicator_label55  "TD Trap buy arrow"
#property indicator_type55   DRAW_ARROW
#property indicator_color55  clrSandyBrown
#property indicator_label56  "TD Trap sell arrow"
#property indicator_type56   DRAW_ARROW
#property indicator_color56  clrSandyBrown

input group "TD Pressure"
input int    PressurePeriod   = 5;
input group "TD ROC"
input int    ROCPeriod        = 12;
input group "TD Channel I"
input int    ChannelPeriod    = 3;
input double ChannelUpperMult = 1.03;
input double ChannelLowerMult = 0.97;
input group "TD REBO"
input double REBOMult1        = 0.382;
input double REBOMult2        = 0.618;
input group "TD Propulsion"
input int    PropulsionLevel  = 3;
input double PropulsionThrust = 0.236;
input double PropulsionTarget = 0.472;

#define DIFF_UP      0
#define RDIFF_UP     2
#define ADIFF_UP     4
#define OPEN_BUY     6
#define CLOP_BUY     8
#define CLOPWIN_BUY 10
#define CAMO_BUY    12
#define TRAP_BUY    14
#define PRESSURE    16
#define ROC         17
#define CHAN_UP     18
#define REBO_U1     20
#define REBO_UQ1    24
#define REBO_UOK    28
#define REBO_UBAD   30
#define RP_HIGH     32
#define PROP_UP_A   36
#define FLAGS       16   // pattern flag buffers 0..15
#define LAB_OUTPUTS 40   // arrow copies follow at 40..55
#define BUFFERS     56

struct IndicatorBuffer { double v[]; };
IndicatorBuffer B[BUFFERS];

// pandas rolling sum/mean state: Kahan add/remove with separate compensations,
// a run counter of identical values, and a negative-value count (mean only).
// Mirrored step for step so the rolling sums are bit-identical to the Lab's.
struct Roll { double sx, ca, cr, prev; int nobs, consec, neg; };
Roll   StChanLo[], StChanHi[], StPrRaw[], StPrAbs[];
double PrRaw[], PrAbs[];
// Propulsion: the last four confirmed TD Points after each bar (bar, is supply).
int    PvCnt[], PvBar[], PvSup[];

int OnInit()
{
   if(PressurePeriod < 1 || ROCPeriod < 1 || ChannelPeriod < 1 || PropulsionLevel < 1)
   {
      Print("DLV_TD_Patterns: periods and PropulsionLevel must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!(REBOMult1 > 0.0 && REBOMult1 < REBOMult2))
   {
      Print("DLV_TD_Patterns: REBO multipliers must satisfy 0 < REBOMult1 < REBOMult2.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   for(int b = 0; b < BUFFERS; b++)
   {
      SetIndexBuffer(b, B[b].v, INDICATOR_DATA);
      PlotIndexSetDouble(b, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   }
   for(int b = REBO_U1; b < REBO_U1 + 4; b++) PlotIndexSetInteger(b, PLOT_ARROW, 158);
   for(int b = RP_HIGH; b < LAB_OUTPUTS; b++) PlotIndexSetInteger(b, PLOT_ARROW, 158);
   for(int k = 0; k < FLAGS; k++)
   {
      bool buy = (k % 2 == 0);
      PlotIndexSetInteger(LAB_OUTPUTS + k, PLOT_ARROW, buy ? 233 : 234);
      PlotIndexSetInteger(LAB_OUTPUTS + k, PLOT_ARROW_SHIFT, buy ? 12 : -12);
   }
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, "DLV TD Patterns");
   return(INIT_SUCCEEDED);
}

void RollAdd(Roll &r, const double v)
{
   r.nobs++;
   double y = v - r.ca;
   double t = r.sx + y;
   r.ca = t - r.sx - y;
   r.sx = t;
   if(v < 0.0) r.neg++;
   if(v == r.prev) r.consec++; else r.consec = 1;
   r.prev = v;
}

void RollRemove(Roll &r, const double v)
{
   r.nobs--;
   double y = -v - r.cr;
   double t = r.sx + y;
   r.cr = t - r.sx - y;
   r.sx = t;
   if(v < 0.0) r.neg--;
}

// Window [i-w+1, i]. pandas restarts from scratch on the first bar and when the
// window no longer overlaps the previous one (w == 1); otherwise it removes the
// leaving value and adds the new one.
void RollStep(Roll &st[], const double &vals[], const int i, const int w)
{
   Roll r;
   int s = MathMax(0, i + 1 - w);
   if(i == 0 || s >= i)
   {
      r.sx = 0.0; r.ca = 0.0; r.cr = 0.0; r.nobs = 0; r.consec = 0; r.neg = 0;
      r.prev = vals[s];
      for(int j = s; j <= i; j++) RollAdd(r, vals[j]);
   }
   else
   {
      r = st[i - 1];
      if(i - w >= 0) RollRemove(r, vals[i - w]);
      RollAdd(r, vals[i]);
   }
   st[i] = r;
}

double RollSum(const Roll &r, const int w)
{
   if(r.nobs < w) return EMPTY_VALUE;
   return (r.consec >= r.nobs) ? r.prev * r.nobs : r.sx;
}

double RollMean(const Roll &r, const int w)
{
   if(r.nobs < w || r.nobs <= 0) return EMPTY_VALUE;
   double m = r.sx / r.nobs;
   if(r.consec >= r.nobs) m = r.prev;
   else if(r.neg == 0 && m < 0.0) m = 0.0;
   else if(r.neg == r.nobs && m > 0.0) m = 0.0;
   return m;
}

double Flag(const bool on) { return on ? 1.0 : 0.0; }

// Level-N TD Points at bar p (needs p-N >= 0 and p+N inside the data), the
// DLV_TD_Point test in oldest-first indexing.
bool IsDemandPoint(const double &low[], const int p, const int n)
{
   for(int k = 1; k <= n; k++)
      if(!(low[p] < low[p - k] && low[p] < low[p + k])) return false;
   return true;
}

bool IsSupplyPoint(const double &high[], const int p, const int n)
{
   for(int k = 1; k <= n; k++)
      if(!(high[p] > high[p - k] && high[p] > high[p + k])) return false;
   return true;
}

void PushPivot(const int i, const int bar, const bool supply)
{
   int n = PvCnt[i];
   if(n == 4)
   {
      for(int k = 0; k < 3; k++) { PvBar[4 * i + k] = PvBar[4 * i + k + 1]; PvSup[4 * i + k] = PvSup[4 * i + k + 1]; }
      n = 3;
   }
   PvBar[4 * i + n] = bar;
   PvSup[4 * i + n] = supply ? 1 : 0;
   PvCnt[i] = n + 1;
}

// Pivot tail oldest->newest equals a, b, c, d (1 = supply).
bool Tail(const int i, const int a, const int b, const int c, const int d)
{
   return PvCnt[i] == 4 && PvSup[4 * i] == a && PvSup[4 * i + 1] == b &&
          PvSup[4 * i + 2] == c && PvSup[4 * i + 3] == d;
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // Oldest bar first. Each bar's state follows from the bar before it, so only
   // new bars and the previously forming one are recomputed; a full pass starts
   // on the oldest bar, so no state restarts inside the history.
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(tick_volume, false);
   for(int b = 0; b < BUFFERS; b++) ArraySetAsSeries(B[b].v, false);
   if(rates_total < 1) return(0);
   int start = 0;
   if(prev_calculated > 0 && prev_calculated <= rates_total) start = prev_calculated - 1;
   ArrayResize(StChanLo, rates_total, 4096);
   ArrayResize(StChanHi, rates_total, 4096);
   ArrayResize(StPrRaw, rates_total, 4096);
   ArrayResize(StPrAbs, rates_total, 4096);
   ArrayResize(PrRaw, rates_total, 4096);
   ArrayResize(PrAbs, rates_total, 4096);
   ArrayResize(PvCnt, rates_total, 4096);
   ArrayResize(PvBar, 4 * rates_total, 16384);
   ArrayResize(PvSup, 4 * rates_total, 16384);
   const int n_lvl = PropulsionLevel;

   for(int i = start; i < rates_total; i++)
   {
      double o = open[i], h = high[i], l = low[i], c = close[i];
      for(int b = 0; b < BUFFERS; b++)
         B[b].v[i] = (b < FLAGS || (b >= REBO_UQ1 && b < RP_HIGH)) ? 0.0 : EMPTY_VALUE;

      // --- Differential family: two-bar buying / selling pressure ---
      if(i >= 2)
      {
         double bp  = c - MathMin(l, close[i - 1]);
         double sp  = MathMax(h, close[i - 1]) - c;
         double bp1 = close[i - 1] - MathMin(low[i - 1], close[i - 2]);
         double sp1 = MathMax(high[i - 1], close[i - 2]) - close[i - 1];
         bool two_down = c < close[i - 1] && close[i - 1] < close[i - 2];
         bool two_up   = c > close[i - 1] && close[i - 1] > close[i - 2];
         B[DIFF_UP].v[i]      = Flag(two_down && bp > bp1 && sp < sp1);
         B[DIFF_UP + 1].v[i]  = Flag(two_up && sp > sp1 && bp < bp1);
         B[RDIFF_UP].v[i]     = Flag(two_up && bp > bp1 && sp < sp1);
         B[RDIFF_UP + 1].v[i] = Flag(two_down && bp < bp1 && sp > sp1);
      }
      if(i >= 4)
      {
         double d0 = c - close[i - 1], d1 = close[i - 1] - close[i - 2];
         double d2 = close[i - 2] - close[i - 3], d3 = close[i - 3] - close[i - 4];
         B[ADIFF_UP].v[i]     = Flag(d3 < 0 && d2 < 0 && d1 > 0 && d0 < 0);
         B[ADIFF_UP + 1].v[i] = Flag(d3 > 0 && d2 > 0 && d1 < 0 && d0 > 0);
      }

      // --- Ch.1 entry patterns ---
      if(i >= 1)
      {
         double h1 = high[i - 1], l1 = low[i - 1], c1 = close[i - 1];
         double body_lo = MathMin(open[i - 1], c1), body_hi = MathMax(open[i - 1], c1);
         B[OPEN_BUY].v[i]     = Flag(o < l1 && h > l1);
         B[OPEN_BUY + 1].v[i] = Flag(o > h1 && l < h1);
         B[CLOP_BUY].v[i]     = Flag(o < body_lo && h > body_hi);
         B[CLOP_BUY + 1].v[i] = Flag(o > body_hi && l < body_lo);
         bool inside_body = o >= body_lo && o <= body_hi && c >= body_lo && c <= body_hi;
         B[CLOPWIN_BUY].v[i]     = Flag(inside_body && c > c1);
         B[CLOPWIN_BUY + 1].v[i] = Flag(inside_body && c < c1);
         bool inside_range = o >= l1 && o <= h1;
         B[TRAP_BUY].v[i]     = Flag(inside_range && h > h1);
         B[TRAP_BUY + 1].v[i] = Flag(inside_range && l < l1);
         if(i >= 2)
         {
            // True low/high two bars back; with no bar t-3 it is the raw low/high.
            double tl2 = (i >= 3) ? MathMin(low[i - 2], close[i - 3]) : low[i - 2];
            double th2 = (i >= 3) ? MathMax(high[i - 2], close[i - 3]) : high[i - 2];
            B[CAMO_BUY].v[i]     = Flag(c < c1 && c > o && l < tl2);
            B[CAMO_BUY + 1].v[i] = Flag(c > c1 && c < o && h > th2);
         }
      }

      // --- TD Pressure (tick volume); a flat bar contributes 0 ---
      double range = h - l;
      double frac = (MathAbs(range) > 1e-12) ? (c - o) / range : 0.0;
      PrRaw[i] = frac * (double)tick_volume[i];
      PrAbs[i] = MathAbs(PrRaw[i]);
      RollStep(StPrRaw, PrRaw, i, PressurePeriod);
      RollStep(StPrAbs, PrAbs, i, PressurePeriod);
      double num = RollSum(StPrRaw[i], PressurePeriod);
      double den = RollSum(StPrAbs[i], PressurePeriod);
      if(num != EMPTY_VALUE && den != EMPTY_VALUE && den > 1e-12)
         B[PRESSURE].v[i] = MathMax(-100.0, MathMin(100.0, 100.0 * num / den));

      // --- TD ROC ---
      if(i >= ROCPeriod && MathAbs(close[i - ROCPeriod]) > 1e-12)
         B[ROC].v[i] = 100.0 * c / close[i - ROCPeriod];

      // --- TD Channel I: upper from the lows, lower from the highs ---
      RollStep(StChanLo, low, i, ChannelPeriod);
      RollStep(StChanHi, high, i, ChannelPeriod);
      double mean_lo = RollMean(StChanLo[i], ChannelPeriod);
      double mean_hi = RollMean(StChanHi[i], ChannelPeriod);
      if(mean_lo != EMPTY_VALUE) B[CHAN_UP].v[i] = mean_lo * ChannelUpperMult;
      if(mean_hi != EMPTY_VALUE) B[CHAN_UP + 1].v[i] = mean_hi * ChannelLowerMult;

      // --- TD REBO and TD Range Projection: prior bar's true range, current open ---
      if(i >= 1)
      {
         double tr = (i >= 2) ? MathMax(high[i - 1], close[i - 2]) - MathMin(low[i - 1], close[i - 2])
                              : high[i - 1] - low[i - 1];
         double up1 = o + tr * REBOMult1, dn1 = o - tr * REBOMult1;
         B[REBO_U1].v[i]     = up1;
         B[REBO_U1 + 1].v[i] = o + tr * REBOMult2;
         B[REBO_U1 + 2].v[i] = dn1;
         B[REBO_U1 + 3].v[i] = o - tr * REBOMult2;
         bool up_brk = h > up1, dn_brk = l < dn1;
         bool up_q1 = false, up_q3 = false, dn_q1 = false, dn_q3 = false;
         if(i >= 2)
         {
            up_q1 = close[i - 1] < close[i - 2];
            dn_q1 = close[i - 1] > close[i - 2];
            up_q3 = 2.0 * close[i - 1] - MathMin(low[i - 1], close[i - 2]) < up1;
            dn_q3 = 2.0 * close[i - 1] - MathMax(high[i - 1], close[i - 2]) > dn1;
         }
         bool up_q2 = o > up1, dn_q2 = o < dn1;
         bool up_any = up_q1 || up_q2 || up_q3, dn_any = dn_q1 || dn_q2 || dn_q3;
         B[REBO_UQ1].v[i]      = Flag(up_brk && up_q1);
         B[REBO_UQ1 + 1].v[i]  = Flag(up_brk && up_q3);
         B[REBO_UQ1 + 2].v[i]  = Flag(dn_brk && dn_q1);
         B[REBO_UQ1 + 3].v[i]  = Flag(dn_brk && dn_q3);
         B[REBO_UOK].v[i]      = Flag(up_brk && up_any);
         B[REBO_UOK + 1].v[i]  = Flag(dn_brk && dn_any);
         B[REBO_UBAD].v[i]     = Flag(up_brk && !up_any);
         B[REBO_UBAD + 1].v[i] = Flag(dn_brk && !dn_any);

         double po = open[i - 1], ph = high[i - 1], pl = low[i - 1], pc = close[i - 1];
         double x = (pc > po) ? (2.0 * ph + pl + pc) / 2.0
                  : (pc < po) ? (ph + 2.0 * pl + pc) / 2.0
                              : (ph + pl + 2.0 * pc) / 2.0;
         double tol = 0.15 * tr;
         B[RP_HIGH].v[i]     = x - pl;
         B[RP_HIGH + 1].v[i] = x - ph;
         B[RP_HIGH + 2].v[i] = o + tol;
         B[RP_HIGH + 3].v[i] = o - tol;
      }

      // --- TD Propulsion: levels off Level-N TD Points, published on Z + N ---
      PvCnt[i] = 0;
      if(i >= 1)
      {
         PvCnt[i] = PvCnt[i - 1];
         for(int k = 0; k < 4; k++) { PvBar[4 * i + k] = PvBar[4 * i - 4 + k]; PvSup[4 * i + k] = PvSup[4 * i - 4 + k]; }
         for(int k = 0; k < 4; k++) B[PROP_UP_A + k].v[i] = B[PROP_UP_A + k].v[i - 1];
      }
      int p = i - n_lvl;   // the pivot this bar can confirm
      if(p >= n_lvl)
      {
         if(IsSupplyPoint(high, p, n_lvl))
         {
            PushPivot(i, p, true);
            // Down setup: demand, X supply, Y demand, Z supply.
            if(Tail(i, 0, 1, 0, 1))
            {
               int b0 = PvBar[4 * i], by = PvBar[4 * i + 2];
               double xv = high[PvBar[4 * i + 1]], yv = low[by], zv = high[PvBar[4 * i + 3]];
               double rng = xv - yv;
               if(rng > 0 && xv - close[b0] >= PropulsionThrust * rng && zv - close[by] >= PropulsionThrust * rng)
               {
                  B[PROP_UP_A + 2].v[i] = zv - PropulsionThrust * rng;
                  B[PROP_UP_A + 3].v[i] = zv - PropulsionTarget * rng;
               }
            }
         }
         if(IsDemandPoint(low, p, n_lvl))
         {
            PushPivot(i, p, false);
            // Up setup: supply, X demand, Y supply, Z demand.
            if(Tail(i, 1, 0, 1, 0))
            {
               int b0 = PvBar[4 * i], by = PvBar[4 * i + 2];
               double xv = low[PvBar[4 * i + 1]], yv = high[by], zv = low[PvBar[4 * i + 3]];
               double rng = yv - xv;
               if(rng > 0 && close[b0] - xv >= PropulsionThrust * rng && close[by] - zv >= PropulsionThrust * rng)
               {
                  B[PROP_UP_A].v[i]     = zv + PropulsionThrust * rng;
                  B[PROP_UP_A + 1].v[i] = zv + PropulsionTarget * rng;
               }
            }
         }
      }

      // --- Arrow copies of the pattern flags ---
      for(int k = 0; k < FLAGS; k++)
         B[LAB_OUTPUTS + k].v[i] = (B[k].v[i] == 1.0) ? ((k % 2 == 0) ? l : h) : EMPTY_VALUE;
   }
   return(rates_total);
}
