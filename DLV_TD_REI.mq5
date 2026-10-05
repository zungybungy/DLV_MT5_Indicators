#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD Range Expansion Index (Perl, chapter 7, p.127-132;"
#property description "DeMark, Stocks & Commodities V15:8). Bounded -100..+100"
#property description "oscillator whose overlap qualifier silences it in clean trends."

// -----------------------------------------------------------------------------
// DLV TD Range Expansion Index (TD REI)
//
// Port of the DLV_Quant_Lab TD_REI pseudo, which transcribes DeMark's own
// article (S&C V15:8, 353-359, published as Excel cell formulas):
//   F = High[t] - High[t-2]
//   G = Low[t]  - Low[t-2]
//   A: (High[t] >= Low[t-5]  or High[t] >= Low[t-6])
//      and (Low[t] <= High[t-5] or Low[t] <= High[t-6])
//   B: (High[t-2] >= Close[t-7] or High[t-2] >= Close[t-8])
//      and (Low[t-2] <= Close[t-7] or Low[t-2] <= Close[t-8])
//   J = F + G when A or B, else 0          (numerator term)
//   K = |F| + |G|                          (denominator term, never zeroed)
//   TD REI = 100 * sum(J, REIPeriod) / sum(K, REIPeriod), clipped to [-100, +100]
// When neither qualifier holds the bar is trending cleanly: it adds 0 to the
// numerator but still adds to the denominator, so the oscillator cannot print an
// extreme in a trend. Zones: oversold < -43, overbought > +43; fewer than six
// bars in a zone is "mild" (tradeable), six or more is extreme.
//
// Lab decisions kept (see the Lab docstring): the article's formula J/K wins
// over its sidebar prose; the "standard" (not "alternate") version; J and K are
// NaN until Close[t-8] and Low[t-6] exist, so the first value is a genuine
// REIPeriod-bar reading (bar REIPeriod+7). A window whose sum(K) <= 1e-12 (flat bars)
// has no value. Perl's ch.7 text groups the qualifiers differently and divides by
// the five-bar high-low range; this port follows the Lab (parity target).
//
// Input:
//   REIPeriod  summation window (default 5, the article's)
//
// Buffer (EA-readable through iCustom / CopyBuffer):
//   0 TD REI   -100..+100, EMPTY_VALUE during warm-up or on a zero denominator
//
// The window sums reproduce pandas' rolling-sum arithmetic (running Kahan sums
// from the oldest bar), so values are bit-identical to the Lab on closed bars
// (mql5/check_td_parity.py). Causal: bar t reads bars t-8..t only. The forming
// bar repaints until it closes; an EA reads shift 1. Full-history incremental:
// the rolling state is carried bar to bar from the oldest bar and never restarts
// inside the history. Uses the chart's symbol and timeframe.
// -----------------------------------------------------------------------------

#property indicator_separate_window
#property indicator_buffers 1
#property indicator_plots   1
#property indicator_minimum -100
#property indicator_maximum 100
#property indicator_level1  43
#property indicator_level2  -43
#property indicator_levelcolor clrDimGray
#property indicator_levelstyle STYLE_DOT

#property indicator_label1  "TD REI"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_width1  1

input group "Calculation"
input int REIPeriod = 5;

double REI[];

// pandas roll_sum state (aggregations.pyx add_sum/remove_sum/calc_sum):
// separate Kahan compensations for adds and removals, plus the run of identical
// trailing values that pandas uses to return an exact multiple.
struct RollSum
{
   long   nobs;
   double sum;
   double comp_add;
   double comp_remove;
   long   same_count;
   double prev;
};

struct REIState
{
   RollSum num;
   RollSum den;
};

REIState g_state;   // state after the last processed CLOSED bar
int      g_done;    // number of closed bars folded into g_state

void RollReset(RollSum &r, const double first)
{
   r.nobs = 0; r.sum = 0.0; r.comp_add = 0.0; r.comp_remove = 0.0;
   r.same_count = 0; r.prev = first;
}

void RollAdd(RollSum &r, const double v)
{
   if(!MathIsValidNumber(v)) return;
   r.nobs++;
   double y = v - r.comp_add;
   double t = r.sum + y;
   r.comp_add = t - r.sum - y;
   r.sum = t;
   if(v == r.prev) r.same_count++;
   else r.same_count = 1;
   r.prev = v;
}

