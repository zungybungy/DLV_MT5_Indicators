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
// EA: retry shift 1 until all masks differ from EMPTY_VALUE. Masks model separate
// long/short legs. An EA must track its actual fills and resolve opposite legs.
// All chart timeframes work in proxy / chart VWAP mode; daily M1 VWAP requires D1.
#include <DLV_Micaletti.mqh>

input ENUM_MICAL_PRESET InpPreset=MICAL_MTSI_H1;
input ENUM_MICAL_DIRECTION InpDirection=MICAL_LONG;
input ENUM_APPLIED_VOLUME InpVolume=VOLUME_TICK;
input ENUM_MICAL_VWAP InpVWAPMode=MICAL_LAB_PROXY;
input string InpVWAPName="VWAP";
input bool InpLogSignals=true;

double RankBuffer[],RawBuffer[],LongEntry[],LongExit[],ShortEntry[],ShortExit[];
double VWAPBuffer[],LongDue[],ShortDue[];
double CalcVolume[],CalcVWAP[],CalcRaw[],CalcRank[],LE[],LX[],SE[],SX[],LD[],SD[];
CMicaletti Core;
int VWAPHandle=INVALID_HANDLE;
datetime LastLogged=0;
datetime LastDependencyWarning=0;
datetime LastM1Check=0;
int LastM1Bars=-1;
datetime LastM1Sweep=0,LastM1First=0,LastM1Latest=0;
double SessionCache[];
datetime SessionTimes[];

void MicalDependencyWarning(const string message)
{
   if(TimeLocal()-LastDependencyWarning<30) return;
   PrintFormat("DLV_Micaletti: %s (error %d)",message,GetLastError());
   LastDependencyWarning=TimeLocal();
}

void MicalUnset(const int start,const int end)
{
   for(int i=start;i<end;i++)
   {
      RankBuffer[i]=RawBuffer[i]=VWAPBuffer[i]=EMPTY_VALUE;
      LongEntry[i]=LongExit[i]=ShortEntry[i]=ShortExit[i]=EMPTY_VALUE;
      LongDue[i]=ShortDue[i]=-1;
   }
}

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
                        const long &volume[],const int n,const bool reset,double &daily[],int &changed)
{
   changed=n;
   int cached=ArraySize(SessionCache);
   ArrayResize(daily,n);
   ArrayInitialize(daily,EMPTY_VALUE);
   // prev_calculated==0 also follows a pending dependency. Preserve validated
   // sessions and their recursion origin; remap actual chart changes by time.
   bool same_layout=(cached<=n && ArraySize(SessionTimes)==cached);
   if(same_layout) for(int i=0;i<cached;i++) if(SessionTimes[i]!=time[i]) { same_layout=false; break; }
   if(same_layout && cached>0) ArrayCopy(daily,SessionCache,0,0,cached);
   else
   {
      changed=0;
      int cursor=0;
      for(int i=0;i<n;i++)
      {
         while(cursor<cached && SessionTimes[cursor]<time[i]) cursor++;
         if(cursor<cached && SessionTimes[cursor]==time[i]) daily[i]=SessionCache[cursor];
      }
   }
   MqlRates minutes[];
   double values[];
   // Start the asynchronous series build before querying its available boundary.
   if(CopyRates(_Symbol,PERIOD_M1,0,1,minutes)!=1 ||
      !SeriesInfoInteger(_Symbol,PERIOD_M1,SERIES_SYNCHRONIZED)) return false;
   int bars=Bars(_Symbol,PERIOD_M1);
   int limit=(int)TerminalInfoInteger(TERMINAL_MAXBARS);
   int oldest=MathMin(bars,limit)-1;
   MqlRates boundary[];
   // Bars can exceed MaxBars while iTime(Bars-1) is inaccessible. Copy just
   // one bar at a capped shift; never allocate the entire M1 history.
   if(oldest<0 || CopyRates(_Symbol,PERIOD_M1,oldest,1,boundary)!=1) return false;
   datetime first=boundary[0].time,latest=minutes[0].time;
   if(first<=0) return false;
   bool sweep=reset || !same_layout || LastM1Sweep==0 || TimeLocal()-LastM1Sweep>=3600 || first<LastM1First ||
      (bars!=LastM1Bars && latest<=LastM1Latest);
   int from=sweep?0:MathMax(0,cached-1);
   for(int i=from;i<n;i++)
   {
      datetime end=time[i]+86400;
      // Retain previously validated sessions after MT5 evicts their minutes.
      // On first load the unavailable prefix stays EMPTY_VALUE.
      if(end<=first) continue;
      int count=CopyRates(_Symbol,PERIOD_M1,time[i],end-1,minutes);
      if(count<=0 || !SeriesInfoInteger(_Symbol,PERIOD_M1,SERIES_SYNCHRONIZED)) return false;
      double session_high=-DBL_MAX,session_low=DBL_MAX;
      long session_volume=0;
      for(int cursor=0;cursor<count;cursor++)
      {
         session_high=MathMax(session_high,minutes[cursor].high);
         session_low=MathMin(session_low,minutes[cursor].low);
         session_volume+=(InpVolume==VOLUME_TICK)?minutes[cursor].tick_volume:minutes[cursor].real_volume;
      }
      int last=count-1;
      long expected_volume=(InpVolume==VOLUME_TICK)?tick_volume[i]:volume[i];
      if(minutes[0].open!=open[i] || session_high!=high[i] || session_low!=low[i] ||
         minutes[last].close!=close[i] || session_volume!=expected_volume)
      {
         // The oldest available session can be truncated by MaxBars. Missing
         // minutes inside the accessible history remain a pending dependency.
         if(time[i]<=first && first<end) continue;
         return false;
      }
      if(CopyBuffer(VWAPHandle,6,minutes[0].time,minutes[last].time,values)!=count) return false;
      if(!MicalValid(values[last]) || values[last]<=0) return false;
      daily[i]=values[last];
   }
   bool usable=false;
   for(int i=0;i<n;i++)
   {
      if(MicalValid(daily[i])) usable=true;
      if(i>=cached || daily[i]!=SessionCache[i]) changed=MathMin(changed,i);
   }
   if(!usable) return false;
   ArrayResize(SessionCache,n);
   ArrayCopy(SessionCache,daily);
   ArrayResize(SessionTimes,n);
   ArrayCopy(SessionTimes,time,0,0,n);
   LastM1First=first; LastM1Latest=latest; LastM1Bars=bars; LastM1Check=TimeLocal();
   if(sweep) LastM1Sweep=TimeLocal();
   return true;
}

