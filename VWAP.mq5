//+------------------------------------------------------------------+
//|                                                         VWAP.mq5 |
//|  Port of TradingView "Volume Weighted Average Price" (Pine v6).  |
//|  Anchored VWAP that resets each Session/Week/Month/Quarter/Year/ |
//|  Decade/Century, with up to three stdev or percentage bands.     |
//|  Earnings/Dividends/Splits anchors are omitted (no MT5 feed).    |
//|  Each completed period's closing VWAP is extended as a dashed    |
//|  ray until a later bar's range reaches it (Lab VWAP_SESSION).    |
//+------------------------------------------------------------------+
#property copyright "DLV"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 16
#property indicator_plots   10

//--- fills first so the lines draw on top (clrNONE = off, like Pine's 95% transparency)
#property indicator_label1  "Bands Fill #1"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  clrNONE,clrNONE
#property indicator_label2  "Bands Fill #2"
#property indicator_type2   DRAW_FILLING
#property indicator_color2  clrNONE,clrNONE
#property indicator_label3  "Bands Fill #3"
#property indicator_type3   DRAW_FILLING
#property indicator_color3  clrNONE,clrNONE

#property indicator_label4  "VWAP"
#property indicator_type4   DRAW_LINE
#property indicator_color4  C'41,98,255'
#property indicator_width4  1

#property indicator_label5  "Upper Band #1"
#property indicator_type5   DRAW_LINE
#property indicator_color5  C'76,175,80'
#property indicator_label6  "Lower Band #1"
#property indicator_type6   DRAW_LINE
#property indicator_color6  C'76,175,80'
#property indicator_label7  "Upper Band #2"
#property indicator_type7   DRAW_LINE
#property indicator_color7  C'128,128,0'
#property indicator_label8  "Lower Band #2"
#property indicator_type8   DRAW_LINE
#property indicator_color8  C'128,128,0'
#property indicator_label9  "Upper Band #3"
#property indicator_type9   DRAW_LINE
#property indicator_color9  C'8,153,129'
#property indicator_label10 "Lower Band #3"
#property indicator_type10  DRAW_LINE
#property indicator_color10 C'8,153,129'

enum ENUM_VWAP_ANCHOR
  {
   ANCHOR_SESSION, // Session
   ANCHOR_WEEK,    // Week
   ANCHOR_MONTH,   // Month
   ANCHOR_QUARTER, // Quarter
   ANCHOR_YEAR,    // Year
   ANCHOR_DECADE,  // Decade
   ANCHOR_CENTURY  // Century
  };

enum ENUM_BAND_MODE
  {
   BAND_STDEV,   // Standard Deviation
   BAND_PERCENT  // Percentage
  };

input group "VWAP Settings"
input bool                InpHideOnDWM = false;          // Hide VWAP on 1D or Above
input ENUM_VWAP_ANCHOR    InpAnchor    = ANCHOR_SESSION; // Anchor Period
input ENUM_APPLIED_PRICE  InpSource    = PRICE_TYPICAL;  // Source
input ENUM_APPLIED_VOLUME InpVolume    = VOLUME_TICK;    // Volume (CFDs only have tick volume)
input int                 InpOffset    = 0;              // Offset

input group "Bands Settings"
input ENUM_BAND_MODE      InpBandMode  = BAND_STDEV;     // Bands Calculation Mode (Percentage: 1 = 1%)
input bool                InpShowBand1 = true;           // Show Band #1
input double              InpBandMult1 = 1.0;            // Bands Multiplier #1
input bool                InpShowBand2 = false;          // Show Band #2
input double              InpBandMult2 = 2.0;            // Bands Multiplier #2
input bool                InpShowBand3 = false;          // Show Band #3
input double              InpBandMult3 = 3.0;            // Bands Multiplier #3

// Last, so iCustom callers passing the leading inputs (DLV_Micaletti) are unaffected.
input group "Rays Settings"
input color               InpRayColor  = clrNONE;        // Ray Colour (None = VWAP line colour)

double FillUp1[], FillDn1[], FillUp2[], FillDn2[], FillUp3[], FillDn3[];
double VwapBuf[], Up1[], Dn1[], Up2[], Dn2[], Up3[], Dn3[];
double SumV[], SumPV[], SumP2V[];

bool g_hidden;

