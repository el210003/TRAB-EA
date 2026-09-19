//+------------------------------------------------------------------+
//|                                                        TRAB_SnR.mq5 |
//|        H4 Support/Resistance + M1 EMA entry                       |
//|                                                                  |
//| Strategy: H4 Donchian channel (recent swing high/low) defines the |
//|   key S/R levels. When M1 price interacts with an H4 level and the |
//|   M1 EMA20/50 pair turns in the expected direction, enter. The     |
//|   stop is set BEYOND the H4 level (wide), so M1 spread/slippage    |
//|   is negligible vs the level distance.                            |
//+------------------------------------------------------------------+
#property copyright   "TRAB"
#property link        ""
#property version     "1.00"
#property description "H4 S/R level + M1 EMA entry (reversal/bounce off the level)"
#include <Trade\Trade.mqh>

input group "=== H4 S/R Levels ==="
input ENUM_TIMEFRAMES InpH4TF       = PERIOD_H4;   // Level timeframe
input int    InpH4ChannelLen        = 8;          // H4 Donchian channel length (bars) -> S/R
input double InpLevelTouchPadPips   = 5.0;        // Price is "at the level" within this pad (pips)

input group "=== M1 EMA Trigger ==="
input ENUM_TIMEFRAMES InpM1TF       = PERIOD_M1;   // Entry/trigger timeframe
input int    InpM1FastPeriod        = 20;         // M1 fast EMA
input int    InpM1SlowPeriod        = 50;         // M1 slow EMA
input bool   InpTradeReversal       = true;       // true = bounce off level; false = break-continuation

input group "=== Risk & Exit ==="
input double InpATRMultSL           = 1.0;        // extra ATR buffer beyond the level for the SL
input double InpRiskPercent         = 1.0;        // Risk % equity (0 = fixed lots)
input double InpFixedLots           = 0.10;       // Fixed lots
input double InpTrailATRMult        = 2.0;        // Trailing distance = x ATR beyond M1 fast EMA
input double InpTrailActivateRR     = 1.0;        // Trailing activation (x initial risk)
input double InpMaxSpreadPips       = 2.0;        // Spread gate
input int    InpATRPeriod           = 14;         // ATR period for SL/trail buffer
input int    InpMaxBarsInTrade      = 0;          // Time-stop (M1 bars) <0 = off

input group "=== General ==="
input long   InpMagic               = 20253001;   // Magic number
input string InpComment             = "TRAB-SR";
input bool   InpShowPanel           = true;

//+------------------------------------------------------------------+
CTrade g_trade;
int    g_hH4Hi = INVALID_HANDLE, g_hH4Lo = INVALID_HANDLE;
int    g_hM1F  = INVALID_HANDLE, g_hM1S  = INVALID_HANDLE;
int    g_hATR  = INVALID_HANDLE;
double g_point=0, g_pip=0; int g_digits=0;
datetime g_lastBar=0;
ulong  g_ticket=0; long g_posID=0; double g_initialRisk=0; bool g_trailActive=false;
int    g_barsIn=0;

void Log(const string m){ Print("TRAB-SR: ", m); }
double PipToPrice(double p){ return p*g_pip; }

int OnInit()
  {
   g_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_pip=(g_digits==3||g_digits==5)?g_point*10.0:g_point;
   if(g_point<=0.0||g_pip<=0.0){Log("INIT FAILED: point/pip");return INIT_FAILED;}
   if(InpH4ChannelLen<2||InpM1FastPeriod<=0||InpM1SlowPeriod<=0||InpATRPeriod<=0||InpRiskPercent<0.0||InpFixedLots<=0.0||InpMaxSpreadPips<=0.0)
     {Log("INIT FAILED: inputs");return INIT_PARAMETERS_INCORRECT;}
   g_hH4Hi=INVALID_HANDLE;   // H4 Donchian computed via CopyRates in H4Level()
   g_hM1F=iMA(_Symbol,InpM1TF,InpM1FastPeriod,0,MODE_EMA,PRICE_CLOSE);
   g_hM1S=iMA(_Symbol,InpM1TF,InpM1SlowPeriod,0,MODE_EMA,PRICE_CLOSE);
   g_hATR=iATR(_Symbol,InpM1TF,InpATRPeriod);
   if(g_hM1F==INVALID_HANDLE||g_hM1S==INVALID_HANDLE||g_hATR==INVALID_HANDLE)
     {Log("INIT FAILED: handles");return INIT_FAILED;}
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   Log(StringFormat("initialized | H4 ch%d level + M1 EMA%d/%d | reversal=%s",
                    InpH4ChannelLen,InpM1FastPeriod,InpM1SlowPeriod, InpTradeReversal?"yes":"no"));
   Adopt();
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int r)
  { if(g_hM1F!=INVALID_HANDLE) IndicatorRelease(g_hM1F);
    if(g_hM1S!=INVALID_HANDLE) IndicatorRelease(g_hM1S);
    if(g_hATR!=INVALID_HANDLE) IndicatorRelease(g_hATR);
    Comment(""); }
