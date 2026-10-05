#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD Trend Factor based on Perl, chapter 6. Three downside"
#property description "and three upside levels projected off qualified, confirmation-"
#property description "lagged TD Points; bit-identical to the DLV_Quant_Lab TD_TREND_FACTOR."

// -----------------------------------------------------------------------------
// DLV TD Trend Factor (Perl, "DeMark Indicators", ch.6 p.115-120)
//
// Pivots: Level-N TD Points (strict, as DLV_TD_Point). A pivot at bar p is known
//   on bar p + N and is acted on there, never earlier.
// Downside ladder (off a qualified HIGH): when a Supply Point p is confirmed and
//   High[p] >= Low[last Demand Point before it] * (1 + Ratio)   (advanced 5.556%),
//     anchor = High[p] if Close[p] > Close[p-1], else Close[p]
//     level 1 = anchor  * (1 - Ratio)
//     level 2 = High[p] * (1 - Ratio)^2      COMPOUNDING
//     level 3 = High[p] * (1 - Ratio)^3
// Upside ladder (off a qualified LOW): when a Demand Point p is confirmed and
//   Low[p] <= High[last Supply Point before it] * (1 - Ratio)   (declined 5.556%),
//     anchor = Low[p] if Close[p] < Close[p-1], else Close[p]
//     level 1 = anchor * (1 + Ratio)
//     level 2 = Low[p] * (1 + 2 * Ratio)     ARITHMETIC
//     level 3 = Low[p] * (1 + 3 * Ratio)
//   The asymmetry is the Lab's deliberate reading of Perl p.116 ("the downside
//   projections are derived differently, since each TD Trend Factor level is
//   used to determine the next one"), pinned in the Lab against Figures 6.2/6.5.
//   On a bar that is both, the Supply Point is processed first, so the Demand
//   Point's qualification sees that same bar as its last Supply Point.
//   Ladders hold until a newer qualified pivot replaces them.
//
// Inputs (Lab defaults): Level = 3, Ratio = 0.0556 (Perl suggests 0.00556 for
//   markets quoted to four decimals).
//
// Buffers (EA-readable through iCustom/CopyBuffer), EMPTY_VALUE until the first
// ladder of that side exists:
//   0 downside level 1   1 downside level 2   2 downside level 3
//   3 upside level 1     4 upside level 2     5 upside level 3
//
// Causality: a ladder appears on the confirmation bar p + Level. The forming
// bar's Low/High is in the newest pivot's right-hand window, so a new ladder on
// bar 0 can still appear or vanish until it closes: an EA reads shift 1.
// Uses the chart's symbol and timeframe.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6

#property indicator_label1  "TF downside 1"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrTomato
#property indicator_label2  "TF downside 2"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrTomato
#property indicator_label3  "TF downside 3"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrTomato
#property indicator_label4  "TF upside 1"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrLimeGreen
#property indicator_label5  "TF upside 2"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrLimeGreen
#property indicator_label6  "TF upside 3"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrLimeGreen

input group "Calculation"
input int    Level = 3;
input double Ratio = 0.0556;

double Dn1[], Dn2[], Dn3[], Up1[], Up2[], Up3[];

// Committed state after every closed bar before g_done.
struct TFState
{
   double dn1, dn2, dn3, up1, up2, up3;
   int    last_dem, last_sup;
};
TFState g_state;
int     g_done = 0;

void Bind(const int index, double &buffer[])
{
   SetIndexBuffer(index, buffer, INDICATOR_DATA);
   ArraySetAsSeries(buffer, false);
   PlotIndexSetDouble(index, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(index, PLOT_ARROW, 158);
}

int OnInit()
{
   if(Level < 1 || !MathIsValidNumber(Ratio))
   {
      Print("DLV_TD_TrendFactor: Level must be >= 1 and Ratio finite.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   Bind(0, Dn1); Bind(1, Dn2); Bind(2, Dn3); Bind(3, Up1); Bind(4, Up2); Bind(5, Up3);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("DLV TD Trend Factor (Level %d, %g)", Level, Ratio));
   return(INIT_SUCCEEDED);
}

void ResetState()
{
   g_done = 0;
   g_state.dn1 = EMPTY_VALUE; g_state.dn2 = EMPTY_VALUE; g_state.dn3 = EMPTY_VALUE;
   g_state.up1 = EMPTY_VALUE; g_state.up2 = EMPTY_VALUE; g_state.up3 = EMPTY_VALUE;
   g_state.last_dem = -1; g_state.last_sup = -1;
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

void Step(TFState &s, const int t, const double &high[], const double &low[], const double &close[])
{
   int p = t - Level;   // the bar whose pivot status is known on t
   if(p >= 1)
   {
      if(IsSupply(high, p))
      {
         if(s.last_dem >= 0 && high[p] >= low[s.last_dem] * (1.0 + Ratio))
         {
            double anchor = close[p] > close[p - 1] ? high[p] : close[p];
            s.dn1 = anchor * (1.0 - Ratio);
            s.dn2 = high[p] * MathPow(1.0 - Ratio, 2);
            s.dn3 = high[p] * MathPow(1.0 - Ratio, 3);
         }
         s.last_sup = p;
      }
      if(IsDemand(low, p))
      {
         if(s.last_sup >= 0 && low[p] <= high[s.last_sup] * (1.0 - Ratio))
         {
            double anchor = close[p] < close[p - 1] ? low[p] : close[p];
            s.up1 = anchor * (1.0 + Ratio);
            s.up2 = low[p] * (1.0 + Ratio * 2);
            s.up3 = low[p] * (1.0 + Ratio * 3);
         }
         s.last_dem = p;
      }
   }
   Dn1[t] = s.dn1; Dn2[t] = s.dn2; Dn3[t] = s.dn3;
   Up1[t] = s.up1; Up2[t] = s.up2; Up3[t] = s.up3;
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
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   if(rates_total < 2) return(0);

   // Full pass from the oldest bar on a fresh or reloaded history; afterwards
   // closed bars are committed once and only the forming bar is re-evaluated.
   if(prev_calculated == 0 || prev_calculated > rates_total || g_done > rates_total - 1) ResetState();
   for(int t = g_done; t < rates_total - 1; t++) Step(g_state, t, high, low, close);
   g_done = rates_total - 1;
   TFState forming = g_state;
   Step(forming, rates_total - 1, high, low, close);
   return(rates_total);
}