//--- Rays: each completed period's closing VWAP is carried right as a dashed
// horizontal line until a later bar's High..Low reaches it, where it ends;
// untouched it extends to the right edge (the Lab chart's VWAP_SESSION rule).
// Drawn only when this indicator is on a chart itself: under iCustom (e.g.
// DLV_Micaletti) it can run on another timeframe than the chart it would draw on,
// and ChartWindowFind() reports 0 there too, so OnOwnChart() checks the list.
bool     g_rays;
string   g_token;         // per instance: two VWAPs on one chart (same anchor,
string   g_prefix;        // other source) must not share or delete objects
double   RayPrice[];      // untouched rays, sorted by price
datetime RayFrom[];       // their start bar, which also names the object
datetime g_lastRayFrom;   // the forming bar is recalculated: open each ray once

//+------------------------------------------------------------------+
// Never switch the draw type here: DRAW_FILLING consumes 2 buffers, DRAW_NONE 1,
// so changing it shifts the buffer->plot mapping of every later plot.
// Hidden bands are blanked with EMPTY_VALUE in OnCalculate instead.
void HidePlot(const int plot)
  {
   PlotIndexSetInteger(plot, PLOT_SHOW_DATA, false);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpOffset < 0 || InpBandMult1 < 0 || InpBandMult2 < 0 || InpBandMult3 < 0)
     {
      Print("VWAP: Offset and band multipliers must be >= 0");
      return(INIT_PARAMETERS_INCORRECT);
     }

   SetIndexBuffer(0,  FillUp1, INDICATOR_DATA);
   SetIndexBuffer(1,  FillDn1, INDICATOR_DATA);
   SetIndexBuffer(2,  FillUp2, INDICATOR_DATA);
   SetIndexBuffer(3,  FillDn2, INDICATOR_DATA);
   SetIndexBuffer(4,  FillUp3, INDICATOR_DATA);
   SetIndexBuffer(5,  FillDn3, INDICATOR_DATA);
   SetIndexBuffer(6,  VwapBuf, INDICATOR_DATA);
   SetIndexBuffer(7,  Up1,     INDICATOR_DATA);
   SetIndexBuffer(8,  Dn1,     INDICATOR_DATA);
   SetIndexBuffer(9,  Up2,     INDICATOR_DATA);
   SetIndexBuffer(10, Dn2,     INDICATOR_DATA);
   SetIndexBuffer(11, Up3,     INDICATOR_DATA);
   SetIndexBuffer(12, Dn3,     INDICATOR_DATA);
   SetIndexBuffer(13, SumV,    INDICATOR_CALCULATIONS);
   SetIndexBuffer(14, SumPV,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(15, SumP2V,  INDICATOR_CALCULATIONS);

   for(int p = 0; p < 10; p++)
     {
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      PlotIndexSetInteger(p, PLOT_SHIFT, InpOffset);
     }
   for(int p = 0; p < 3; p++)
      PlotIndexSetInteger(p, PLOT_SHOW_DATA, false); // fills duplicate the band lines

   if(!InpShowBand1) { HidePlot(0); HidePlot(4); HidePlot(5); }
   if(!InpShowBand2) { HidePlot(1); HidePlot(6); HidePlot(7); }
   if(!InpShowBand3) { HidePlot(2); HidePlot(8); HidePlot(9); }

   g_hidden = InpHideOnDWM && Period() >= PERIOD_D1;
   g_rays   = false;   // decided on the first calculation (OnOwnChart)
   g_token  = NewToken();
   g_prefix = "VWAP ray " + g_token + " ";

   IndicatorSetString(INDICATOR_SHORTNAME, "VWAP");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Unique per instance across the terminal: an atomic counter in a  |
//| temporary global variable. (GetMicrosecondCount counts from each |
//| program's own start, so two instances can draw the same value.)  |
//+------------------------------------------------------------------+
string NewToken()
  {
   const string gv = "DLV VWAP ray seq";
   GlobalVariableTemp(gv);   // fails harmlessly when it already exists
   for(int attempt = 0; attempt < 100; attempt++)
     {
      double v = GlobalVariableGet(gv);
      if(GlobalVariableSetOnCondition(gv, v + 1, v))
         return(IntegerToString((long)v + 1));
     }
   return(StringFormat("t%I64u", GetTickCount64()));
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_rays)
     {
      ObjectsDeleteAll(0, g_prefix);
      ChartRedraw();
     }
  }

