#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD Relative and Absolute Retracements based on Perl,"
#property description "chapter 5: causal levels, TD Magnet Prices and qualified breaks;"
#property description "bit-identical to the DLV_Quant_Lab TD_REL/ABS_RETRACEMENT."

// -----------------------------------------------------------------------------
// DLV TD Retracements (Perl, "DeMark Indicators", ch.5 p.103-110)
//
// TD Relative Retracement (Lab TD_REL_RETRACEMENT):
//   Z = a Level-N TD Demand/Supply Point (strict, as DLV_TD_Point), used only on
//   its confirmation bar Z + N.
//   Demand Z: X = the most recent earlier bar with Low[X] <= Low[Z]; Y = the
//     first highest High in X..Z (inclusive).
//     upside level = Low[Z] + RelRatio * (High[Y] - Low[Z]);  magnet = Close[Y].
//   Supply Z: X = the most recent earlier bar with High[X] >= High[Z]; Y = the
//     first lowest Low in X..Z.
//     downside level = High[Z] - RelRatio * (High[Z] - Low[Y]); magnet = Close[Y].
//   A side stays empty until a Z has an X; then level and magnet hold until the
//   next such Z of that side (each replacement starts a new level generation).
//   Breaks (the TD Line qualifiers, Q2 with the retracement clause), upside
//   level U on bar t:
//     break   High[t] > U
//     Q1      Close[t-1] < Close[t-2]
//     Q2      Open[t] > U and High[t] > Open[t]   (opens above U "and then trades
//             one tick above the open", Perl p.106; OHLC reading, no tick size)
//     Q3      2*Close[t-1] - min(Low[t-1], Close[t-2]) < U   (needs bar t-2)
//     qualified = break and (Q1 or Q2 or Q3); disqualified = break and none.
//   Downside mirrored (Low < D, Close[t-1] > Close[t-2], Open < D and Low < Open,
//   2*Close[t-1] - max(High[t-1], Close[t-2]) > D). Only a FRESH break counts:
//   the prior bar was not beyond the level, or the level generation changed.
// TD Absolute Retracement (Lab TD_ABS_RETRACEMENT):
//   upside level   = Close of each new strict all-history Low record  * AbsUpRatio
//   downside level = Close of each new strict all-history High record * AbsDownRatio
//   held until the next record.
//
// Inputs (Lab defaults): RelLevel = 1, RelRatio = 0.382, AbsUpRatio = 1.382,
//   AbsDownRatio = 0.618.
//
// Buffers 0-9 (EA-readable via iCustom/CopyBuffer); prices EMPTY_VALUE until set:
//   0 REL upside level      1 REL downside level
//   2 REL upside magnet     3 REL downside magnet
//   4 REL upper qualified   5 REL lower qualified       flags 1/0
//   6 REL upper disqualified 7 REL lower disqualified   flags 1/0
//   8 ABS upside level      9 ABS downside level
// Buffers 10-13 are display only: qualified upper break = up arrow below the Low,
// qualified lower break = down arrow above the High, disqualified upper break =
// cross above the High, disqualified lower break = cross below the Low.
//
// Causality: a relative level appears on Z's confirmation bar Z + RelLevel, never
// on Z. Break flags use bar t's own Open/High/Low and earlier closes, so on the
// forming bar they (and a new level) can still change until it closes: an EA
// reads shift 1. Uses the chart's symbol and timeframe.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 14
#property indicator_plots   14

