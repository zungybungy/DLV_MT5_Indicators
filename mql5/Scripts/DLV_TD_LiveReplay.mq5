#property copyright "DLV"
#property version "1.00"
#property script_show_inputs

// Live-vs-history check for the TD indicators (smoke_test/_smoke_test_td_live_mql5.py).
// The Strategy Tester needs an account, so the live path is driven offline instead:
// a custom clone of InpSource gets the source's InpFeed bars up to InpFrom as its
// M1 history (CustomRatesUpdate), then every InpFeed bar of [InpFrom, InpTo)
// arrives as four ticks (open, low/high in the tester's OHLC order, close) through
// CustomTicksAdd, exactly as broker ticks reach a chart. Handle A per indicator /
// input set of Scripts/DLV_TD_Export.mq5 and per period runs in the symbol's
// indicator thread on those ticks (prev_calculated > 0, forming-bar recomputes).
// On each new bar, once every A has counted it, A is read at shift 1 (the
// just-closed bar, what a live EA reads) and shift 0 (the forming bar after one
// tick: the negative control). At the end handle B, a byte-identical copy loaded
// from Indicators/LiveB (identical iCustom parameters would share A's instance),
// recomputes everything in full; A is re-read over the window. No orders.
input string   InpSource="EURUSD";
input string   InpCustom="DLVLIVE_EURUSD";
input datetime InpPreload=D'2022.09.01';
input datetime InpFrom=D'2024.09.01';
input datetime InpTo=D'2026.09.01';
input string   InpPeriods="H4,D1";
input string   InpFeed="M1";        // source bars replayed as four ticks each (M1 = the tester's "1 minute OHLC")
input string   InpOnly="";          // comma-separated indicator names; empty = all
input int      InpFlushTicks=240;   // ticks per mid-bar batch
input string   InpFilePrefix="DLV_TD_Live";

string g_name[];
int    g_buffers[];
int    g_offset[];
int    g_total=0;
int    g_failures=0;    // CopyBuffer calls on A that failed while recording
int    g_timeouts=0;    // new bars read before every A handle caught up, or tick batches never calculated

struct Feed
{
   ENUM_TIMEFRAMES tf;
   int      handles[];
   int      counter;    // DLV_CalcCounter: OnCalculate calls per bar while it formed
   datetime current;    // open time of the forming bar
   datetime times[];
   double   close[];    // A at shift 1 on the new bar's first tick
   double   form[];     // A at shift 0 on the new bar's first tick
   double   calls[];    // counter at shift 1 = forming recomputes of the closed bar
   int      bars;
   datetime init_oldest;
};
Feed g_p[];

// The export script's iCustom lists; f="" is handle A, f="LiveB\\" handle B.
int Create(const string sym,const ENUM_TIMEFRAMES tf,const string name,const string f)
{
   if(name=="TD_SEQ") return iCustom(sym,tf,f+"TD_DLV_v3.6","",INT_MAX);
   if(name=="TD_MA1") return iCustom(sym,tf,f+"DLV_TD_MA","",5,12,4,INT_MAX);
   if(name=="TD_POINT_L1") return iCustom(sym,tf,f+"DLV_TD_Point","",1);
   if(name=="TD_POINT_L3") return iCustom(sym,tf,f+"DLV_TD_Point","",3);
   if(name=="TD_REI") return iCustom(sym,tf,f+"DLV_TD_REI","",5);
   if(name=="TD_COMBO_P1") return iCustom(sym,tf,f+"DLV_TD_Combo","",1);
   if(name=="TD_COMBO_P2") return iCustom(sym,tf,f+"DLV_TD_Combo","",2);
   if(name=="TD_DWAVE") return iCustom(sym,tf,f+"DLV_TD_DWave");
   if(name=="TD_PATTERNS") return iCustom(sym,tf,f+"DLV_TD_Patterns",
      "",5,"",12,"",3,1.03,0.97,"",0.382,0.618,"",3,0.236,0.472);
   if(name=="TD_PATTERNS_ALT") return iCustom(sym,tf,f+"DLV_TD_Patterns",
      "",3,"",10,"",5,1.09,0.91,"",0.25,0.5,"",1,0.25,0.5);
   if(name=="TD_WALDO") return iCustom(sym,tf,f+"DLV_TD_Waldo","",21,"",2.0,"",10,"",8,"",7,5);
   if(name=="TD_WALDO_ALT") return iCustom(sym,tf,f+"DLV_TD_Waldo","",10,"",1.5,"",5,"",4,"",5,3);
   if(name=="TD_TREND_FACTOR") return iCustom(sym,tf,f+"DLV_TD_TrendFactor","",3,0.0556);
   if(name=="TD_TREND_FACTOR_L1") return iCustom(sym,tf,f+"DLV_TD_TrendFactor","",1,0.0556);
   if(name=="TD_RETRACEMENT") return iCustom(sym,tf,f+"DLV_TD_Retracement","",1,0.382,"",1.382,0.618);
   if(name=="TD_RETRACEMENT_L3") return iCustom(sym,tf,f+"DLV_TD_Retracement","",3,0.618,"",1.618,0.5);
   if(name=="TD_LINES_L1") return iCustom(sym,tf,f+"DLV_TD_Lines","",1,400,1.0);
   if(name=="TD_LINES_L3") return iCustom(sym,tf,f+"DLV_TD_Lines","",3,25,1.618);
   return INVALID_HANDLE;
}