bool IsNewBar(){ datetime t=iTime(_Symbol,InpM1TF,0); if(t==0||t==g_lastBar)return false; g_lastBar=t; return true; }
bool HasOpen(ulong &tk){ for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i); if(t==0)continue; if(PositionGetString(POSITION_SYMBOL)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==InpMagic){tk=t;return true;}} return false; }

void OnTick(){ ManageOpen(); if(IsNewBar()){ if(g_ticket!=0) g_barsIn++; Evaluate(); } if(InpShowPanel) Panel(); }

// H4 Donchian channel over prior InpH4ChannelLen bars (index 1..N)
bool H4Level(double &hi, double &lo)
  {
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,InpH4TF,1,InpH4ChannelLen+1,r)<InpH4ChannelLen+1) return false;
   hi=-DBL_MAX; lo=DBL_MAX;
   for(int i=1;i<=InpH4ChannelLen;i++){ if(r[i].high>hi)hi=r[i].high; if(r[i].low<lo)lo=r[i].low; }
   return true;
  }

void Evaluate()
  {
   ulong tk=0; if(HasOpen(tk)) return;
   double hRes, hSup;
   if(!H4Level(hRes,hSup)) return;
   // M1 current close
   MqlRates r1[]; ArraySetAsSeries(r1,true);
   if(CopyRates(_Symbol,InpM1TF,1,1,r1)<1) return;
   const double cl=r1[0].close, hi=r1[0].high, lo=r1[0].low;
   double mf[], ms[];
   ArraySetAsSeries(mf,true); ArraySetAsSeries(ms,true);
   if(CopyBuffer(g_hM1F,0,1,2,mf)<2||CopyBuffer(g_hM1S,0,1,2,ms)<2) return;
   const double e20=mf[0], e50=ms[0], e20p=mf[1], e50p=ms[1];
   const bool bull=(e20>e50)&&(e20p<=e50p);
   const bool bear=(e20<e50)&&(e20p>=e50p);
   const double pad=PipToPrice(InpLevelTouchPadPips);

   int dir=0;
   if(InpTradeReversal)
     {
      // bounce off the level in the M1-EMA-triggered direction
      if(lo<=hSup+pad && bull) dir=+1;      // touched H4 support (low) + M1 bull turn
      else if(hi>=hRes-pad && bear) dir=-1; // touched H4 resistance + M1 bear turn
     }
   else
     {
      // break-continuation: M1 closes through the H4 level + M1 EMA confirms
      if(cl>hRes && bull) dir=+1;
      else if(cl<hSup && bear) dir=-1;
     }
   if(dir==0) return;
   TryEnter(dir,hRes,hSup);
  }

void TryEnter(const int dir, const double hRes, const double hSup)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;
   const double spread=(tick.ask-tick.bid)/g_pip;
   if(spread>InpMaxSpreadPips){Log("ENTRY ABORTED: spread "+DoubleToString(spread,1));return;}
   double atr[]; ArraySetAsSeries(atr,true);
   if(CopyBuffer(g_hATR,0,1,1,atr)<1||atr[0]<=0.0) return;
   double entry,sl,risk;
   if(dir>0)  { entry=tick.ask; sl=hSup - InpATRMultSL*atr[0]; if(sl>=entry) sl=entry - InpATRMultSL*atr[0]; }
   else       { entry=tick.bid; sl=hRes + InpATRMultSL*atr[0]; if(sl<=entry) sl=entry + InpATRMultSL*atr[0]; }
   risk=MathAbs(entry-sl); if(risk<=0.0) return;
   const double lots=ComputeLots(risk,entry,dir); if(lots<=0.0) return;
   const double slN=NormalizeDouble(sl,g_digits);
   bool sent=(dir>0)?g_trade.Buy(lots,_Symbol,0.0,slN,0.0,InpComment):g_trade.Sell(lots,_Symbol,0.0,slN,0.0,InpComment);
   uint ret=g_trade.ResultRetcode();
   if(sent&&(ret==TRADE_RETCODE_DONE||ret==TRADE_RETCODE_DONE_PARTIAL||ret==TRADE_RETCODE_PLACED))
     { ulong t2=0; if(HasOpen(t2)){ g_ticket=t2; if(PositionSelectByTicket(t2)){ g_initialRisk=MathAbs(PositionGetDouble(POSITION_PRICE_OPEN)-slN); g_posID=(long)PositionGetInteger(POSITION_IDENTIFIER);} g_trailActive=false; g_barsIn=0; }
       Log(StringFormat(">>> %s %.2f | SL %.5f | risk %.1f pips",dir>0?"BUY":"SELL",lots,slN,risk/g_pip)); }
   else Log("OrderSend FAILED "+IntegerToString(ret));
  }