int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],
                const double &open[],const double &high[],const double &low[],const double &close[],
                const long &tick_volume[],const long &volume[],const int &spread[])
{
   if(rates_total<2) { MicalUnset(0,rates_total); return 0; }
   bool m1=(VWAPHandle!=INVALID_HANDLE && InpVWAPMode==MICAL_M1_SESSION_VWAP);
   if(prev_calculated==rates_total && !m1) return rates_total;
   int minute_bars=m1?Bars(_Symbol,PERIOD_M1):0;
   // Ordinary minute updates validate only the most recent closed session;
   // older backfill and the hourly sweep revalidate the accessible history.
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
      int changed=n;
      if(!MicalLoadDailyVWAP(time,open,high,low,close,tick_volume,volume,n,
                             prev_calculated==0,sessions,changed))
      {
         MicalDependencyWarning("M1 history/VWAP pending or minute session OHLC/volume differs from D1");
         MicalUnset(0,rates_total);
         return 0;
      }
      start=MathMin(start,changed);
      if(prev_calculated==rates_total && start>=n) return rates_total;
   }
   // A pending/missing dependency must expose empty values, not MT5's default
   // zero-filled buffers (which could otherwise look like an oversold rank).
   MicalUnset(start,rates_total);
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
      if(CopyBuffer(VWAPHandle,6,0,1,ready)!=1)
      { MicalDependencyWarning("chart VWAP buffer not ready"); return prev_calculated; }
      double values[];
      if(CopyBuffer(VWAPHandle,6,time[start],time[n-1],values)!=n-start)
      { MicalDependencyWarning("closed-bar chart VWAP copy failed"); return prev_calculated; }
      for(int i=0;i<ArraySize(values);i++) if(!MicalValid(values[i]) || values[i]<=0)
      { MicalDependencyWarning("closed-bar chart VWAP value not ready"); return prev_calculated; }
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
      if(m1 && !MicalValid(CalcVWAP[i])) MicalUnset(i,i+1);
   }
   MicalUnset(n,n+1);
   if(InpLogSignals)
   {
      // First attach logs the latest close; reconnect/reset catches up every
      // subsequent close, without replaying the entire initial history.
      int log_start=LastLogged==0?n-1:0;
      for(int i=log_start;i<n;i++) if(time[i]>LastLogged && MicalValid(LongEntry[i]))
      {
         if(LE[i]+LX[i]+SE[i]+SX[i]>0)
            PrintFormat("%s %s %s: rank=%.8f LE=%.0f LX=%.0f SE=%.0f SX=%.0f",MicalName(InpPreset),_Symbol,TimeToString(time[i]),CalcRank[i],LE[i],LX[i],SE[i],SX[i]);
         LastLogged=time[i];
      }
   }
   return rates_total;
}
