#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD Combo (Perl, chapter 2, p.59-66): TD Setup plus the"
#property description "retrospective four-condition Combo Countdown, Version I (strict)"
#property description "or II (bars 11-13 need only successively lower/higher closes)."

// -----------------------------------------------------------------------------
// DLV TD Combo
//
// Port of the DLV_Quant_Lab TD_COMBO pseudo (bar-identical on closed bars,
// mql5/check_td_parity.py).
//
// Setup (identical to TD Sequential): a strict TD Price Flip, then nine
// uninterrupted closes below (buy) / above (sell) the close four bars earlier.
//
// Combo Countdown (buy; sell mirrors): counted from Setup bar 1 (the flip bar is
// automatic Combo bar 1), but nothing is published until Setup 9 completes, and
// bars 1-8 are never back-filled. A bar counts when
//   1. Close <= Low two bars earlier,
//   2. Low <= the prior bar's Low,
//   3. Close < the previous COUNTED bar's Close, and
//   4. Close < the prior bar's Close.
// Version 2: once the count is at 10, bars 11-13 need only condition 3.
//
// Lifecycle (TD_SEQ's, which Perl's Combo chapter calls identical):
//   - an opposing Setup 9 cancels every developing countdown;
//   - a buy countdown is cancelled when the bar's True Low is above the TDST
//     (Setup 9 True High) of the Setup that seeded it; sell mirrors with True High
//     below its TDST;
//   - a new same-direction Setup recycles an older countdown only when its true
//     range is >= the old one's and < 1.618x (Qualifier I), unless it lies within
//     the old Setup with no opposing Setup between them (Qualifier II keeps it);
//   - a Setup's range and containment bounds grow with its whole run; TDST stays
//     fixed at bar 9;
//   - Perl's R: a run reaching 18 closes recycles every same-direction
//     countdown, ungated. Its Combo count starts on run bar 10 (automatic bar 1),
//     advances hidden through bar 18 and is published only on bar 18.
//   Several countdowns may run at once; the one nearest completion is
//   published, and a 13 from any of them is.
//
// Risk level (Perl p.62/65): over every bar of the Combo process (counted or
// not), the lowest True Low minus that bar's True Range (buy) / highest True
// High plus its True Range (sell); first occurrence wins ties. Published only on
// the +13 bar.
//
// True High/Low = High/Low extended to the prior close (bar 0 uses its own).
//
// Input:
//   Version  1 = conservative (all four conditions on every bar), 2 = less strict
//
// Buffers (Lab output order; EA-readable through iCustom / CopyBuffer):
//   0 Buy Setup        1..9 on Setup bars, else 0
//   1 Sell Setup       1..9 on Setup bars, else 0
//   2 Buy Countdown    +n on the bar advancing the published count to n (13 =
//                      completed buy Combo), -n while parked at n, 0 none
//   3 Sell Countdown   same convention
//   4 Buy risk level   price on the +13 bar only, else EMPTY_VALUE
//   5 Sell risk level  price on the +13 bar only, else EMPTY_VALUE
// Chart: buffers 4/5 are drawn as arrows at the risk price, which marks each
// completed Combo on its 13 bar; buffers 0-3 are not drawn (Data Window / EA).
//
// Causal: every value uses bars up to its own only. The forming bar can change
// until it closes; an EA reads shift 1 (e.g. Buy Countdown == 13 at shift 1).
// Full-history incremental: state is carried bar to bar from the oldest bar;
// closed bars commit it, the forming bar works on a copy. Uses the chart's symbol
// and timeframe.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6

#property indicator_label1  "Buy Setup"
#property indicator_type1   DRAW_NONE
#property indicator_label2  "Sell Setup"
#property indicator_type2   DRAW_NONE
#property indicator_label3  "Buy Combo Countdown"
#property indicator_type3   DRAW_NONE
#property indicator_label4  "Sell Combo Countdown"
#property indicator_type4   DRAW_NONE

#property indicator_label5  "Buy Combo 13 risk"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrLimeGreen
#property indicator_width5  2

#property indicator_label6  "Sell Combo 13 risk"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrTomato
#property indicator_width6  2

input group "Calculation"
input int Version = 1;

double BuySetup[];
double SellSetup[];
double BuyCountdown[];
double SellCountdown[];
double BuyRisk[];
double SellRisk[];

