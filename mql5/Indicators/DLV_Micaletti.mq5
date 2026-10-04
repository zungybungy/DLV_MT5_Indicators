#property copyright "DLV"
#property version "1.00"
#property description "22 Micaletti Lab presets, percent rank and fixed-hold masks."
#property indicator_separate_window
#property indicator_buffers 9
#property indicator_plots 9
#property indicator_label1 "Percent rank"
#property indicator_type1 DRAW_LINE
#property indicator_color1 clrDodgerBlue
#property indicator_minimum 0
#property indicator_maximum 1
#property indicator_level1 0.10
#property indicator_level2 0.90

// Entry: closed-bar rank < .10 long / > .90 short. Defaults to long only.
// Exit: accepted threshold entry + preset h bars; repeated entries do not
// extend the deadline. Same-side exit wins on the deadline bar.
// Risk: signal indicator only; no orders, sizing, SL/TP, fees or slippage.
// EA: read shift 1 once per new bar. Buffer masks model the Lab's separate
// long/short legs. An EA must track its actual fills and resolve opposite legs.
// All chart timeframes work in proxy / chart VWAP mode; daily M1 VWAP requires D1.
#include <DLV_Micaletti.mqh>

input ENUM_MICAL_PRESET InpPreset=MICAL_MTSI_H1;
input ENUM_MICAL_DIRECTION InpDirection=MICAL_LONG;
input ENUM_APPLIED_VOLUME InpVolume=VOLUME_TICK;
input ENUM_MICAL_VWAP InpVWAPMode=MICAL_LAB_PROXY;
input string InpVWAPName="VWAP";
input bool InpLogSignals=false;

double RankBuffer[],RawBuffer[],LongEntry[],LongExit[],ShortEntry[],ShortExit[];
double VWAPBuffer[],LongDue[],ShortDue[];
double CalcVolume[],CalcVWAP[],CalcRaw[],CalcRank[],LE[],LX[],SE[],SX[],LD[],SD[];
CMicaletti Core;
int VWAPHandle=INVALID_HANDLE;
datetime LastLogged=0;
datetime LastDependencyWarning=0;
datetime LastM1Check=0;
int LastM1Bars=-1;

