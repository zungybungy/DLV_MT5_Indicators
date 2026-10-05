#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD Lines based on Perl, chapter 4: Demand/Supply Lines"
#property description "through confirmation-lagged TD Points, the three breakout"
#property description "qualifiers and break objectives; bit-identical to the Lab TD_LINES."

// -----------------------------------------------------------------------------
// DLV TD Lines (Perl, "DeMark Indicators", ch.4 p.91-101)
//
// Points: Level-N TD Points (strict, as DLV_TD_Point), confirmed on bar p + N.
//   A Demand Point is stored at its True Low (min(Low, prior Close)), a Supply
//   Point at its True High (max(High, prior Close)).
// Line: the two most recent confirmed points of a type, both with pivot bar
//   >= i - Lookback + 1. Demand needs the newer point HIGHER, Supply LOWER;
//   otherwise there is no line (an intervening point is never skipped). The
//   line appears on the confirmation bar of its second point; its slope uses
//   the pivot bars: value[i] = y0 + slope * (i - p0). A new point pair (or a
//   line that returns after vanishing) starts a new generation.
// Breaks (demand line D on bar t; supply mirrored):
//   break   Low[t] < D
//   Q1      Close[t-1] > Close[t-2]
//   Q2      Open[t] < D
//   Q3      2*Close[t-1] - max(High[t-1], Close[t-2]) > D   (needs bar t-2)
//   qualified = break and (Q1 or Q2 or Q3); disqualified = break and none.
//   Only a FRESH break is reported: the prior bar was not beyond the line, or
//   the generation changed. Q flags are reported on fresh breaks only.
// Objective (on a fresh qualified break only): the highest True High strictly
//   above the demand line from its older pivot p0 through t (first one on ties);
//   distance = that True High - line value at its bar (vertical);
//   objective = D[t] - Objective * distance. Supply: lowest True Low below,
//   objective = S[t] + Objective * distance.
//
// Inputs (Lab defaults): Level = 1, Lookback = 400 (bars a pivot stays usable),
//   Objective = 1.0 (100% of the measured distance).
//
// Buffers 0-13 (EA-readable via iCustom/CopyBuffer):
//   0 demand line   1 supply line              price, EMPTY_VALUE when no line
//   2-4 demand Q1/Q2/Q3   5-7 supply Q1/Q2/Q3  flags 1/0 (fresh breaks only)
//   8 qualified demand break   9 qualified supply break        flags 1/0
//  10 disqualified demand break 11 disqualified supply break   flags 1/0
//  12 downside objective  13 upside objective  price on the break bar, else EMPTY_VALUE
// Buffers 14-17 are display only: qualified demand break = down arrow above the
// High, qualified supply break = up arrow below the Low, disqualified demand
// break = cross below the Low, disqualified supply break = cross above the High.
//
// Causality: a point is used from bar p + Level on, never back-dated, so a line
// can never appear before its second point is knowable. Breaks use bar t's own
// Open/High/Low and earlier closes; on the forming bar a break or a new line can
// still change until it closes: an EA reads shift 1. Uses the chart's symbol and
// timeframe.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 18
#property indicator_plots   18

#property indicator_label1  "TD Demand Line"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLimeGreen
#property indicator_width1  2
#property indicator_label2  "TD Supply Line"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrTomato
#property indicator_width2  2
#property indicator_label3  "Demand Q1"
#property indicator_type3   DRAW_NONE
#property indicator_label4  "Demand Q2"
#property indicator_type4   DRAW_NONE
#property indicator_label5  "Demand Q3"
#property indicator_type5   DRAW_NONE
#property indicator_label6  "Supply Q1"
#property indicator_type6   DRAW_NONE
#property indicator_label7  "Supply Q2"
#property indicator_type7   DRAW_NONE
#property indicator_label8  "Supply Q3"
#property indicator_type8   DRAW_NONE
#property indicator_label9  "Qualified demand break"
#property indicator_type9   DRAW_NONE
#property indicator_label10 "Qualified supply break"
#property indicator_type10  DRAW_NONE
#property indicator_label11 "Disqualified demand break"
#property indicator_type11  DRAW_NONE
#property indicator_label12 "Disqualified supply break"
#property indicator_type12  DRAW_NONE
#property indicator_label13 "Downside objective"
#property indicator_type13  DRAW_ARROW
#property indicator_color13 clrTomato
#property indicator_label14 "Upside objective"
#property indicator_type14  DRAW_ARROW
#property indicator_color14 clrLimeGreen
#property indicator_label15 "Qualified demand break arrow"
#property indicator_type15  DRAW_ARROW
#property indicator_color15 clrTomato
#property indicator_label16 "Qualified supply break arrow"
#property indicator_type16  DRAW_ARROW
#property indicator_color16 clrLimeGreen
#property indicator_label17 "Disqualified demand break mark"
#property indicator_type17  DRAW_ARROW
#property indicator_color17 clrSilver
#property indicator_label18 "Disqualified supply break mark"
#property indicator_type18  DRAW_ARROW
#property indicator_color18 clrSilver

