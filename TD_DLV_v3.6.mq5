#property copyright "DLV"
#property link      "DLV"
#property version   "3.6"

// v3.6 - Rule-correct TD Sequential implementation based on Jason Perl,
// "DeMark Indicators" (Bloomberg, 2008). This version keeps the source-visible
// chart state non-stale while preserving the completed-bar history.
//
//   1. TD Setup Recycle, gated on setup size. A competing same-direction Setup 9
//      recycles a live Countdown only when its true range is >= the active
//      Setup's and < 1.618x it. Smaller means the move is fading; 1.618x or more
//      means exhaustion. Neither recycles. Whichever Setup has the larger true
//      range becomes the active one, so the TDST line follows it.
//   2. The "R" qualifier. A Setup extending to 18 closes without an intervening
//      TD Price Flip recycles the developing Countdown on its own, ungated.
//   3. The Countdown 13 TD Risk Level scanned only bar 13. Perl: "identify the
//      lowest true low throughout the TD Sequential Buy Countdown process, which
//      includes bars one through thirteen, whether or not it is a numbered price
//      bar" — then subtract that bar's true range from its true low. Scanning only
//      bar 13 understates the stop whenever an earlier Countdown bar traded lower,
//      which is the common case. The Setup 9 risk level already scanned its full
//      nine bars and is unchanged.
//   4. Deferred Setup Perfection compared against the LIVE bars 6/7 lows, which the
//      next setup overwrites as it counts past 6 and 7. An unperfected setup left
//      waiting would then be perfected against a different setup's reference bars —
//      and once the new setup wrote bar 6, the test degenerated to Low[i] <= Low[i],
//      trivially true. The reference lows are now frozen at completion.
//      Rule coverage (bar 8, bar 9, then any subsequent bar) was already complete.
//
// Additional v3.6 corrections:
//   - strict TD Price Flips (equality is not a flip);
//   - TDST uses only the completed Setup's true extremes;
//   - true-low/true-high Countdown cancellation occurs before advancement;
//   - Cancellation Qualifier II preserves contained prior Countdowns while the
//     new Setup starts its own standard and Aggressive Countdown episodes;
//   - multiple same-direction Countdown episodes advance in parallel;
//   - Setup Perfection is reported when it becomes known, never back-dated;
//   - live chart objects are synchronised on every recalculated bar and alerts
//     fire only for a newly closed bar;
//   - Setup metadata (true range, TDST, Qualifier II bounds) is measured on the
//     trailing NINE bars via SetupWindow, at Setup 9, while a run extends, and at
//     the R bar. Accumulating from the Price Flip published an 18-bar TDST at
//     every R bar and inflated the range used by the 1.618 recycle gate;
//   - buffers 0/1 (TDST Resistance/Support) are CAUSAL. They are published on the
//     Setup 9 bar and propagate forward, never back-filled across the Setup's own
//     nine bars. The back-fill was invisible on the chart but fed look-ahead to
//     any EA reading these buffers over history through iCustom. If the
//     Setup-spanning visual is wanted back, add it as a separate overlay rather
//     than by making these buffers noncausal again.

#property description "Shows setups and countdowns based on Tom DeMark's Sequential method."
#property description "Includes fixes for True High/Low TDST and Series Array iteration."
#property description "v3.6 implements strict Price Flips, true-extreme TDST,"
#property description "parallel standard/Aggressive Countdowns, Qualifier II,"
#property description "true-range cancellation and closed-bar-safe alerts."

#property indicator_chart_window
#property indicator_buffers 14
#property indicator_plots 14

// --- PLOT SETTINGS ---

// 1. TDST Resistance
#property indicator_color1 clrRed
#property indicator_type1  DRAW_ARROW 
#property indicator_width1 1
#property indicator_label1 "TDST Resistance"

// 2. TDST Support
#property indicator_color2 clrGreen
#property indicator_type2  DRAW_ARROW
#property indicator_width2 1
#property indicator_label2 "TDST Support"

// 3. Setup Numbers
#property indicator_type3  DRAW_NONE
#property indicator_color3 clrNONE
#property indicator_label3 "Setup"

// 4. Countdown Numbers
#property indicator_type4  DRAW_NONE
#property indicator_label4 "Countdown"
#property indicator_color4 clrNONE

// 5. Perfection Arrows
#property indicator_type5  DRAW_NONE
#property indicator_label5 "Perfection"
#property indicator_color5 clrNONE

// --- SETUP RISKS (DOTTED) ---

// 6. Buy Setup Risk A 
#property indicator_color6 clrMagenta
#property indicator_type6  DRAW_LINE
#property indicator_style6 STYLE_DOT
#property indicator_width6 1
#property indicator_label6 "Buy Setup Stop A"

// 7. Sell Setup Risk A 
#property indicator_color7 clrCyan
#property indicator_type7  DRAW_LINE
#property indicator_style7 STYLE_DOT
#property indicator_width7 1
#property indicator_label7 "Sell Setup Stop A"

// 8. Buy Setup Risk B 
#property indicator_color8 clrMagenta
#property indicator_type8  DRAW_LINE
#property indicator_style8 STYLE_DOT
#property indicator_width8 1
#property indicator_label8 "Buy Setup Stop B"

// 9. Sell Setup Risk B 
#property indicator_color9 clrCyan
#property indicator_type9  DRAW_LINE
#property indicator_style9 STYLE_DOT
#property indicator_width9 1
#property indicator_label9 "Sell Setup Stop B"

// --- COUNTDOWN RISKS (SOLID) ---

// 10. Buy Countdown Risk A
#property indicator_color10 clrMagenta
#property indicator_type10  DRAW_LINE
#property indicator_style10 STYLE_SOLID
#property indicator_width10 1
#property indicator_label10 "Buy Countdown Stop A"

// 11. Sell Countdown Risk A
#property indicator_color11 clrCyan
#property indicator_type11  DRAW_LINE
#property indicator_style11 STYLE_SOLID
#property indicator_width11 1
#property indicator_label11 "Sell Countdown Stop A"

// 12. Buy Countdown Risk B
#property indicator_color12 clrMagenta
#property indicator_type12  DRAW_LINE
#property indicator_style12 STYLE_SOLID
#property indicator_width12 1
#property indicator_label12 "Buy Countdown Stop B"

// 13. Sell Countdown Risk B
#property indicator_color13 clrCyan
#property indicator_type13  DRAW_LINE
#property indicator_style13 STYLE_SOLID
#property indicator_width13 1
#property indicator_label13 "Sell Countdown Stop B"

// 14. Aggressive Countdown values (objects provide the chart labels)
#property indicator_type14  DRAW_NONE
#property indicator_color14 clrNONE
#property indicator_label14 "Aggressive Countdown"

enum ENUM_COUNTDOWN_DISPLAY
{
   COUNTDOWN_DISPLAY_OFF = 0,
   COUNTDOWN_DISPLAY_STANDARD,
   COUNTDOWN_DISPLAY_AGGRESSIVE,
   COUNTDOWN_DISPLAY_BOTH
};