#property indicator_label1  "REL upside"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrTomato
#property indicator_label2  "REL downside"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLimeGreen
#property indicator_label3  "REL upside magnet"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrGold
#property indicator_label4  "REL downside magnet"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrGold
#property indicator_label5  "REL upper qualified"
#property indicator_type5   DRAW_NONE
#property indicator_label6  "REL lower qualified"
#property indicator_type6   DRAW_NONE
#property indicator_label7  "REL upper disqualified"
#property indicator_type7   DRAW_NONE
#property indicator_label8  "REL lower disqualified"
#property indicator_type8   DRAW_NONE
#property indicator_label9  "ABS upside"
#property indicator_type9   DRAW_ARROW
#property indicator_color9  clrOrange
#property indicator_label10 "ABS downside"
#property indicator_type10  DRAW_ARROW
#property indicator_color10 clrDodgerBlue
#property indicator_label11 "REL upper qualified arrow"
#property indicator_type11  DRAW_ARROW
#property indicator_color11 clrLimeGreen
#property indicator_label12 "REL lower qualified arrow"
#property indicator_type12  DRAW_ARROW
#property indicator_color12 clrTomato
#property indicator_label13 "REL upper disqualified mark"
#property indicator_type13  DRAW_ARROW
#property indicator_color13 clrSilver
#property indicator_label14 "REL lower disqualified mark"
#property indicator_type14  DRAW_ARROW
#property indicator_color14 clrSilver

input group "TD Relative Retracement"
input int    RelLevel = 1;
input double RelRatio = 0.382;
input group "TD Absolute Retracement"
input double AbsUpRatio = 1.382;
input double AbsDownRatio = 0.618;

double RelUp[], RelDown[], UpMagnet[], DownMagnet[], UpperOk[], LowerOk[], UpperBad[], LowerBad[], AbsUp[], AbsDown[];
double UpperOkArrow[], LowerOkArrow[], UpperBadMark[], LowerBadMark[];

// Committed state after every closed bar before g_done.
struct RetState
{
   double up, down, up_magnet, down_magnet;
   int    up_gen, down_gen;
   bool   up_beyond, down_beyond;       // the previous bar was beyond its level
   double low_record, high_record, abs_up, abs_down;
};
RetState g_state;
int      g_done = 0;

