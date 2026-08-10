#property copyright "DLV"
#property link      "DLV"
#property version   "3.6" // FIX: Countdown recycling per Perl, "DeMark Indicators"

// v3.6 — Countdown recycling, from Jason Perl, "DeMark Indicators" (Bloomberg,
// 2008). Both rules were missing entirely: a second Setup 9 left a running
// Countdown untouched, so counts continued through a re-energised trend that
// should have restarted them.
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
// Already correct in v3.5 and left alone: inclusive countdown comparisons
// (Close <= Low[2]), the explicit TD Price Flip prerequisite on setup start,
// true high/low TDST, the bar-13 qualifier against the Countdown 8 close, and
// close-based TDST breaks — which Perl confirms ("what is relevant is only
// whether or not the market is able to sustain a TDST break on a closing basis").
//
// Not implemented: the Aggressive Countdown, and Perl's Countdown Cancellation
// Qualifier II ("setup within a setup").

#property description "Shows setups and countdowns based on Tom DeMark's Sequential method."
#property description "Includes fixes for True High/Low TDST and Series Array iteration."
#property description "v3.6 adds the Countdown recycle rules from Perl (2008):"
#property description "size-gated Setup Recycle (1.0x to 1.618x true range) and"
#property description "the 'R' qualifier at 18 closes. See header comment."

#property indicator_chart_window
#property indicator_buffers 13
#property indicator_plots 13

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
double Setup[], Countdown[], Perfection[];

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
   ALERT_TYPE_SUPPORT,
   ALERT_TYPE_RESISTANCE
};