input group "Calculation"
input int MaxBars  = 1000; 

input group "Display"
input color BuySetupColor  = clrLime;
input color SellSetupColor = clrRed;
input color CountdownColor = clrOrange;
input string FontFace      = "Verdana";
input int FontSize         = 10; 
input int ArrowWidth       = 2;
input int TextOffsetPoints = 20; 
input int RiskLineLength   = 12; 
input string Prefix        = "TDS_";

input group "Countdown Display"
// Controls Countdown 12/13 labels and Countdown 13 alerts.
input ENUM_COUNTDOWN_DISPLAY CountdownDisplay = COUNTDOWN_DISPLAY_BOTH;
input color AggressiveCountdownColor = clrDeepSkyBlue;

input group "Alerts"
input bool AlertOnSetup = false;
input bool AlertOnPerfecting = false;
input bool AlertOnCountdown13 = false;
input bool AlertOnSupportResistance = false;
input bool AlertNative       = false;
input bool AlertEmail        = false;
input bool AlertNotification = false;

// Buffers
double Resistance[], Support[];
double Setup[], Countdown[], Perfection[], AggressiveCountdown[];

// Setup Risk Buffers
double BuyRiskA[], SellRiskA[];
double BuyRiskB[], SellRiskB[];

// Countdown Risk Buffers
double BuyCountRiskA[], SellCountRiskA[];
double BuyCountRiskB[], SellCountRiskB[];

enum ENUM_COUNT_TYPE
{
   COUNT_TYPE_BUY_SETUP,
   COUNT_TYPE_SELL_SETUP,
   COUNT_TYPE_BUY_COUNTDOWN,
   COUNT_TYPE_SELL_COUNTDOWN,
   COUNT_TYPE_BUY_AGGRESSIVE,
   COUNT_TYPE_SELL_AGGRESSIVE,
   COUNT_TYPE_BUY_PERFECTION,
   COUNT_TYPE_SELL_PERFECTION
};

enum ENUM_ALERT_TYPE
{
   ALERT_TYPE_SETUP_BUY,
   ALERT_TYPE_SETUP_SELL,
   ALERT_TYPE_PERFECTING_BUY,
   ALERT_TYPE_PERFECTING_SELL,
   ALERT_TYPE_COUNT13_BUY,
   ALERT_TYPE_COUNT13_SELL,
   ALERT_TYPE_COUNT13_AGGRESSIVE_BUY,
   ALERT_TYPE_COUNT13_AGGRESSIVE_SELL,
   ALERT_TYPE_SUPPORT,
   ALERT_TYPE_RESISTANCE,
   ALERT_TYPE_TOTAL
};

// Global counters for A/B toggling
int BuySetupCounter = 0;
int SellSetupCounter = 0;
int BuyCountCounter = 0;
int SellCountCounter = 0;

bool AlertsArmed = false;

struct TDCountdownEpisode
{
   int      setup_id;
   datetime setup_time;
   int      level;
   double   close8;
   double   tdst;
   double   setup_range;
   double   setup_true_high;
   double   setup_true_low;
   double   setup_close_high;
   double   setup_close_low;
   int      countdown_start_idx;
   bool     is_active;
};

int OnInit()
{
   SetIndexBuffer(0, Resistance, INDICATOR_DATA);
   SetIndexBuffer(1, Support, INDICATOR_DATA);
   SetIndexBuffer(2, Setup, INDICATOR_DATA);
   SetIndexBuffer(3, Countdown, INDICATOR_DATA);
   SetIndexBuffer(4, Perfection, INDICATOR_DATA);
   
   // Setup Risks
   SetIndexBuffer(5, BuyRiskA, INDICATOR_DATA);
   SetIndexBuffer(6, SellRiskA, INDICATOR_DATA);
   SetIndexBuffer(7, BuyRiskB, INDICATOR_DATA);
   SetIndexBuffer(8, SellRiskB, INDICATOR_DATA);
   
   // Countdown Risks
   SetIndexBuffer(9, BuyCountRiskA, INDICATOR_DATA);
   SetIndexBuffer(10, SellCountRiskA, INDICATOR_DATA);
   SetIndexBuffer(11, BuyCountRiskB, INDICATOR_DATA);
   SetIndexBuffer(12, SellCountRiskB, INDICATOR_DATA);
   SetIndexBuffer(13, AggressiveCountdown, INDICATOR_DATA);

   ArraySetAsSeries(Resistance, true);
   ArraySetAsSeries(Support, true);
   ArraySetAsSeries(Setup, true);
   ArraySetAsSeries(Countdown, true);
   ArraySetAsSeries(Perfection, true);
   ArraySetAsSeries(AggressiveCountdown, true);
   
   ArraySetAsSeries(BuyRiskA, true); ArraySetAsSeries(SellRiskA, true);
   ArraySetAsSeries(BuyRiskB, true); ArraySetAsSeries(SellRiskB, true);
   
   ArraySetAsSeries(BuyCountRiskA, true); ArraySetAsSeries(SellCountRiskA, true);
   ArraySetAsSeries(BuyCountRiskB, true); ArraySetAsSeries(SellCountRiskB, true);
   
   PlotIndexSetInteger(0, PLOT_ARROW, 158);
   PlotIndexSetInteger(1, PLOT_ARROW, 158);

   for(int i=0; i<14; i++) PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) 
{
   ObjectsDeleteAll(0, Prefix);
}

void AppendCountdownEpisode(TDCountdownEpisode &episodes[],
                            const int setup_id,
                            const datetime setup_time,
                            const double setup_range,
                            const double setup_true_high,
                            const double setup_true_low,
                            const double setup_close_high,
                            const double setup_close_low,
                            const double tdst)
{
   int n = ArraySize(episodes);
   ArrayResize(episodes, n + 1);
   episodes[n].setup_id = setup_id;
   episodes[n].setup_time = setup_time;
   episodes[n].level = 0;
   episodes[n].close8 = 0.0;
   episodes[n].tdst = tdst;
   episodes[n].setup_range = setup_range;
   episodes[n].setup_true_high = setup_true_high;
   episodes[n].setup_true_low = setup_true_low;
   episodes[n].setup_close_high = setup_close_high;
   episodes[n].setup_close_low = setup_close_low;
   episodes[n].countdown_start_idx = -1;
   episodes[n].is_active = false;
}

void SelectActiveCountdownEpisode(TDCountdownEpisode &episodes[],
                                  const int preferred_setup_id)
{
   int total = ArraySize(episodes);
   if(total == 0) return;

   int active = -1;
   if(preferred_setup_id >= 0)
   {
      for(int i = 0; i < total; i++)
      {
         if(episodes[i].setup_id == preferred_setup_id)
         {
            active = i;
            break;
         }
      }
   }

   if(active < 0)
   {
      active = 0;
      for(int i = 1; i < total; i++)
         if(episodes[i].setup_range > episodes[active].setup_range) active = i;
   }

   for(int i = 0; i < total; i++) episodes[i].is_active = (i == active);
}

