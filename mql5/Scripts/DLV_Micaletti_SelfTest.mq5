#property copyright "DLV"
#property version "1.00"
#include <DLV_Micaletti.mqh>

input string InpFilePrefix="DLV_Micaletti_selftest";

// Deterministic MQL-VM arithmetic test; no market feed/account/order dependency.
// Outputs both batch and incremental evaluations of the SAME production core.
// Run from any chart, then check the CSVs with check_micaletti_parity.py.
string TestCell(const double x) { return MicalValid(x)?StringFormat("%.17g",x):""; }
void OnStart()
{
   const int n=850;
   double o[],hi[],lo[],cl[],v[],vw[];
   ArrayResize(o,n); ArrayResize(hi,n); ArrayResize(lo,n); ArrayResize(cl,n); ArrayResize(v,n); ArrayResize(vw,n);
   for(int scenario=0;scenario<7;scenario++)
   {
      for(int i=0;i<n;i++)
      {
         double mid=100+0.01*i+2*MathSin(0.71*i)+3*MathCos(0.13*i);
         o[i]=mid; hi[i]=mid+1+(i%7)*0.1; lo[i]=mid-1-(i%5)*0.1;
         cl[i]=lo[i]+(hi[i]-lo[i])*(0.05+(i%19)*0.05);
         v[i]=1000+(i%23)*317;
         if(scenario==1) { o[i]=hi[i]=lo[i]=cl[i]=100; v[i]=1000; }
         if(scenario==2 && i>=300 && i<340) v[i]=0;
         if(scenario==3) { cl[i]=lo[i]+0.05*(hi[i]-lo[i]); v[i]=1000; }
         if(scenario==4)
         {
            double repeated[]={99.7,100.1,100.1,100.1};
            o[i]=100; hi[i]=101; lo[i]=99; cl[i]=repeated[i%4]; v[i]=1000;
         }
         if(scenario==5) { o[i]=cl[i]=100+0.01*i; hi[i]=cl[i]+1; lo[i]=cl[i]-1; v[i]=1000; }
         if(scenario==6)
         {
            double highs[]={101.1,100.8,101.0,100.2},lows[]={99.7,99.9,99.8,99.5},closes[]={99.91,100.1,100.11,99.64};
            o[i]=cl[i]=closes[i%4]; hi[i]=highs[i%4]; lo[i]=lows[i%4]; v[i]=1000;
         }
         vw[i]=(hi[i]+lo[i]+cl[i])/3;
      }
      for(int p=0;p<22;p++) for(int incremental=0;incremental<2;incremental++)
      {
         CMicaletti core;
         double raw[],rank[],le[],lx[],se[],sx[],ld[],sd[];
         if(incremental==0) core.Calculate(p,hi,lo,cl,v,vw,n,0,raw);
         else
         {
            // Append, re-evaluate the previous tail, and cross both rank warmups.
            core.Calculate(p,hi,lo,cl,v,vw,100,0,raw);
            core.Calculate(p,hi,lo,cl,v,vw,300,99,raw);
            core.Calculate(p,hi,lo,cl,v,vw,n,299,raw);
         }
         ArrayResize(rank,n);
         for(int i=0;i<n;i++) rank[i]=MicalRank(raw,i,252);
         if(incremental==0) MicalSignals(rank,n,MicalHold(p),MICAL_BOTH,0,le,lx,se,sx,ld,sd);
         else
         {
            MicalSignals(rank,100,MicalHold(p),MICAL_BOTH,0,le,lx,se,sx,ld,sd);
            MicalSignals(rank,300,MicalHold(p),MICAL_BOTH,99,le,lx,se,sx,ld,sd);
            MicalSignals(rank,n,MicalHold(p),MICAL_BOTH,299,le,lx,se,sx,ld,sd);
         }
         string name=StringFormat("%s_%d_%d_%s.csv",InpFilePrefix,scenario,incremental,MicalName(p));
         int file=FileOpen(name,FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',',CP_UTF8);
         if(file==INVALID_HANDLE) { PrintFormat("SelfTest file error %d",GetLastError()); return; }
         FileWrite(file,"preset","vwap_mode","time","Open","High","Low","Close","Volume","vwap","raw","rank","long_entry","long_exit","short_entry","short_exit");
         for(int i=0;i<n;i++) FileWrite(file,MicalName(p),0,(long)D'2020.01.01'+i*86400,
            TestCell(o[i]),TestCell(hi[i]),TestCell(lo[i]),TestCell(cl[i]),TestCell(v[i]),TestCell(vw[i]),
            TestCell(raw[i]),TestCell(rank[i]),(int)le[i],(int)lx[i],(int)se[i],(int)sx[i]);
         FileClose(file);
      }
   }
   Print("Micaletti SelfTest complete (308 CSVs): ",TerminalInfoString(TERMINAL_COMMONDATA_PATH),"\\Files");
}