double ComputeLots(const double riskDist,const double price,const int dir)
  { double lots=0.0; if(InpRiskPercent<=0.0)lots=InpFixedLots;
    else{ double rm=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0; double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE); double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); if(tv<=0.0||ts<=0.0)return 0.0; double perLot=riskDist/ts*tv; if(perLot<=0.0)return 0.0; lots=rm/perLot; }
    double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    if(st>0.0)lots=MathFloor(lots/st)*st; if(lots>mx)lots=mx; return (lots<mn)?0.0:lots; }

void ManageOpen()
  {
   if(g_ticket==0)return;
   if(!PositionSelectByTicket(g_ticket)){ LogClosed(); g_ticket=0;g_posID=0;g_trailActive=false; return; }
   const long type=PositionGetInteger(POSITION_TYPE); const double open=PositionGetDouble(POSITION_PRICE_OPEN); const double sl=PositionGetDouble(POSITION_SL);
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick))return;
   if(g_initialRisk<=0.0){ if(sl>0.0)g_initialRisk=MathAbs(open-sl); else return; }
   if(InpMaxBarsInTrade>0&&g_barsIn>=InpMaxBarsInTrade){ g_trade.PositionClose(g_ticket); return; }
   const double prof=(type==POSITION_TYPE_BUY)?(tick.bid-open):(open-tick.ask);
   if(prof<InpTrailActivateRR*g_initialRisk)return;
   if(!g_trailActive){g_trailActive=true;Log("trailing activated");}
   double mf[]; ArraySetAsSeries(mf,true); if(CopyBuffer(g_hM1F,0,1,1,mf)<1)return;
   double atr[]; ArraySetAsSeries(atr,true); if(CopyBuffer(g_hATR,0,1,1,atr)<1||atr[0]<=0.0)return;
   const double stopsLevel=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*g_point;
   if(type==POSITION_TYPE_BUY){ double cand=NormalizeDouble(mf[0]-InpTrailATRMult*atr[0],g_digits); if(cand>sl&&cand<=tick.bid-stopsLevel&&cand<tick.bid)g_trade.PositionModify(g_ticket,cand,0.0); }
   else{ double cand=NormalizeDouble(mf[0]+InpTrailATRMult*atr[0],g_digits); if((sl==0.0||cand<sl)&&cand>=tick.ask+stopsLevel&&cand>tick.ask)g_trade.PositionModify(g_ticket,cand,0.0); }
  }

void LogClosed()
  { if(g_posID==0)return; double net=0.0;
    if(HistorySelectByPosition(g_posID)) for(int i=0;i<HistoryDealsTotal();i++){ulong d=HistoryDealGetTicket(i); if(d)net+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);}
    double r=0.0; if(g_initialRisk>0.0){double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); double perLot=(tv>0&&ts>0)?(g_initialRisk/ts*tv):0.0; r=(perLot>0.0)?net/perLot:0.0;}
    Log(StringFormat("position #%I64u CLOSED - net %s%.2fR / %.2f USD",(ulong)g_posID,r>=0.0?"+":"",r,net)); }

void Adopt()
  { ulong tk=0; if(!HasOpen(tk))return; g_ticket=tk; if(PositionSelectByTicket(tk)){double open=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL); g_initialRisk=(sl>0.0)?MathAbs(open-sl):0.0; g_posID=(long)PositionGetInteger(POSITION_IDENTIFIER);} }

void Panel()
  { double hRes,hSup; H4Level(hRes,hSup);
    string s="TRAB-SnR v1.00 | "+_Symbol+" H4 level + M1 EMA\n";
    s+=StringFormat("H4 S/R: %.5f / %.5f | Pos: %s\n",hSup,hRes, g_ticket!=0?"OPEN":"flat");
    Comment(s); }
//+------------------------------------------------------------------+