void EnsureActiveCountdownEpisode(TDCountdownEpisode &episodes[])
{
   for(int i = 0; i < ArraySize(episodes); i++)
      if(episodes[i].is_active) return;
   SelectActiveCountdownEpisode(episodes, -1);
}

// A Setup is NINE bars. Its true range, TDST and Qualifier II containment bounds
// are measured on the nine bars ending at `i` (series indexing, so i..i+8), never
// on everything accumulated since the Price Flip. Perl's "R" recycle at 18
// conforming closes stands in for a SECOND nine-bar Setup, so it is measured on
// that second nine. Accumulating across the whole run publishes an 18-bar TDST at
// every R bar and stores an inflated setup_range that then skews the 1.618 recycle
// gate and the active-episode selection for the rest of that Countdown's life.
//
// Used by all three consumers — Setup 9 completion, the extension refresh while a
// run continues, and the R bar. Applying it at only one is pointless: the
// extension refresh overwrites the R bar's values on the very next bar.
void SetupWindow(const double &High[], const double &Low[], const double &Close[],
                 const int i, const int rates_total,
                 double &w_true_high, double &w_true_low,
                 double &w_close_high, double &w_close_low)
{
   w_true_high = -DBL_MAX; w_true_low = DBL_MAX;
   w_close_high = -DBL_MAX; w_close_low = DBL_MAX;
   for(int k = 0; k < 9; k++)
   {
      int idx = i + k;
      // Close[idx + 1] must exist. This guard cannot leave a PARTIAL window in
      // practice: the main loop starts at rates_total - 7 with the run counters
      // at zero, and every caller needs at least nine conforming bars first
      // (Setup 9, run > 9, or the R bar at 18), so i is already <= rates_total-16
      // by the time any of them fire and i + 8 is comfortably in range.
      if(idx >= rates_total - 1) break;
      double th = MathMax(High[idx], Close[idx + 1]);
      double tl = MathMin(Low[idx], Close[idx + 1]);
      w_true_high  = MathMax(w_true_high, th);
      w_true_low   = MathMin(w_true_low, tl);
      w_close_high = MathMax(w_close_high, Close[idx]);
      w_close_low  = MathMin(w_close_low, Close[idx]);
   }
}

void ReconcileCountdownEpisodes(TDCountdownEpisode &episodes[],
                                const bool is_buy,
                                const bool r_recycle,
                                const int setup_id,
                                const datetime setup_time,
                                const datetime last_opposing_setup_time,
                                const double setup_range,
                                const double setup_true_high,
                                const double setup_true_low,
                                const double setup_close_high,
                                const double setup_close_low,
                                const double tdst)
{
   int qualifier_ii_setup_id = -1;
   datetime qualifier_ii_setup_time = 0;
   bool qualifier_ii_was_active = false;

   if(r_recycle)
   {
      // Perl's R qualifier recycles every developing same-direction Countdown.
      ArrayResize(episodes, 0);
   }
   else
   {
      int write = 0;
      int total = ArraySize(episodes);
      for(int read = 0; read < total; read++)
      {
         bool no_opposing = (last_opposing_setup_time == 0 ||
                             last_opposing_setup_time < episodes[read].setup_time);
         bool closing_range_inside =
            (setup_close_low >= episodes[read].setup_true_low &&
             setup_close_high <= episodes[read].setup_true_high);
         bool price_extreme_inside = is_buy
            ? (setup_true_low >= episodes[read].setup_true_low)
            : (setup_true_high <= episodes[read].setup_true_high);
         bool qualifier_ii = no_opposing && closing_range_inside && price_extreme_inside;
         bool qualifier_i_recycle =
            (episodes[read].setup_range > 0.0 &&
             setup_range >= episodes[read].setup_range &&
             setup_range < 1.618 * episodes[read].setup_range);

         if(qualifier_ii &&
            (!qualifier_ii_was_active || episodes[read].is_active) &&
            (episodes[read].is_active ||
             episodes[read].setup_time > qualifier_ii_setup_time))
         {
            qualifier_ii_setup_id = episodes[read].setup_id;
            qualifier_ii_setup_time = episodes[read].setup_time;
            qualifier_ii_was_active = episodes[read].is_active;
         }

         if(qualifier_ii || !qualifier_i_recycle)
         {
            if(write != read) episodes[write] = episodes[read];
            write++;
         }
      }
      ArrayResize(episodes, write);
   }

   AppendCountdownEpisode(episodes, setup_id, setup_time, setup_range,
                          setup_true_high, setup_true_low,
                          setup_close_high, setup_close_low, tdst);
   SelectActiveCountdownEpisode(episodes, qualifier_ii_setup_id);
}

void UpdateSetupEpisodes(TDCountdownEpisode &episodes[],
                         const int setup_id,
                         const double setup_range,
                         const double setup_true_high,
                         const double setup_true_low,
                         const double setup_close_high,
                         const double setup_close_low)
{
   for(int i = 0; i < ArraySize(episodes); i++)
   {
      if(episodes[i].setup_id != setup_id) continue;
      episodes[i].setup_range = setup_range;
      episodes[i].setup_true_high = setup_true_high;
      episodes[i].setup_true_low = setup_true_low;
      episodes[i].setup_close_high = setup_close_high;
      episodes[i].setup_close_low = setup_close_low;
   }
}

void CancelEpisodesByTrueExtreme(TDCountdownEpisode &episodes[],
                                 const bool is_buy,
                                 const double true_high,
                                 const double true_low)
{
   int write = 0;
   int total = ArraySize(episodes);
   for(int read = 0; read < total; read++)
   {
      // Buy cancellation requires the entire bar above resistance; sell mirrors.
      bool keep = is_buy
         ? (true_low <= episodes[read].tdst)
         : (true_high >= episodes[read].tdst);
      if(keep)
      {
         if(write != read) episodes[write] = episodes[read];
         write++;
      }
   }
   ArrayResize(episodes, write);
   EnsureActiveCountdownEpisode(episodes);
}

double ActiveEpisodeTDST(const TDCountdownEpisode &episodes[], const double fallback)
{
   int total = ArraySize(episodes);
   if(total == 0) return fallback;

   for(int i = 0; i < total; i++)
      if(episodes[i].is_active) return episodes[i].tdst;

   int largest = 0;
   for(int i = 1; i < total; i++)
      if(episodes[i].setup_range > episodes[largest].setup_range) largest = i;
   return episodes[largest].tdst;
}