//+------------------------------------------------------------------+
//| Anchor period id: a change between bars starts a new VWAP.       |
//+------------------------------------------------------------------+
long PeriodKey(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   switch(InpAnchor)
     {
      case ANCHOR_SESSION: return((long)t / 86400);             // server-time day, same as D1 bars
      case ANCHOR_WEEK:    return(((long)t / 86400 + 4) / 7);   // Sunday-start week, same as W1 bars
      case ANCHOR_MONTH:   return(d.year * 12 + d.mon);
      case ANCHOR_QUARTER: return(d.year * 4 + (d.mon - 1) / 3);
      case ANCHOR_YEAR:    return(d.year);
      case ANCHOR_DECADE:  return(d.year / 10);
      case ANCHOR_CENTURY: return(d.year / 100);
     }
   return(0);
  }

//+------------------------------------------------------------------+
double SourcePrice(const double o, const double h, const double l, const double c)
  {
   switch(InpSource)
     {
      case PRICE_OPEN:     return(o);
      case PRICE_HIGH:     return(h);
      case PRICE_LOW:      return(l);
      case PRICE_MEDIAN:   return((h + l) / 2.0);
      case PRICE_TYPICAL:  return((h + l + c) / 3.0);
      case PRICE_WEIGHTED: return((h + l + 2.0 * c) / 4.0);
     }
   return(c);
  }

//+------------------------------------------------------------------+
//| Listed on its own chart (dropped there or from a template)? An   |
//| iCustom instance is on no chart's list. A unique short name for  |
//| the lookup, so another VWAP on the chart is not mistaken for it. |
//+------------------------------------------------------------------+
bool OnOwnChart()
  {
   string probe = "VWAP#" + g_token;
   IndicatorSetString(INDICATOR_SHORTNAME, probe);
   bool found = false;
   for(int k = ChartIndicatorsTotal(0, 0) - 1; k >= 0 && !found; k--)
      found = ChartIndicatorName(0, 0, k) == probe;
   IndicatorSetString(INDICATOR_SHORTNAME, "VWAP");
   return(found);
  }

//+------------------------------------------------------------------+
//| First untouched ray priced >= p (> p when below is false).       |
//+------------------------------------------------------------------+
int RayIndex(const double p, const bool below)
  {
   int lo = 0, hi = ArraySize(RayPrice);
   while(lo < hi)
     {
      int m = (lo + hi) / 2;
      if(below ? RayPrice[m] < p : RayPrice[m] <= p)
         lo = m + 1;
      else
         hi = m;
     }
   return(lo);
  }

//+------------------------------------------------------------------+
//| Bar i opens a period: ray from the previous period's last bar at |
//| its closing VWAP (the last bar that has one).                    |
//+------------------------------------------------------------------+
bool RayOpen(const int i, const datetime &time[])
  {
   if(time[i - 1] <= g_lastRayFrom)
      return(false);
   long key = PeriodKey(time[i - 1]);
   int  j   = i - 1;
   while(j > 0 && VwapBuf[j] == EMPTY_VALUE && PeriodKey(time[j - 1]) == key)
      j--;
   if(VwapBuf[j] == EMPTY_VALUE)
      return(false);
   double   price = VwapBuf[j];
   datetime from  = time[i - 1];
   string   name  = g_prefix + IntegerToString((long)from);
   g_lastRayFrom = from;
   if(!ObjectCreate(0, name, OBJ_TREND, 0, from, price, time[i], price))
      return(false);
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    InpRayColor == clrNONE ? PlotIndexGetInteger(3, PLOT_LINE_COLOR) : (long)InpRayColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   int k = RayIndex(price, false), n = ArraySize(RayPrice);
   ArrayResize(RayPrice, n + 1, 256);
   ArrayResize(RayFrom, n + 1, 256);
   for(int m = n; m > k; m--)
     {
      RayPrice[m] = RayPrice[m - 1];
      RayFrom[m]  = RayFrom[m - 1];
     }
   RayPrice[k] = price;
   RayFrom[k]  = from;
   return(true);
  }