// Every buffer each indicator declares (#property indicator_buffers), not only the exported ones.
void Specs()
{
   string names[]={"TD_SEQ","TD_MA1","TD_POINT_L1","TD_POINT_L3","TD_REI","TD_COMBO_P1","TD_COMBO_P2",
                   "TD_DWAVE","TD_PATTERNS","TD_PATTERNS_ALT","TD_WALDO","TD_WALDO_ALT","TD_TREND_FACTOR",
                   "TD_TREND_FACTOR_L1","TD_RETRACEMENT","TD_RETRACEMENT_L3","TD_LINES_L1","TD_LINES_L3"};
   int buffers[]={14,2,6,6,1,6,6,10,56,56,26,26,6,6,14,14,18,18};
   for(int s=0;s<ArraySize(names);s++)
   {
      if(InpOnly!="" && StringFind(","+InpOnly+",",","+names[s]+",")<0) continue;
      int n=ArraySize(g_name);
      ArrayResize(g_name,n+1); ArrayResize(g_buffers,n+1); ArrayResize(g_offset,n+1);
      g_name[n]=names[s]; g_buffers[n]=buffers[s]; g_offset[n]=g_total;
      g_total+=buffers[s];
   }
}

bool Ready(const int handle,const string sym,const ENUM_TIMEFRAMES tf,const int timeout_ms)
{
   for(int waited=0;waited<=timeout_ms && !IsStopped();waited+=1)
   {
      int bars=Bars(sym,tf);
      if(bars>0 && BarsCalculated(handle)==bars) return true;
      Sleep(1);
   }
   return false;
}

double One(const int handle,const int buffer,const int shift)
{
   double v[];
   if(CopyBuffer(handle,buffer,shift,1,v)!=1) { g_failures++; return EMPTY_VALUE; }
   return v[0];
}

// `start` is the new bar's open time; the closed bar must be the one that was forming.
void Record(Feed &p,const datetime start)
{
   for(int waited=0;waited<10000 && iTime(InpCustom,p.tf,0)!=start && !IsStopped();waited++) Sleep(1);
   if(iTime(InpCustom,p.tf,0)!=start || iTime(InpCustom,p.tf,1)!=p.current)
      { g_timeouts++; PrintFormat("LiveReplay: timeout %s new bar %s not formed",EnumToString(p.tf),TimeToString(start)); }
   for(int s=0;s<ArraySize(p.handles);s++)
      if(!Ready(p.handles[s],InpCustom,p.tf,10000))
         { g_timeouts++; PrintFormat("LiveReplay: timeout %s %s not calculated at %s",EnumToString(p.tf),g_name[s],TimeToString(start)); }
   Ready(p.counter,InpCustom,p.tf,10000);
   int k=p.bars;
   ArrayResize(p.times,k+1,4096);
   ArrayResize(p.calls,k+1,4096);
   ArrayResize(p.close,(k+1)*g_total,4096*g_total);
   ArrayResize(p.form,(k+1)*g_total,4096*g_total);
   p.times[k]=iTime(InpCustom,p.tf,1);
   p.calls[k]=One(p.counter,0,1);
   for(int s=0;s<ArraySize(p.handles);s++)
      for(int b=0;b<g_buffers[s];b++)
      {
         p.close[k*g_total+g_offset[s]+b]=One(p.handles[s],b,1);
         p.form[k*g_total+g_offset[s]+b]=One(p.handles[s],b,0);
      }
   p.bars++;
}

