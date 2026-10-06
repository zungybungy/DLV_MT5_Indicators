#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD D-Wave (Perl, chapter 3, p.69-89), close-validated:"
#property description "independent bullish and bearish wave counts 1-5/A/B/C with"
#property description "the Close-based Wave 3, Wave 5 and Wave C projections."

// -----------------------------------------------------------------------------
// DLV TD D-Wave
//
// Port of the DLV_Quant_Lab TD_DWAVE pseudo (bar-identical on closed bars,
// mql5/check_td_parity.py). Closes only (Perl's recommended construction).
// "N-bar high close" = a close above all N-1 prior closes (strict); "low" mirrors.
//
// Bullish count (bearish mirrors every comparison):
//   origin  a 21-bar low close (re-anchored on every later one while inactive)
//   Wave 1  a 13-bar high close after an origin
//   Wave 2  an 8-bar low close; a close below the origin close ends the count
//           (inactive; that bar may itself be a new origin)
//   Wave 3  a 21-bar high close above the Wave 1 close
//   Wave 4  a 13-bar low close; if it is below the Wave 2 close, Wave 2 moves
//           there instead (Waves 3+ cleared). In Wave 4, any close below the
//           Wave 2 close does the same
//   Wave 5  a 34-bar high close above the Wave 3 close
//   Wave A  a 13-bar low close
//   Wave B  an 8-bar high close; if it also closes above Wave 5, A/B are erased
//           and Wave 5 moves there
//   Wave C  a 21-bar low close; locked when (or once) a close is below the
//           Wave A close. Before the lock, a close above Wave 5 erases A/B/C and
//           moves Wave 5 there; after the lock it starts a fresh Wave 1 whose
//           origin is the Wave C close.
//   Shallow pullbacks: in Waves 1, 3 and 5 a close beyond the wave's close moves
//   that wave to the new bar. Waves 2 and A likewise trail to their extreme
//   close while active (bull: a lower close), since Perl p.76-80 reads "the low
//   close of TD D-Wave 2 / A" for the violation, C-lock and projections.
//   Moved anchors never revise bars already output.
//
// Projections (Close-based, 1.618):
//   Wave 3 = origin + 1.618 * (Wave 1 - origin)       from Wave 1 on
//   Wave 5 = Wave 2 + 1.618 * (Wave 3 - Wave 2)       from Wave 3 on
//   Wave C = Wave 5 - 1.618 * (Wave 5 - Wave A)       from Wave A on
//   (bearish: the mirrored signs). High/Low validation, RSI composition and the
//   "ultimate" targets are not part of the Lab pseudo and are omitted.
//
// Inputs: none (the Lab pseudo is parameterless; 21/13/8/21/13/34/13/8/21 are
// Perl's recommended lengths).
//
// Buffers (Lab output order; EA-readable through iCustom / CopyBuffer):
//   0 Bullish wave   0 inactive, 1-5, 6/7/8 = A/B/C
//   1 Bearish wave   same codes
//   2 Bullish event  the wave code on the bar that wave starts, else 0
//                    (1 = a bullish Wave 1 has just begun)
//   3 Bearish event  same
//   4 Bullish Wave 3 projection     5 Bearish Wave 3 projection
//   6 Bullish Wave 5 projection     7 Bearish Wave 5 projection
//   8 Bullish Wave C projection     9 Bearish Wave C projection
//   Projections are EMPTY_VALUE while not applicable.
// Chart: buffers 4-9 are drawn as lines; 0-3 are not drawn (Data Window / EA).
//
// Causal: bar t reads closes up to t only (lookbacks up to 33 bars back). The
// forming bar can change until it closes; an EA reads shift 1 (e.g. Bullish
// event == 1 at shift 1). Full-history incremental: state is carried bar to bar
// from the oldest bar; closed bars commit it, the forming bar works on a copy.
// Uses the chart's symbol and timeframe.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 10
#property indicator_plots   10

#property indicator_label1  "Bullish D-Wave"
#property indicator_type1   DRAW_NONE
#property indicator_label2  "Bearish D-Wave"
#property indicator_type2   DRAW_NONE
#property indicator_label3  "Bullish D-Wave event"
#property indicator_type3   DRAW_NONE
#property indicator_label4  "Bearish D-Wave event"
#property indicator_type4   DRAW_NONE

#property indicator_label5  "Bullish Wave 3 target"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrLimeGreen
#property indicator_style5  STYLE_DOT
#property indicator_label6  "Bearish Wave 3 target"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrTomato
#property indicator_style6  STYLE_DOT
#property indicator_label7  "Bullish Wave 5 target"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrLimeGreen
#property indicator_style7  STYLE_DASH
#property indicator_label8  "Bearish Wave 5 target"
#property indicator_type8   DRAW_LINE
#property indicator_color8  clrTomato
#property indicator_style8  STYLE_DASH
#property indicator_label9  "Bullish Wave C target"
#property indicator_type9   DRAW_LINE
#property indicator_color9  clrDodgerBlue
#property indicator_style9  STYLE_DASHDOT
#property indicator_label10 "Bearish Wave C target"
#property indicator_type10  DRAW_LINE
#property indicator_color10 clrOrange
#property indicator_style10 STYLE_DASHDOT

