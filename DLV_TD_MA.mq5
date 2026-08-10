#property copyright "DLV"
#property link      "DLV"
#property version   "1.00"
#property description "DeMark TD Moving Average I based on Perl, chapter 8."
#property description "Plots intermittent 5-bar SMAs of lows/highs after a"
#property description "12-bar qualification and extends each signal for 4 bars."

// -----------------------------------------------------------------------------
// DLV TD Moving Average I
//
// Bullish activation:
//   The current True Low is strictly higher than every True Low on the preceding
//   Lookback bars. The bullish line is SMA(True Low, MAPeriod).
//
// Bearish activation:
//   The current True High is strictly lower than every True High on the preceding
//   Lookback bars. The bearish line is SMA(True High, MAPeriod).
//
//   True Low  = min(Low,  prior Close)
//   True High = max(High, prior Close)
//   so a gap counts against the line instead of being ignored.
//
// Duration:
//   A qualifying bar activates its line for ExtensionBars including the
//   qualifying bar. A fresh qualification restarts the full extension.
//   Otherwise the line disappears. This is causal: no value is written into
//   a future bar before that bar exists.
//
// DeMark two-stage exit (documented, not emitted as a trade signal here):
//   Long  - prior bar closes below its bullish line, then the current bar opens
//           below that prior line.
//   Short - prior bar closes above its bearish line, then the current bar opens
//           above that prior line.
//
// Defaults are Perl's chapter 8 settings: 5 / 12 / 4. On True vs raw prices the
// chapter is not uniform: the PROSE says lows/highs generically, but the
// recommended-settings panel explicitly selects True Low and True High, and the
// panel is the specific instruction. This indicator follows the panel, which also
// keeps it consistent with the TD_MA1 pseudo in DLV_Quant_Lab. An earlier revision
// of this header claimed the book specifies raw prices; that was wrong, and the
// two constructions diverge on gap bars.
//
// The indicator uses the chart's current symbol and timeframe and does not
// hardcode either.
// -----------------------------------------------------------------------------

#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "Bullish TD MA I"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLimeGreen
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "Bearish TD MA I"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrTomato
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

input group "Calculation"
input int MAPeriod     = 5;
input int Lookback     = 12;
input int ExtensionBars = 4;
input int MaxBars      = 5000;

input group "Display"
input color BullishColor = clrLimeGreen;
input color BearishColor = clrTomato;
input ENUM_LINE_STYLE LineStyle = STYLE_SOLID;
input int LineWidth = 2;

double BullishTDMA[];
double BearishTDMA[];

// True Low / True High of bar `i`: the bar's extreme extended to the PRIOR close,
// so a gap counts against it. Series indexing, so the prior bar is i + 1. Both
// need one bar of history beyond `i`, which RequiredHistory() accounts for.
double TrueLow(const double &low[], const double &close[], const int i)
{
   return MathMin(low[i], close[i + 1]);
}

double TrueHigh(const double &high[], const double &close[], const int i)
{
   return MathMax(high[i], close[i + 1]);
}

// Deepest bar the calculation reads. The qualifier reaches back Lookback bars and
// the moving average MAPeriod - 1, and the True extreme of the deepest of those
// needs one more bar for its prior close.
int RequiredHistory()
{
   return MathMax(Lookback, MAPeriod - 1) + 1;
}

int OnInit()
{
   if(MAPeriod < 1 || Lookback < 1 || ExtensionBars < 1 ||
      MaxBars < 1 || LineWidth < 1 || LineWidth > 5)
   {
      Print("DLV_TD_MA: invalid parameters. MAPeriod, Lookback, ExtensionBars, "
            "MaxBars and LineWidth must be positive; LineWidth must be <= 5.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   SetIndexBuffer(0, BullishTDMA, INDICATOR_DATA);
   SetIndexBuffer(1, BearishTDMA, INDICATOR_DATA);
   ArraySetAsSeries(BullishTDMA, true);
   ArraySetAsSeries(BearishTDMA, true);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, BullishColor);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, BearishColor);
   PlotIndexSetInteger(0, PLOT_LINE_STYLE, LineStyle);
   PlotIndexSetInteger(1, PLOT_LINE_STYLE, LineStyle);
   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, LineWidth);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, LineWidth);

   int required_history = RequiredHistory();
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, required_history);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, required_history);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(
      INDICATOR_SHORTNAME,
      StringFormat("DLV TD Moving Average I (%d,%d,%d)",
                   MAPeriod, Lookback, ExtensionBars));

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
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(BullishTDMA, true);
   ArraySetAsSeries(BearishTDMA, true);

   int required_history = RequiredHistory();
   if(rates_total <= required_history)
   {
      if(prev_calculated == 0)
      {
         ArrayInitialize(BullishTDMA, EMPTY_VALUE);
         ArrayInitialize(BearishTDMA, EMPTY_VALUE);
      }
      return(0);
   }

   int oldest_safe = rates_total - 1 - required_history;
   int display_limit = MathMin(MaxBars - 1, oldest_safe);
   int calc_limit = MathMin(oldest_safe,
                            display_limit + MathMax(ExtensionBars - 1, 0));

   if(prev_calculated == 0)
   {
      ArrayInitialize(BullishTDMA, EMPTY_VALUE);
      ArrayInitialize(BearishTDMA, EMPTY_VALUE);
   }
   else
   {
      // Clear the visible range plus its state warm-up. Clearing only the visible
      // bars would allow yesterday's oldest plotted value to shift beyond
      // MaxBars and remain on the chart indefinitely.
      for(int i = calc_limit; i >= 0; i--)
      {
         BullishTDMA[i] = EMPTY_VALUE;
         BearishTDMA[i] = EMPTY_VALUE;
      }
   }

   int bullish_remaining = 0;
   int bearish_remaining = 0;

   for(int i = calc_limit; i >= 0; i--)
   {
      double prior_low_max = -DBL_MAX;
      double prior_high_min = DBL_MAX;
      for(int k = 1; k <= Lookback; k++)
      {
         prior_low_max = MathMax(prior_low_max, TrueLow(low, close, i + k));
         prior_high_min = MathMin(prior_high_min, TrueHigh(high, close, i + k));
      }

      bool bullish_qualification = (TrueLow(low, close, i) > prior_low_max);
      bool bearish_qualification = (TrueHigh(high, close, i) < prior_high_min);
      if(bullish_qualification) bullish_remaining = ExtensionBars;
      if(bearish_qualification) bearish_remaining = ExtensionBars;

      if(i <= display_limit && bullish_remaining > 0)
      {
         double sum_low = 0.0;
         for(int k = 0; k < MAPeriod; k++) sum_low += TrueLow(low, close, i + k);
         BullishTDMA[i] = sum_low / MAPeriod;
      }

      if(i <= display_limit && bearish_remaining > 0)
      {
         double sum_high = 0.0;
         for(int k = 0; k < MAPeriod; k++) sum_high += TrueHigh(high, close, i + k);
         BearishTDMA[i] = sum_high / MAPeriod;
      }

      if(bullish_remaining > 0) bullish_remaining--;
      if(bearish_remaining > 0) bearish_remaining--;
   }

   return(rates_total);
}