// A developing (published) Combo Countdown.
struct Episode
{
   int    level;
   double last_close;
   double tdst;
   double rng;
   double th, tl, cmax, cmin;   // Setup containment bounds
   int    setup_id;
   int    setup_bar;
   double risk_extreme;
   double risk_tr;
   int    promoted_bar;         // bar it was published from a candidate, -1 none
   bool   promoted_counted;
   bool   counted;
};

// A hidden candidate: the Setup-tentative count, or the R run-bar-10 count.
struct Candidate
{
   bool   active;
   int    level;
   double last_close;
   int    setup_id;
   int    start_bar;
   double risk_extreme;
   double risk_tr;
   bool   advanced;
};

struct Side
{
   Episode   eps[];
   Candidate tentative;
   Candidate r_cand;
   int       setup;     // published Setup count
   int       run;       // conforming closes since the flip
   int       start;     // flip bar of the live run
   double    tdst;      // the live run's TDST, fixed at its bar 9
   int       setup_id;
   int       last9;     // bar of the last Setup 9, -1 none
};

struct ComboState
{
   Side buy;
   Side sell;
};

ComboState g_closed;   // state after the last CLOSED bar
ComboState g_work;
int        g_done;     // closed bars folded into g_closed

void CopySide(Side &dst, const Side &src)
{
   int n = ArraySize(src.eps);
   ArrayResize(dst.eps, n);
   for(int k = 0; k < n; k++) dst.eps[k] = src.eps[k];
   dst.tentative = src.tentative;
   dst.r_cand = src.r_cand;
   dst.setup = src.setup;
   dst.run = src.run;
   dst.start = src.start;
   dst.tdst = src.tdst;
   dst.setup_id = src.setup_id;
   dst.last9 = src.last9;
}

void ResetSide(Side &s)
{
   ArrayResize(s.eps, 0);
   s.tentative.active = false;
   s.r_cand.active = false;
   s.setup = 0; s.run = 0; s.start = 0; s.tdst = 0.0; s.setup_id = 0; s.last9 = -1;
}

double TrueHigh(const int i, const double &high[], const double &close[])
{
   return i > 0 ? MathMax(high[i], close[i - 1]) : high[i];
}

double TrueLow(const int i, const double &low[], const double &close[])
{
   return i > 0 ? MathMin(low[i], close[i - 1]) : low[i];
}

// Extremes of the Setup run lo..i: true high, true low, max close, min close.
void SetupWindow(const int lo, const int i, const double &high[], const double &low[], const double &close[],
                 double &th, double &tl, double &cmax, double &cmin)
{
   th = TrueHigh(lo, high, close); tl = TrueLow(lo, low, close);
   cmax = close[lo]; cmin = close[lo];
   for(int k = lo + 1; k <= i; k++)
   {
      th = MathMax(th, TrueHigh(k, high, close));
      tl = MathMin(tl, TrueLow(k, low, close));
      cmax = MathMax(cmax, close[k]);
      cmin = MathMin(cmin, close[k]);
   }
}

bool Qualifies(const int level, const double last_close, const int i, const bool is_buy,
               const double &high[], const double &low[], const double &close[])
{
   if(i < 2) return false;
   bool close_ok = is_buy ? close[i] < last_close : close[i] > last_close;
   if(Version == 2 && level >= 10) return close_ok;
   if(is_buy)
      return close[i] <= low[i - 2] && low[i] <= low[i - 1] && close_ok && close[i] < close[i - 1];
   return close[i] >= high[i - 2] && high[i] >= high[i - 1] && close_ok && close[i] > close[i - 1];
}

// Keep the first occurrence of the directional true extreme.
void RiskScan(double &extreme, double &tr_at, const int i, const bool is_buy,
              const double &high[], const double &low[], const double &close[])
{
   double th = TrueHigh(i, high, close), tl = TrueLow(i, low, close);
   if(is_buy) { if(tl < extreme) { extreme = tl; tr_at = th - tl; } }
   else if(th > extreme) { extreme = th; tr_at = th - tl; }
}

void SeedCandidate(Candidate &c, const int setup_id, const int i, const bool is_buy,
                   const double &high[], const double &low[], const double &close[])
{
   double th = TrueHigh(i, high, close), tl = TrueLow(i, low, close);
   c.active = true; c.level = 1; c.last_close = close[i]; c.setup_id = setup_id; c.start_bar = i;
   c.risk_extreme = is_buy ? tl : th; c.risk_tr = th - tl; c.advanced = true;
}

