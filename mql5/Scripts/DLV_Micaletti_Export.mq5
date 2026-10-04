#property copyright "DLV"
#property version "1.00"
#property script_show_inputs
#include <DLV_Micaletti.mqh>

// Read-only terminal-bar dump. Exports ALL loaded bars (including warmup) so
// Python starts every recursion on the same bar. Last/forming bar is omitted.
// No orders, login changes or indicator/chart object changes.
input ENUM_MICAL_VWAP InpVWAPMode=MICAL_LAB_PROXY;
input ENUM_APPLIED_VOLUME InpVolume=VOLUME_TICK;
input string InpVWAPName="VWAP";
input string InpFilePrefix="DLV_Micaletti";

string Cell(const double x) { return MicalValid(x)?StringFormat("%.17g",x):""; }
int NativeHandle(const int p)
{
   if(p==MICAL_RSI_H1) return iRSI(_Symbol,_Period,2,PRICE_CLOSE);
   if(p==MICAL_CCI_H1) return iCCI(_Symbol,_Period,3,PRICE_TYPICAL);
   if(p==MICAL_MFI_H1) return iMFI(_Symbol,_Period,3,InpVolume);
   if(p==MICAL_CHIOSC_H1) return iChaikin(_Symbol,_Period,2,3,MODE_EMA,InpVolume);
   if(p==MICAL_STOK_H1) return iStochastic(_Symbol,_Period,1,3,1,MODE_SMA,STO_LOWHIGH);
   if(p==MICAL_STOD_H3) return iStochastic(_Symbol,_Period,1,2,1,MODE_SMA,STO_LOWHIGH);
   return INVALID_HANDLE;
}
void OnStart()
{
   MqlRates rates[];
   ArraySetAsSeries(rates,false);
   // CopyRates requests history construction; Bars alone can return zero before
   // the chart's timeframe has synchronized, including in an offline terminal.
   int count=0;
   for(int attempt=0;attempt<150 && !IsStopped();attempt++)
   {
      CopyRates(_Symbol,_Period,0,1,rates);
      count=Bars(_Symbol,_Period);
      if(count>=600) break;
      Sleep(100);
   }
   if(count<600 || CopyRates(_Symbol,_Period,0,count,rates)!=count)
   { Print("Micaletti export: load at least 600 bars, then retry."); return; }
   datetime origin=rates[0].time,tail=rates[count-1].time;
   string prefix=InpFilePrefix+"_"+_Symbol+"_"+EnumToString(_Period)+"_"+IntegerToString((int)TimeLocal());
   for(int p=0;p<22 && !IsStopped();p++)
   {
      int handle=iCustom(_Symbol,_Period,"DLV_Micaletti",(ENUM_MICAL_PRESET)p,MICAL_BOTH,InpVolume,InpVWAPMode,InpVWAPName,false);
      if(handle==INVALID_HANDLE) { PrintFormat("Micaletti export: handle %d failed (%d)",p,GetLastError()); return; }
      int waited=0;
      double pending[];
      while(BarsCalculated(handle)<count && waited<15000 && !IsStopped())
      { CopyBuffer(handle,0,0,1,pending); Sleep(100); waited+=100; }
      double rank[],raw[],le[],lx[],se[],sx[],vwap[];
      bool ok=CopyBuffer(handle,0,0,count,rank)==count && CopyBuffer(handle,1,0,count,raw)==count
         && CopyBuffer(handle,2,0,count,le)==count && CopyBuffer(handle,3,0,count,lx)==count
         && CopyBuffer(handle,4,0,count,se)==count && CopyBuffer(handle,5,0,count,sx)==count
         && CopyBuffer(handle,6,0,count,vwap)==count;
      IndicatorRelease(handle);
      if(ok && (MicalValid(rank[count-1]) || MicalValid(raw[count-1]) ||
         le[count-1]!=EMPTY_VALUE || lx[count-1]!=EMPTY_VALUE ||
         se[count-1]!=EMPTY_VALUE || sx[count-1]!=EMPTY_VALUE))
      { Print("Micaletti export: forming bar exposed a value/signal; refusing export."); return; }
      // Abort rather than compare a truncated or moving calculation window.
      if(!ok || Bars(_Symbol,_Period)!=count || iTime(_Symbol,_Period,count-1)!=origin || iTime(_Symbol,_Period,0)!=tail)
      { Print("Micaletti export: buffers not ready or history changed; retry."); return; }
      // Diagnostic only: native mappings are not silently used as replacements.
      double native[]; ArrayResize(native,count); ArrayInitialize(native,EMPTY_VALUE);
      int nh=NativeHandle(p);
      if(nh!=INVALID_HANDLE)
      {
         waited=0;
         while(BarsCalculated(nh)<count && waited<15000 && !IsStopped()) { Sleep(100); waited+=100; }
         if(CopyBuffer(nh,p==MICAL_STOD_H3?1:0,0,count,native)!=count)
         { ArrayInitialize(native,EMPTY_VALUE); PrintFormat("Micaletti export: native diagnostic unavailable for %s",MicalName(p)); }
         IndicatorRelease(nh);
      }
      string name=prefix+"_"+MicalName(p)+".csv";
      int file=FileOpen(name,FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',',CP_UTF8);
      if(file==INVALID_HANDLE) { PrintFormat("Micaletti export: FileOpen failed (%d)",GetLastError()); return; }
      FileWrite(file,"preset","vwap_mode","time","Open","High","Low","Close","Volume","vwap","raw","rank","long_entry","long_exit","short_entry","short_exit","native_raw");
      for(int i=0;i<count-1;i++)
         FileWrite(file,MicalName(p),(int)InpVWAPMode,(long)rates[i].time,
            Cell(rates[i].open),Cell(rates[i].high),Cell(rates[i].low),Cell(rates[i].close),
            InpVolume==VOLUME_TICK?rates[i].tick_volume:rates[i].real_volume,Cell(vwap[i]),
            Cell(raw[i]),Cell(rank[i]),Cell(le[i]),Cell(lx[i]),Cell(se[i]),Cell(sx[i]),Cell(native[i]));
      FileClose(file);
      Print("Micaletti export: ",name);
   }
   Print("Micaletti export finished: ",TerminalInfoString(TERMINAL_COMMONDATA_PATH),"\\Files\\",prefix,"_*.csv");
}