//+------------------------------------------------------------------+
//| End every untouched ray inside the bar's range on that bar.      |
//| One pass over a price-sorted list, not a rescan per ray.         |
//+------------------------------------------------------------------+
bool RayTouch(const datetime t, const double lo, const double hi)
  {
   int n = ArraySize(RayPrice);
   if(n == 0 || !(lo <= hi))
      return(false);
   int a = RayIndex(lo, true), b = a;
   while(b < n && RayPrice[b] <= hi)
     {
      string name = g_prefix + IntegerToString((long)RayFrom[b]);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      b++;
     }
   if(b == a)
      return(false);
   ArrayRemove(RayPrice, a, b - a);
   ArrayRemove(RayFrom, a, b - a);
   return(true);
  }

//+------------------------------------------------------------------+
void SetEmpty(const int i)
  {
   VwapBuf[i] = Up1[i] = Dn1[i] = Up2[i] = Dn2[i] = Up3[i] = Dn3[i] = EMPTY_VALUE;
   FillUp1[i] = FillDn1[i] = FillUp2[i] = FillDn2[i] = FillUp3[i] = FillDn3[i] = EMPTY_VALUE;
  }

//+------------------------------------------------------------------+
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
   if(rates_total < 1)
      return(0);

   // Recompute the still-forming bar from the closed bar before it.
   int  start    = (prev_calculated > 0) ? prev_calculated - 1 : 0;
   long prevKey  = (start > 0) ? PeriodKey(time[start - 1]) : 0;
   double totVol = 0.0;
   bool   redraw = false;
   if(prev_calculated == 0)
      g_rays = !g_hidden && OnOwnChart();
   if(g_rays && prev_calculated == 0)
     {
      ObjectsDeleteAll(0, g_prefix);
      ArrayResize(RayPrice, 0);
      ArrayResize(RayFrom, 0);
      g_lastRayFrom = 0;
      redraw = true;
     }

   for(int i = start; i < rates_total; i++)
     {
      double p   = SourcePrice(open[i], high[i], low[i], close[i]);
      double v   = (InpVolume == VOLUME_TICK) ? (double)tick_volume[i] : (double)volume[i];
      long   key = PeriodKey(time[i]);
      totVol += v;

      // Open the ray first: the new period's first bar can already touch it.
      if(g_rays && i > 0 && key != prevKey)
         redraw |= RayOpen(i, time);
      if(g_rays)
         redraw |= RayTouch(time[i], low[i], high[i]);

      if(i == 0 || key != prevKey)
        {
         SumV[i]   = v;
         SumPV[i]  = p * v;
         SumP2V[i] = p * p * v;
        }
      else
        {
         SumV[i]   = SumV[i - 1]   + v;
         SumPV[i]  = SumPV[i - 1]  + p * v;
         SumP2V[i] = SumP2V[i - 1] + p * p * v;
        }
      prevKey = key;

      if(g_hidden || SumV[i] <= 0.0)
        {
         SetEmpty(i);
         continue;
        }

      double vwap  = SumPV[i] / SumV[i];
      double stdev = MathSqrt(MathMax(SumP2V[i] / SumV[i] - vwap * vwap, 0.0));
      double basis = (InpBandMode == BAND_STDEV) ? stdev : vwap * 0.01;

      VwapBuf[i] = vwap;
      Up1[i] = FillUp1[i] = vwap + basis * InpBandMult1;
      Dn1[i] = FillDn1[i] = vwap - basis * InpBandMult1;
      Up2[i] = FillUp2[i] = vwap + basis * InpBandMult2;
      Dn2[i] = FillDn2[i] = vwap - basis * InpBandMult2;
      Up3[i] = FillUp3[i] = vwap + basis * InpBandMult3;
      Dn3[i] = FillDn3[i] = vwap - basis * InpBandMult3;

      if(!InpShowBand1) Up1[i] = Dn1[i] = FillUp1[i] = FillDn1[i] = EMPTY_VALUE;
      if(!InpShowBand2) Up2[i] = Dn2[i] = FillUp2[i] = FillDn2[i] = EMPTY_VALUE;
      if(!InpShowBand3) Up3[i] = Dn3[i] = FillUp3[i] = FillDn3[i] = EMPTY_VALUE;
     }

   if(prev_calculated == 0 && totVol == 0.0)
      Print("VWAP: no volume provided for ", _Symbol,
            (InpVolume == VOLUME_REAL) ? " - real volume is empty, switch Volume to tick volume" : "");

   if(redraw)
      ChartRedraw();
   return(rates_total);
  }
//+------------------------------------------------------------------+