void Bind(const int index, double &buffer[], const int arrow)
{
   SetIndexBuffer(index, buffer, INDICATOR_DATA);
   ArraySetAsSeries(buffer, false);
   PlotIndexSetDouble(index, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   if(arrow > 0) PlotIndexSetInteger(index, PLOT_ARROW, arrow);
}

int OnInit()
{
   if(RelLevel < 1 || !(RelRatio > 0.0) || !MathIsValidNumber(RelRatio) ||
      !(AbsUpRatio > 0.0) || !MathIsValidNumber(AbsUpRatio) || !(AbsDownRatio > 0.0) || !MathIsValidNumber(AbsDownRatio))
   {
      Print("DLV_TD_Retracement: RelLevel must be >= 1 and all ratios positive.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   Bind(0, RelUp, 158);  Bind(1, RelDown, 158);  Bind(2, UpMagnet, 158); Bind(3, DownMagnet, 158);
   Bind(4, UpperOk, 0);  Bind(5, LowerOk, 0);    Bind(6, UpperBad, 0);   Bind(7, LowerBad, 0);
   Bind(8, AbsUp, 158);  Bind(9, AbsDown, 158);
   Bind(10, UpperOkArrow, 233); Bind(11, LowerOkArrow, 234); Bind(12, UpperBadMark, 251); Bind(13, LowerBadMark, 251);
   PlotIndexSetInteger(10, PLOT_ARROW_SHIFT, 12);
   PlotIndexSetInteger(11, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(12, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(13, PLOT_ARROW_SHIFT, 12);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("DLV TD Retracement (REL L%d %g; ABS %g/%g)",
                      RelLevel, RelRatio, AbsUpRatio, AbsDownRatio));
   return(INIT_SUCCEEDED);
}

void ResetState()
{
   g_done = 0;
   g_state.up = EMPTY_VALUE; g_state.down = EMPTY_VALUE;
   g_state.up_magnet = EMPTY_VALUE; g_state.down_magnet = EMPTY_VALUE;
   g_state.up_gen = -1; g_state.down_gen = -1;
   g_state.up_beyond = false; g_state.down_beyond = false;
   g_state.low_record = DBL_MAX; g_state.high_record = -DBL_MAX;
   g_state.abs_up = EMPTY_VALUE; g_state.abs_down = EMPTY_VALUE;
}

// Strict Level-N pivots at p; the caller guarantees p + RelLevel exists.
bool IsDemand(const double &low[], const int p)
{
   if(p < RelLevel) return false;
   for(int k = 1; k <= RelLevel; k++)
      if(!(low[p] < low[p - k] && low[p] < low[p + k])) return false;
   return true;
}
bool IsSupply(const double &high[], const int p)
{
   if(p < RelLevel) return false;
   for(int k = 1; k <= RelLevel; k++)
      if(!(high[p] > high[p - k] && high[p] > high[p + k])) return false;
   return true;
}

void Step(RetState &s, const int t, const double &open[], const double &high[], const double &low[], const double &close[])
{
   int prev_up_gen = s.up_gen, prev_down_gen = s.down_gen;   // the previous bar's generations
   int z = t - RelLevel;
   if(z >= 0 && IsDemand(low, z))
   {
      int x = z - 1;
      while(x >= 0 && !(low[x] <= low[z])) x--;
      if(x >= 0)
      {
         int y = x;
         for(int k = x + 1; k <= z; k++) if(high[k] > high[y]) y = k;
         s.up = low[z] + RelRatio * (high[y] - low[z]);
         s.up_magnet = close[y];
         s.up_gen++;
      }
   }
   if(z >= 0 && IsSupply(high, z))
   {
      int x = z - 1;
      while(x >= 0 && !(high[x] >= high[z])) x--;
      if(x >= 0)
      {
         int y = x;
         for(int k = x + 1; k <= z; k++) if(low[k] < low[y]) y = k;
         s.down = high[z] - RelRatio * (high[z] - low[y]);
         s.down_magnet = close[y];
         s.down_gen++;
      }
   }
   if(low[t] < s.low_record)   { s.low_record = low[t];   s.abs_up = close[t] * AbsUpRatio; }
   if(high[t] > s.high_record) { s.high_record = high[t]; s.abs_down = close[t] * AbsDownRatio; }

   // Fresh breaks: the previous bar was inside, or this bar replaced the level.
   bool upper_ok = false, upper_bad = false, lower_ok = false, lower_bad = false;
   bool up_beyond = (s.up != EMPTY_VALUE && high[t] > s.up);
   bool down_beyond = (s.down != EMPTY_VALUE && low[t] < s.down);
   bool has2 = (t >= 2);
   if(up_beyond && (!s.up_beyond || s.up_gen != prev_up_gen))
   {
      bool q = (has2 && close[t - 1] < close[t - 2]) || (open[t] > s.up && high[t] > open[t]) ||
               (has2 && 2.0 * close[t - 1] - MathMin(low[t - 1], close[t - 2]) < s.up);
      upper_ok = q; upper_bad = !q;
   }
   if(down_beyond && (!s.down_beyond || s.down_gen != prev_down_gen))
   {
      bool q = (has2 && close[t - 1] > close[t - 2]) || (open[t] < s.down && low[t] < open[t]) ||
               (has2 && 2.0 * close[t - 1] - MathMax(high[t - 1], close[t - 2]) > s.down);
      lower_ok = q; lower_bad = !q;
   }
   s.up_beyond = up_beyond;
   s.down_beyond = down_beyond;

   RelUp[t] = s.up; RelDown[t] = s.down; UpMagnet[t] = s.up_magnet; DownMagnet[t] = s.down_magnet;
   UpperOk[t] = upper_ok ? 1.0 : 0.0;   LowerOk[t] = lower_ok ? 1.0 : 0.0;
   UpperBad[t] = upper_bad ? 1.0 : 0.0; LowerBad[t] = lower_bad ? 1.0 : 0.0;
   AbsUp[t] = s.abs_up; AbsDown[t] = s.abs_down;
   UpperOkArrow[t] = upper_ok ? low[t] : EMPTY_VALUE;
   LowerOkArrow[t] = lower_ok ? high[t] : EMPTY_VALUE;
   UpperBadMark[t] = upper_bad ? high[t] : EMPTY_VALUE;
   LowerBadMark[t] = lower_bad ? low[t] : EMPTY_VALUE;
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
   for(int t = g_done; t < rates_total - 1; t++) Step(g_state, t, open, high, low, close);
   g_done = rates_total - 1;
   RetState forming = g_state;
   Step(forming, rates_total - 1, open, high, low, close);
   return(rates_total);
}