int AdvanceCountdownEpisodes(TDCountdownEpisode &episodes[],
                             const bool is_buy,
                             const bool aggressive,
                             const int bar,
                             const int rates_total,
                             const double &High[],
                             const double &Low[],
                             const double &Close[],
                             double &risk_a[],
                             double &risk_b[],
                             int &risk_counter)
{
   if(bar + 2 >= rates_total) return 0;

   int write = 0;
   int total = ArraySize(episodes);
   int visible = -1;
   int visible_event = 0;

   // Choose the chart-visible leader before any episode advances on this bar.
   for(int i = 0; i < total; i++)
   {
      if(visible < 0 || episodes[i].level > episodes[visible].level ||
         (episodes[i].level == episodes[visible].level &&
          episodes[i].is_active && !episodes[visible].is_active))
         visible = i;
   }

   for(int read = 0; read < total; read++)
   {
      TDCountdownEpisode ep = episodes[read];
      bool is_visible = (read == visible);
      bool raw_qualifies;
      if(is_buy)
         raw_qualifies = aggressive ? (Low[bar] <= Low[bar + 2])
                                    : (Close[bar] <= Low[bar + 2]);
      else
         raw_qualifies = aggressive ? (High[bar] >= High[bar + 2])
                                    : (Close[bar] >= High[bar + 2]);

      bool counted = raw_qualifies;
      bool deferred = false;
      if(!aggressive && raw_qualifies && ep.level == 12 && ep.close8 != 0.0)
      {
         bool qualifier = is_buy ? (Low[bar] <= ep.close8)
                                 : (High[bar] >= ep.close8);
         counted = qualifier;
         deferred = !qualifier;
      }

      if(counted)
      {
         ep.level++;
         if(ep.level == 1) ep.countdown_start_idx = bar;
         if(!aggressive && ep.level == 8) ep.close8 = Close[bar];
      }

      if(ep.level >= 13)
      {
         if(is_visible)
         {
            visible_event = 13;

            if(!aggressive)
            {
               int start = (ep.countdown_start_idx >= bar)
                  ? ep.countdown_start_idx : bar;
               int extreme_idx = -1;
               double extreme = is_buy ? DBL_MAX : -DBL_MAX;

               for(int idx = start; idx >= bar; idx--)
               {
                  if(idx >= rates_total - 1) continue;
                  double true_high = MathMax(High[idx], Close[idx + 1]);
                  double true_low = MathMin(Low[idx], Close[idx + 1]);
                  if((is_buy && true_low < extreme) ||
                     (!is_buy && true_high > extreme))
                  {
                     extreme = is_buy ? true_low : true_high;
                     extreme_idx = idx;
                  }
               }

               if(extreme_idx != -1)
               {
                  double previous_close = Close[extreme_idx + 1];
                  double true_high = MathMax(High[extreme_idx], previous_close);
                  double true_low = MathMin(Low[extreme_idx], previous_close);
                  double true_range = true_high - true_low;
                  double risk_level = is_buy ? true_low - true_range
                                             : true_high + true_range;

                  risk_counter++;
                  bool use_a = (risk_counter % 2 != 0);
                  for(int k = 0; k < RiskLineLength; k++)
                  {
                     int draw_idx = bar - k;
                     if(draw_idx < 0) break;
                     if(use_a)
                     {
                        risk_a[draw_idx] = risk_level;
                        risk_b[draw_idx] = EMPTY_VALUE;
                     }
                     else
                     {
                        risk_b[draw_idx] = risk_level;
                        risk_a[draw_idx] = EMPTY_VALUE;
                     }
                  }
               }
            }
         }
      }
      else
      {
         if(write != read) episodes[write] = ep;
         else episodes[write] = ep;

         if(is_visible)
         {
            if(ep.level > 0 && counted) visible_event = ep.level;
            else if(ep.level == 12 && deferred) visible_event = 14;
         }
         write++;
      }
   }

   ArrayResize(episodes, write);
   EnsureActiveCountdownEpisode(episodes);
   return visible_event;
}