// Lets the indicator thread work through a batch: waits until the counter has
// seen the last tick (its running total of calls moved). 2 s without that is counted
// as a timeout, which fails the run.
void Settle(Feed &p,const double before)
{
   for(int waited=0;waited<2000 && !IsStopped();waited++)
   {
      double v[];
      if(CopyBuffer(p.counter,1,0,1,v)==1 && v[0]!=before) return;
      Sleep(1);
   }
   g_timeouts++;
   PrintFormat("LiveReplay: timeout %s counter stayed at %g after the batch ending %s",EnumToString(p.tf),before,
      TimeToString((datetime)SymbolInfoInteger(InpCustom,SYMBOL_TIME),TIME_DATE|TIME_SECONDS));
}

double Count(Feed &p)
{
   double v[];
   return CopyBuffer(p.counter,1,0,1,v)==1?v[0]:-1;
}

bool AddTicks(MqlTick &ticks[])
{
   if(ArraySize(ticks)==0) return true;
   double before[];
   ArrayResize(before,ArraySize(g_p));
   for(int i=0;i<ArraySize(g_p);i++) before[i]=Count(g_p[i]);
   int added=CustomTicksAdd(InpCustom,ticks);
   if(added!=ArraySize(ticks)) { PrintFormat("LiveReplay: CustomTicksAdd %d of %d (%d)",added,ArraySize(ticks),GetLastError()); return false; }
   for(int i=0;i<ArraySize(g_p);i++) Settle(g_p[i],before[i]);
   ArrayResize(ticks,0,1024);
   return true;
}

void Push(MqlTick &ticks[],const datetime t,const int second,const double price)
{
   int n=ArraySize(ticks);
   ArrayResize(ticks,n+1,1024);
   ZeroMemory(ticks[n]);
   ticks[n].time=t+second;
   ticks[n].time_msc=(long)(t+second)*1000;
   ticks[n].bid=price;
   ticks[n].ask=price;
   ticks[n].last=price;
   ticks[n].volume=1;
   ticks[n].flags=TICK_FLAG_BID|TICK_FLAG_ASK;
}

bool CopyFeed(const datetime from,const datetime to,MqlRates &rates[])
{
   ArrayResize(rates,0);
   for(int attempt=0;attempt<100 && !IsStopped();attempt++)
   {
      int n=CopyRates(InpSource,ParsePeriod(InpFeed),from,to-1,rates);
      if(n>=0) return true;
      Sleep(100);
   }
   PrintFormat("LiveReplay: CopyRates %s %s %s failed (%d)",InpSource,InpFeed,TimeToString(from),GetLastError());
   return false;
}

datetime NextMonth(const datetime t)
{
   MqlDateTime d;
   TimeToStruct(t,d);
   d.day=1; d.hour=0; d.min=0; d.sec=0;
   d.mon++;
   if(d.mon>12) { d.mon=1; d.year++; }
   return StructToTime(d);
}

ENUM_TIMEFRAMES ParsePeriod(const string s)
{
   if(s=="M1") return PERIOD_M1;
   if(s=="M5") return PERIOD_M5;
   if(s=="M15") return PERIOD_M15;
   if(s=="M30") return PERIOD_M30;
   if(s=="H1") return PERIOD_H1;
   if(s=="H4") return PERIOD_H4;
   if(s=="D1") return PERIOD_D1;
   return PERIOD_CURRENT;
}

string Cell(const double x) { return x==EMPTY_VALUE?"":StringFormat("%.17g",x); }

// Every buffer of `handle` over all bars, mapped onto the recorded bar times.
bool Window(const Feed &p,const int handle,const int buffers,double &values[])
{
   int n=Bars(InpCustom,p.tf);
   datetime times[];
   if(CopyTime(InpCustom,p.tf,0,n,times)!=n) return false;
   int index[];
   ArrayResize(index,p.bars);
   ArrayResize(values,p.bars*buffers);
   for(int k=0,j=0;k<p.bars;k++)
   {
      while(j<n && times[j]<p.times[k]) j++;
      if(j>=n || times[j]!=p.times[k]) { PrintFormat("LiveReplay: bar %s missing at the end",TimeToString(p.times[k])); return false; }
      index[k]=j;
   }
   for(int b=0;b<buffers;b++)
   {
      double all[];
      if(CopyBuffer(handle,b,0,n,all)!=n) { PrintFormat("LiveReplay: CopyBuffer %d failed (%d)",b,GetLastError()); return false; }
      for(int k=0;k<p.bars;k++) values[k*buffers+b]=all[index[k]];
   }
   return true;
}

