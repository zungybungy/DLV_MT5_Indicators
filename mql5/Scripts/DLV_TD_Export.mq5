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
input string InpOnly="";   // comma-separated CSV names to export (e.g. "TD_SEQ,TD_POINT_L1"); empty = all

bool Want(const string name) { return InpOnly=="" || StringFind(","+InpOnly+",",","+name+",")>=0; }

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
   FileWriteString(file,"indicator,time,Open,High,Low,Close,Volume,"+header+"\n");
   for(int i=0;i<count-1;i++)
   {
      string row=name+","+IntegerToString((long)rates[i].time)+","+Cell(rates[i].open)+","+
                 Cell(rates[i].high)+","+Cell(rates[i].low)+","+Cell(rates[i].close)+","+
                 IntegerToString(rates[i].tick_volume);   // the Lab maps MT5 tick_volume to Volume
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
   if(Want("TD_SEQ") && !Export("TD_SEQ",iCustom(_Symbol,_Period,"TD_DLV_v3.6","",INT_MAX),14,
      "tdst_resistance,tdst_support,setup,countdown,perfection,"+
      "buy_setup_risk_a,sell_setup_risk_a,buy_setup_risk_b,sell_setup_risk_b,"+
      "buy_countdown_risk_a,sell_countdown_risk_a,buy_countdown_risk_b,sell_countdown_risk_b,"+
      "aggressive_countdown",prefix)) return;
   if(Want("TD_MA1") && !Export("TD_MA1",iCustom(_Symbol,_Period,"DLV_TD_MA","",5,12,4,INT_MAX),2,
      "bullish,bearish",prefix)) return;
   for(int level=1;level<=3;level+=2)
      if(Want("TD_POINT_L"+IntegerToString(level)) && !Export("TD_POINT_L"+IntegerToString(level),iCustom(_Symbol,_Period,"DLV_TD_Point","",level),6,
         "demand,supply,demand_confirmed,supply_confirmed,prior_demand,prior_supply",prefix)) return;
   // TD_REI, native DeMarker, TD_COMBO (Versions 1 and 2), TD_DWAVE
   if(Want("TD_REI") && !Export("TD_REI",iCustom(_Symbol,_Period,"DLV_TD_REI","",5),1,"rei",prefix)) return;
   // DEMARKER is the terminal's native iDeMarker (no DLV source), compared with the Lab's DEMARKER(14).
   if(Want("DEMARKER") && !Export("DEMARKER",iDeMarker(_Symbol,_Period,14),1,"demarker",prefix)) return;
   for(int version=1;version<=2;version++)
      if(Want("TD_COMBO_P"+IntegerToString(version)) && !Export("TD_COMBO_P"+IntegerToString(version),
         iCustom(_Symbol,_Period,"DLV_TD_Combo","",version),6,
         "buy_setup,sell_setup,buy_countdown,sell_countdown,buy_risk,sell_risk",prefix)) return;
   if(Want("TD_DWAVE") && !Export("TD_DWAVE",iCustom(_Symbol,_Period,"DLV_TD_DWave"),10,
      "bull_code,bear_code,bull_event,bear_event,bull_w3,bear_w3,bull_w5,bear_w5,bull_wc,bear_wc",prefix)) return;

   // DLV_TD_Patterns (14 pseudos): defaults, then every param changed
   // Inputs must match B2_PATTERN_PARAMS in check_td_parity.py. Buffers 0-39 only
   // (40-55 are arrow drawing copies). Groups: Pressure, ROC, Channel I, REBO, Propulsion.
   string patterns="diff_up,diff_down,revdiff_up,revdiff_down,antidiff_up,antidiff_down,"+
                   "open_buy,open_sell,clop_buy,clop_sell,clopwin_buy,clopwin_sell,camo_buy,camo_sell,"+
                   "trap_buy,trap_sell,pressure,roc,chan1_upper,chan1_lower,"+
                   "rebo_upper1,rebo_upper2,rebo_lower1,rebo_lower2,rebo_upper_q1,rebo_upper_q3,"+
                   "rebo_lower_q1,rebo_lower_q3,rebo_upper_ok,rebo_lower_ok,rebo_upper_bad,rebo_lower_bad,"+
                   "rp_high,rp_low,rp_tol_up,rp_tol_down,"+
                   "prop_up_threshold,prop_up_target,prop_down_threshold,prop_down_target";
   if(Want("TD_PATTERNS") && !Export("TD_PATTERNS",iCustom(_Symbol,_Period,"DLV_TD_Patterns",
      "",5,"",12,"",3,1.03,0.97,"",0.382,0.618,"",3,0.236,0.472),40,patterns,prefix)) return;
   if(Want("TD_PATTERNS_ALT") && !Export("TD_PATTERNS_ALT",iCustom(_Symbol,_Period,"DLV_TD_Patterns",
      "",3,"",10,"",5,1.09,0.91,"",0.25,0.5,"",1,0.25,0.5),40,patterns,prefix)) return;

   // TD_WALDO2-8, TD_TREND_FACTOR, TD_REL/ABS_RETRACEMENT, TD_LINES
   // Inputs must match B3_* in check_td_parity.py. Defaults first, then one materially different set.
   string waldo="w2_bottom,w2_top,w3_upside,w3_downside,w4_bottom,w4_top,w5_bottom,w5_top,"+
                "w6_bottom,w6_top,w7_bottom,w7_top,w8_bottom,w8_top";
   if(Want("TD_WALDO") && !Export("TD_WALDO",iCustom(_Symbol,_Period,"DLV_TD_Waldo","",21,"",2.0,"",10,"",8,"",7,5),
      14,waldo,prefix)) return;
   if(Want("TD_WALDO_ALT") && !Export("TD_WALDO_ALT",iCustom(_Symbol,_Period,"DLV_TD_Waldo","",10,"",1.5,"",5,"",4,"",5,3),
      14,waldo,prefix)) return;
   if(Want("TD_TREND_FACTOR") && !Export("TD_TREND_FACTOR",iCustom(_Symbol,_Period,"DLV_TD_TrendFactor","",3,0.0556),
      6,"dn1,dn2,dn3,up1,up2,up3",prefix)) return;
   if(Want("TD_TREND_FACTOR_L1") && !Export("TD_TREND_FACTOR_L1",iCustom(_Symbol,_Period,"DLV_TD_TrendFactor","",1,0.0556),
      6,"dn1,dn2,dn3,up1,up2,up3",prefix)) return;
   string retracement="rel_upside,rel_downside,rel_up_magnet,rel_down_magnet,rel_upper_ok,rel_lower_ok,"+
                      "rel_upper_bad,rel_lower_bad,abs_upside,abs_downside";
   if(Want("TD_RETRACEMENT") && !Export("TD_RETRACEMENT",
      iCustom(_Symbol,_Period,"DLV_TD_Retracement","",1,0.382,"",1.382,0.618),10,retracement,prefix)) return;
   if(Want("TD_RETRACEMENT_L3") && !Export("TD_RETRACEMENT_L3",
      iCustom(_Symbol,_Period,"DLV_TD_Retracement","",3,0.618,"",1.618,0.5),10,retracement,prefix)) return;
   string lines="demand,supply,demand_q1,demand_q2,demand_q3,supply_q1,supply_q2,supply_q3,"+
                "demand_ok,supply_ok,demand_bad,supply_bad,demand_objective,supply_objective";
   if(Want("TD_LINES_L1") && !Export("TD_LINES_L1",iCustom(_Symbol,_Period,"DLV_TD_Lines","",1,400,1.0),
      14,lines,prefix)) return;
   if(Want("TD_LINES_L3") && !Export("TD_LINES_L3",iCustom(_Symbol,_Period,"DLV_TD_Lines","",3,25,1.618),
      14,lines,prefix)) return;

   Print("TD export finished: ",TerminalInfoString(TERMINAL_COMMONDATA_PATH),"\\Files\\",prefix,"_*.csv");
}
