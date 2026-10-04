// Micaletti / Lab arithmetic. Arrays are chronological, oldest bar first.
// EMPTY_VALUE represents NaN. No orders, chart objects, or future-bar reads.
#ifndef DLV_MICALETTI_MQH
#define DLV_MICALETTI_MQH

enum ENUM_MICAL_PRESET
{
   MICAL_MTSI_H1, MICAL_MTSI_H3, MICAL_MTSI22_H1, MICAL_MTSI22_H3,
   MICAL_MRSI_H1, MICAL_VWMRSI_H5, MICAL_VWMRSI_H1,
   MICAL_STODD_H3, MICAL_STODD_H5, MICAL_CHIOSC_H1, MICAL_UO_H1,
   MICAL_STOK_H1, MICAL_STOD_H3, MICAL_DVO_H1, MICAL_RSI_H1,
   MICAL_TSI_H1, MICAL_BBI_H1, MICAL_CCI_H1, MICAL_MFI_H1,
   MICAL_KCR_H1, MICAL_PPO_H1, MICAL_DVI_H1
};
enum ENUM_MICAL_DIRECTION { MICAL_LONG, MICAL_SHORT, MICAL_BOTH };
enum ENUM_MICAL_VWAP { MICAL_LAB_PROXY, MICAL_EXISTING_VWAP, MICAL_M1_SESSION_VWAP };

string MicalName(const int preset)
{
   string names[]={"mtsi_h1","mtsi_h3","mtsi22_h1","mtsi22_h3",
      "mrsi_h1","vwmrsi_h5","vwmrsi_h1","stodd_h3","stodd_h5",
      "chiosc_h1","uo_h1","stok_h1","stod_h3","dvo_h1","rsi_h1",
      "tsi_h1","bbi_h1","cci_h1","mfi_h1","kcr_h1","ppo_h1","dvi_h1"};
   return "micaletti_"+names[preset];
}
int MicalHold(const int p)
{
   if(p==MICAL_MTSI_H3 || p==MICAL_MTSI22_H3 || p==MICAL_STODD_H3 || p==MICAL_STOD_H3) return 3;
   if(p==MICAL_VWMRSI_H5 || p==MICAL_STODD_H5) return 5;
   return 1;
}
bool MicalValid(const double x) { return x!=EMPTY_VALUE && MathIsValidNumber(x); }

// Full windows for SMA, partial VALID windows for Lab's numba percent rank.
double MicalMean(const double &x[],const int i,const int period)
{
   if(i<period-1) return EMPTY_VALUE;
   double sum=0;
   for(int j=i-period+1;j<=i;j++) { if(!MicalValid(x[j])) return EMPTY_VALUE; sum+=x[j]; }
   return sum/period;
}
double MicalRank(const double &x[],const int i,const int period)
{
   if(i<period-1 || !MicalValid(x[i])) return EMPTY_VALUE;
   int valid=0,le=0;
   for(int j=i-period+1;j<=i;j++) if(MicalValid(x[j])) { valid++; if(x[j]<=x[i]) le++; }
   return valid>0 ? (double)le/valid : EMPTY_VALUE;
}
void MicalSMA(const double &x[],double &y[],const int n,const int p,const int start)
{
   ArrayResize(y,n);
   // Replay the compensated rolling sum to retain pandas' tie behaviour.
   // This linear pass is cheap; recursive oscillators and rank remain incremental.
   double sum=0,add_comp=0,remove_comp=0,prev=EMPTY_VALUE;
   int valid=0,same=0,negative=0;
   for(int i=0;i<n;i++)
   {
      if(i>=p && MicalValid(x[i-p]))
      {
         double delta=-x[i-p]-remove_comp,next=sum+delta;
         remove_comp=next-sum-delta; sum=next; valid--;
         if(x[i-p]<0) negative--;
      }
      if(MicalValid(x[i]))
      {
         double delta=x[i]-add_comp,next=sum+delta;
         add_comp=next-sum-delta; sum=next; valid++;
         if(x[i]<0) negative++;
         same=(x[i]==prev)?same+1:1; prev=x[i];
      }
      if(i<start) continue;
      y[i]=EMPTY_VALUE;
      if(valid>=p)
      {
         y[i]=(same>=valid)?prev:sum/valid;
         if((negative==0 && y[i]<0) || (negative==valid && y[i]>0)) y[i]=0;
      }
   }
}
void MicalTASMA(const double &x[],double &y[],const int n,const int p)
{
   ArrayResize(y,n);
   double sum=0;
   for(int i=0;i<n;i++)
   {
      sum+=x[i]; y[i]=EMPTY_VALUE;
      if(i>=p-1) { y[i]=sum/p; sum-=x[i-p+1]; }
   }
}
// pandas ewm(adjust=False, ignore_na=False): first observation seed; missing
// observations retain the value but decay its weight before the next update.
void MicalEWM(const double &x[],double &y[],const int n,const double alpha,const int start)
{
   ArrayResize(y,n);
   for(int i=start;i<n;i++)
   {
      double prev=(i>0)?y[i-1]:EMPTY_VALUE;
      if(!MicalValid(prev)) { y[i]=x[i]; continue; }
      if(!MicalValid(x[i])) { y[i]=prev; continue; }
      int gaps=0;
      for(int j=i-1;j>=0 && !MicalValid(x[j]);j--) gaps++;
      double weight=MathPow(1-alpha,gaps+1);
      y[i]=(weight*prev+alpha*x[i])/(weight+alpha);
   }
}
// TA-Lib EMA: SMA seed at the first complete period (leading NaNs allowed).
void MicalEMA(const double &x[],double &y[],const int n,const int p,const int start)
{
   ArrayResize(y,n);
   int first=0;
   while(first<n && !MicalValid(x[first])) first++;
   int seed=first+p-1;
   double alpha=2.0/(p+1);
   for(int i=start;i<n;i++)
   {
      y[i]=EMPTY_VALUE;
      if(i==seed) y[i]=MicalMean(x,i,p);
      else if(i>seed && MicalValid(y[i-1]) && MicalValid(x[i])) y[i]=y[i-1]+alpha*(x[i]-y[i-1]);
   }
}