void DeleteCountObjectsAtTime(const datetime time)
{
   string suffix = IntegerToString((long)time);
   string stems[] = {"BS", "SS", "BC", "SC", "BA", "SA", "BP", "SP"};
   for(int i = 0; i < ArraySize(stems); i++)
   {
      string name = Prefix + stems[i] + suffix;
      if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   }
}
  
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &Time[],
                const double &open[],
                const double &High[],
                const double &Low[],
                const double &Close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   ArraySetAsSeries(Time, true);
   ArraySetAsSeries(High, true);
   ArraySetAsSeries(Low, true);
   ArraySetAsSeries(Close, true);

   ArraySetAsSeries(Resistance, true);
   ArraySetAsSeries(Support, true);
   ArraySetAsSeries(Setup, true);
   ArraySetAsSeries(Countdown, true);
   ArraySetAsSeries(Perfection, true);
   ArraySetAsSeries(AggressiveCountdown, true);

   if (rates_total < 7) return(0);

   int limit = MathMin(rates_total - 7, MathMax(MaxBars, 0));
   int draw_limit = rates_total - prev_calculated + 2;
   if(prev_calculated == 0) draw_limit = limit;

   AlertsArmed = (prev_calculated > 0);
   BuySetupCounter = 0;
   SellSetupCounter = 0;
   BuyCountCounter = 0;
   SellCountCounter = 0;

   bool show_standard_countdown =
      (CountdownDisplay == COUNTDOWN_DISPLAY_STANDARD ||
       CountdownDisplay == COUNTDOWN_DISPLAY_BOTH);
   bool show_aggressive_countdown =
      (CountdownDisplay == COUNTDOWN_DISPLAY_AGGRESSIVE ||
       CountdownDisplay == COUNTDOWN_DISPLAY_BOTH);

   for(int i = limit; i >= 0; i--)
   {
      Resistance[i] = EMPTY_VALUE;
      Support[i] = EMPTY_VALUE;
      Setup[i] = 0.0;
      Countdown[i] = 0.0;
      AggressiveCountdown[i] = 0.0;
      Perfection[i] = 0.0;
      BuyRiskA[i] = EMPTY_VALUE;
      SellRiskA[i] = EMPTY_VALUE;
      BuyRiskB[i] = EMPTY_VALUE;
      SellRiskB[i] = EMPTY_VALUE;
      BuyCountRiskA[i] = EMPTY_VALUE;
      SellCountRiskA[i] = EMPTY_VALUE;
      BuyCountRiskB[i] = EMPTY_VALUE;
      SellCountRiskB[i] = EMPTY_VALUE;
   }

   if (prev_calculated == 0)
   {
      for (int i = 0; i < rates_total; i++)
      {
         Resistance[i] = EMPTY_VALUE;
         Support[i] = EMPTY_VALUE;
         Setup[i] = 0.0;
         Countdown[i] = 0.0;
         AggressiveCountdown[i] = 0.0;
         Perfection[i] = 0.0;
         BuyRiskA[i] = EMPTY_VALUE;
         SellRiskA[i] = EMPTY_VALUE;
         BuyRiskB[i] = EMPTY_VALUE;
         SellRiskB[i] = EMPTY_VALUE;
         BuyCountRiskA[i] = EMPTY_VALUE;
         SellCountRiskA[i] = EMPTY_VALUE;
         BuyCountRiskB[i] = EMPTY_VALUE;
         SellCountRiskB[i] = EMPTY_VALUE;
      }
      ObjectsDeleteAll(0, Prefix);
   }
   else
   {
      int redraw = MathMin(draw_limit, rates_total - 1);
      for(int i = 0; i <= redraw; i++) DeleteCountObjectsAtTime(Time[i]);
   }

   int buy_setup = 0;
   int sell_setup = 0;
   int buy_run = 0;
   int sell_run = 0;
   int buy_setup_id = 0;
   int sell_setup_id = 0;
   datetime buy_setup_first_time = 0;
   datetime sell_setup_first_time = 0;
   datetime last_buy_setup9_time = 0;
   datetime last_sell_setup9_time = 0;


   double buy_setup6_low = 0.0;
   double buy_setup7_low = 0.0;
   double sell_setup6_high = 0.0;
   double sell_setup7_high = 0.0;
   double buy_perfection6_low = 0.0;
   double buy_perfection7_low = 0.0;
   double sell_perfection6_high = 0.0;
   double sell_perfection7_high = 0.0;
   bool buy_perfection_pending = false;
   bool sell_perfection_pending = false;

   TDCountdownEpisode buy_standard[];
   TDCountdownEpisode sell_standard[];
   TDCountdownEpisode buy_aggressive[];
   TDCountdownEpisode sell_aggressive[];
   ArrayResize(buy_standard, 0);
   ArrayResize(sell_standard, 0);
   ArrayResize(buy_aggressive, 0);
   ArrayResize(sell_aggressive, 0);

   for(int i = limit; i >= 0; i--)
   {
      bool update_objects = (i <= draw_limit);

      if(i < limit)
      {
         if(Resistance[i + 1] != EMPTY_VALUE && Close[i] > Resistance[i + 1])
         {
            Resistance[i] = EMPTY_VALUE;
            if(AlertOnSupportResistance) DoAlert(i, ALERT_TYPE_RESISTANCE);
         }
         else Resistance[i] = Resistance[i + 1];

         if(Support[i + 1] != EMPTY_VALUE && Close[i] < Support[i + 1])
         {
            Support[i] = EMPTY_VALUE;
            if(AlertOnSupportResistance) DoAlert(i, ALERT_TYPE_SUPPORT);
         }
         else Support[i] = Support[i + 1];
      }

      if(i + 5 >= rates_total) continue;

      double true_high = MathMax(High[i], Close[i + 1]);
      double true_low = MathMin(Low[i], Close[i + 1]);
      bool buy_condition = (Close[i] < Close[i + 4]);
      bool sell_condition = (Close[i] > Close[i + 4]);
      bool bearish_flip = (Close[i + 1] > Close[i + 5] && buy_condition);
      bool bullish_flip = (Close[i + 1] < Close[i + 5] && sell_condition);
      bool buy_setup_completed = false;
      bool sell_setup_completed = false;

      if(bearish_flip)
      {
         buy_setup_id++;
         buy_setup = 1;
         buy_run = 1;
         buy_setup_first_time = Time[i];
         buy_setup6_low = 0.0;
         buy_setup7_low = 0.0;
         Setup[i] = 1.0;
         if(update_objects) PutCount(COUNT_TYPE_BUY_SETUP, "1", Time[i], Low[i]);
      }
      else if(buy_run > 0 && buy_condition)
      {
         buy_run++;

         if(buy_setup > 0 && buy_setup < 9)
         {
            buy_setup++;
            Setup[i] = (double)buy_setup;
            if(update_objects)
               PutCount(COUNT_TYPE_BUY_SETUP, IntegerToString(buy_setup), Time[i], Low[i]);
            if(buy_setup == 6) buy_setup6_low = Low[i];
            if(buy_setup == 7) buy_setup7_low = Low[i];
            if(buy_setup == 9) buy_setup_completed = true;
         }
      }
      else
      {
         if(buy_setup > 0 && buy_setup < 9 && update_objects)
            RemoveCount(COUNT_TYPE_BUY_SETUP, buy_setup_first_time, Time, rates_total, buy_setup);
         buy_setup = 0;
         buy_run = 0;
      }

      if(bullish_flip)
      {
         sell_setup_id++;
         sell_setup = 1;
         sell_run = 1;
         sell_setup_first_time = Time[i];
         sell_setup6_high = 0.0;
         sell_setup7_high = 0.0;
         Setup[i] = -1.0;
         if(update_objects) PutCount(COUNT_TYPE_SELL_SETUP, "1", Time[i], High[i]);
      }
      else if(sell_run > 0 && sell_condition)
      {
         sell_run++;

         if(sell_setup > 0 && sell_setup < 9)
         {
            sell_setup++;
            Setup[i] = -(double)sell_setup;
            if(update_objects)
               PutCount(COUNT_TYPE_SELL_SETUP, IntegerToString(sell_setup), Time[i], High[i]);
            if(sell_setup == 6) sell_setup6_high = High[i];
            if(sell_setup == 7) sell_setup7_high = High[i];
            if(sell_setup == 9) sell_setup_completed = true;
         }
      }
      else
      {
         if(sell_setup > 0 && sell_setup < 9 && update_objects)
            RemoveCount(COUNT_TYPE_SELL_SETUP, sell_setup_first_time, Time, rates_total, sell_setup);
         sell_setup = 0;
         sell_run = 0;
      }

      if(buy_run > 9)
      {
         double w_th, w_tl, w_ch, w_cl;
         SetupWindow(High, Low, Close, i, rates_total, w_th, w_tl, w_ch, w_cl);
         double range = w_th - w_tl;
         UpdateSetupEpisodes(buy_standard, buy_setup_id, range,
                             w_th, w_tl, w_ch, w_cl);
         UpdateSetupEpisodes(buy_aggressive, buy_setup_id, range,
                             w_th, w_tl, w_ch, w_cl);
      }
      if(sell_run > 9)
      {
         double w_th, w_tl, w_ch, w_cl;
         SetupWindow(High, Low, Close, i, rates_total, w_th, w_tl, w_ch, w_cl);
         double range = w_th - w_tl;
         UpdateSetupEpisodes(sell_standard, sell_setup_id, range,
                             w_th, w_tl, w_ch, w_cl);
         UpdateSetupEpisodes(sell_aggressive, sell_setup_id, range,
                             w_th, w_tl, w_ch, w_cl);
      }

      if(buy_setup_completed)
      {
         ArrayResize(sell_standard, 0);
         ArrayResize(sell_aggressive, 0);
         buy_perfection6_low = buy_setup6_low;
         buy_perfection7_low = buy_setup7_low;
         buy_perfection_pending = true;

         double w_th, w_tl, w_ch, w_cl;
         SetupWindow(High, Low, Close, i, rates_total, w_th, w_tl, w_ch, w_cl);
         double setup_range = w_th - w_tl;
         ReconcileCountdownEpisodes(buy_standard, true, false,
                                    buy_setup_id, Time[i], last_sell_setup9_time,
                                    setup_range, w_th, w_tl,
                                    w_ch, w_cl,
                                    w_th);
         ReconcileCountdownEpisodes(buy_aggressive, true, false,
                                    buy_setup_id, Time[i], last_sell_setup9_time,
                                    setup_range, w_th, w_tl,
                                    w_ch, w_cl,
                                    w_th);
         last_buy_setup9_time = Time[i];

         // CAUSAL: publish TDST on the completion bar only. Series indexing makes
         // j > i the PAST, so writing the Setup's own nine bars back-filled a value
         // that was not knowable until up to eight bars later — invisible on the
         // chart, but look-ahead for any iCustom consumer reading buffer 0 over
         // history. The propagation at the top of the loop carries this forward to
         // later bars and voids it on a close-through.
         Resistance[i] = ActiveEpisodeTDST(buy_standard, w_th);

         double min_true_low = DBL_MAX;
         int min_idx = -1;
         for(int k = 0; k < 9; k++)
         {
            int idx = i + k;
            if(idx >= rates_total - 1) continue;
            double tl = MathMin(Low[idx], Close[idx + 1]);
            if(tl < min_true_low) { min_true_low = tl; min_idx = idx; }
         }
         if(min_idx != -1)
         {
            double th = MathMax(High[min_idx], Close[min_idx + 1]);
            double risk_level = min_true_low - (th - min_true_low);
            BuySetupCounter++;
            bool use_a = (BuySetupCounter % 2 != 0);
            for(int k = 0; k < RiskLineLength; k++)
            {
               int draw_idx = i - k;
               if(draw_idx < 0) break;
               if(use_a) { BuyRiskA[draw_idx] = risk_level; BuyRiskB[draw_idx] = EMPTY_VALUE; }
               else      { BuyRiskB[draw_idx] = risk_level; BuyRiskA[draw_idx] = EMPTY_VALUE; }
            }
         }
         if(AlertOnSetup) DoAlert(i, ALERT_TYPE_SETUP_BUY);
      }

      if(sell_setup_completed)
      {
         ArrayResize(buy_standard, 0);
         ArrayResize(buy_aggressive, 0);
         sell_perfection6_high = sell_setup6_high;
         sell_perfection7_high = sell_setup7_high;
         sell_perfection_pending = true;

         double w_th, w_tl, w_ch, w_cl;
         SetupWindow(High, Low, Close, i, rates_total, w_th, w_tl, w_ch, w_cl);
         double setup_range = w_th - w_tl;
         ReconcileCountdownEpisodes(sell_standard, false, false,
                                    sell_setup_id, Time[i], last_buy_setup9_time,
                                    setup_range, w_th, w_tl,
                                    w_ch, w_cl,
                                    w_tl);
         ReconcileCountdownEpisodes(sell_aggressive, false, false,
                                    sell_setup_id, Time[i], last_buy_setup9_time,
                                    setup_range, w_th, w_tl,
                                    w_ch, w_cl,
                                    w_tl);
         last_sell_setup9_time = Time[i];

         // CAUSAL: see the buy-side note above. Publish on the completion bar only
         // and let the loop's propagation carry it forward.
         Support[i] = ActiveEpisodeTDST(sell_standard, w_tl);

         double max_true_high = -DBL_MAX;
         int max_idx = -1;
         for(int k = 0; k < 9; k++)
         {
            int idx = i + k;
            if(idx >= rates_total - 1) continue;
            double th = MathMax(High[idx], Close[idx + 1]);
            if(th > max_true_high) { max_true_high = th; max_idx = idx; }
         }
         if(max_idx != -1)
         {
            double tl = MathMin(Low[max_idx], Close[max_idx + 1]);
            double risk_level = max_true_high + (max_true_high - tl);
            SellSetupCounter++;
            bool use_a = (SellSetupCounter % 2 != 0);
            for(int k = 0; k < RiskLineLength; k++)
            {
               int draw_idx = i - k;
               if(draw_idx < 0) break;
               if(use_a) { SellRiskA[draw_idx] = risk_level; SellRiskB[draw_idx] = EMPTY_VALUE; }
               else      { SellRiskB[draw_idx] = risk_level; SellRiskA[draw_idx] = EMPTY_VALUE; }
            }
         }
         if(AlertOnSetup) DoAlert(i, ALERT_TYPE_SETUP_SELL);
      }

      bool buy_r = (buy_run == 18 && ArraySize(buy_standard) > 0);
      bool sell_r = (sell_run == 18 && ArraySize(sell_standard) > 0);
      if(buy_r)
      {
         double w_th, w_tl, w_ch, w_cl;
         SetupWindow(High, Low, Close, i, rates_total, w_th, w_tl, w_ch, w_cl);
         double setup_range = w_th - w_tl;
         ReconcileCountdownEpisodes(buy_standard, true, true,
                                    buy_setup_id, Time[i], last_sell_setup9_time,
                                    setup_range, w_th, w_tl,
                                    w_ch, w_cl,
                                    w_th);
         ReconcileCountdownEpisodes(buy_aggressive, true, true,
                                    buy_setup_id, Time[i], last_sell_setup9_time,
                                    setup_range, w_th, w_tl,
                                    w_ch, w_cl,
                                    w_th);
         Resistance[i] = ActiveEpisodeTDST(buy_standard, w_th);
      }
      if(sell_r)
      {
         double w_th, w_tl, w_ch, w_cl;
         SetupWindow(High, Low, Close, i, rates_total, w_th, w_tl, w_ch, w_cl);
         double setup_range = w_th - w_tl;
         ReconcileCountdownEpisodes(sell_standard, false, true,
                                    sell_setup_id, Time[i], last_buy_setup9_time,
                                    setup_range, w_th, w_tl,
                                    w_ch, w_cl,
                                    w_tl);
         ReconcileCountdownEpisodes(sell_aggressive, false, true,
                                    sell_setup_id, Time[i], last_buy_setup9_time,
                                    setup_range, w_th, w_tl,
                                    w_ch, w_cl,
                                    w_tl);
         Support[i] = ActiveEpisodeTDST(sell_standard, w_tl);
      }

      if(buy_perfection_pending && buy_perfection6_low != 0.0 && buy_perfection7_low != 0.0)
      {
         bool hit = (Low[i] <= buy_perfection6_low && Low[i] <= buy_perfection7_low);
         if(buy_setup_completed && i + 1 < rates_total)
            hit = hit || (Low[i + 1] <= buy_perfection6_low &&
                          Low[i + 1] <= buy_perfection7_low);
         if(hit)
         {
            buy_perfection_pending = false;
            Perfection[i] = 1.0;
            if(update_objects) PutCount(COUNT_TYPE_BUY_PERFECTION, "233", Time[i], Low[i]);
            if(AlertOnPerfecting) DoAlert(i, ALERT_TYPE_PERFECTING_BUY);
         }
      }
      if(sell_perfection_pending && sell_perfection6_high != 0.0 && sell_perfection7_high != 0.0)
      {
         bool hit = (High[i] >= sell_perfection6_high && High[i] >= sell_perfection7_high);
         if(sell_setup_completed && i + 1 < rates_total)
            hit = hit || (High[i + 1] >= sell_perfection6_high &&
                          High[i + 1] >= sell_perfection7_high);
         if(hit)
         {
            sell_perfection_pending = false;
            Perfection[i] = -1.0;
            if(update_objects) PutCount(COUNT_TYPE_SELL_PERFECTION, "234", Time[i], High[i]);
            if(AlertOnPerfecting) DoAlert(i, ALERT_TYPE_PERFECTING_SELL);
         }
      }

      // Cancellation is evaluated before the bar is allowed to advance a count.
      CancelEpisodesByTrueExtreme(buy_standard, true, true_high, true_low);
      CancelEpisodesByTrueExtreme(buy_aggressive, true, true_high, true_low);
      CancelEpisodesByTrueExtreme(sell_standard, false, true_high, true_low);
      CancelEpisodesByTrueExtreme(sell_aggressive, false, true_high, true_low);

      int buy_event = AdvanceCountdownEpisodes(
         buy_standard, true, false, i, rates_total, High, Low, Close,
         BuyCountRiskA, BuyCountRiskB, BuyCountCounter);
      int sell_event = AdvanceCountdownEpisodes(
         sell_standard, false, false, i, rates_total, High, Low, Close,
         SellCountRiskA, SellCountRiskB, SellCountCounter);
      int buy_aggressive_event = AdvanceCountdownEpisodes(
         buy_aggressive, true, true, i, rates_total, High, Low, Close,
         BuyCountRiskA, BuyCountRiskB, BuyCountCounter);
      int sell_aggressive_event = AdvanceCountdownEpisodes(
         sell_aggressive, false, true, i, rates_total, High, Low, Close,
         SellCountRiskA, SellCountRiskB, SellCountCounter);

      if(buy_event > 0)
      {
         Countdown[i] = (double)buy_event;
         if(show_standard_countdown && update_objects && buy_event >= 12)
         {
            string label = (buy_event == 14) ? "+" : IntegerToString(buy_event);
            PutCount(COUNT_TYPE_BUY_COUNTDOWN, label, Time[i], Low[i]);
         }
         if(buy_event == 13 && show_standard_countdown && AlertOnCountdown13)
            DoAlert(i, ALERT_TYPE_COUNT13_BUY);
      }
      else if(sell_event > 0)
      {
         Countdown[i] = -(double)sell_event;
         if(show_standard_countdown && update_objects && sell_event >= 12)
         {
            string label = (sell_event == 14) ? "+" : IntegerToString(sell_event);
            PutCount(COUNT_TYPE_SELL_COUNTDOWN, label, Time[i], High[i]);
         }
         if(sell_event == 13 && show_standard_countdown && AlertOnCountdown13)
            DoAlert(i, ALERT_TYPE_COUNT13_SELL);
      }

      if(buy_aggressive_event > 0)
      {
         AggressiveCountdown[i] = (double)buy_aggressive_event;
         if(show_aggressive_countdown && update_objects && buy_aggressive_event >= 12)
            PutCount(COUNT_TYPE_BUY_AGGRESSIVE,
                     IntegerToString(buy_aggressive_event), Time[i], Low[i]);
         if(buy_aggressive_event == 13 && show_aggressive_countdown && AlertOnCountdown13)
            DoAlert(i, ALERT_TYPE_COUNT13_AGGRESSIVE_BUY);
      }
      else if(sell_aggressive_event > 0)
      {
         AggressiveCountdown[i] = -(double)sell_aggressive_event;
         if(show_aggressive_countdown && update_objects && sell_aggressive_event >= 12)
            PutCount(COUNT_TYPE_SELL_AGGRESSIVE,
                     IntegerToString(sell_aggressive_event), Time[i], High[i]);
         if(sell_aggressive_event == 13 && show_aggressive_countdown && AlertOnCountdown13)
            DoAlert(i, ALERT_TYPE_COUNT13_AGGRESSIVE_SELL);
      }

      if(buy_r)
      {
         Countdown[i] = 15.0;
         if(show_standard_countdown && update_objects)
            PutCount(COUNT_TYPE_BUY_COUNTDOWN, "R", Time[i], Low[i]);
      }
      else if(sell_r)
      {
         Countdown[i] = -15.0;
         if(show_standard_countdown && update_objects)
            PutCount(COUNT_TYPE_SELL_COUNTDOWN, "R", Time[i], High[i]);
      }
   }

   return(rates_total);
}