int OnInit()
{
   if((int)InpPreset<0 || (int)InpPreset>21) return INIT_PARAMETERS_INCORRECT;
   if((int)InpDirection<0 || (int)InpDirection>2 || (int)InpVWAPMode<0 || (int)InpVWAPMode>2 ||
      (InpVolume!=VOLUME_TICK && InpVolume!=VOLUME_REAL)) return INIT_PARAMETERS_INCORRECT;
   bool mtsi=(InpPreset<=MICAL_MTSI22_H3);
   if(mtsi && InpVWAPMode==MICAL_M1_SESSION_VWAP && _Period!=PERIOD_D1)
   {
      Print("DLV_Micaletti: M1 session VWAP is a daily MTSI input; select D1.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(mtsi && InpVWAPMode!=MICAL_LAB_PROXY)
   {
      ENUM_TIMEFRAMES tf=(InpVWAPMode==MICAL_M1_SESSION_VWAP)?PERIOD_M1:_Period;
      // Existing DLV VWAP: group placeholder, hide=false, SESSION=0,
      // typical price, volume, offset=0. Its compiled input group occupies a
      // positional argument; omitting it shifts all subsequent settings.
      // Three DRAW_FILLING plots consume six buffers; VWAP itself is buffer 6.
      VWAPHandle=iCustom(_Symbol,tf,InpVWAPName,"",false,0,PRICE_TYPICAL,InpVolume,0);
      if(VWAPHandle==INVALID_HANDLE) { PrintFormat("DLV_Micaletti: VWAP handle failed (%d)",GetLastError()); return INIT_FAILED; }
   }
   SetIndexBuffer(0,RankBuffer,INDICATOR_DATA); SetIndexBuffer(1,RawBuffer,INDICATOR_DATA);
   SetIndexBuffer(2,LongEntry,INDICATOR_DATA); SetIndexBuffer(3,LongExit,INDICATOR_DATA);
   SetIndexBuffer(4,ShortEntry,INDICATOR_DATA); SetIndexBuffer(5,ShortExit,INDICATOR_DATA);
   SetIndexBuffer(6,VWAPBuffer,INDICATOR_DATA);
   SetIndexBuffer(7,LongDue,INDICATOR_CALCULATIONS); SetIndexBuffer(8,ShortDue,INDICATOR_CALCULATIONS);
   ArraySetAsSeries(RankBuffer,false); ArraySetAsSeries(RawBuffer,false);
   ArraySetAsSeries(LongEntry,false); ArraySetAsSeries(LongExit,false);
   ArraySetAsSeries(ShortEntry,false); ArraySetAsSeries(ShortExit,false);
   ArraySetAsSeries(VWAPBuffer,false); ArraySetAsSeries(LongDue,false); ArraySetAsSeries(ShortDue,false);
   string labels[]={"Percent rank","Oscillator","Long entry","Long exit","Short entry","Short exit","MTSI VWAP"};
   for(int p=0;p<9;p++)
   {
      PlotIndexSetDouble(p,PLOT_EMPTY_VALUE,EMPTY_VALUE);
      if(p>0) PlotIndexSetInteger(p,PLOT_DRAW_TYPE,DRAW_NONE);
      if(p<7) PlotIndexSetString(p,PLOT_LABEL,labels[p]);
   }
   IndicatorSetString(INDICATOR_SHORTNAME,MicalName(InpPreset));
   IndicatorSetInteger(INDICATOR_DIGITS,8);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { if(VWAPHandle!=INVALID_HANDLE) IndicatorRelease(VWAPHandle); }

// Establish coverage from the same completed session's OHLC and selected
// volume, rather than requiring a midnight bar or guessing its closing minute.
bool MicalLoadDailyVWAP(const datetime &time[],const double &open[],const double &high[],
                        const double &low[],const double &close[],const long &tick_volume[],
                        const long &volume[],const int n,double &daily[])
{
   ArrayResize(daily,n);
   // Stream one day at a time: long histories must not allocate millions of
   // temporary MqlRates/VWAP values on a chart tick.
   MqlRates minutes[];
   double values[];
   for(int i=0;i<n;i++)
   {
      datetime end=time[i]+86400;
      int count=CopyRates(_Symbol,PERIOD_M1,time[i],end-1,minutes);
      if(count<=0 || !SeriesInfoInteger(_Symbol,PERIOD_M1,SERIES_SYNCHRONIZED)) return false;
      if(CopyBuffer(VWAPHandle,6,minutes[0].time,minutes[count-1].time,values)!=count) return false;
      double session_high=-DBL_MAX,session_low=DBL_MAX;
      long session_volume=0;
      for(int cursor=0;cursor<count;cursor++)
      {
         if(minutes[cursor].time<time[i] || minutes[cursor].time+60>end) return false;
         session_high=MathMax(session_high,minutes[cursor].high);
         session_low=MathMin(session_low,minutes[cursor].low);
         session_volume+=(InpVolume==VOLUME_TICK)?minutes[cursor].tick_volume:minutes[cursor].real_volume;
      }
      int last=count-1;
      long expected_volume=(InpVolume==VOLUME_TICK)?tick_volume[i]:volume[i];
      if(minutes[0].open!=open[i] || session_high!=high[i] || session_low!=low[i] ||
         minutes[last].close!=close[i] || session_volume!=expected_volume) return false;
      if(!MicalValid(values[last]) || values[last]<=0) return false;
      daily[i]=values[last];
   }
   return true;
}

int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],
                const double &open[],const double &high[],const double &low[],const double &close[],
                const long &tick_volume[],const long &volume[],const int &spread[])
{
   if(rates_total<2) return 0;
   bool m1=(VWAPHandle!=INVALID_HANDLE && InpVWAPMode==MICAL_M1_SESSION_VWAP);
   if(prev_calculated==rates_total && !m1) return rates_total;
   int minute_bars=m1?Bars(_Symbol,PERIOD_M1):0;
   // New D1 bars/resets and M1 backfill revalidate immediately. Same-count
   // minute corrections are revisited on the first chart tick after 60s.
   if(m1 && prev_calculated==rates_total && minute_bars==LastM1Bars &&
      TimeLocal()-LastM1Check<60 && SeriesInfoInteger(_Symbol,PERIOD_M1,SERIES_SYNCHRONIZED)) return rates_total;
   ArraySetAsSeries(time,false); ArraySetAsSeries(open,false); ArraySetAsSeries(high,false); ArraySetAsSeries(low,false);
   ArraySetAsSeries(close,false); ArraySetAsSeries(tick_volume,false); ArraySetAsSeries(volume,false);
   // Never calculate/emit a signal on the forming bar. New history triggers a
   // full reset; ordinary ticks reuse the previously computed closed prefix.
   int n=rates_total-1;
   int start=(prev_calculated>0 && prev_calculated<=rates_total)?prev_calculated-1:0;
   if(start>n) start=0;
   double sessions[];
   if(m1)
   {
      // Revalidate even without a new D1 bar: M1 backfill/corrections can change
      // a previously accepted input. A failed dependency invalidates all masks.
      if(!MicalLoadDailyVWAP(time,open,high,low,close,tick_volume,volume,n,sessions))
      {
         if(TimeLocal()-LastDependencyWarning>=30)
         {
            Print("DLV_Micaletti: M1 history/VWAP pending or minute session OHLC/volume differs from D1.");
            LastDependencyWarning=TimeLocal();
         }
         for(int i=0;i<rates_total;i++)
         {
            RankBuffer[i]=RawBuffer[i]=VWAPBuffer[i]=EMPTY_VALUE;
            LongEntry[i]=LongExit[i]=ShortEntry[i]=ShortExit[i]=0;
            LongDue[i]=ShortDue[i]=-1;
         }
         return 0;
      }
      LastM1Check=TimeLocal(); LastM1Bars=minute_bars;
      for(int i=0;i<MathMin(n,ArraySize(CalcVWAP));i++) if(sessions[i]!=CalcVWAP[i]) { start=0; break; }
      if(prev_calculated==rates_total && start!=0) return rates_total;
   }
   // A pending/missing dependency must expose empty values, not MT5's default
   // zero-filled buffers (which could otherwise look like an oversold rank).
   for(int i=start;i<rates_total;i++)
   {
      RankBuffer[i]=RawBuffer[i]=VWAPBuffer[i]=EMPTY_VALUE;
      LongEntry[i]=LongExit[i]=ShortEntry[i]=ShortExit[i]=0;
      LongDue[i]=ShortDue[i]=-1;
   }
   ArrayResize(CalcVolume,n); ArrayResize(CalcVWAP,n); ArrayResize(CalcRank,n);
   for(int i=start;i<n;i++)
   {
      CalcVolume[i]=(InpVolume==VOLUME_TICK)?(double)tick_volume[i]:(double)volume[i];
      CalcVWAP[i]=m1?sessions[i]:(high[i]+low[i]+close[i])/3;
   }
   if(VWAPHandle!=INVALID_HANDLE && !m1 && start<n)
   {
      double ready[];
      // Request the dependent buffer before mapping timestamps. In a newly
      // opened terminal the M1 series can still be building asynchronously.
      if(CopyBuffer(VWAPHandle,6,0,1,ready)!=1) return prev_calculated;
      double values[];
      if(CopyBuffer(VWAPHandle,6,time[start],time[n-1],values)!=n-start) return prev_calculated;
      for(int i=start;i<n;i++) CalcVWAP[i]=values[i-start];
   }
   Core.Calculate(InpPreset,high,low,close,CalcVolume,CalcVWAP,n,start,CalcRaw);
   for(int i=start;i<n;i++) CalcRank[i]=MicalRank(CalcRaw,i,252);
   MicalSignals(CalcRank,n,MicalHold(InpPreset),InpDirection,start,LE,LX,SE,SX,LD,SD);
   for(int i=start;i<n;i++)
   {
      RawBuffer[i]=CalcRaw[i]; RankBuffer[i]=CalcRank[i]; VWAPBuffer[i]=CalcVWAP[i];
      LongEntry[i]=LE[i]; LongExit[i]=LX[i]; ShortEntry[i]=SE[i]; ShortExit[i]=SX[i];
      LongDue[i]=LD[i]; ShortDue[i]=SD[i];
   }
   RankBuffer[n]=RawBuffer[n]=VWAPBuffer[n]=EMPTY_VALUE;
   LongEntry[n]=LongExit[n]=ShortEntry[n]=ShortExit[n]=0;
   LongDue[n]=ShortDue[n]=-1;
   if(InpLogSignals && time[n-1]!=LastLogged && prev_calculated>0)
   {
      if(LE[n-1]+LX[n-1]+SE[n-1]+SX[n-1]>0)
         PrintFormat("%s %s %s: rank=%.8f LE=%.0f LX=%.0f SE=%.0f SX=%.0f",MicalName(InpPreset),_Symbol,TimeToString(time[n-1]),CalcRank[n-1],LE[n-1],LX[n-1],SE[n-1],SX[n-1]);
      LastLogged=time[n-1];
   }
   return rates_total;
}
