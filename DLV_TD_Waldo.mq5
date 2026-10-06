#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD Waldo Patterns 2-8 based on Perl, chapter 11."
#property description "Prospective reversal flags (arrows) and Pattern 3 exhaustion"
#property description "levels, bit-identical to the DLV_Quant_Lab TD_WALDO2..8 pseudos."

// -----------------------------------------------------------------------------
// DLV TD Waldo Patterns (Perl, "DeMark Indicators", ch.11 p.171-174)
//
// Rules (the DLV_Quant_Lab readings; t = current bar, all prices raw):
//   Waldo 2  candidate X = bar t-1, needs X >= Lookback2 and X >= 4.
//            bottom: Low[X] < every Low of the Lookback2 bars before X, and
//                    (Close[X] > all four prior Closes or Close[X] <= Close[X-1]),
//                    and Close[t] > Open[t] and Close[t] < Close[t-2].
//            top:    High[X] > every High of the Lookback2 bars before X, and
//                    (Close[X] < all four prior Closes or Close[X] > Close[X-1]),
//                    and Close[t] < Open[t] and Close[t] > Close[t-2].
//   Waldo 3  range[t] >= Multiple3 * range[t-1] (range = High - Low). Then
//            upside level   = Close[t]   + range[t]  if High[t-1] > High[t-2];
//            downside level = Close[t-1] - range[t]  if Low[t-1]  < Low[t-2].
//            Levels exist on the setup bar only (never carried forward).
//   Waldo 4  X = the newest strict all-history Low (High) record that is at
//            least MinAge4 bars old. bottom when Low[t-1] < Low[X], Low[t] < Low[X],
//            Close[t-1] < Close[t-2] and Close[t] < Close[t-1]; top mirrored.
//            Each record fires at most once; a consumed record still blocks
//            older ones until a newer record matures (no fallback). X must
//            still be the lowest (highest) price: a younger record in (X, t-2]
//            that has not matured blocks the flag (Perl p.173).
//   Waldo 5  bottom: Close[t] == Close[t-1] and Close[t-1] < Close[t-2] (exact);
//            top:    Close[t] == Close[t-1] and Close[t-1] > Close[t-2].
//   Waldo 6  bottom: Low[t] < every Low of the Lookback6 prior bars and
//                    Close[t]-Low[t] > Close[t-1]-Low[t-1];
//            top:    High[t] > every High of the Lookback6 prior bars and
//                    High[t]-Close[t] > High[t-1]-Close[t-1].
//   Waldo 7  A Level-1 TD Demand (Supply) Point at pivot p is known on bar p+1;
//            from that bar on, the first Close above (below) Close[p-4] fires
//            once. A newer same-type point replaces an untriggered reference.
//   Waldo 8  bottom: Low[t] < every Low of the Extreme8 prior bars and
//                    Close[t] > Close[t-CloseLag8];
//            top:    High[t] > every High of the Extreme8 prior bars and
//                    Close[t] < Close[t-CloseLag8].
//
// Inputs (Lab defaults): Lookback2=21, Multiple3=2.0, MinAge4=10 (the value the
//   shipped td_waldo4_long preset trades), Lookback6=8, Extreme8=7, CloseLag8=5.
//   Patterns 5 and 7 have no parameters.
//
// Buffers 0-13 = the Lab outputs in order (EA-readable via iCustom/CopyBuffer):
//   0 Waldo2 bottom  1 Waldo2 top           flags 1/0
//   2 Waldo3 upside  3 Waldo3 downside      price on the setup bar, else EMPTY_VALUE
//   4 Waldo4 bottom  5 Waldo4 top           flags 1/0
//   6 Waldo5 bottom  7 Waldo5 top           flags 1/0
//   8 Waldo6 bottom  9 Waldo6 top           flags 1/0
//  10 Waldo7 bottom 11 Waldo7 top           flags 1/0
//  12 Waldo8 bottom 13 Waldo8 top           flags 1/0
// Buffers 14-25 are display only: an arrow below the Low on each bottom flag
// and above the High on each top flag, in the order of the flags above.
//
// Causality: every flag uses only bar t and earlier bars, and appears on the bar
// that completes the pattern. Waldo 7's TD Point needs bar p+1, so nothing is
// marked on the pivot. The forming bar's flags can appear or vanish until it
// closes: an EA reads shift 1. Uses the chart's symbol and timeframe.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 26
#property indicator_plots   26