void RollRemove(RollSum &r, const double v)
{
   if(!MathIsValidNumber(v)) return;
   r.nobs--;
   double y = -v - r.comp_remove;
   double t = r.sum + y;
   r.comp_remove = t - r.sum - y;
   r.sum = t;
}

// NaN-free result flag: false while fewer than REIPeriod valid values.
bool RollValue(const RollSum &r, double &out)
{
   if(r.nobs < REIPeriod || r.nobs == 0) return false;
   out = (r.same_count >= r.nobs) ? r.prev * (double)r.nobs : r.sum;
   return true;
}

// J (numerator) and K (denominator) terms of bar i; false = NaN (warm-up).
bool Terms(const int i, const double &high[], const double &low[], const double &close[],
           double &j, double &k)
{
   if(i < 8) return false;
   double f = high[i] - high[i - 2];
   double g = low[i] - low[i - 2];
   bool a = (high[i] >= low[i - 5] || high[i] >= low[i - 6])
            && (low[i] <= high[i - 5] || low[i] <= high[i - 6]);
   bool b = (high[i - 2] >= close[i - 7] || high[i - 2] >= close[i - 8])
            && (low[i - 2] <= close[i - 7] || low[i - 2] <= close[i - 8]);
   j = (a || b) ? f + g : 0.0;
   k = MathAbs(f) + MathAbs(g);
   return true;
}

double TermJ(const int i, const double &high[], const double &low[], const double &close[])
{
   double j, k;
   return Terms(i, high, low, close, j, k) ? j : EMPTY_VALUE;
}

double TermK(const int i, const double &high[], const double &low[], const double &close[])
{
   double j, k;
   return Terms(i, high, low, close, j, k) ? k : EMPTY_VALUE;
}

// Fold bar i into the state (pandas fixed-window streaming) and return TD REI.
double Step(REIState &st, const int i, const double &high[], const double &low[], const double &close[])
{
   double nan = MathSqrt(-1.0);
   double ji = TermJ(i, high, low, close), ki = TermK(i, high, low, close);
   double jv = (ji == EMPTY_VALUE) ? nan : ji, kv = (ki == EMPTY_VALUE) ? nan : ki;
   int s = MathMax(0, i + 1 - REIPeriod);
   if(i == 0 || s >= i)   // pandas recomputes the window (always when REIPeriod == 1)
   {
      double first_j = TermJ(s, high, low, close), first_k = TermK(s, high, low, close);
      RollReset(st.num, first_j == EMPTY_VALUE ? nan : first_j);
      RollReset(st.den, first_k == EMPTY_VALUE ? nan : first_k);
      for(int x = s; x <= i; x++)
      {
         double jx = TermJ(x, high, low, close), kx = TermK(x, high, low, close);
         RollAdd(st.num, jx == EMPTY_VALUE ? nan : jx);
         RollAdd(st.den, kx == EMPTY_VALUE ? nan : kx);
      }
   }
   else
   {
      int r = i - REIPeriod;
      if(r >= 0)
      {
         double jr = TermJ(r, high, low, close), kr = TermK(r, high, low, close);
         RollRemove(st.num, jr == EMPTY_VALUE ? nan : jr);
         RollRemove(st.den, kr == EMPTY_VALUE ? nan : kr);
      }
      RollAdd(st.num, jv);
      RollAdd(st.den, kv);
   }
   double num, den;
   if(!RollValue(st.num, num) || !RollValue(st.den, den) || !(den > 1e-12)) return EMPTY_VALUE;
   double rei = 100.0 * num / den;
   return MathMax(-100.0, MathMin(100.0, rei));
}

int OnInit()
{
   if(REIPeriod < 1)
   {
      Print("DLV_TD_REI: REIPeriod must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   SetIndexBuffer(0, REI, INDICATOR_DATA);
   ArraySetAsSeries(REI, false);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetInteger(INDICATOR_DIGITS, 2);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("DLV TD REI (%d)", REIPeriod));
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
   ArraySetAsSeries(high, false);
   ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);
   if(rates_total < 1) return(0);
   // Full recompute from the oldest bar whenever the terminal resets the history.
   if(prev_calculated == 0 || g_done > rates_total - 1) g_done = 0;
   // Closed bars commit their state; the forming bar works on a copy.
   for(int i = g_done; i < rates_total - 1; i++)
      REI[i] = Step(g_state, i, high, low, close);
   g_done = rates_total - 1;
   REIState live = g_state;
   REI[rates_total - 1] = Step(live, rates_total - 1, high, low, close);
   return(rates_total);
}