double BullCode[], BearCode[], BullEvent[], BearEvent[];
double BullW3[], BearW3[], BullW5[], BearW5[], BullWC[], BearWC[];

// One directional count. Only the anchor closes that a decision or projection
// reads are kept (the Lab also stores bars and the Wave 4/B closes, unused).
struct Wave
{
   int    phase;        // 0 inactive, 1-5, 6/7/8 = A/B/C
   bool   has_origin;
   double origin;
   double w1, w2, w3, w5, a, c;
   bool   locked;
};

struct DWState
{
   Wave bull;
   Wave bear;
};

DWState g_closed;   // state after the last CLOSED bar
int     g_done;     // closed bars folded into g_closed

void ResetWave(Wave &w)
{
   w.phase = 0; w.has_origin = false; w.locked = false;
   w.origin = 0; w.w1 = 0; w.w2 = 0; w.w3 = 0; w.w5 = 0; w.a = 0; w.c = 0;
}

// Close[i] strictly below (above) all `lookback` prior closes.
bool StrictLow(const double &close[], const int i, const int lookback)
{
   if(i < lookback) return false;
   for(int k = i - lookback; k < i; k++) if(!(close[i] < close[k])) return false;
   return true;
}

bool StrictHigh(const double &close[], const int i, const int lookback)
{
   if(i < lookback) return false;
   for(int k = i - lookback; k < i; k++) if(!(close[i] > close[k])) return false;
   return true;
}

// Trend-direction extreme (bull: high) / counter-direction extreme (bull: low).
bool Thrust(const double &close[], const int i, const int lookback, const bool bull)
{
   return bull ? StrictHigh(close, i, lookback) : StrictLow(close, i, lookback);
}

bool Pullback(const double &close[], const int i, const int lookback, const bool bull)
{
   return bull ? StrictLow(close, i, lookback) : StrictHigh(close, i, lookback);
}

// Close beyond `level` in the trend direction (bull: above).
bool Beyond(const double x, const double level, const bool bull) { return bull ? x > level : x < level; }

// Close beyond `level` against the trend (bull: below).
bool Against(const double x, const double level, const bool bull) { return bull ? x < level : x > level; }

void Inactive(Wave &w, const double &close[], const int i, const bool bull)
{
   ResetWave(w);
   if(Pullback(close, i, 20, bull)) { w.has_origin = true; w.origin = close[i]; }
}

// Wave 1 starts: later anchors and the lock are cleared.
int StartWave1(Wave &w, const double x)
{
   w.phase = 1; w.w1 = x;
   w.w2 = 0; w.w3 = 0; w.w5 = 0; w.a = 0; w.c = 0; w.locked = false;
   return 1;
}

// Relocate Wave 2 to bar i (a Wave-2 close violation); Waves 3+ cleared.
void ShiftWave2(Wave &w, const double x)
{
   w.phase = 2; w.w2 = x;
   w.w3 = 0; w.w5 = 0; w.a = 0; w.c = 0; w.locked = false;
}

// Relocate Wave 5 to bar i (A/B/C erased).
void ShiftWave5(Wave &w, const double x)
{
   w.phase = 5; w.w5 = x;
   w.a = 0; w.c = 0; w.locked = false;
}