#property indicator_label1  "Waldo2 bottom"
#property indicator_type1   DRAW_NONE
#property indicator_label2  "Waldo2 top"
#property indicator_type2   DRAW_NONE
#property indicator_label3  "Waldo3 upside level"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrTomato
#property indicator_label4  "Waldo3 downside level"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrLimeGreen
#property indicator_label5  "Waldo4 bottom"
#property indicator_type5   DRAW_NONE
#property indicator_label6  "Waldo4 top"
#property indicator_type6   DRAW_NONE
#property indicator_label7  "Waldo5 bottom"
#property indicator_type7   DRAW_NONE
#property indicator_label8  "Waldo5 top"
#property indicator_type8   DRAW_NONE
#property indicator_label9  "Waldo6 bottom"
#property indicator_type9   DRAW_NONE
#property indicator_label10 "Waldo6 top"
#property indicator_type10  DRAW_NONE
#property indicator_label11 "Waldo7 bottom"
#property indicator_type11  DRAW_NONE
#property indicator_label12 "Waldo7 top"
#property indicator_type12  DRAW_NONE
#property indicator_label13 "Waldo8 bottom"
#property indicator_type13  DRAW_NONE
#property indicator_label14 "Waldo8 top"
#property indicator_type14  DRAW_NONE

#property indicator_label15 "Waldo2 bottom arrow"
#property indicator_type15  DRAW_ARROW
#property indicator_color15 clrLimeGreen
#property indicator_label16 "Waldo2 top arrow"
#property indicator_type16  DRAW_ARROW
#property indicator_color16 clrTomato
#property indicator_label17 "Waldo4 bottom arrow"
#property indicator_type17  DRAW_ARROW
#property indicator_color17 clrLimeGreen
#property indicator_label18 "Waldo4 top arrow"
#property indicator_type18  DRAW_ARROW
#property indicator_color18 clrTomato
#property indicator_label19 "Waldo5 bottom arrow"
#property indicator_type19  DRAW_ARROW
#property indicator_color19 clrLimeGreen
#property indicator_label20 "Waldo5 top arrow"
#property indicator_type20  DRAW_ARROW
#property indicator_color20 clrTomato
#property indicator_label21 "Waldo6 bottom arrow"
#property indicator_type21  DRAW_ARROW
#property indicator_color21 clrLimeGreen
#property indicator_label22 "Waldo6 top arrow"
#property indicator_type22  DRAW_ARROW
#property indicator_color22 clrTomato
#property indicator_label23 "Waldo7 bottom arrow"
#property indicator_type23  DRAW_ARROW
#property indicator_color23 clrLimeGreen
#property indicator_label24 "Waldo7 top arrow"
#property indicator_type24  DRAW_ARROW
#property indicator_color24 clrTomato
#property indicator_label25 "Waldo8 bottom arrow"
#property indicator_type25  DRAW_ARROW
#property indicator_color25 clrLimeGreen
#property indicator_label26 "Waldo8 top arrow"
#property indicator_type26  DRAW_ARROW
#property indicator_color26 clrTomato

input group "Waldo 2"
input int Lookback2 = 21;
input group "Waldo 3"
input double Multiple3 = 2.0;
input group "Waldo 4"
input int MinAge4 = 10;
input group "Waldo 6"
input int Lookback6 = 8;
input group "Waldo 8"
input int Extreme8 = 7;
input int CloseLag8 = 5;