// Global counters for A/B toggling
int BuySetupCounter = 0;
int SellSetupCounter = 0;
int BuyCountCounter = 0;
int SellCountCounter = 0;

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

   ArraySetAsSeries(Resistance, true);
   ArraySetAsSeries(Support, true);
   ArraySetAsSeries(Setup, true);
   ArraySetAsSeries(Countdown, true);
   ArraySetAsSeries(Perfection, true);
   
   ArraySetAsSeries(BuyRiskA, true); ArraySetAsSeries(SellRiskA, true);
   ArraySetAsSeries(BuyRiskB, true); ArraySetAsSeries(SellRiskB, true);
   
   ArraySetAsSeries(BuyCountRiskA, true); ArraySetAsSeries(SellCountRiskA, true);
   ArraySetAsSeries(BuyCountRiskB, true); ArraySetAsSeries(SellCountRiskB, true);
   
   PlotIndexSetInteger(0, PLOT_ARROW, 158);
   PlotIndexSetInteger(1, PLOT_ARROW, 158);

   for(int i=0; i<13; i++) PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) 
{
   ObjectsDeleteAll(0, Prefix);
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
   // FIX: Re-enforce series properties natively to prevent buffer shifting anomalies
   ArraySetAsSeries(Time, true);
   ArraySetAsSeries(High, true);
   ArraySetAsSeries(Low, true);
   ArraySetAsSeries(Close, true);
   
   ArraySetAsSeries(Resistance, true);
   ArraySetAsSeries(Support, true);
   ArraySetAsSeries(Setup, true);
   ArraySetAsSeries(Countdown, true);
   ArraySetAsSeries(Perfection, true);
   
   // Reset internal state variables to 0 every tick
   
   // Buy Variables
   double Preceding_TrueHigh_Buy = 0; // FIX: TD Sequential requires True High for price flip, not just Close
   bool Use_Preceding_TrueHigh_Buy = false;
   int Setup_Buy = 0;
   datetime Setup_Buy_First_Candle = 0;
   datetime Setup_Buy_9_Time = 0; // FIX: Added Tracker for safe countdown deletion
   double Setup_Buy_Highest_High = 0;
   double Setup_Buy_Highest_High_Candidate = 0;
   double Setup_Buy_6_Low = 0;
   double Setup_Buy_7_Low = 0;
   // Snapshot of the bars 6/7 lows taken when a setup COMPLETES. Deferred
   // perfection must keep comparing against ITS OWN setup's reference lows; the
   // live Setup_Buy_6_Low / _7_Low get overwritten as the next setup counts past
   // 6 and 7, which would otherwise perfect the old setup against the new one.
   double Perf_Buy_6_Low = 0;
   double Perf_Buy_7_Low = 0;
   bool No_More_Countdown_Buy_Until_Next_Buy_Setup = false;
   bool Setup_Buy_Perfected = false;
   bool Setup_Buy_Needs_Perfecting = false;
   int Countdown_Buy = 0;
   double Countdown_Buy_8_Close = 0;
   double Setup_Buy_Range = 0;  // True range of the ACTIVE buy setup (recycle gate)
   int Buy_Run = 0;             // Consecutive closes < close 4 bars earlier (Perl "R")
   int Countdown_Buy_Start_Idx = -1; // Bar of Countdown 1, for the TD Risk Level scan

   // Sell Variables
   double Preceding_TrueLow_Sell = 0; // FIX: TD Sequential requires True Low for price flip, not just Close
   bool Use_Preceding_TrueLow_Sell = false;
   int Setup_Sell = 0;
   datetime Setup_Sell_First_Candle = 0;
   datetime Setup_Sell_9_Time = 0; // FIX: Added Tracker for safe countdown deletion
   double Setup_Sell_Lowest_Low = 0;
   double Setup_Sell_Lowest_Low_Candidate = 0;
   double Setup_Sell_6_High = 0;
   double Setup_Sell_7_High = 0;
   double Perf_Sell_6_High = 0;   // frozen at completion; see Perf_Buy_6_Low above
   double Perf_Sell_7_High = 0;
   bool No_More_Countdown_Sell_Until_Next_Sell_Setup = false;
   bool Setup_Sell_Perfected = false;
   bool Setup_Sell_Needs_Perfecting = false;
   int Countdown_Sell = 0;
   double Countdown_Sell_8_Close = 0;
   double Setup_Sell_Range = 0; // True range of the ACTIVE sell setup (recycle gate)
   int Sell_Run = 0;            // Consecutive closes > close 4 bars earlier (Perl "R")
   int Countdown_Sell_Start_Idx = -1; // Bar of Countdown 1, for the TD Risk Level scan

   if (rates_total < 7) return(0);
   
   int limit = rates_total - 7;
   if (limit > MaxBars) limit = MaxBars;

   // We define a "Draw Limit". We calculate math for ALL bars (limit), 
   // but we only draw objects for the changed bars (draw_limit).
   int draw_limit = rates_total - prev_calculated + 2; 
   if (prev_calculated == 0) draw_limit = limit + 1; // On first load, draw everything

   // Initialize Counters for Risk Lines (reset per calc)
   BuySetupCounter = 0; SellSetupCounter = 0;
   BuyCountCounter = 0; SellCountCounter = 0;

   // 1. Clean buffers
   for(int i = limit; i >= 0; i--) 
   {
       Setup[i] = 0; Countdown[i] = 0; Perfection[i] = 0;
       
       BuyRiskA[i] = EMPTY_VALUE; SellRiskA[i] = EMPTY_VALUE;
       BuyRiskB[i] = EMPTY_VALUE; SellRiskB[i] = EMPTY_VALUE;
       BuyCountRiskA[i] = EMPTY_VALUE; SellCountRiskA[i] = EMPTY_VALUE;
       BuyCountRiskB[i] = EMPTY_VALUE; SellCountRiskB[i] = EMPTY_VALUE;
   }

   // 2. Global Cleanup on First Run
   if (prev_calculated == 0)
   {
      for (int i = 0; i < rates_total; i++)
      {
         Setup[i] = 0; Countdown[i] = 0; Perfection[i] = 0;
         Support[i] = EMPTY_VALUE; Resistance[i] = EMPTY_VALUE;
         
         BuyRiskA[i] = EMPTY_VALUE; SellRiskA[i] = EMPTY_VALUE;
         BuyRiskB[i] = EMPTY_VALUE; SellRiskB[i] = EMPTY_VALUE;
         BuyCountRiskA[i] = EMPTY_VALUE; SellCountRiskA[i] = EMPTY_VALUE;
         BuyCountRiskB[i] = EMPTY_VALUE; SellCountRiskB[i] = EMPTY_VALUE;
      }
      ObjectsDeleteAll(0, Prefix);
   }

   // --- MAIN LOGIC LOOP ---
   for (int i = limit; i >= 0; i--) 
   {
      // Decide if we should update objects for this specific bar
      bool update_objects = (i <= draw_limit);

      // --- Propagate S/R ---
      if(i < rates_total - 1)
      {
          if ((Resistance[i + 1] != EMPTY_VALUE) && (Close[i] > Resistance[i + 1]))
          {
             Resistance[i] = EMPTY_VALUE;
             if (AlertOnSupportResistance) DoAlert(i, ALERT_TYPE_RESISTANCE);
          }
          else Resistance[i] = Resistance[i + 1];
          
          if ((Support[i + 1] != EMPTY_VALUE) && (Close[i] < Support[i + 1]))
          {
             Support[i] = EMPTY_VALUE;
             if (AlertOnSupportResistance) DoAlert(i, ALERT_TYPE_SUPPORT);
          }
          else Support[i] = Support[i + 1];
      }
      
      if (i >= rates_total - 5) continue;

      // --- TD Price Flip run lengths (for Perl's "R" recycle qualifier) ---
      // No flip can occur inside an unbroken run, so these count how far a single
      // Setup has extended past its 9.
      if (Close[i] < Close[i + 4]) Buy_Run++;  else Buy_Run = 0;
      if (Close[i] > Close[i + 4]) Sell_Run++; else Sell_Run = 0;

      // --- BUY SETUP ---
      if ((Close[i + 1] >= Close[i + 5]) && (Close[i] < Close[i + 4]) && ((Setup_Buy == 0) || (Setup_Buy == 9))) 
      {
         // FIX: Use True High of the setup price flip bar for DeMark TDST rule
         Preceding_TrueHigh_Buy = MathMax(High[i + 1], Close[i + 2]);
         Use_Preceding_TrueHigh_Buy = false;
         Setup_Buy = 1;
         if(update_objects) PutCount(COUNT_TYPE_BUY_SETUP, "1", Time[i], Low[i]);
         Setup_Buy_First_Candle = Time[i];
         
         Setup_Buy_Highest_High_Candidate = MathMax(High[i], Close[i+1]);
         Setup[i] = Setup_Buy;
      }
      else if ((Close[i] < Close[i + 4]) && (Setup_Buy > 0) && (Setup_Buy < 9))
      {
         Setup_Buy++;
         Setup[i] = Setup_Buy;
         if(update_objects) PutCount(COUNT_TYPE_BUY_SETUP, IntegerToString(Setup_Buy), Time[i], Low[i]);
         
         double true_high = MathMax(High[i], Close[i+1]);
         if (Setup_Buy_Highest_High_Candidate < true_high) Setup_Buy_Highest_High_Candidate = true_high;
         
         if (Setup_Buy == 6) Setup_Buy_6_Low = Low[i];
         if (Setup_Buy == 7) Setup_Buy_7_Low = Low[i];
         
         if (Setup_Buy == 9)
         {
            // Keep the outgoing setup's identity: the recycle gate below needs the
            // OLD 9-bar timestamp to clean up a countdown it displaces, and the OLD
            // high in case the incoming setup turns out to be the smaller one.
            datetime Prev_Buy_9_Time = Setup_Buy_9_Time;
            double   Prev_Buy_High   = Setup_Buy_Highest_High;

            Setup_Buy_9_Time = Time[i]; // FIX: Record start of countdown for safe object deletion

            if (Countdown_Sell > 0)
            {
               Countdown_Sell = 0;
               Countdown_Sell_Start_Idx = -1;
               if(update_objects) RemoveCount(COUNT_TYPE_SELL_COUNTDOWN, Setup_Sell_9_Time, Time, rates_total); // FIX
            }
            No_More_Countdown_Sell_Until_Next_Sell_Setup = true;
            if (AlertOnSetup) DoAlert(i, ALERT_TYPE_SETUP_BUY);
            Setup_Buy_Perfected = false;
            Setup_Buy_Needs_Perfecting = true;
            Perf_Buy_6_Low = Setup_Buy_6_Low;   // freeze this setup's reference lows
            Perf_Buy_7_Low = Setup_Buy_7_Low;
            No_More_Countdown_Buy_Until_Next_Buy_Setup = false;
            Setup_Sell = 0;
            
            // FIX: Check against the true high of the price flip, not just its close
            if (Preceding_TrueHigh_Buy > Setup_Buy_Highest_High_Candidate)
            {
               Setup_Buy_Highest_High = Preceding_TrueHigh_Buy;
               Use_Preceding_TrueHigh_Buy = true;
            }
            else Setup_Buy_Highest_High = Setup_Buy_Highest_High_Candidate;

            // --- Perl's TD Setup Recycle gate ---------------------------------
            // A competing same-direction Setup recycles a live Countdown only when
            // its true range is >= the active Setup's and < 1.618x it. Smaller means
            // the move is fading; 1.618x or more means exhaustion. Neither recycles.
            // Whichever Setup has the larger true range becomes the active one, so
            // the TDST line follows it.
            // Lowest true low of the nine setup bars. Serves both the size gate
            // below and the TD Risk Level further down — scanned once.
            double new_low_buy = DBL_MAX;
            int    new_low_idx_buy = -1;
            for(int k = 0; k < 9; k++)
            {
               int idx = i + k;
               if(idx >= rates_total - 1) continue;
               double tl_k = MathMin(Low[idx], Close[idx + 1]);
               if(tl_k < new_low_buy) { new_low_buy = tl_k; new_low_idx_buy = idx; }
            }
            double new_range_buy = (new_low_buy == DBL_MAX) ? 0 : Setup_Buy_Highest_High - new_low_buy;
            bool adopt_buy = true;

            if (Countdown_Buy > 0)
            {
               if ((Setup_Buy_Range > 0) && (new_range_buy >= Setup_Buy_Range)
                                         && (new_range_buy < 1.618 * Setup_Buy_Range))
               {
                  // Recycle: the trend re-energised, so the count starts over.
                  Countdown_Buy = 0;
                  Countdown_Buy_8_Close = 0;
                  Countdown_Buy_Start_Idx = -1;
                  if(update_objects) RemoveCount(COUNT_TYPE_BUY_COUNTDOWN, Prev_Buy_9_Time, Time, rates_total);
               }
               else if (new_range_buy < Setup_Buy_Range)
               {
                  // Smaller competing setup: the countdown runs on and the older,
                  // larger setup stays active — including its TDST line.
                  adopt_buy = false;
                  Setup_Buy_Highest_High = Prev_Buy_High;
                  Setup_Buy_9_Time = Prev_Buy_9_Time;
               }
            }
            if (adopt_buy) Setup_Buy_Range = new_range_buy;

            int res_count = 9;
            if (Use_Preceding_TrueHigh_Buy) res_count = 10;
            if (adopt_buy)
            for (int j = i; j < i + res_count; j++)
            {
               if(j >= rates_total) break;
               Resistance[j] = Setup_Buy_Highest_High;
               // FIX: Removed the buggy 'break' condition. Drawing the full 9 bars ensures clean, visible TDST lines.
            }

            // Buy Risk — reuses the lowest-true-low scan from the size gate above.
            if(new_low_idx_buy != -1)
            {
               double prev_c_of_min = Close[new_low_idx_buy + 1];
               double true_high_of_min = MathMax(High[new_low_idx_buy], prev_c_of_min);
               double tr_val = true_high_of_min - new_low_buy;
               double risk_level = new_low_buy - tr_val;
               
               BuySetupCounter++;
               bool use_A = (BuySetupCounter % 2 != 0); 
               for(int k=0; k<RiskLineLength; k++) {
                  int draw_idx = i - k;
                  if(draw_idx >= 0) {
                     if(use_A) { BuyRiskA[draw_idx] = risk_level; BuyRiskB[draw_idx] = EMPTY_VALUE; } 
                     else      { BuyRiskB[draw_idx] = risk_level; BuyRiskA[draw_idx] = EMPTY_VALUE; }
                  }
               }
            }
            
            if(i < rates_total - 1) { 
                if ((Low[i + 1] <= Perf_Buy_6_Low) && (Low[i + 1] <= Perf_Buy_7_Low))
                {
                   Setup_Buy_Perfected = true;
                   Setup_Buy_Needs_Perfecting = false;
                   Perfection[i + 1] = 1;
                   if(update_objects) PutCount(COUNT_TYPE_BUY_PERFECTION, "233", Time[i + 1], Low[i + 1]); 
                   if (AlertOnPerfecting) DoAlert(i + 1, ALERT_TYPE_PERFECTING_BUY);
                }
            }
         }
      }
      else if ((Close[i] >= Close[i + 4]) && (Setup_Buy != 9) && (Setup_Buy != 0))
      {
         if(update_objects) RemoveCount(COUNT_TYPE_BUY_SETUP, Setup_Buy_First_Candle, Time, rates_total, Setup_Buy);
         Setup_Buy = 0;
         Setup_Buy_First_Candle = 0;
         Setup_Buy_Highest_High_Candidate = 0;
         Setup_Buy_Needs_Perfecting = false;
         Setup_Buy_Perfected = false;
      }

      // --- Perl's "R" recycle qualifier (buy) ---
      // A Setup that extends to 18 closes, each less than the close four bars
      // earlier, without an intervening bullish TD Price Flip signifies intensified
      // bearish momentum and recycles the developing Countdown. Ungated by size,
      // unlike the Setup Recycle above. Runs before the Countdown block so the
      // restarted count can take its first bar here.
      if ((Buy_Run == 18) && (Countdown_Buy > 0))
      {
         Countdown_Buy = 0;
         Countdown_Buy_8_Close = 0;
         Countdown_Buy_Start_Idx = -1;
         if(update_objects) RemoveCount(COUNT_TYPE_BUY_COUNTDOWN, Setup_Buy_9_Time, Time, rates_total);
         Setup_Buy_9_Time = Time[i];
      }

      // --- BUY COUNTDOWN ---
      if ((!No_More_Countdown_Buy_Until_Next_Buy_Setup) && ((Setup_Buy == 9) || (Countdown_Buy > 0)))
      {
         if (Countdown_Buy < 13)
         {
            if (Close[i] <= Low[i + 2])
            {
               if (Countdown_Buy < 12)
               {
                  Countdown_Buy++;
                  // Remember where this Countdown began: the TD Risk Level scans
                  // every bar from Countdown 1 to 13, numbered or not.
                  if (Countdown_Buy == 1) Countdown_Buy_Start_Idx = i;
                  if (Countdown_Buy == 8) Countdown_Buy_8_Close = Close[i];
                  Countdown[i] = Countdown_Buy;
                  if(update_objects) PutCount(COUNT_TYPE_BUY_COUNTDOWN, IntegerToString(Countdown_Buy), Time[i], Low[i]);
               }
               // FIX: TD DeMark Rule - Low of Countdown 13 must be <= Close of Countdown 8
               else if (Low[i] <= Countdown_Buy_8_Close) 
               {
                  Countdown_Buy++;
                  Countdown[i] = Countdown_Buy;
                  if(update_objects) PutCount(COUNT_TYPE_BUY_COUNTDOWN, IntegerToString(Countdown_Buy), Time[i], Low[i]);
                  if (AlertOnCountdown13) DoAlert(i, ALERT_TYPE_COUNT13_BUY);
                  
                  // --- Buy Countdown 13 TD Risk Level ---
                  // Perl: identify the lowest true low throughout the Countdown
                  // process, bars one through thirteen, WHETHER OR NOT it is a
                  // numbered price bar, and subtract that bar's true range from
                  // its true low. Scanning only bar 13 (as before) understates the
                  // stop whenever any earlier Countdown bar traded lower.
                  if(i < rates_total - 1) {
                      double cd_min_tl = DBL_MAX;
                      int    cd_min_idx = -1;
                      int    cd_start = (Countdown_Buy_Start_Idx >= i) ? Countdown_Buy_Start_Idx : i;
                      for(int idx = cd_start; idx >= i; idx--) {
                         if(idx >= rates_total - 1) continue;
                         double tl_c = MathMin(Low[idx], Close[idx + 1]);
                         if(tl_c < cd_min_tl) { cd_min_tl = tl_c; cd_min_idx = idx; }
                      }
                      if(cd_min_idx == -1) { cd_min_idx = i; cd_min_tl = MathMin(Low[i], Close[i + 1]); }

                      double prev_c_13 = Close[cd_min_idx + 1];
                      double true_high_13 = MathMax(High[cd_min_idx], prev_c_13);
                      double tr_13 = true_high_13 - cd_min_tl;
                      double cd_risk_level = cd_min_tl - tr_13;

                      BuyCountCounter++;
                      bool use_A = (BuyCountCounter % 2 != 0); 
                      for(int k=0; k<RiskLineLength; k++) {
                         int draw_idx = i - k;
                         if(draw_idx >= 0) {
                            if(use_A) { BuyCountRiskA[draw_idx] = cd_risk_level; BuyCountRiskB[draw_idx] = EMPTY_VALUE; } 
                            else      { BuyCountRiskB[draw_idx] = cd_risk_level; BuyCountRiskA[draw_idx] = EMPTY_VALUE; }
                         }
                      }
                  }

                  Countdown_Buy = 0;
                  Countdown_Buy_Start_Idx = -1;
                  No_More_Countdown_Buy_Until_Next_Buy_Setup = true;
               }
               else
               {
                  // 14 in the buffer = "qualifier pending": the bar met the count
                  // condition at 12 but its low was above the Countdown 8 close, so
                  // the count defers rather than advancing. Drawn as "+".
                  Countdown[i] = 14;
                  if(update_objects) PutCount(COUNT_TYPE_BUY_COUNTDOWN, "+", Time[i], Low[i]);
               }
            }
         }
      }
      
      // Cancellation
      if (Countdown_Buy > 0)
      {
         if (Close[i] > Setup_Buy_Highest_High)
         {
            Countdown_Buy = 0;
            Countdown_Buy_Start_Idx = -1;
            // FIX: Safely pass the 9th Bar timestamp to only remove the failed countdown
            if(update_objects) RemoveCount(COUNT_TYPE_BUY_COUNTDOWN, Setup_Buy_9_Time, Time, rates_total);
            Setup_Buy = 0;
         }
      }
      
      // Deferred Perfection
      if ((!Setup_Buy_Perfected) && (Setup_Buy_Needs_Perfecting))
      {
         if ((Low[i] <= Perf_Buy_6_Low) && (Low[i] <= Perf_Buy_7_Low))
         {
            Setup_Buy_Perfected = true;
            Setup_Buy_Needs_Perfecting = false;
            Perfection[i] = 1;
            if(update_objects) PutCount(COUNT_TYPE_BUY_PERFECTION, "233", Time[i], Low[i]); 
            if (AlertOnPerfecting) DoAlert(i, ALERT_TYPE_PERFECTING_BUY);
         }
      }
      
      // --- SELL SETUP ---
      if ((Close[i + 1] <= Close[i + 5]) && (Close[i] > Close[i + 4]) && ((Setup_Sell == 0) || (Setup_Sell == 9)))
      {
         // FIX: Use True Low of the setup price flip bar for DeMark TDST rule
         Preceding_TrueLow_Sell = MathMin(Low[i + 1], Close[i + 2]);
         Use_Preceding_TrueLow_Sell = false;
         Setup_Sell = 1;
         if(update_objects) PutCount(COUNT_TYPE_SELL_SETUP, "1", Time[i], High[i]);
         Setup_Sell_First_Candle = Time[i];
         
         Setup_Sell_Lowest_Low_Candidate = MathMin(Low[i], Close[i+1]);
         Setup[i] = -Setup_Sell;
      }
      else if ((Close[i] > Close[i + 4]) && (Setup_Sell > 0) && (Setup_Sell < 9))
      {
         Setup_Sell++;
         Setup[i] = -Setup_Sell;
         if(update_objects) PutCount(COUNT_TYPE_SELL_SETUP, IntegerToString(Setup_Sell), Time[i], High[i]);
         
         double true_low = MathMin(Low[i], Close[i+1]);
         if (Setup_Sell_Lowest_Low_Candidate > true_low) Setup_Sell_Lowest_Low_Candidate = true_low;
         
         if (Setup_Sell == 6) Setup_Sell_6_High = High[i];
         if (Setup_Sell == 7) Setup_Sell_7_High = High[i];
         
         if (Setup_Sell == 9)
         {
            // Outgoing setup's identity, for the recycle gate below.
            datetime Prev_Sell_9_Time = Setup_Sell_9_Time;
            double   Prev_Sell_Low    = Setup_Sell_Lowest_Low;

            Setup_Sell_9_Time = Time[i]; // FIX: Record start of countdown for safe object deletion

            if (Countdown_Buy > 0)
            {
               Countdown_Buy = 0;
               Countdown_Buy_Start_Idx = -1;
               if(update_objects) RemoveCount(COUNT_TYPE_BUY_COUNTDOWN, Setup_Buy_9_Time, Time, rates_total); // FIX
            }
            No_More_Countdown_Buy_Until_Next_Buy_Setup = true;
            if (AlertOnSetup) DoAlert(i, ALERT_TYPE_SETUP_SELL);
            Setup_Sell_Perfected = false;
            Setup_Sell_Needs_Perfecting = true;
            Perf_Sell_6_High = Setup_Sell_6_High;   // freeze this setup's reference highs
            Perf_Sell_7_High = Setup_Sell_7_High;
            No_More_Countdown_Sell_Until_Next_Sell_Setup = false;
            Setup_Buy = 0;
            
            // FIX: Check against the true low of the price flip, not just its close
            if (Preceding_TrueLow_Sell < Setup_Sell_Lowest_Low_Candidate)
            {
               Setup_Sell_Lowest_Low = Preceding_TrueLow_Sell;
               Use_Preceding_TrueLow_Sell = true;
            }
            else Setup_Sell_Lowest_Low = Setup_Sell_Lowest_Low_Candidate;

            // --- Perl's TD Setup Recycle gate (mirror of the buy side) --------
            // Highest true high of the nine setup bars, scanned once for both the
            // size gate and the TD Risk Level.
            double new_high_sell = -DBL_MAX;
            int    new_high_idx_sell = -1;
            for(int k = 0; k < 9; k++)
            {
               int idx = i + k;
               if(idx >= rates_total - 1) continue;
               double th_k = MathMax(High[idx], Close[idx + 1]);
               if(th_k > new_high_sell) { new_high_sell = th_k; new_high_idx_sell = idx; }
            }
            double new_range_sell = (new_high_sell == -DBL_MAX) ? 0 : new_high_sell - Setup_Sell_Lowest_Low;
            bool adopt_sell = true;

            if (Countdown_Sell > 0)
            {
               if ((Setup_Sell_Range > 0) && (new_range_sell >= Setup_Sell_Range)
                                          && (new_range_sell < 1.618 * Setup_Sell_Range))
               {
                  Countdown_Sell = 0;
                  Countdown_Sell_8_Close = 0;
                  Countdown_Sell_Start_Idx = -1;
                  if(update_objects) RemoveCount(COUNT_TYPE_SELL_COUNTDOWN, Prev_Sell_9_Time, Time, rates_total);
               }
               else if (new_range_sell < Setup_Sell_Range)
               {
                  adopt_sell = false;
                  Setup_Sell_Lowest_Low = Prev_Sell_Low;
                  Setup_Sell_9_Time = Prev_Sell_9_Time;
               }
            }
            if (adopt_sell) Setup_Sell_Range = new_range_sell;

            int supp_count = 9;
            if (Use_Preceding_TrueLow_Sell) supp_count = 10;
            if (adopt_sell)
            for (int j = i; j < i + supp_count; j++)
            {
               if(j >= rates_total) break;
               Support[j] = Setup_Sell_Lowest_Low;
               // FIX: Removed the buggy 'break' condition. Drawing the full 9 bars ensures clean, visible TDST lines.
            }
            
            // Sell Risk — reuses the highest-true-high scan from the size gate above.
            if(new_high_idx_sell != -1)
            {
               double prev_c_of_max = Close[new_high_idx_sell + 1];
               double true_low_of_max = MathMin(Low[new_high_idx_sell], prev_c_of_max);
               double tr_val = new_high_sell - true_low_of_max;
               double risk_level = new_high_sell + tr_val;
               
               SellSetupCounter++;
               bool use_A = (SellSetupCounter % 2 != 0); 
               for(int k=0; k<RiskLineLength; k++) {
                  int draw_idx = i - k;
                  if(draw_idx >= 0) {
                     if(use_A) { SellRiskA[draw_idx] = risk_level; SellRiskB[draw_idx] = EMPTY_VALUE; } 
                     else      { SellRiskB[draw_idx] = risk_level; SellRiskA[draw_idx] = EMPTY_VALUE; }
                  }
               }
            }
            
            if(i < rates_total - 1) {
                if ((High[i + 1] >= Perf_Sell_6_High) && (High[i + 1] >= Perf_Sell_7_High))
                {
                   Setup_Sell_Perfected = true;
                   Setup_Sell_Needs_Perfecting = false;
                   Perfection[i + 1] = -1;
                   if(update_objects) PutCount(COUNT_TYPE_SELL_PERFECTION, "234", Time[i + 1], High[i + 1]); 
                   if (AlertOnPerfecting) DoAlert(i + 1, ALERT_TYPE_PERFECTING_SELL);
                }
            }
         }
      }
      else if ((Close[i] <= Close[i + 4]) && (Setup_Sell != 9) && (Setup_Sell != 0))
      {
         if(update_objects) RemoveCount(COUNT_TYPE_SELL_SETUP, Setup_Sell_First_Candle, Time, rates_total, Setup_Sell);
         Setup_Sell = 0;
         Setup_Sell_First_Candle = 0;
         Setup_Sell_Lowest_Low_Candidate = 0;
         Setup_Sell_Needs_Perfecting = false;
         Setup_Sell_Perfected = false;
      }
      
      // --- Perl's "R" recycle qualifier (sell) ---
      if ((Sell_Run == 18) && (Countdown_Sell > 0))
      {
         Countdown_Sell = 0;
         Countdown_Sell_8_Close = 0;
         Countdown_Sell_Start_Idx = -1;
         if(update_objects) RemoveCount(COUNT_TYPE_SELL_COUNTDOWN, Setup_Sell_9_Time, Time, rates_total);
         Setup_Sell_9_Time = Time[i];
      }

      // --- SELL COUNTDOWN ---
      if ((!No_More_Countdown_Sell_Until_Next_Sell_Setup) && ((Setup_Sell == 9) || (Countdown_Sell > 0)))
      {
         if (Countdown_Sell < 13)
         {
            if (Close[i] >= High[i + 2])
            {
               if (Countdown_Sell < 12)
               {
                  Countdown_Sell++;
                  if (Countdown_Sell == 1) Countdown_Sell_Start_Idx = i;
                  if (Countdown_Sell == 8) Countdown_Sell_8_Close = Close[i];
                  Countdown[i] = -Countdown_Sell;
                  if(update_objects) PutCount(COUNT_TYPE_SELL_COUNTDOWN, IntegerToString(Countdown_Sell), Time[i], High[i]);
               }
               // FIX: TD DeMark Rule - High of Countdown 13 must be >= Close of Countdown 8
               else if (High[i] >= Countdown_Sell_8_Close)
               {
                  Countdown_Sell++;
                  Countdown[i] = -Countdown_Sell;
                  if(update_objects) PutCount(COUNT_TYPE_SELL_COUNTDOWN, IntegerToString(Countdown_Sell), Time[i], High[i]);
                  if (AlertOnCountdown13) DoAlert(i, ALERT_TYPE_COUNT13_SELL);
                  
                  // --- Sell Countdown 13 TD Risk Level (mirror of the buy side) ---
                  // Highest true high across Countdown bars 1..13, numbered or not,
                  // plus that bar's true range.
                  if(i < rates_total - 1) {
                      double cd_max_th = -DBL_MAX;
                      int    cd_max_idx = -1;
                      int    cd_start = (Countdown_Sell_Start_Idx >= i) ? Countdown_Sell_Start_Idx : i;
                      for(int idx = cd_start; idx >= i; idx--) {
                         if(idx >= rates_total - 1) continue;
                         double th_c = MathMax(High[idx], Close[idx + 1]);
                         if(th_c > cd_max_th) { cd_max_th = th_c; cd_max_idx = idx; }
                      }
                      if(cd_max_idx == -1) { cd_max_idx = i; cd_max_th = MathMax(High[i], Close[i + 1]); }

                      double prev_c_13 = Close[cd_max_idx + 1];
                      double true_low_13 = MathMin(Low[cd_max_idx], prev_c_13);
                      double tr_13 = cd_max_th - true_low_13;
                      double cd_risk_level = cd_max_th + tr_13;

                      SellCountCounter++;
                      bool use_A = (SellCountCounter % 2 != 0); 
                      for(int k=0; k<RiskLineLength; k++) {
                         int draw_idx = i - k;
                         if(draw_idx >= 0) {
                            if(use_A) { SellCountRiskA[draw_idx] = cd_risk_level; SellCountRiskB[draw_idx] = EMPTY_VALUE; } 
                            else      { SellCountRiskB[draw_idx] = cd_risk_level; SellCountRiskA[draw_idx] = EMPTY_VALUE; }
                         }
                      }
                  }

                  Countdown_Sell = 0;
                  Countdown_Sell_Start_Idx = -1;
                  No_More_Countdown_Sell_Until_Next_Sell_Setup = true;
               }
               else
               {
                  // -14 = "qualifier pending" at 12 (mirror of the buy side). Drawn as "+".
                  Countdown[i] = -14;
                  if(update_objects) PutCount(COUNT_TYPE_SELL_COUNTDOWN, "+", Time[i], High[i]);
               }
            }
         }
      }
      
      if (Countdown_Sell > 0)
      {
         if (Close[i] < Setup_Sell_Lowest_Low)
         {
            Countdown_Sell = 0;
            Countdown_Sell_Start_Idx = -1;
            // FIX: Safely pass the 9th Bar timestamp to only remove the failed countdown
            if(update_objects) RemoveCount(COUNT_TYPE_SELL_COUNTDOWN, Setup_Sell_9_Time, Time, rates_total);
            Setup_Sell = 0;
         }
      }
      
      if ((!Setup_Sell_Perfected) && (Setup_Sell_Needs_Perfecting))
      {
         if ((High[i] >= Perf_Sell_6_High) && (High[i] >= Perf_Sell_7_High))
         {
            Setup_Sell_Perfected = true;
            Setup_Sell_Needs_Perfecting = false;
            Perfection[i] = -1;
            if(update_objects) PutCount(COUNT_TYPE_SELL_PERFECTION, "234", Time[i], High[i]); 
            if (AlertOnPerfecting) DoAlert(i, ALERT_TYPE_PERFECTING_SELL);
         }
      }
   }
   
   return(rates_total);
}