// Work arrays persist across calls. Recalculate from the previous forming bar
// so ticks never accumulate into an EMA twice. A history reset starts at zero.
class CMicaletti
{
private:
   double a[],b[],c[],d[],e[],f[],g[],h[],k[];
public:
   void Calculate(const int p,const double &high[],const double &low[],
                  const double &close[],const double &vol[],const double &vwap[],
                  const int n,const int start,double &out[])
   {
      ArrayResize(a,n); ArrayResize(b,n); ArrayResize(c,n); ArrayResize(d,n);
      ArrayResize(e,n); ArrayResize(f,n); ArrayResize(g,n); ArrayResize(h,n); ArrayResize(k,n);
      ArrayResize(out,n);
      for(int i=start;i<n;i++) out[i]=a[i]=b[i]=c[i]=d[i]=e[i]=f[i]=g[i]=h[i]=k[i]=EMPTY_VALUE;

      if(p<=MICAL_MTSI22_H3 || p==MICAL_TSI_H1)
      {
         int outer=(p==MICAL_MTSI22_H1 || p==MICAL_MTSI22_H3)?2:3;
         if(p==MICAL_TSI_H1) outer=1;
         for(int i=start;i<n;i++)
         {
            if(p==MICAL_TSI_H1) { if(i>0) a[i]=close[i]-close[i-1]; }
            else if(MicalValid(vwap[i]) && vwap[i]>0 && close[i]>0) a[i]=MathLog(close[i]/vwap[i]);
            if(MicalValid(a[i])) b[i]=MathAbs(a[i]);
         }
         MicalEWM(a,c,n,2.0/3,start); MicalEWM(c,d,n,2.0/(outer+1),start);
         MicalEWM(b,e,n,2.0/3,start); MicalEWM(e,f,n,2.0/(outer+1),start);
         for(int i=start;i<n;i++) if(MicalValid(d[i]) && MicalValid(f[i]) && f[i]>(p==MICAL_TSI_H1?1e-10:0))
            out[i]=(p==MICAL_TSI_H1)?100*(d[i]/f[i]):100*d[i]/f[i];
      }
      else if(p==MICAL_MRSI_H1 || p==MICAL_VWMRSI_H5 || p==MICAL_VWMRSI_H1)
      {
         for(int i=start;i<n;i++)
         {
            double weight=1;
            if(p!=MICAL_MRSI_H1)
            {
               double mean=MicalMean(vol,i,21);
               if(!MicalValid(mean) || mean==0) continue;
               weight=vol[i]/mean;
            }
            if(low[i]>0 && close[i]>0 && high[i]>0) { a[i]=weight*MathLog(close[i]/low[i]); b[i]=weight*MathLog(high[i]/close[i]); }
         }
         MicalEWM(a,c,n,0.5,start); MicalEWM(b,d,n,0.5,start);
         for(int i=start;i<n;i++) if(MicalValid(c[i]) && MicalValid(d[i]) && c[i]+d[i]!=0) out[i]=100*c[i]/(c[i]+d[i]);
      }
      else if(p==MICAL_STODD_H3 || p==MICAL_STODD_H5 || p==MICAL_STOK_H1 || p==MICAL_STOD_H3)
      {
         // Shipped presets all have K=1. TA-Lib masks BOTH fast outputs until
         // D is available, whereas the custom STODD adds its own SMA(2).
         bool custom=(p==MICAL_STODD_H3 || p==MICAL_STODD_H5);
         int dp=(p==MICAL_STOK_H1)?3:2;
         for(int i=start;i<n;i++) if(high[i]!=low[i]) a[i]=custom?100*(close[i]-low[i])/(high[i]-low[i]):(close[i]-low[i])/((high[i]-low[i])/100); else if(!custom) a[i]=0;
         if(custom) MicalSMA(a,b,n,dp,start); else MicalTASMA(a,b,n,dp);
         if(custom) MicalSMA(b,out,n,2,start);
         else for(int i=start;i<n;i++) if(i>=dp-1) out[i]=(p==MICAL_STOK_H1)?a[i]:b[i];
      }
      else if(p==MICAL_DVO_H1)
      {
         for(int i=start;i<n;i++) if(high[i]+low[i]!=0) a[i]=close[i]/((high[i]+low[i])/2);
         // _njit_dvo permits partial valid SMA windows after bar 3.
         // Preserve its add-new-before-remove-old running sum and rank ties.
         for(int i=start;i<n;i++)
         {
            double sum=(i>0)?c[i-1]:0; int valid=(i>0)?(int)d[i-1]:0;
            if(MicalValid(a[i])) { sum+=a[i]; valid++; }
            if(i>=4 && MicalValid(a[i-4])) { sum-=a[i-4]; valid--; }
            c[i]=sum; d[i]=valid;
            if(i>=3 && valid>0) b[i]=sum/valid;
         }
         for(int i=start;i<n;i++) out[i]=MicalRank(b,i,21);
      }
      else if(p==MICAL_CHIOSC_H1)
      {
         for(int i=start;i<n;i++) a[i]=(i>0?a[i-1]:0)+(high[i]!=low[i]?(2*close[i]-high[i]-low[i])/(high[i]-low[i])*vol[i]:0);
         MicalEWM(a,b,n,2.0/3,start); MicalEWM(a,c,n,0.5,start);
         for(int i=start;i<n;i++) if(i>=2) out[i]=b[i]-c[i];
      }
      else if(p==MICAL_UO_H1 || p==MICAL_KCR_H1)
      {
         for(int i=start;i<n;i++) if(i>0)
         {
            a[i]=close[i]-MathMin(low[i],close[i-1]);
            b[i]=MathMax(high[i],close[i-1])-MathMin(low[i],close[i-1]);
         }
         if(p==MICAL_UO_H1)
         {
            for(int i=start;i<n;i++) if(i>=4)
            {
               double result=0;
               for(int period=2;period<=4;period++)
               {
                  double bp=0,tr=0;
                  for(int j=i-period+1;j<=i;j++) { bp+=a[j]; tr+=b[j]; }
                  if(tr!=0) result+=(period==2?4:(period==3?2:1))*bp/tr;
               }
               out[i]=100*result/7;
            }
         }
         else
         {
            MicalEWM(close,c,n,2.0/3,start);
            for(int i=start;i<n;i++)
            {
               if(i==2) d[i]=(b[1]+b[2])/2;
               else if(i>2 && MicalValid(d[i-1])) d[i]=(d[i-1]+b[i])/2;
               if(MicalValid(d[i]) && d[i]!=0) out[i]=100*(close[i]-(c[i]-2*d[i]))/(4*d[i]);
            }
         }
      }
      else if(p==MICAL_RSI_H1)
      {
         for(int i=start;i<n;i++) if(i>0) { a[i]=MathMax(close[i]-close[i-1],0); b[i]=MathMax(close[i-1]-close[i],0); }
         for(int i=start;i<n;i++)
         {
            if(i==2) { c[i]=(a[1]+a[2])/2; d[i]=(b[1]+b[2])/2; }
            else if(i>2) { c[i]=(c[i-1]+a[i])/2; d[i]=(d[i-1]+b[i])/2; }
            if(i>=2) out[i]=(c[i]+d[i]!=0)?100*(c[i]/(c[i]+d[i])):0;
         }
      }
      else if(p==MICAL_BBI_H1)
      {
         MicalTASMA(close,a,n,5);
         for(int i=start;i<n;i++)
         {
            // TA-Lib BBANDS reuses SMA and a running squared-price sum.
            double sq=(i>0)?b[i-1]:0;
            sq+=close[i]*close[i];
            double variance=sq/5;
            if(i>=4) sq-=close[i-4]*close[i-4];
            b[i]=sq;
            if(i<4) continue;
            variance-=a[i]*a[i];
            double sd=(variance<1e-14)?0:MathSqrt(variance);
            double upper=a[i]+2*sd,lower=a[i]-2*sd;
            if(upper!=lower) out[i]=(close[i]-lower)/(upper-lower);
         }
      }
      else if(p==MICAL_CCI_H1 || p==MICAL_MFI_H1)
      {
         for(int i=start;i<n;i++) a[i]=(high[i]+low[i]+close[i])/3;
         if(p==MICAL_CCI_H1)
         {
            for(int i=start;i<n;i++) if(i>=2)
            {
               // TA-Lib sums the three slots in circular-buffer order.
               double mean=0,dev=0;
               for(int slot=0;slot<3;slot++) mean+=a[i-((i-slot)%3+3)%3];
               mean/=3;
               for(int slot=0;slot<3;slot++) dev+=MathAbs(a[i-((i-slot)%3+3)%3]-mean);
               out[i]=(dev!=0 && a[i]!=mean)?(a[i]-mean)/(0.015*(dev/3)):0;
            }
         }
         else
         {
            for(int i=start;i<n;i++) if(i>0) { b[i]=(a[i]>a[i-1])?a[i]*vol[i]:0; c[i]=(a[i]<a[i-1])?a[i]*vol[i]:0; }
            for(int i=start;i<n;i++) if(i>=3)
            {
               double pos=0,neg=0;
               if(i==3) for(int j=1;j<=3;j++) { pos+=b[j]; neg+=c[j]; }
               else { pos=e[i-1]-b[i-3]; neg=f[i-1]-c[i-3]; pos+=b[i]; neg+=c[i]; }
               e[i]=pos; f[i]=neg;
               out[i]=(pos+neg>=1)?100*(pos/(pos+neg)):0;
            }
         }
      }
      else if(p==MICAL_PPO_H1)
      {
         MicalEMA(close,a,n,3,start); MicalEMA(close,b,n,5,start);
         for(int i=start;i<n;i++) if(i>=4) c[i]=(b[i]!=0)?(a[i]-b[i])/b[i]*100:0;
         MicalEMA(c,out,n,5,start);
      }
      else if(p==MICAL_DVI_H1)
      {
         for(int i=start;i<n;i++) if(i>0 && close[i-1]!=0)
         {
            double ret=close[i]/close[i-1]-1;
            a[i]=MathMax(ret,0); b[i]=MathMax(-ret,0);
         }
         for(int i=start;i<n;i++) if(i>=2 && MicalValid(a[i-1]) && MicalValid(a[i]))
         {
            double up=a[i]+a[i-1],dn=b[i]+b[i-1];
            if(up+dn!=0) c[i]=up/(up+dn);
         }
         MicalSMA(c,d,n,5,start); MicalSMA(close,e,n,10,start);
         for(int i=start;i<n;i++) if(MicalValid(e[i]) && e[i]!=0) f[i]=close[i]/e[i]-1;
         MicalSMA(f,g,n,3,start); MicalSMA(g,h,n,5,start);
         for(int i=start;i<n;i++) if(MicalValid(d[i]) && MicalValid(h[i])) k[i]=0.8*d[i]+0.2*h[i];
         for(int i=start;i<n;i++) out[i]=MicalRank(k,i,252);
      }
   }
};