void AdvanceCandidate(Candidate &c, const int i, const bool is_buy,
                      const double &high[], const double &low[], const double &close[])
{
   RiskScan(c.risk_extreme, c.risk_tr, i, is_buy, high, low, close);
   c.advanced = false;
   if(Qualifies(c.level, c.last_close, i, is_buy, high, low, close))
   {
      c.level++; c.last_close = close[i]; c.advanced = true;
   }
}

void RemoveEpisode(Side &s, const int k)
{
   int n = ArraySize(s.eps);
   for(int m = k; m < n - 1; m++) s.eps[m] = s.eps[m + 1];
   ArrayResize(s.eps, n - 1);
}

// Publish a candidate as an episode (Setup 9 or R18), recycling per Qualifiers.
void StartEpisode(Side &s, const Candidate &c, const int i, const bool is_buy, const double rng,
                  const double th, const double tl, const double cmax, const double cmin,
                  const double tdst, const int opposing9, const bool is_r18)
{
   if(is_r18) ArrayResize(s.eps, 0);
   else
   {
      for(int k = ArraySize(s.eps) - 1; k >= 0; k--)
      {
         bool no_opposing = opposing9 < 0 || opposing9 < s.eps[k].setup_bar;
         bool within = cmin >= s.eps[k].tl && cmax <= s.eps[k].th
                       && ((is_buy && tl >= s.eps[k].tl) || (!is_buy && th <= s.eps[k].th));
         bool qii = no_opposing && within;
         bool recycles = s.eps[k].rng <= rng && rng < 1.618 * s.eps[k].rng;
         if(!(qii || !recycles)) RemoveEpisode(s, k);
      }
   }
   int n = ArraySize(s.eps);
   ArrayResize(s.eps, n + 1);
   s.eps[n].level = c.level;
   s.eps[n].last_close = c.last_close;
   s.eps[n].tdst = tdst;
   s.eps[n].rng = rng;
   s.eps[n].th = th; s.eps[n].tl = tl; s.eps[n].cmax = cmax; s.eps[n].cmin = cmin;
   s.eps[n].setup_id = s.setup_id;
   s.eps[n].setup_bar = i;
   s.eps[n].risk_extreme = c.risk_extreme;
   s.eps[n].risk_tr = c.risk_tr;
   s.eps[n].promoted_bar = i;
   s.eps[n].promoted_counted = c.advanced;
   s.eps[n].counted = false;
}

// Setup run bookkeeping for one side; cond = close beyond the close 4 bars back.
void UpdateRun(Side &s, const bool flip, const bool cond, const int i, const bool is_buy,
               const double &high[], const double &low[], const double &close[])
{
   if(flip)
   {
      s.setup_id++;
      s.run = 1; s.setup = 1; s.start = i;
      SeedCandidate(s.tentative, s.setup_id, i, is_buy, high, low, close);
   }
   else if(s.run > 0 && cond)
   {
      s.run++;
      s.setup = s.run <= 9 ? s.run : 0;
   }
   else { s.setup = 0; s.run = 0; }
}

void UpdateCandidates(Side &s, const int i, const bool is_buy,
                      const double &high[], const double &low[], const double &close[])
{
   // The tentative count lives only inside its own uninterrupted Setup.
   if(s.tentative.active)
   {
      if(!(s.run > 0 && s.setup >= 1 && s.setup <= 9)) s.tentative.active = false;
      else if(s.tentative.start_bar != i) AdvanceCandidate(s.tentative, i, is_buy, high, low, close);
   }
   // R candidate: automatic bar 1 on run bar 10, hidden through run bar 18.
   if(s.run == 10 && !s.r_cand.active)
      SeedCandidate(s.r_cand, s.setup_id, i, is_buy, high, low, close);
   else if(s.r_cand.active)
   {
      if(!(s.run >= 10 && s.run <= 18)) s.r_cand.active = false;
      else if(s.r_cand.start_bar != i) AdvanceCandidate(s.r_cand, i, is_buy, high, low, close);
   }
}