// Advance one directional count by bar i; returns the event code.
int Advance(Wave &w, const double &close[], const int i, const bool bull)
{
   double x = close[i];
   switch(w.phase)
   {
      case 0:
         if(Pullback(close, i, 20, bull)) { w.has_origin = true; w.origin = x; }
         if(w.has_origin && Thrust(close, i, 12, bull)) return StartWave1(w, x);
         return 0;
      case 1:
         if(Pullback(close, i, 7, bull))
         {
            if(Against(x, w.origin, bull)) { Inactive(w, close, i, bull); return 0; }
            w.phase = 2; w.w2 = x;
            return 2;
         }
         if(Beyond(x, w.w1, bull)) w.w1 = x;
         return 0;
      case 2:
         if(Against(x, w.origin, bull)) { Inactive(w, close, i, bull); return 0; }
         if(Thrust(close, i, 20, bull) && Beyond(x, w.w1, bull)) { w.phase = 3; w.w3 = x; return 3; }
         if(Against(x, w.w2, bull)) w.w2 = x;
         return 0;
      case 3:
         if(Pullback(close, i, 12, bull))
         {
            if(Against(x, w.w2, bull)) { ShiftWave2(w, x); return 0; }
            w.phase = 4;
            return 4;
         }
         if(Beyond(x, w.w3, bull)) w.w3 = x;
         return 0;
      case 4:
         if(Against(x, w.w2, bull)) { ShiftWave2(w, x); return 0; }
         if(Thrust(close, i, 33, bull) && Beyond(x, w.w3, bull)) { w.phase = 5; w.w5 = x; return 5; }
         return 0;
      case 5:
         if(Pullback(close, i, 12, bull)) { w.phase = 6; w.a = x; return 6; }
         if(Beyond(x, w.w5, bull)) w.w5 = x;
         return 0;
      case 6:
         if(Thrust(close, i, 7, bull))
         {
            if(Beyond(x, w.w5, bull)) { ShiftWave5(w, x); return 0; }
            w.phase = 7;
            return 7;
         }
         if(Against(x, w.a, bull)) w.a = x;
         return 0;
      case 7:
         if(Beyond(x, w.w5, bull)) { ShiftWave5(w, x); return 0; }
         if(Pullback(close, i, 20, bull))
         {
            w.phase = 8; w.c = x; w.locked = Against(x, w.a, bull);
            return 8;
         }
         return 0;
   }
   // Phase 8 (Wave C).
   if(w.locked)
   {
      if(Beyond(x, w.w5, bull))
      {
         // A fresh sequence: the locked C close is its origin.
         double origin = w.c;
         ResetWave(w);
         w.has_origin = true; w.origin = origin;
         return StartWave1(w, x);
      }
      return 0;
   }
   if(Beyond(x, w.w5, bull)) { ShiftWave5(w, x); return 0; }
   if(Against(x, w.a, bull)) w.locked = true;
   return 0;
}

void Publish(const Wave &w, const bool bull, double &w3, double &w5, double &wc)
{
   w3 = EMPTY_VALUE; w5 = EMPTY_VALUE; wc = EMPTY_VALUE;
   if(w.phase >= 1 && w.has_origin)
      w3 = bull ? w.origin + 1.618 * (w.w1 - w.origin) : w.origin - 1.618 * (w.origin - w.w1);
   if(w.phase >= 3)
      w5 = bull ? w.w2 + 1.618 * (w.w3 - w.w2) : w.w2 - 1.618 * (w.w2 - w.w3);
   if(w.phase >= 6)
      wc = bull ? w.w5 - 1.618 * (w.w5 - w.a) : w.w5 + 1.618 * (w.a - w.w5);
}

void Step(DWState &st, const double &close[], const int i)
{
   BullEvent[i] = Advance(st.bull, close, i, true);
   BearEvent[i] = Advance(st.bear, close, i, false);
   BullCode[i] = st.bull.phase;
   BearCode[i] = st.bear.phase;
   Publish(st.bull, true, BullW3[i], BullW5[i], BullWC[i]);
   Publish(st.bear, false, BearW3[i], BearW5[i], BearWC[i]);
}

int OnInit()
{
   SetIndexBuffer(0, BullCode, INDICATOR_DATA);
   SetIndexBuffer(1, BearCode, INDICATOR_DATA);
   SetIndexBuffer(2, BullEvent, INDICATOR_DATA);
   SetIndexBuffer(3, BearEvent, INDICATOR_DATA);
   SetIndexBuffer(4, BullW3, INDICATOR_DATA);
   SetIndexBuffer(5, BearW3, INDICATOR_DATA);
   SetIndexBuffer(6, BullW5, INDICATOR_DATA);
   SetIndexBuffer(7, BearW5, INDICATOR_DATA);
   SetIndexBuffer(8, BullWC, INDICATOR_DATA);
   SetIndexBuffer(9, BearWC, INDICATOR_DATA);
   ArraySetAsSeries(BullCode, false);
   ArraySetAsSeries(BearCode, false);
   ArraySetAsSeries(BullEvent, false);
   ArraySetAsSeries(BearEvent, false);
   ArraySetAsSeries(BullW3, false);
   ArraySetAsSeries(BearW3, false);
   ArraySetAsSeries(BullW5, false);
   ArraySetAsSeries(BearW5, false);
   ArraySetAsSeries(BullWC, false);
   ArraySetAsSeries(BearWC, false);
   for(int b = 0; b < 10; b++) PlotIndexSetDouble(b, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, "DLV TD D-Wave");
   g_done = 0;
   return(INIT_SUCCEEDED);
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
   ArraySetAsSeries(close, false);
   if(rates_total < 1) return(0);
   // Full recompute from the oldest bar whenever the terminal resets the history.
   if(prev_calculated == 0 || g_done > rates_total - 1)
   {
      g_done = 0;
      ResetWave(g_closed.bull);
      ResetWave(g_closed.bear);
   }
   for(int i = g_done; i < rates_total - 1; i++)
      Step(g_closed, close, i);
   g_done = rates_total - 1;
   DWState live = g_closed;   // the forming bar works on a copy
   Step(live, close, rates_total - 1);
   return(rates_total);
}