void PutCount(const ENUM_COUNT_TYPE count_type, const string s, const datetime time, const double price)
{
   string numeric_label = s;
   if(StringLen(numeric_label) > 0 && StringSubstr(numeric_label, 0, 1) == "A")
      numeric_label = StringSubstr(numeric_label, 1);

   if(numeric_label != "+" && numeric_label != "R")
   {
      int num = (int)StringToInteger(numeric_label);
      if (count_type == COUNT_TYPE_BUY_SETUP || count_type == COUNT_TYPE_SELL_SETUP)
      {
         if (num != 8 && num != 9) return;
      }
      else if (count_type == COUNT_TYPE_BUY_COUNTDOWN ||
               count_type == COUNT_TYPE_SELL_COUNTDOWN ||
               count_type == COUNT_TYPE_BUY_AGGRESSIVE ||
               count_type == COUNT_TYPE_SELL_AGGRESSIVE)
      {
         if (num != 12 && num != 13) return;
      }
   }

   string name = Prefix;
   color colour = clrNONE;
   ENUM_OBJECT object_type = OBJ_TEXT;
   long anchor_val = ANCHOR_CENTER; 
   double final_price = price;
   double point = Point();
   double layer_mult = 1.0; 
   
   switch(count_type)
   {
      case COUNT_TYPE_BUY_SETUP:
         name += "BS";
         colour = BuySetupColor;
         anchor_val = ANCHOR_UPPER; 
         layer_mult = 1.0; 
         final_price = price - (TextOffsetPoints * layer_mult * point);
         break;
         
      case COUNT_TYPE_SELL_SETUP:
         name += "SS";
         colour = SellSetupColor;
         anchor_val = ANCHOR_LOWER; 
         layer_mult = 1.0;
         final_price = price + (TextOffsetPoints * layer_mult * point);
         break;
         
      case COUNT_TYPE_BUY_COUNTDOWN:
         name += "BC";
         colour = CountdownColor;
         anchor_val = ANCHOR_UPPER;
         layer_mult = 2.5; 
         final_price = price - (TextOffsetPoints * layer_mult * point);
         break;
         
      case COUNT_TYPE_SELL_COUNTDOWN:
         name += "SC";
         colour = CountdownColor;
         anchor_val = ANCHOR_LOWER;
         layer_mult = 2.5; 
         final_price = price + (TextOffsetPoints * layer_mult * point);
         break;

      case COUNT_TYPE_BUY_AGGRESSIVE:
         name += "BA";
         colour = AggressiveCountdownColor;
         anchor_val = ANCHOR_UPPER;
         layer_mult = 3.5;
         final_price = price - (TextOffsetPoints * layer_mult * point);
         break;

      case COUNT_TYPE_SELL_AGGRESSIVE:
         name += "SA";
         colour = AggressiveCountdownColor;
         anchor_val = ANCHOR_LOWER;
         layer_mult = 3.5;
         final_price = price + (TextOffsetPoints * layer_mult * point);
         break;
         
      case COUNT_TYPE_BUY_PERFECTION:
         name += "BP";
         colour = BuySetupColor;
         object_type = OBJ_ARROW;
         anchor_val = ANCHOR_TOP; 
         layer_mult = 4.0; 
         final_price = price - (TextOffsetPoints * layer_mult * point); 
         break;
         
      case COUNT_TYPE_SELL_PERFECTION:
         name += "SP";
         colour = SellSetupColor;
         object_type = OBJ_ARROW;
         anchor_val = ANCHOR_BOTTOM; 
         layer_mult = 4.0; 
         final_price = price + (TextOffsetPoints * layer_mult * point); 
         break;
   }
   
   name += IntegerToString((long)time);

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, object_type, 0, time, final_price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, colour);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor_val);

      if ((count_type == COUNT_TYPE_BUY_PERFECTION) || (count_type == COUNT_TYPE_SELL_PERFECTION))
      {
         ObjectSetInteger(0, name, OBJPROP_ARROWCODE, StringToInteger(s));
         ObjectSetInteger(0, name, OBJPROP_WIDTH, ArrowWidth);
      }
      else
      {
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FontSize);
         ObjectSetString(0, name, OBJPROP_FONT, FontFace);
         ObjectSetString(0, name, OBJPROP_TEXT, s);
      }
   }
   else
   {
      if(MathAbs(ObjectGetDouble(0, name, OBJPROP_PRICE) - final_price) > point)
         ObjectSetDouble(0, name, OBJPROP_PRICE, final_price);

      ObjectSetInteger(0, name, OBJPROP_COLOR, colour);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor_val);
      if((count_type == COUNT_TYPE_BUY_PERFECTION) ||
         (count_type == COUNT_TYPE_SELL_PERFECTION))
      {
         ObjectSetInteger(0, name, OBJPROP_ARROWCODE, StringToInteger(s));
         ObjectSetInteger(0, name, OBJPROP_WIDTH, ArrowWidth);
      }
      else
      {
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FontSize);
         ObjectSetString(0, name, OBJPROP_FONT, FontFace);
         ObjectSetString(0, name, OBJPROP_TEXT, s);
      }
   }
}