input group "Calculation"
input int    Level = 1;
input int    Lookback = 400;
input double Objective = 1.0;

double DemandLine[], SupplyLine[], DQ1[], DQ2[], DQ3[], SQ1[], SQ2[], SQ3[];
double DemandOk[], SupplyOk[], DemandBad[], SupplyBad[], DemandObjective[], SupplyObjective[];
double DemandOkArrow[], SupplyOkArrow[], DemandBadMark[], SupplyBadMark[];

// One side's committed state: the two most recent confirmed points, the line
// identity and the previous bar's break context.
struct SideState
{
   int    count;                  // confirmed points so far (only the last two kept)
   int    old_idx, new_idx;
   double old_price, new_price;
   bool   has_key;
   int    key_p0, key_p1;
   int    gen_next, gen;          // gen = this bar's generation, -1 without a line
   bool   beyond;                 // this bar was beyond the line
};
SideState g_dem, g_sup;
int       g_done = 0;

void Bind(const int index, double &buffer[], const int arrow)
{
   SetIndexBuffer(index, buffer, INDICATOR_DATA);
   ArraySetAsSeries(buffer, false);
   PlotIndexSetDouble(index, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   if(arrow > 0) PlotIndexSetInteger(index, PLOT_ARROW, arrow);
}

int OnInit()
{
   if(Level < 1 || Lookback < 1 || !MathIsValidNumber(Objective))
   {
      Print("DLV_TD_Lines: Level and Lookback must be >= 1 and Objective finite.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   Bind(0, DemandLine, 0); Bind(1, SupplyLine, 0);
   Bind(2, DQ1, 0); Bind(3, DQ2, 0); Bind(4, DQ3, 0); Bind(5, SQ1, 0); Bind(6, SQ2, 0); Bind(7, SQ3, 0);
   Bind(8, DemandOk, 0); Bind(9, SupplyOk, 0); Bind(10, DemandBad, 0); Bind(11, SupplyBad, 0);
   Bind(12, DemandObjective, 159); Bind(13, SupplyObjective, 159);
   Bind(14, DemandOkArrow, 234); Bind(15, SupplyOkArrow, 233); Bind(16, DemandBadMark, 251); Bind(17, SupplyBadMark, 251);
   PlotIndexSetInteger(14, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(15, PLOT_ARROW_SHIFT, 12);
   PlotIndexSetInteger(16, PLOT_ARROW_SHIFT, 12);
   PlotIndexSetInteger(17, PLOT_ARROW_SHIFT, -12);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("DLV TD Lines (Level %d, %d, %g)", Level, Lookback, Objective));
   return(INIT_SUCCEEDED);
}

void ResetSide(SideState &s)
{
   s.count = 0; s.old_idx = -1; s.new_idx = -1; s.old_price = 0.0; s.new_price = 0.0;
   s.has_key = false; s.key_p0 = -1; s.key_p1 = -1;
   s.gen_next = 0; s.gen = -1; s.beyond = false;
}

// Strict Level-N pivots at p; the caller guarantees p + Level exists.
bool IsDemand(const double &low[], const int p)
{
   if(p < Level) return false;
   for(int k = 1; k <= Level; k++)
      if(!(low[p] < low[p - k] && low[p] < low[p + k])) return false;
   return true;
}
bool IsSupply(const double &high[], const int p)
{
   if(p < Level) return false;
   for(int k = 1; k <= Level; k++)
      if(!(high[p] > high[p - k] && high[p] > high[p + k])) return false;
   return true;
}

double TrueLow(const double &low[], const double &close[], const int k)  { return k == 0 ? low[k] : MathMin(low[k], close[k - 1]); }
double TrueHigh(const double &high[], const double &close[], const int k) { return k == 0 ? high[k] : MathMax(high[k], close[k - 1]); }

void AddPoint(SideState &s, const int idx, const double price)
{
   s.old_idx = s.new_idx; s.old_price = s.new_price;
   s.new_idx = idx; s.new_price = price;
   s.count++;
}

// Advance one side to bar i. Returns the line value (EMPTY_VALUE without a line)
// and its slope/intercept/p0; updates the generation.
double Line(SideState &s, const int i, const bool demand, double &slope, double &intercept, int &p0)
{
   bool valid = s.count >= 2 && s.old_idx >= i - Lookback + 1 &&
                (demand ? s.new_price > s.old_price : s.new_price < s.old_price);
   if(!valid)
   {
      s.has_key = false;
      s.gen = -1;
      return EMPTY_VALUE;
   }
   p0 = s.old_idx;
   slope = (s.new_price - s.old_price) / (double)(s.new_idx - s.old_idx);
   intercept = s.old_price - slope * p0;
   if(!s.has_key || s.key_p0 != p0 || s.key_p1 != s.new_idx)
   {
      s.gen_next++;
      s.has_key = true; s.key_p0 = p0; s.key_p1 = s.new_idx;
   }
   s.gen = s.gen_next;
   return s.old_price + slope * (i - p0);
}

void Step(SideState &dem, SideState &sup, const int i, const double &open[], const double &high[],
          const double &low[], const double &close[])
{
   int pivot = i - Level;
   if(pivot >= 0 && IsDemand(low, pivot)) AddPoint(dem, pivot, TrueLow(low, close, pivot));
   if(pivot >= 0 && IsSupply(high, pivot)) AddPoint(sup, pivot, TrueHigh(high, close, pivot));

   int d_prev_gen = dem.gen, s_prev_gen = sup.gen;
   double d_slope = 0.0, d_icpt = 0.0, s_slope = 0.0, s_icpt = 0.0;
   int d_p0 = -1, s_p0 = -1;
   double d = Line(dem, i, true, d_slope, d_icpt, d_p0);
   double s = Line(sup, i, false, s_slope, s_icpt, s_p0);
   bool has2 = (i >= 2);

   // Demand line: downside breaks.
   bool d_beyond = (d != EMPTY_VALUE && low[i] < d);
   bool d_fresh = d_beyond && (!dem.beyond || dem.gen != d_prev_gen);
   bool dq1 = false, dq2 = false, dq3 = false;
   if(d_fresh)
   {
      dq1 = has2 && close[i - 1] > close[i - 2];
      dq2 = open[i] < d;
      dq3 = has2 && 2.0 * close[i - 1] - MathMax(high[i - 1], close[i - 2]) > d;
   }
   bool d_ok = d_fresh && (dq1 || dq2 || dq3), d_bad = d_fresh && !(dq1 || dq2 || dq3);
   double d_obj = EMPTY_VALUE;
   if(d_ok)
   {
      int best = -1;
      double best_th = 0.0;
      for(int k = d_p0; k <= i; k++)
      {
         double th = TrueHigh(high, close, k);
         if(th > d_icpt + d_slope * k && (best < 0 || th > best_th)) { best = k; best_th = th; }
      }
      if(best >= 0) d_obj = d - Objective * (best_th - (d_icpt + d_slope * best));
   }

   // Supply line: upside breaks.
   bool s_beyond = (s != EMPTY_VALUE && high[i] > s);
   bool s_fresh = s_beyond && (!sup.beyond || sup.gen != s_prev_gen);
   bool sq1 = false, sq2 = false, sq3 = false;
   if(s_fresh)
   {
      sq1 = has2 && close[i - 1] < close[i - 2];
      sq2 = open[i] > s;
      sq3 = has2 && 2.0 * close[i - 1] - MathMin(low[i - 1], close[i - 2]) < s;
   }
   bool s_ok = s_fresh && (sq1 || sq2 || sq3), s_bad = s_fresh && !(sq1 || sq2 || sq3);
   double s_obj = EMPTY_VALUE;
   if(s_ok)
   {
      int best = -1;
      double best_tl = 0.0;
      for(int k = s_p0; k <= i; k++)
      {
         double tl = TrueLow(low, close, k);
         if(tl < s_icpt + s_slope * k && (best < 0 || tl < best_tl)) { best = k; best_tl = tl; }
      }
      if(best >= 0) s_obj = s + Objective * ((s_icpt + s_slope * best) - best_tl);
   }
   dem.beyond = d_beyond;
   sup.beyond = s_beyond;

   DemandLine[i] = d; SupplyLine[i] = s;
   DQ1[i] = dq1 ? 1.0 : 0.0; DQ2[i] = dq2 ? 1.0 : 0.0; DQ3[i] = dq3 ? 1.0 : 0.0;
   SQ1[i] = sq1 ? 1.0 : 0.0; SQ2[i] = sq2 ? 1.0 : 0.0; SQ3[i] = sq3 ? 1.0 : 0.0;
   DemandOk[i] = d_ok ? 1.0 : 0.0;   SupplyOk[i] = s_ok ? 1.0 : 0.0;
   DemandBad[i] = d_bad ? 1.0 : 0.0; SupplyBad[i] = s_bad ? 1.0 : 0.0;
   DemandObjective[i] = d_obj; SupplyObjective[i] = s_obj;
   DemandOkArrow[i] = d_ok ? high[i] : EMPTY_VALUE;
   SupplyOkArrow[i] = s_ok ? low[i] : EMPTY_VALUE;
   DemandBadMark[i] = d_bad ? low[i] : EMPTY_VALUE;
   SupplyBadMark[i] = s_bad ? high[i] : EMPTY_VALUE;
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
   ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   if(rates_total < 2) return(0);

   // Full pass from the oldest bar on a fresh or reloaded history; afterwards
   // closed bars are committed once and only the forming bar is re-evaluated.
   if(prev_calculated == 0 || prev_calculated > rates_total || g_done > rates_total - 1)
   {
      g_done = 0;
      ResetSide(g_dem);
      ResetSide(g_sup);
   }
   for(int i = g_done; i < rates_total - 1; i++) Step(g_dem, g_sup, i, open, high, low, close);
   g_done = rates_total - 1;
   SideState dem = g_dem, sup = g_sup;
   Step(dem, sup, rates_total - 1, open, high, low, close);
   return(rates_total);
}