#define N_OUT 14
double B0[], B1[], B2[], B3[], B4[], B5[], B6[], B7[], B8[], B9[], B10[], B11[], B12[], B13[];
double A0[], A1[], A2[], A3[], A4[], A5[], A6[], A7[], A8[], A9[], A10[], A11[];

// Committed state of the stateful patterns (4 and 7) after every closed bar
// before g_done; the forming bar is evaluated on a copy and never committed.
int    g_done = 0;
double g_low_record, g_high_record;
int    g_low_rec[], g_high_rec[];          // record bar indices, oldest first
bool   g_low_used[], g_high_used[];
int    g_low_sel, g_high_sel;              // index into the record arrays, -1 = none aged
double g_dem_ref, g_sup_ref;
bool   g_dem_armed, g_sup_armed;

void Bind(const int index, double &buffer[])
{
   SetIndexBuffer(index, buffer, INDICATOR_DATA);
   ArraySetAsSeries(buffer, false);
   PlotIndexSetDouble(index, PLOT_EMPTY_VALUE, EMPTY_VALUE);
}

int OnInit()
{
   if(Lookback2 < 1 || !(Multiple3 > 0.0) || !MathIsValidNumber(Multiple3) || MinAge4 < 1 ||
      Lookback6 < 1 || Extreme8 < 1 || CloseLag8 < 1)
   {
      Print("DLV_TD_Waldo: lookbacks must be >= 1 and Multiple3 > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   Bind(0, B0);  Bind(1, B1);  Bind(2, B2);  Bind(3, B3);  Bind(4, B4);  Bind(5, B5);  Bind(6, B6);
   Bind(7, B7);  Bind(8, B8);  Bind(9, B9);  Bind(10, B10); Bind(11, B11); Bind(12, B12); Bind(13, B13);
   Bind(14, A0); Bind(15, A1); Bind(16, A2); Bind(17, A3); Bind(18, A4);  Bind(19, A5);
   Bind(20, A6); Bind(21, A7); Bind(22, A8); Bind(23, A9); Bind(24, A10); Bind(25, A11);
   PlotIndexSetInteger(2, PLOT_ARROW, 159);
   PlotIndexSetInteger(3, PLOT_ARROW, 159);
   for(int k = 0; k < 12; k++)
   {
      bool bottom = (k % 2 == 0);
      int shift = 12 + 10 * (k / 2);   // stagger patterns that fire on the same bar
      PlotIndexSetInteger(14 + k, PLOT_ARROW, bottom ? 233 : 234);
      PlotIndexSetInteger(14 + k, PLOT_ARROW_SHIFT, bottom ? shift : -shift);
   }
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("DLV TD Waldo (%d, %g, %d, %d, %d/%d)",
                      Lookback2, Multiple3, MinAge4, Lookback6, Extreme8, CloseLag8));
   return(INIT_SUCCEEDED);
}

void ResetState()
{
   g_done = 0;
   g_low_record = DBL_MAX;
   g_high_record = -DBL_MAX;
   ArrayResize(g_low_rec, 0);  ArrayResize(g_high_rec, 0);
   ArrayResize(g_low_used, 0); ArrayResize(g_high_used, 0);
   g_low_sel = -1; g_high_sel = -1;
   g_dem_ref = 0.0; g_sup_ref = 0.0;
   g_dem_armed = false; g_sup_armed = false;
}

// Strict Level-1 TD Points (low/high flanked by a higher/lower one each side).
bool IsDemand1(const double &low[], const int p) { return p >= 1 && low[p] < low[p - 1] && low[p] < low[p + 1]; }
bool IsSupply1(const double &high[], const int p) { return p >= 1 && high[p] > high[p - 1] && high[p] > high[p + 1]; }

double MinOf(const double &a[], const int from, const int count)
{
   double m = a[from];
   for(int k = from + 1; k < from + count; k++) if(a[k] < m) m = a[k];
   return m;
}
double MaxOf(const double &a[], const int from, const int count)
{
   double m = a[from];
   for(int k = from + 1; k < from + count; k++) if(a[k] > m) m = a[k];
   return m;
}

void Stateless(const int t, const double &open[], const double &high[], const double &low[], const double &close[])
{
   double w2b = 0.0, w2t = 0.0, w3u = EMPTY_VALUE, w3d = EMPTY_VALUE, w5b = 0.0, w5t = 0.0;
   double w6b = 0.0, w6t = 0.0, w8b = 0.0, w8t = 0.0;

   int x = t - 1;
   if(t >= 1 && x >= Lookback2 && x >= 4)
   {
      bool fresh_low = low[x] < MinOf(low, x - Lookback2, Lookback2);
      bool fresh_high = high[x] > MaxOf(high, x - Lookback2, Lookback2);
      bool low_cand = (close[x] > MaxOf(close, x - 4, 4) || close[x] <= close[x - 1]);
      bool high_cand = (close[x] < MinOf(close, x - 4, 4) || close[x] > close[x - 1]);
      if(fresh_low && low_cand && close[t] > open[t] && close[t] < close[t - 2]) w2b = 1.0;
      if(fresh_high && high_cand && close[t] < open[t] && close[t] > close[t - 2]) w2t = 1.0;
   }
   if(t >= 2)
   {
      double cr = high[t] - low[t];
      double pr = high[t - 1] - low[t - 1];
      if(!(cr < Multiple3 * pr))
      {
         if(high[t - 1] > high[t - 2]) w3u = close[t] + cr;
         if(low[t - 1] < low[t - 2]) w3d = close[t - 1] - cr;
      }
      if(close[t] == close[t - 1])
      {
         if(close[t - 1] < close[t - 2]) w5b = 1.0;
         if(close[t - 1] > close[t - 2]) w5t = 1.0;
      }
   }
   if(t >= Lookback6)
   {
      if(low[t] < MinOf(low, t - Lookback6, Lookback6) && close[t] - low[t] > close[t - 1] - low[t - 1]) w6b = 1.0;
      if(high[t] > MaxOf(high, t - Lookback6, Lookback6) && high[t] - close[t] > high[t - 1] - close[t - 1]) w6t = 1.0;
   }
   if(t >= MathMax(Extreme8, CloseLag8))
   {
      if(low[t] < MinOf(low, t - Extreme8, Extreme8) && close[t] > close[t - CloseLag8]) w8b = 1.0;
      if(high[t] > MaxOf(high, t - Extreme8, Extreme8) && close[t] < close[t - CloseLag8]) w8t = 1.0;
   }
   B0[t] = w2b; B1[t] = w2t; B2[t] = w3u; B3[t] = w3d;
   B6[t] = w5b; B7[t] = w5t; B8[t] = w6b; B9[t] = w6t; B12[t] = w8b; B13[t] = w8t;
}

// Patterns 4 and 7 on bar t. commit=false (the forming bar) leaves the state untouched.
void Stateful(const int t, const bool commit, const double &high[], const double &low[], const double &close[])
{
   double w4b = 0.0, w4t = 0.0, w7b = 0.0, w7t = 0.0;

   // Waldo 4. A record set on bar t is 0 bars old, so it cannot be selected on t.
   int lsel = g_low_sel, hsel = g_high_sel;
   int nl = ArraySize(g_low_rec), nh = ArraySize(g_high_rec);
   while(lsel + 1 < nl && t - g_low_rec[lsel + 1] >= MinAge4) lsel++;
   while(hsel + 1 < nh && t - g_high_rec[hsel + 1] >= MinAge4) hsel++;
   if(t >= 2 && lsel >= 0)
   {
      int xl = g_low_rec[lsel];
      bool clean = (lsel + 1 >= nl || g_low_rec[lsel + 1] >= t - 1);
      if(!g_low_used[lsel] && clean && low[t - 1] < low[xl] && low[t] < low[xl] &&
         close[t - 1] < close[t - 2] && close[t] < close[t - 1])
      {
         w4b = 1.0;
         if(commit) g_low_used[lsel] = true;
      }
   }
   if(t >= 2 && hsel >= 0)
   {
      int xh = g_high_rec[hsel];
      bool clean = (hsel + 1 >= nh || g_high_rec[hsel + 1] >= t - 1);
      if(!g_high_used[hsel] && clean && high[t - 1] > high[xh] && high[t] > high[xh] &&
         close[t - 1] > close[t - 2] && close[t] > close[t - 1])
      {
         w4t = 1.0;
         if(commit) g_high_used[hsel] = true;
      }
   }

   // Waldo 7: the Level-1 point at p = t-1 is confirmed by bar t.
   double dref = g_dem_ref, sref = g_sup_ref;
   bool darmed = g_dem_armed, sarmed = g_sup_armed;
   int p = t - 1;
   if(p >= 0 && IsDemand1(low, p)) { darmed = (p >= 4); dref = darmed ? close[p - 4] : 0.0; }
   if(p >= 0 && IsSupply1(high, p)) { sarmed = (p >= 4); sref = sarmed ? close[p - 4] : 0.0; }
   if(darmed && close[t] > dref) { w7b = 1.0; darmed = false; }
   if(sarmed && close[t] < sref) { w7t = 1.0; sarmed = false; }

   if(commit)
   {
      g_low_sel = lsel; g_high_sel = hsel;
      if(low[t] < g_low_record)
      {
         g_low_record = low[t];
         ArrayResize(g_low_rec, nl + 1, 1024);  g_low_rec[nl] = t;
         ArrayResize(g_low_used, nl + 1, 1024); g_low_used[nl] = false;
      }
      if(high[t] > g_high_record)
      {
         g_high_record = high[t];
         ArrayResize(g_high_rec, nh + 1, 1024);  g_high_rec[nh] = t;
         ArrayResize(g_high_used, nh + 1, 1024); g_high_used[nh] = false;
      }
      g_dem_ref = dref; g_sup_ref = sref; g_dem_armed = darmed; g_sup_armed = sarmed;
   }
   B4[t] = w4b; B5[t] = w4t; B10[t] = w7b; B11[t] = w7t;
}

void Arrows(const int t, const double &high[], const double &low[])
{
   A0[t] = B0[t] == 1.0 ? low[t] : EMPTY_VALUE;    A1[t] = B1[t] == 1.0 ? high[t] : EMPTY_VALUE;
   A2[t] = B4[t] == 1.0 ? low[t] : EMPTY_VALUE;    A3[t] = B5[t] == 1.0 ? high[t] : EMPTY_VALUE;
   A4[t] = B6[t] == 1.0 ? low[t] : EMPTY_VALUE;    A5[t] = B7[t] == 1.0 ? high[t] : EMPTY_VALUE;
   A6[t] = B8[t] == 1.0 ? low[t] : EMPTY_VALUE;    A7[t] = B9[t] == 1.0 ? high[t] : EMPTY_VALUE;
   A8[t] = B10[t] == 1.0 ? low[t] : EMPTY_VALUE;   A9[t] = B11[t] == 1.0 ? high[t] : EMPTY_VALUE;
   A10[t] = B12[t] == 1.0 ? low[t] : EMPTY_VALUE;  A11[t] = B13[t] == 1.0 ? high[t] : EMPTY_VALUE;
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
   if(prev_calculated == 0 || prev_calculated > rates_total || g_done > rates_total - 1) ResetState();
   int first = g_done;
   for(int t = g_done; t < rates_total - 1; t++) Stateful(t, true, high, low, close);
   g_done = rates_total - 1;
   Stateful(rates_total - 1, false, high, low, close);

   for(int t = MathMin(first, rates_total - 1); t < rates_total; t++)
   {
      Stateless(t, open, high, low, close);
      Arrows(t, high, low);
   }
   return(rates_total);
}