// Lab close_to_close time_stops: exits suppress same-side entries at deadline.
// Entry buffers are raw threshold masks, exit buffers match apply_bar_stop.
// BOTH exposes the two independently researched legs, not a combined portfolio.
void MicalSignals(const double &rank[],const int n,const int hold,const int direction,
                  const int start,double &le[],double &lx[],double &se[],double &sx[],
                  double &long_due[],double &short_due[])
{
   ArrayResize(le,n); ArrayResize(lx,n); ArrayResize(se,n); ArrayResize(sx,n);
   ArrayResize(long_due,n); ArrayResize(short_due,n);
   for(int i=start;i<n;i++)
   {
      le[i]=(direction!=MICAL_SHORT && MicalValid(rank[i]) && rank[i]<0.10)?1:0;
      se[i]=(direction!=MICAL_LONG && MicalValid(rank[i]) && rank[i]>0.90)?1:0;
      int ld=(i>0)?(int)long_due[i-1]:-1,sd=(i>0)?(int)short_due[i-1]:-1;
      lx[i]=(ld>=0 && i>=ld)?1:0; sx[i]=(sd>=0 && i>=sd)?1:0;
      if(lx[i]==1) ld=-1; else if(ld<0 && le[i]==1) ld=i+hold;
      if(sx[i]==1) sd=-1; else if(sd<0 && se[i]==1) sd=i+hold;
      long_due[i]=ld; short_due[i]=sd;
   }
}
#endif
