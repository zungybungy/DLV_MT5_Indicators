#property copyright "DLV"
#property version "1.00"
#property script_show_inputs

// Read-only terminal-bar dump of TD_DLV_v3.6 (14 buffers), DLV_TD_MA (2) and
// DLV_TD_Point at Levels 1 and 3 (6 each; the levels the Lab presets trade) for
// mql5/check_td_parity.py. Each runs over all bars (MaxBars=INT_MAX where it has
// one) and the CSV starts on the oldest bar the indicator saw (its rates_total),
// so every state machine starts on the same bar as the Python reference. The
// forming bar is omitted: the indicators deliberately paint it. No orders or
// login changes.
input string InpFilePrefix="DLV_TD";

string Cell(const double x) { return x==EMPTY_VALUE?"":StringFormat("%.17g",x); }
bool Export(const string name,const int handle,const int buffers,const string header,const string prefix)
{
   if(handle==INVALID_HANDLE) { PrintFormat("TD export: %s handle failed (%d)",name,GetLastError()); return false; }
   // rates_total is authoritative: Bars() can exceed TERMINAL_MAXBARS.
   int count=0,previous=-1;
   double pending[];
   for(int waited=0;waited<120000 && !IsStopped();waited+=200)
   {
      CopyBuffer(handle,0,0,1,pending);
      count=BarsCalculated(handle);
      if(count>=100 && count==previous) break;
      previous=count;
      Sleep(200);
   }
   MqlRates rates[];
   ArraySetAsSeries(rates,false);
   double values[];
   ArrayResize(values,buffers*count);
   bool ok=count>=100 && CopyRates(_Symbol,_Period,0,count,rates)==count;
   for(int b=0;b<buffers && ok;b++)
   {
      double one[];
      ok=CopyBuffer(handle,b,0,count,one)==count;
      if(ok) ArrayCopy(values,one,b*count,0,count);
   }
   // Abort rather than compare a truncated or moving calculation window.
   ok=ok && BarsCalculated(handle)==count && iTime(_Symbol,_Period,0)==rates[count-1].time;
   IndicatorRelease(handle);
   if(!ok) { PrintFormat("TD export: %s buffers not ready or history changed; retry.",name); return false; }
   string path=prefix+"_"+name+".csv";
   int file=FileOpen(path,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(file==INVALID_HANDLE) { PrintFormat("TD export: FileOpen failed (%d)",GetLastError()); return false; }
   FileWriteString(file,"indicator,time,Open,High,Low,Close,"+header+"\n");
   for(int i=0;i<count-1;i++)
   {
      string row=name+","+IntegerToString((long)rates[i].time)+","+Cell(rates[i].open)+","+
                 Cell(rates[i].high)+","+Cell(rates[i].low)+","+Cell(rates[i].close);
      for(int b=0;b<buffers;b++) row+=","+Cell(values[b*count+i]);
      FileWriteString(file,row+"\n");
   }
   FileClose(file);
   Print("TD export: ",path," (",count-1," closed bars)");
   return true;
}
void OnStart()
{
   // CopyRates requests history construction; wait until the bar count settles.
   MqlRates probe[];
   int count=0,previous=-1;
   for(int attempt=0;attempt<150 && !IsStopped();attempt++)
   {
      CopyRates(_Symbol,_Period,0,1,probe);
      count=Bars(_Symbol,_Period);
      if(count>=100 && count==previous) break;
      previous=count;
      Sleep(200);
   }
   if(count<100) { Print("TD export: load at least 100 bars, then retry."); return; }
   string prefix=InpFilePrefix+"_"+_Symbol+"_"+EnumToString(_Period)+"_"+IntegerToString((int)TimeLocal());
   // Positional inputs: each `input group` occupies one argument ("" placeholder).
   if(!Export("TD_SEQ",iCustom(_Symbol,_Period,"TD_DLV_v3.6","",INT_MAX),14,
      "tdst_resistance,tdst_support,setup,countdown,perfection,"+
      "buy_setup_risk_a,sell_setup_risk_a,buy_setup_risk_b,sell_setup_risk_b,"+
      "buy_countdown_risk_a,sell_countdown_risk_a,buy_countdown_risk_b,sell_countdown_risk_b,"+
      "aggressive_countdown",prefix)) return;
   if(!Export("TD_MA1",iCustom(_Symbol,_Period,"DLV_TD_MA","",5,12,4,INT_MAX),2,
      "bullish,bearish",prefix)) return;
   for(int level=1;level<=3;level+=2)
      if(!Export("TD_POINT_L"+IntegerToString(level),iCustom(_Symbol,_Period,"DLV_TD_Point","",level),6,
         "demand,supply,demand_confirmed,supply_confirmed,prior_demand,prior_supply",prefix)) return;
   Print("TD export finished: ",TerminalInfoString(TERMINAL_COMMONDATA_PATH),"\\Files\\",prefix,"_*.csv");
}