// Advance live episodes and write the published count / risk: +13 and its risk
// when any episode completes, else the episode nearest completion.
void AdvanceAndPublish(Side &s, const int i, const bool is_buy,
                       const double &high[], const double &low[], const double &close[],
                       double &count_out, double &risk_out)
{
   bool   completed = false;
   double risk = EMPTY_VALUE;
   for(int k = 0; k < ArraySize(s.eps); k++)
   {
      bool counted;
      if(s.eps[k].promoted_bar == i) counted = s.eps[k].promoted_counted;
      else
      {
         RiskScan(s.eps[k].risk_extreme, s.eps[k].risk_tr, i, is_buy, high, low, close);
         counted = Qualifies(s.eps[k].level, s.eps[k].last_close, i, is_buy, high, low, close);
         if(counted) { s.eps[k].level++; s.eps[k].last_close = close[i]; }
      }
      s.eps[k].counted = counted;
      if(s.eps[k].level >= 13)
      {
         if(counted && !completed)
         {
            completed = true;
            risk = is_buy ? s.eps[k].risk_extreme - s.eps[k].risk_tr
                          : s.eps[k].risk_extreme + s.eps[k].risk_tr;
         }
         RemoveEpisode(s, k);
         k--;
      }
   }
   if(completed) { count_out = 13.0; risk_out = risk; return; }
   risk_out = EMPTY_VALUE;
   count_out = 0.0;
   int best = -1;
   for(int k = 0; k < ArraySize(s.eps); k++)
      if(best < 0 || s.eps[k].level > s.eps[best].level) best = k;
   if(best < 0 || s.eps[best].level <= 0) return;
   double level = (double)s.eps[best].level;
   if(s.eps[best].promoted_bar == i) count_out = level;
   else count_out = s.eps[best].counted ? level : -level;
}

void Step(ComboState &st, const int i, const double &high[], const double &low[], const double &close[])
{
   bool b_cond = i >= 4 && close[i] < close[i - 4];
   bool s_cond = i >= 4 && close[i] > close[i - 4];
   bool bearish_flip = i >= 5 && close[i - 1] > close[i - 5] && b_cond;
   bool bullish_flip = i >= 5 && close[i - 1] < close[i - 5] && s_cond;
   UpdateRun(st.buy, bearish_flip, b_cond, i, true, high, low, close);
   UpdateRun(st.sell, bullish_flip, s_cond, i, false, high, low, close);
   BuySetup[i] = st.buy.setup;
   SellSetup[i] = st.sell.setup;
   UpdateCandidates(st.buy, i, true, high, low, close);
   UpdateCandidates(st.sell, i, false, high, low, close);

   bool b_done = st.buy.setup == 9 || st.buy.run == 18;
   bool s_done = st.sell.setup == 9 || st.sell.run == 18;
   double b_th = 0, b_tl = 0, b_cmax = 0, b_cmin = 0, s_th = 0, s_tl = 0, s_cmax = 0, s_cmin = 0;
   if(b_done) SetupWindow(st.buy.start, i, high, low, close, b_th, b_tl, b_cmax, b_cmin);
   if(s_done) SetupWindow(st.sell.start, i, high, low, close, s_th, s_tl, s_cmax, s_cmin);
   if(st.buy.setup == 9) st.buy.tdst = b_th;
   if(st.sell.setup == 9) st.sell.tdst = s_tl;

   // An extending run refreshes its episodes' range and containment bounds.
   if(st.buy.run > 9)
   {
      double w_th, w_tl, w_cmax, w_cmin;
      SetupWindow(st.buy.start, i, high, low, close, w_th, w_tl, w_cmax, w_cmin);
      for(int k = 0; k < ArraySize(st.buy.eps); k++)
         if(st.buy.eps[k].setup_id == st.buy.setup_id)
         {
            st.buy.eps[k].rng = w_th - w_tl;
            st.buy.eps[k].th = w_th; st.buy.eps[k].tl = w_tl;
            st.buy.eps[k].cmax = w_cmax; st.buy.eps[k].cmin = w_cmin;
         }
   }
   if(st.sell.run > 9)
   {
      double w_th, w_tl, w_cmax, w_cmin;
      SetupWindow(st.sell.start, i, high, low, close, w_th, w_tl, w_cmax, w_cmin);
      for(int k = 0; k < ArraySize(st.sell.eps); k++)
         if(st.sell.eps[k].setup_id == st.sell.setup_id)
         {
            st.sell.eps[k].rng = w_th - w_tl;
            st.sell.eps[k].th = w_th; st.sell.eps[k].tl = w_tl;
            st.sell.eps[k].cmax = w_cmax; st.sell.eps[k].cmin = w_cmin;
         }
   }

   // Opposing Setup 9 and the true-extreme TDST rule cancel episodes.
   double tl_i = TrueLow(i, low, close), th_i = TrueHigh(i, high, close);
   for(int k = ArraySize(st.buy.eps) - 1; k >= 0; k--)
      if(st.sell.setup == 9 || tl_i > st.buy.eps[k].tdst) RemoveEpisode(st.buy, k);
   for(int k = ArraySize(st.sell.eps) - 1; k >= 0; k--)
      if(st.buy.setup == 9 || th_i < st.sell.eps[k].tdst) RemoveEpisode(st.sell, k);

   if(st.buy.setup == 9 && st.buy.tentative.active)
   {
      StartEpisode(st.buy, st.buy.tentative, i, true, b_th - b_tl, b_th, b_tl, b_cmax, b_cmin,
                   b_th, st.sell.last9, false);
      st.buy.tentative.active = false;
   }
   else if(st.buy.run == 18 && st.buy.r_cand.active)
   {
      StartEpisode(st.buy, st.buy.r_cand, i, true, b_th - b_tl, b_th, b_tl, b_cmax, b_cmin,
                   st.buy.tdst, st.sell.last9, true);
      st.buy.r_cand.active = false;
   }
   if(st.sell.setup == 9 && st.sell.tentative.active)
   {
      StartEpisode(st.sell, st.sell.tentative, i, false, s_th - s_tl, s_th, s_tl, s_cmax, s_cmin,
                   s_tl, st.buy.last9, false);
      st.sell.tentative.active = false;
   }
   else if(st.sell.run == 18 && st.sell.r_cand.active)
   {
      StartEpisode(st.sell, st.sell.r_cand, i, false, s_th - s_tl, s_th, s_tl, s_cmax, s_cmin,
                   st.sell.tdst, st.buy.last9, true);
      st.sell.r_cand.active = false;
   }
   if(st.buy.setup == 9) st.buy.last9 = i;
   if(st.sell.setup == 9) st.sell.last9 = i;

   double count, risk;
   AdvanceAndPublish(st.buy, i, true, high, low, close, count, risk);
   BuyCountdown[i] = count; BuyRisk[i] = risk;
   AdvanceAndPublish(st.sell, i, false, high, low, close, count, risk);
   SellCountdown[i] = count; SellRisk[i] = risk;
}