void PutCount(const ENUM_COUNT_TYPE count_type, const string s, const datetime time, const double price)
{
   if (s != "+")
   {
      int num = (int)StringToInteger(s);
      if (count_type == COUNT_TYPE_BUY_SETUP || count_type == COUNT_TYPE_SELL_SETUP)
      {
         if (num != 8 && num != 9) return;
      }
      else if (count_type == COUNT_TYPE_BUY_COUNTDOWN || count_type == COUNT_TYPE_SELL_COUNTDOWN)
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
   }
}

void RemoveCount(const ENUM_COUNT_TYPE count_type, const datetime begin, const datetime &Time[], const int rates_total, const int n = 0)
{
   string name_start = Prefix;
   if (count_type == COUNT_TYPE_BUY_SETUP) name_start += "BS";
   else if (count_type == COUNT_TYPE_SELL_SETUP) name_start += "SS";
   else if (count_type == COUNT_TYPE_BUY_COUNTDOWN) name_start += "BC";
   else if (count_type == COUNT_TYPE_SELL_COUNTDOWN) name_start += "SC";

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
   else if ((count_type == COUNT_TYPE_BUY_COUNTDOWN) || (count_type == COUNT_TYPE_SELL_COUNTDOWN))
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
   if (i > 2) return; 
   
   // FIX: Alert Spamming - Ensure each specific alert type only fires ONCE per candle
   static datetime last_alert_time[8] = {0}; 
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