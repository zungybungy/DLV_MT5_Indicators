#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD Points based on Perl, chapter 4. Level-N TD Demand"
#property description "and Supply Points, each published N bars after the pivot,"
#property description "the first bar on which it is knowable."

// -----------------------------------------------------------------------------
// DLV TD Points
//
// Definition (Perl, "DeMark Indicators", ch.4 p.91-92):
//   Level-N TD Demand Point: a low with N HIGHER lows on either side,
//     Low[p] < every Low of the N bars before p and of the N bars after p.
//   Level-N TD Supply Point: a high with N LOWER highs on either side.
//   Raw Low/High, strict inequality: an equal low or high disqualifies.
//   Perl prefers Level 1 (most responsive); higher levels are rarer.
//
// Confirmation lag (the point of this port):
//   A pivot at bar p needs the N bars AFTER it, so it is only knowable on bar
//   p + N. It is published there and never back-dated onto p. Marking the pivot
//   on its own bar reads N bars into the future; in the DLV_Quant_Lab TD_POINT
//   pseudo that hindsight was measured at about +0.25 Sharpe of fiction.
//
// Buffers (EA-readable through iCustom / CopyBuffer, normal series shifts):
//   0 Demand price     last confirmed Demand Point low, carried forward
//   1 Supply price     last confirmed Supply Point high, carried forward
//   2 Demand confirmed 1 on the bar a Demand Point becomes known, else 0
//   3 Supply confirmed 1 on the bar a Supply Point becomes known, else 0
//   4 Prior demand     the Demand Point before the current one, carried forward
//   5 Prior supply     the Supply Point before the current one, carried forward
//   EMPTY_VALUE until the first (or second, for 4/5) point exists.
//   Buffers 4/5 exist because a TD Line needs the two most recent points.
//
// The forming bar's own Low/High is in the newest pivot's right-hand window, so
// a confirmation on bar 0 can still appear or vanish until it closes. Read shift
// 1 for a final value. Bit-identical to the Lab's TD_POINT on closed bars
// (mql5/check_td_parity.py). Uses the chart's symbol and timeframe.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6

#property indicator_label1  "TD Demand Point"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLimeGreen
#property indicator_width1  1

#property indicator_label2  "TD Supply Point"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrTomato
#property indicator_width2  1

#property indicator_label3  "Demand confirmed"
#property indicator_type3   DRAW_NONE
#property indicator_label4  "Supply confirmed"
#property indicator_type4   DRAW_NONE
#property indicator_label5  "Prior demand"
#property indicator_type5   DRAW_NONE
#property indicator_label6  "Prior supply"
#property indicator_type6   DRAW_NONE

input group "Calculation"
input int Level = 1;

double DemandPrice[];
double SupplyPrice[];
double DemandConfirmed[];
double SupplyConfirmed[];
double PriorDemand[];
double PriorSupply[];

int OnInit()
{
   if(Level < 1)
   {
      Print("DLV_TD_Point: Level must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   SetIndexBuffer(0, DemandPrice, INDICATOR_DATA);
   SetIndexBuffer(1, SupplyPrice, INDICATOR_DATA);
   SetIndexBuffer(2, DemandConfirmed, INDICATOR_DATA);
   SetIndexBuffer(3, SupplyConfirmed, INDICATOR_DATA);
   SetIndexBuffer(4, PriorDemand, INDICATOR_DATA);
   SetIndexBuffer(5, PriorSupply, INDICATOR_DATA);
   ArraySetAsSeries(DemandPrice, true);
   ArraySetAsSeries(SupplyPrice, true);
   ArraySetAsSeries(DemandConfirmed, true);
   ArraySetAsSeries(SupplyConfirmed, true);
   ArraySetAsSeries(PriorDemand, true);
   ArraySetAsSeries(PriorSupply, true);

   PlotIndexSetInteger(0, PLOT_ARROW, 158);
   PlotIndexSetInteger(1, PLOT_ARROW, 158);
   for(int b = 0; b < 6; b++) PlotIndexSetDouble(b, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("DLV TD Points (Level %d)", Level));
   return(INIT_SUCCEEDED);
}

// Is series bar p a strict Level-N pivot? Older side p+1..p+N, newer p-1..p-N.
bool IsDemandPoint(const double &low[], const int p)
{
   for(int k = 1; k <= Level; k++)
      if(!(low[p] < low[p + k] && low[p] < low[p - k])) return false;
   return true;
}

bool IsSupplyPoint(const double &high[], const int p)
{
   for(int k = 1; k <= Level; k++)
      if(!(high[p] > high[p + k] && high[p] > high[p - k])) return false;
   return true;
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
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

   // Incremental and exact: each bar's state follows from the bar before it, so
   // only new bars and the previously forming one are recomputed. A full pass
   // starts on the oldest bar, so state never restarts inside the history.
   int start = rates_total - 1;
   if(prev_calculated > 0 && prev_calculated <= rates_total)
      start = MathMin(rates_total - prev_calculated + 1, rates_total - 1);
   int newest_pivot_bar = rates_total - 1 - 2 * Level;   // deepest i with a full window

   for(int i = start; i >= 0; i--)
   {
      bool has_prior = (i + 1 < rates_total);
      double demand = has_prior ? DemandPrice[i + 1] : EMPTY_VALUE;
      double supply = has_prior ? SupplyPrice[i + 1] : EMPTY_VALUE;
      double prior_demand = has_prior ? PriorDemand[i + 1] : EMPTY_VALUE;
      double prior_supply = has_prior ? PriorSupply[i + 1] : EMPTY_VALUE;
      bool demand_conf = false, supply_conf = false;

      if(i <= newest_pivot_bar)
      {
         int p = i + Level;   // the pivot this bar can confirm
         demand_conf = IsDemandPoint(low, p);
         supply_conf = IsSupplyPoint(high, p);
         if(demand_conf) { prior_demand = demand; demand = low[p]; }
         if(supply_conf) { prior_supply = supply; supply = high[p]; }
      }

      DemandPrice[i] = demand;
      SupplyPrice[i] = supply;
      PriorDemand[i] = prior_demand;
      PriorSupply[i] = prior_supply;
      DemandConfirmed[i] = demand_conf ? 1.0 : 0.0;
      SupplyConfirmed[i] = supply_conf ? 1.0 : 0.0;
   }
   return(rates_total);
}