int OnInit()
{
   if(Version != 1 && Version != 2)
   {
      Print("DLV_TD_Combo: Version must be 1 or 2.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   SetIndexBuffer(0, BuySetup, INDICATOR_DATA);
   SetIndexBuffer(1, SellSetup, INDICATOR_DATA);
   SetIndexBuffer(2, BuyCountdown, INDICATOR_DATA);
   SetIndexBuffer(3, SellCountdown, INDICATOR_DATA);
   SetIndexBuffer(4, BuyRisk, INDICATOR_DATA);
   SetIndexBuffer(5, SellRisk, INDICATOR_DATA);
   ArraySetAsSeries(BuySetup, false);
   ArraySetAsSeries(SellSetup, false);
   ArraySetAsSeries(BuyCountdown, false);
   ArraySetAsSeries(SellCountdown, false);
   ArraySetAsSeries(BuyRisk, false);
   ArraySetAsSeries(SellRisk, false);
   PlotIndexSetInteger(4, PLOT_ARROW, 233);
   PlotIndexSetInteger(5, PLOT_ARROW, 234);
   for(int b = 0; b < 6; b++) PlotIndexSetDouble(b, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("DLV TD Combo (Version %d)", Version));
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
   if(prev_calculated == 0 || g_done > rates_total - 1)
   {
      g_done = 0;
      ResetSide(g_closed.buy);
      ResetSide(g_closed.sell);
   }
   for(int i = g_done; i < rates_total - 1; i++)
      Step(g_closed, i, high, low, close);
   g_done = rates_total - 1;
   // The forming bar works on a copy of the committed state.
   CopySide(g_work.buy, g_closed.buy);
   CopySide(g_work.sell, g_closed.sell);
   Step(g_work, rates_total - 1, high, low, close);
   return(rates_total);
}