void RemoveCount(const ENUM_COUNT_TYPE count_type, const datetime begin, const datetime &Time[], const int rates_total, const int n = 0)
{
   string name_start = Prefix;
   if (count_type == COUNT_TYPE_BUY_SETUP) name_start += "BS";
   else if (count_type == COUNT_TYPE_SELL_SETUP) name_start += "SS";
   else if (count_type == COUNT_TYPE_BUY_COUNTDOWN) name_start += "BC";
   else if (count_type == COUNT_TYPE_SELL_COUNTDOWN) name_start += "SC";
   else if (count_type == COUNT_TYPE_BUY_AGGRESSIVE) name_start += "BA";
   else if (count_type == COUNT_TYPE_SELL_AGGRESSIVE) name_start += "SA";

   int begin_candle = iBarShift(Symbol(), Period(), begin, true);
   if (begin_candle == -1) return;

   if ((count_type == COUNT_TYPE_BUY_SETUP) || (count_type == COUNT_TYPE_SELL_SETUP))
   {
      for (int i = begin_candle; i > begin_candle - n; i--)
      {
         if(i < 0) break;
         string name = name_start + IntegerToString((long)Time[i]);
         if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
      }
   }
   else if ((count_type == COUNT_TYPE_BUY_COUNTDOWN) ||
            (count_type == COUNT_TYPE_SELL_COUNTDOWN) ||
            (count_type == COUNT_TYPE_BUY_AGGRESSIVE) ||
            (count_type == COUNT_TYPE_SELL_AGGRESSIVE))
   {
       // FIX: Safely sweep forward in time from Bar 9 to the current forming bar (0)
       for (int i = begin_candle; i >= 0; i--) 
       {
          string name = name_start + IntegerToString((long)Time[i]);
          if(ObjectFind(0, name) >= 0) {
              ObjectDelete(0, name);
          }
       }
   }
}