bool Write(Feed &p)
{
   string path=InpFilePrefix+"_"+InpSource+"_"+StringSubstr(EnumToString(p.tf),7)+".csv";
   int file=FileOpen(path,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(file==INVALID_HANDLE) { PrintFormat("LiveReplay: FileOpen failed (%d)",GetLastError()); return false; }
   int bars=Bars(InpCustom,p.tf);
   double calls[];
   ArrayCopy(calls,p.calls);
   ArraySort(calls);
   FileWriteString(file,StringFormat("#meta,symbol=%s,period=%s,recorded=%d,copy_failures=%d,timeouts=%d,init_oldest=%d,end_bars=%d,end_oldest=%d,calls_min=%g,calls_median=%g\n",
      InpSource,EnumToString(p.tf),p.bars,g_failures,g_timeouts,(long)p.init_oldest,bars,
      (long)iTime(InpCustom,p.tf,bars-1),p.bars?calls[0]:0,p.bars?calls[p.bars/2]:0));
   FileWriteString(file,"indicator,buffer,time,a_close,a_end,b,a_forming\n");
   bool ok=p.bars>0;
   for(int s=0;s<ArraySize(p.handles) && ok;s++)
   {
      int nb=g_buffers[s];
      double a_end[],b_vals[];
      int hb=Create(InpCustom,p.tf,g_name[s],"LiveB\\");
      ok=hb!=INVALID_HANDLE && Ready(hb,InpCustom,p.tf,300000) && Ready(p.handles[s],InpCustom,p.tf,10000) &&
         Window(p,p.handles[s],nb,a_end) && Window(p,hb,nb,b_vals);
      FileWriteString(file,StringFormat("#calc,indicator=%s,buffers=%d,a=%d,b=%d,handle_a=%d,handle_b=%d\n",
         g_name[s],nb,BarsCalculated(p.handles[s]),BarsCalculated(hb),p.handles[s],hb));
      if(hb!=INVALID_HANDLE) IndicatorRelease(hb);
      if(!ok) { PrintFormat("LiveReplay: %s end-of-replay copy failed",g_name[s]); break; }
      for(int b=0;b<nb;b++)
         for(int k=0;k<p.bars;k++)
         {
            int at=k*g_total+g_offset[s]+b;
            FileWriteString(file,g_name[s]+","+IntegerToString(b)+","+IntegerToString((long)p.times[k])+","+
               Cell(p.close[at])+","+Cell(a_end[k*nb+b])+","+Cell(b_vals[k*nb+b])+","+Cell(p.form[at])+"\n");
         }
   }
   for(int k=0;k<p.bars && ok;k++)
      FileWriteString(file,StringFormat("#calls,%d,%g\n",(long)p.times[k],p.calls[k]));
   FileWriteString(file,ok?"#done\n":"#incomplete\n");
   FileClose(file);
   PrintFormat("LiveReplay: %s %s %s, %d bars x %d buffers -> %s",ok?"wrote":"INCOMPLETE",InpSource,
      EnumToString(p.tf),p.bars,g_total,path);
   return ok;
}

void OnStart()
{
   Specs();
   if(g_total==0) { Print("LiveReplay: no indicators selected"); return; }
   if(!SymbolSelect(InpSource,true)) { PrintFormat("LiveReplay: %s unknown",InpSource); return; }
   if(!SymbolInfoInteger(InpCustom,SYMBOL_CUSTOM) && !CustomSymbolCreate(InpCustom,"",InpSource))
      { PrintFormat("LiveReplay: CustomSymbolCreate failed (%d)",GetLastError()); return; }
   if(!SymbolSelect(InpCustom,true)) { PrintFormat("LiveReplay: SymbolSelect %s failed",InpCustom); return; }
   // History before the window: the state every A starts from.
   MqlRates rates[];
   int preload=0;
   for(datetime m=InpPreload;m<InpFrom && !IsStopped();m=NextMonth(m))
   {
      datetime stop=MathMin(NextMonth(m),InpFrom);
      if(!CopyFeed(m,stop,rates)) return;
      if(ArraySize(rates)>0 && CustomRatesUpdate(InpCustom,rates)!=ArraySize(rates))
         { PrintFormat("LiveReplay: CustomRatesUpdate failed (%d)",GetLastError()); return; }
      preload+=ArraySize(rates);
   }
   PrintFormat("LiveReplay: preloaded %d %s bars of %s",preload,InpFeed,InpSource);

   string parts[];
   int np=StringSplit(InpPeriods,',',parts);
   ArrayResize(g_p,np);
   for(int i=0;i<np;i++)
   {
      g_p[i].tf=ParsePeriod(parts[i]);
      if(g_p[i].tf==PERIOD_CURRENT) { PrintFormat("LiveReplay: unsupported period %s",parts[i]); return; }
      ArrayResize(g_p[i].handles,ArraySize(g_name));
      for(int s=0;s<ArraySize(g_name);s++)
      {
         g_p[i].handles[s]=Create(InpCustom,g_p[i].tf,g_name[s],"");
         if(g_p[i].handles[s]==INVALID_HANDLE) { PrintFormat("LiveReplay: %s handle failed (%d)",g_name[s],GetLastError()); return; }
      }
      g_p[i].counter=iCustom(InpCustom,g_p[i].tf,"DLV_CalcCounter");
      if(g_p[i].counter==INVALID_HANDLE) { PrintFormat("LiveReplay: DLV_CalcCounter handle failed (%d)",GetLastError()); return; }
      for(int s=0;s<ArraySize(g_name);s++)
         if(!Ready(g_p[i].handles[s],InpCustom,g_p[i].tf,300000)) { PrintFormat("LiveReplay: %s not calculated",g_name[s]); return; }
      Ready(g_p[i].counter,InpCustom,g_p[i].tf,60000);
      g_p[i].current=iTime(InpCustom,g_p[i].tf,0);
      g_p[i].init_oldest=iTime(InpCustom,g_p[i].tf,Bars(InpCustom,g_p[i].tf)-1);
      g_p[i].bars=0;
   }

   // The live feed: each InpFeed bar as four ticks spread over the bar.
   int span=PeriodSeconds(ParsePeriod(InpFeed));
   for(int i=0;i<np;i++)
      if(ParsePeriod(InpFeed)==PERIOD_CURRENT || span>=PeriodSeconds(g_p[i].tf)) { PrintFormat("LiveReplay: bad feed %s",InpFeed); return; }
   MqlTick ticks[];
   bool first=true;
   uint began=GetTickCount();
   for(datetime m=InpFrom;m<InpTo && !IsStopped();m=NextMonth(m))
   {
      if(!CopyFeed(m,MathMin(NextMonth(m),InpTo),rates)) return;
      for(int r=0;r<ArraySize(rates);r++)
      {
         datetime t=rates[r].time;
         bool opens[];
         ArrayResize(opens,np);
         bool any=false;
         for(int i=0;i<np;i++)
         {
            datetime start=t-t%PeriodSeconds(g_p[i].tf);
            opens[i]=start!=g_p[i].current;
            any=any || opens[i];
         }
         if(any)
         {
            // Close the old bars, then deliver the new bar's first tick alone.
            if(!AddTicks(ticks)) return;
            Push(ticks,t,0,rates[r].open);
            if(!AddTicks(ticks)) return;
            for(int i=0;i<np;i++)
               if(opens[i])
               {
                  // The bar open at the replay start was only seen by A's full
                  // calculation, not by forming ticks: skip it.
                  datetime start=t-t%PeriodSeconds(g_p[i].tf);
                  if(!first) Record(g_p[i],start);
                  g_p[i].current=start;
               }
            first=false;
         }
         else Push(ticks,t,0,rates[r].open);
         bool up=rates[r].close>=rates[r].open;
         Push(ticks,t,span/3,up?rates[r].low:rates[r].high);
         Push(ticks,t,2*span/3,up?rates[r].high:rates[r].low);
         Push(ticks,t,span-1,rates[r].close);
         if(ArraySize(ticks)>=InpFlushTicks && !AddTicks(ticks)) return;
      }
   }
   if(!AddTicks(ticks)) return;
   PrintFormat("LiveReplay: replay of %s %s..%s took %u s (A copy failures %d, timeouts %d)",InpSource,
      TimeToString(InpFrom),TimeToString(InpTo),(GetTickCount()-began)/1000,g_failures,g_timeouts);
   for(int i=0;i<np;i++) if(!Write(g_p[i])) return;
   Print("LiveReplay finished");
}