void DoAlert(int i, ENUM_ALERT_TYPE alert_type)
{
   if(!AlertsArmed || i != 1) return;
   
   // FIX: Alert Spamming - Ensure each specific alert type only fires ONCE per candle
   static datetime last_alert_time[ALERT_TYPE_TOTAL] = {0}; 
   datetime current_time = iTime(Symbol(), Period(), i);
   if (last_alert_time[alert_type] == current_time) return;
   last_alert_time[alert_type] = current_time;
   
   string main_text = "Sequential: " + Symbol() + " @ " + EnumToString((ENUM_TIMEFRAMES)Period());
   string email_subject = main_text;
   
   switch(alert_type)
   {
      case ALERT_TYPE_SETUP_BUY:
         main_text += " Buy Setup completed"; email_subject += " Buy Setup"; break;
      case ALERT_TYPE_SETUP_SELL:
         main_text += " Sell Setup completed"; email_subject += " Sell Setup"; break;
      case ALERT_TYPE_PERFECTING_BUY:
         main_text += " Buy Setup Perfected"; email_subject += " Buy Perfecting"; break;
      case ALERT_TYPE_PERFECTING_SELL:
         main_text += " Sell Setup Perfected"; email_subject += " Sell Perfecting"; break;
      case ALERT_TYPE_COUNT13_BUY:
         main_text += " Buy Countdown completed"; email_subject += " Buy Countdown"; break;
      case ALERT_TYPE_COUNT13_SELL:
         main_text += " Sell Countdown completed"; email_subject += " Sell Countdown"; break;
      case ALERT_TYPE_COUNT13_AGGRESSIVE_BUY:
         main_text += " Aggressive Buy Countdown completed";
         email_subject += " Aggressive Buy Countdown"; break;
      case ALERT_TYPE_COUNT13_AGGRESSIVE_SELL:
         main_text += " Aggressive Sell Countdown completed";
         email_subject += " Aggressive Sell Countdown"; break;
      case ALERT_TYPE_RESISTANCE:
         main_text += " TDST Resistance broken"; email_subject += " Buy TDST Resistance"; break;
      case ALERT_TYPE_SUPPORT:
         main_text += " TDST Support broken"; email_subject += " TDST Support"; break;
   }

   main_text += " by " + TimeToString(current_time) + " candle.";

   if (AlertNative) Alert(main_text);
   if (AlertEmail) SendMail(email_subject, main_text);
   if (AlertNotification) SendNotification(main_text);
}
