//+------------------------------------------------------------------+
//|                                                  TRAB_Breakout.mq5 |
//|        Channel-breakout trend-follower (Donchian + ATR)           |
//|                                                                  |
//| Strategy: price-structure BREAKOUT, not EMA cross. Enter when a   |
//|   bar closes beyond the highest/lowest high/low of the prior N    |
//|   bars (Donchian channel). Filtered by a higher-TF trend regime.  |
//|   Wide ATR stop; trailing behind a Donchian/MATR low to let the   |
//|   trend run (no fixed TP). Designed for ~1+ trades/day.           |
//+------------------------------------------------------------------+
#property copyright   "TRAB"
#property link        ""
#property version     "1.00"
#property description "Donchian channel breakout trend-follower with ATR stop + trailing"
#include <Trade\Trade.mqh>

input group "=== Channel Breakout ==="
input ENUM_TIMEFRAMES InpEntryTF     = PERIOD_H1;   // Entry timeframe (attach chart)
input ENUM_TIMEFRAMES InpChannelTF    = PERIOD_H1;   // Donchian channel timeframe (breakout level)
input int    InpChannelLen           = 20;         // Donchian channel length (bars)
input bool   InpUseCloseBreak        = true;       // Trade close beyond channel (vs just wick)
input bool   InpUsePullbackReentry   = false;      // H1 breakout arms; M15 pullback re-entry (better entry)
input int    InpEntryFastPeriod      = 20;         // Entry-TF fast EMA (pullback resume confirm)
input double InpPullbackPadPips      = 3.0;        // Tolerance to the H1 breakout level for the pullback
input int    InpArmTimeoutBars       = 48;         // Entry-TF bars to find the pullback after an H1 breakout
input ENUM_TIMEFRAMES InpTrendTF     = PERIOD_H4;   // Trend-filter timeframe
input int    InpTrendEmaFast         = 20;         // Trend fast EMA
input int    InpTrendEmaSlow         = 50;         // Trend slow EMA
input bool   InpUseTrendFilter       = true;       // Only trade in the higher-TF trend direction

input group "=== Risk & Exit ==="
input int    InpATRPeriod            = 14;         // ATR period (entry TF)
input double InpATRMultSL            = 2.5;        // SL distance = x ATR
input double InpRiskPercent          = 1.0;        // Risk % equity (0 = fixed lots)
input double InpFixedLots            = 0.10;       // Fixed lots
input int    InpTrailChannelLen      = 10;         // Trail behind this Donchian low/high
input double InpTrailATRMult         = 1.5;        // Extra ATR beyond the trail level
input double InpTrailActivateRR      = 1.0;        // Trailing activation (x initial risk)
input bool   InpUseTrailing          = true;       // Enabling trailing
input double InpBreakevenRR          = 0.0;        // Move SL to breakeven after this x risk (0 = off)
input double InpBreakevenBufferPips  = 0.5;        // Breakeven buffer beyond entry
input double InpTakeProfitRR         = 0.0;        // Fixed hit-and-run TP at x risk (0 = trail only)
input double InpMaxSLPips            = 0.0;        // Skip breakout if SL > this (pips); 0 = off (volatility filter)
input double InpMaxSpreadPips        = 2.0;        // Spread gate
input int    InpMaxBarsInTrade       = 96;         // Time-stop (bars) <0 = off

input group "=== General ==="
input long   InpMagic                = 20252001;   // Magic number
input string InpComment              = "TRAB-B";
input bool   InpShowPanel            = true;

//+------------------------------------------------------------------+
CTrade g_trade;
int    g_hATR     = INVALID_HANDLE;
int    g_hTrF     = INVALID_HANDLE;
int    g_hTrS     = INVALID_HANDLE;
double g_point = 0.0, g_pip = 0.0;
int    g_digits = 0;
ulong  g_dev = 0;
datetime g_lastBar = 0;

ulong  g_ticket = 0;
long   g_posID = 0;
double g_initialRisk = 0.0;
bool   g_trailActive = false;
int    g_barsIn = 0;
int    g_dirArmed = 0;      // H1 breakout arm direction
int    g_hEnF = INVALID_HANDLE;
int    g_hADX = INVALID_HANDLE;
int    g_hRSI = INVALID_HANDLE;
int    g_hChEF = INVALID_HANDLE;
double g_armLevel = 0.0;
datetime g_armTime = 0;
double g_chanHi = 0.0, g_chanLo = 0.0;   // last channel level (for feature logging)
datetime g_lastEntry = 0;

void Log(const string m) { Print("TRAB-B: ", m); }
double PipToPrice(double p) { return p * g_pip; }

int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = (g_digits == 3 || g_digits == 5) ? g_point * 10.0 : g_point;
   if(g_point <= 0.0 || g_pip <= 0.0) { Log("INIT FAILED: point/pip"); return(INIT_FAILED); }
   if(InpATRPeriod <= 0 || InpChannelLen < 2 || InpRiskPercent < 0.0 || InpFixedLots <= 0.0 ||
      InpATRMultSL <= 0.0 || InpTrailActivateRR <= 0.0 || InpMaxSpreadPips <= 0.0)
     { Log("INIT FAILED: invalid inputs"); return(INIT_PARAMETERS_INCORRECT); }

   g_hATR = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   g_hTrF = iMA(_Symbol, InpTrendTF, InpTrendEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hTrS = iMA(_Symbol, InpTrendTF, InpTrendEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hEnF = iMA(_Symbol, InpEntryTF, InpEntryFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hADX  = iADX(_Symbol, InpChannelTF, 14);
   g_hRSI  = iRSI(_Symbol, InpChannelTF, 14, PRICE_CLOSE);
   g_hChEF = iMA(_Symbol, InpChannelTF, 20, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hATR == INVALID_HANDLE || g_hTrF == INVALID_HANDLE || g_hTrS == INVALID_HANDLE || g_hEnF == INVALID_HANDLE || g_hADX == INVALID_HANDLE || g_hRSI == INVALID_HANDLE || g_hChEF == INVALID_HANDLE)
     { Log("INIT FAILED: handles"); return(INIT_FAILED); }

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   Log(StringFormat("initialized | channel %d | TF %s @ %s | SL %.1f ATR",
                    InpChannelLen, EnumToString(InpTrendTF), EnumToString(InpEntryTF), InpATRMultSL));
   Adopt();
   return(INIT_SUCCEEDED);
  }
void OnDeinit(const int r)
  {
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hTrF != INVALID_HANDLE) IndicatorRelease(g_hTrF);
   if(g_hTrS != INVALID_HANDLE) IndicatorRelease(g_hTrS);
   if(g_hEnF != INVALID_HANDLE) IndicatorRelease(g_hEnF);
   if(g_hADX != INVALID_HANDLE) IndicatorRelease(g_hADX);
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hChEF != INVALID_HANDLE) IndicatorRelease(g_hChEF);
   Comment("");
  }
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, InpEntryTF, 0);
   if(t == 0 || t == g_lastBar) return false;
   g_lastBar = t;
   return true;
  }
bool HasOpenPosition(ulong &tk)
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
        { tk = t; return true; }
     }
   return false;
  }
void OnTick()
  {
   ManageOpen();
   if(IsNewBar())
     {
      if(g_ticket != 0) g_barsIn++;
      Evaluate();
     }
   if(InpShowPanel) Panel();
  }

// signal: close beyond prior-N-bar Donchian; filtered by higher-TF trend
//+------------------------------------------------------------------+
//| Pullback re-entry: H1 breakout arms the setup; M15 pullback re-   |
//| entry times the trade for a better price + tighter SL.             |
//+------------------------------------------------------------------+
void EvaluatePullback()
  {
   // 1) arm on a real H1-close breakout (channel timeframe)
   datetime tH1 = iTime(_Symbol, InpChannelTF, 0);
   bool h1New = (tH1 != g_armTime);
   if(h1New)
     {
      MqlRates rc[];
      ArraySetAsSeries(rc, true);
      if(CopyRates(_Symbol, InpChannelTF, 2, InpChannelLen+1, rc) >= InpChannelLen+1)
        {
         double hi=-DBL_MAX, lo=DBL_MAX;
         for(int i=1;i<=InpChannelLen;i++){ if(rc[i].high>hi)hi=rc[i].high; if(rc[i].low<lo)lo=rc[i].low; }
         const double h1c = rc[0].close;               // last closed H1 bar close
         if(h1c > hi){ g_dirArmed=+1; g_armLevel=hi; }
         else if(h1c < lo){ g_dirArmed=-1; g_armLevel=lo; }
         else g_dirArmed=0;
         g_armTime = tH1;
        }
     }
   if(g_dirArmed == 0) return;
   // arm timeout
   if(InpArmTimeoutBars > 0 && iBarShift(_Symbol, InpEntryTF, g_armTime) > InpArmTimeoutBars){ g_dirArmed=0; return; }

   // 2) M15 pullback to the broken level + resume confirmation
   MqlRates r1[]; ArraySetAsSeries(r1, true);
   if(CopyRates(_Symbol, InpEntryTF, 1, 1, r1) < 1) return;
   const double cl=r1[0].close, hi=r1[0].high, lo=r1[0].low, op=r1[0].open;
   double ef[]; ArraySetAsSeries(ef, true);
   if(CopyBuffer(g_hEnF, 0, 1, 1, ef) < 1) return;
   const double e20 = ef[0];
   const double pad = PipToPrice(InpPullbackPadPips);
   int dir = 0;
   if(g_dirArmed > 0) { if(lo <= g_armLevel + pad && cl > e20 && cl > op) dir=+1; }   // pulled to support, closed back up
   else               { if(hi >= g_armLevel - pad && cl < e20 && cl < op) dir=-1; }
   if(dir == 0) return;
   TryEnter(dir);
  }

//+------------------------------------------------------------------+
//| Channel-breakout signal (close beyond Donchian)                   |
//+------------------------------------------------------------------+
void Evaluate()
  {
   ulong tk = 0;
   if(HasOpenPosition(tk)) return;
   if(InpUsePullbackReentry) { EvaluatePullback(); return; }

   // Donchian channel on the CHANNEL timeframe (e.g. H1)
   MqlRates rc[];
   ArraySetAsSeries(rc, true);
   if(CopyRates(_Symbol, InpChannelTF, 1, InpChannelLen+1, rc) < InpChannelLen+1) return;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 1; i <= InpChannelLen; i++)
     { if(rc[i].high > hi) hi = rc[i].high; if(rc[i].low < lo) lo = rc[i].low; }

   // entry timed on the ENTRY timeframe (e.g. M15)
   MqlRates r1[];
   ArraySetAsSeries(r1, true);
   if(CopyRates(_Symbol, InpEntryTF, 1, 1, r1) < 1) return;
   const double cl = r1[0].close;

   int dir = 0;
   if(InpUseCloseBreak && cl > hi)      dir = +1;
   else if(InpUseCloseBreak && cl < lo) dir = -1;
   if(dir == 0) return;
   g_chanHi = hi;                         // expose channel to TryEnter for feature logging
   g_chanLo = lo;

   if(InpUseTrendFilter)
     {
      double tf[], ts[];
      ArraySetAsSeries(tf, true); ArraySetAsSeries(ts, true);
      if(CopyBuffer(g_hTrF, 0, 1, 1, tf) < 1 || CopyBuffer(g_hTrS, 0, 1, 1, ts) < 1) return;
      const long bias = (tf[0] > ts[0]) ? +1 : (tf[0] < ts[0] ? -1 : 0);
      if(bias == 0 || bias != dir) return;
     }
   TryEnter(dir);
  }

//+------------------------------------------------------------------+
//| Extra ML features: ADX, RSI, EMA slope, session                  |
//+------------------------------------------------------------------+
double ADXVal()
  {
   double b[]; ArraySetAsSeries(b, true);
   return (CopyBuffer(g_hADX, 0, 1, 1, b) >= 1) ? b[0] : 0.0;
  }
double RSIVal()
  {
   double b[]; ArraySetAsSeries(b, true);
   return (CopyBuffer(g_hRSI, 0, 1, 1, b) >= 1) ? b[0] : 50.0;
  }
double SlopeVal()
  {
   double a[], c[]; ArraySetAsSeries(a, true); ArraySetAsSeries(c, true);
   if(CopyBuffer(g_hChEF, 0, 1, 5, a) < 5) return 0.0;
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) return 0.0;
   return (a[0] - a[4]) / atr[0];      // channel-TF EMA20 slope over 4 bars, normalized by ATR
  }
int SessionVal(const int hour)
  {
   if(hour >= 7 && hour < 12) return 1;   // London
   if(hour >= 12 && hour < 20) return 2;  // NY / overlap
   if(hour >= 0 && hour < 7)   return 0;  // Asia
   return 3;                              // late NY
  }
double VolRatio()
  {
   double a[]; ArraySetAsSeries(a, true);
   if(CopyBuffer(g_hATR, 0, 1, 20, a) < 20 || a[0] <= 0.0) return 1.0;
   double s = 0.0;
   for(int i = 0; i < 20; i++) s += a[i];
   return a[0] / (s / 20.0);              // current ATR vs 20-bar average (vol regime)
  }
double ADXSlope()
  {
   double a[]; ArraySetAsSeries(a, true);
   return (CopyBuffer(g_hADX, 0, 1, 5, a) >= 5) ? (a[0] - a[4]) : 0.0;
  }
double RsiSlope()
  {
   double a[]; ArraySetAsSeries(a, true);
   return (CopyBuffer(g_hRSI, 0, 1, 5, a) >= 5) ? (a[0] - a[4]) : 0.0;
  }
double BodyRatio()
  {
   MqlRates r[]; ArraySetAsSeries(r, true);
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyRates(_Symbol, InpEntryTF, 1, 1, r) < 1) return 0.0;
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) return 0.0;
   return MathAbs(r[0].close - r[0].open) / atr[0];   // breakout candle body in ATR
  }
int HtfAlign()
  {
   double f[], s[]; ArraySetAsSeries(f, true); ArraySetAsSeries(s, true);
   if(CopyBuffer(g_hTrF, 0, 1, 1, f) < 1 || CopyBuffer(g_hTrS, 0, 1, 1, s) < 1) return 0;
   return (f[0] > s[0]) ? +1 : (f[0] < s[0] ? -1 : 0);   // H4 trend alignment
  }
int GapSince()
  {
   if(g_lastEntry == 0) return 99;
   const int bars = iBarShift(_Symbol, InpEntryTF, g_lastEntry);
   return (bars >= 0) ? bars : 99;
  }

//+------------------------------------------------------------------+
//| Log per-trade entry features for the ML filter                    |
//+------------------------------------------------------------------+
void LogExitFeatures(const int dir, const double risk)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   double atr[]; ArraySetAsSeries(atr, true);
   double atrVal = 0.0;
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) >= 1) atrVal = atr[0];
   const double span = g_chanHi - g_chanLo;
   const double px  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mag = 0.0, pos = 0.5, cw = 0.0;
   if(atrVal > 0.0)
     {
      mag = (dir > 0) ? (px - g_chanHi)/atrVal : (g_chanLo - px)/atrVal;
      cw  = span/atrVal;
      if(span > 0.0) pos = (px - g_chanLo)/span;
     }
   Log(StringFormat("FEAT %I64d dir=%d hh=%02d dd=%d atr=%.4f mag=%.3f pos=%.3f cw=%.3f risk=%.2f adx=%.1f rsi=%.1f slop=%.2f vr=%.2f adxS=%.1f body=%.2f htf=%d rsiS=%.1f gap=%d",
                    (long)g_posID, dir, dt.hour, dt.day_of_week, atrVal, mag, pos, cw, risk/g_pip,
                    ADXVal(), RSIVal(), SlopeVal(), VolRatio(), ADXSlope(),
                    BodyRatio(), HtfAlign(), RsiSlope(), GapSince()));
  }

void TryEnter(const int dir)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   const double spread = (tick.ask - tick.bid) / g_pip;
   if(spread > InpMaxSpreadPips) { Log("ENTRY ABORTED: spread " + DoubleToString(spread,1)); return; }

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1) return;
   const double av = atr[0];
   if(av <= 0.0) return;

   double entry, sl;
   if(dir > 0) { entry = tick.ask; sl = entry - InpATRMultSL * av; }
   else        { entry = tick.bid; sl = entry + InpATRMultSL * av; }
   const double risk = MathAbs(entry - sl);
   if(InpMaxSLPips > 0.0 && risk/g_pip > InpMaxSLPips)
     { Log(StringFormat("SKIP high-vol breakout: SL %.1f pips > max %.1f", risk/g_pip, InpMaxSLPips)); return; }
   if(risk <= 0.0) return;

   const double lots = ComputeLots(risk, entry, dir);
   if(lots <= 0.0) return;

   const double slN = NormalizeDouble(sl, g_digits);
   double tp = 0.0;
   if(InpTakeProfitRR > 0.0) tp = (dir > 0) ? entry + InpTakeProfitRR * risk : entry - InpTakeProfitRR * risk;
   const double tpN = NormalizeDouble(tp, g_digits);
   bool sent = (dir > 0) ? g_trade.Buy(lots, _Symbol, 0.0, slN, tpN, InpComment)
                         : g_trade.Sell(lots, _Symbol, 0.0, slN, tpN, InpComment);
   uint ret = g_trade.ResultRetcode();
   if(sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
     {
      ulong tk = 0;
      if(HasOpenPosition(tk))
        {
         g_ticket = tk;
         if(PositionSelectByTicket(tk))
           {
            g_initialRisk = MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - slN);
            g_posID = (long)PositionGetInteger(POSITION_IDENTIFIER);
           }
         g_trailActive = false; g_barsIn = 0;
         g_lastEntry = iTime(_Symbol, InpEntryTF, 0);
         LogExitFeatures(dir, risk);
        }
      Log(StringFormat(">>> %s %s | SL %.5f | risk %.1f pips", dir>0?"BUY":"SELL", DoubleToString(lots,2), slN, risk/g_pip));
     }
   else Log("OrderSend FAILED " + IntegerToString(ret));
  }

double ComputeLots(const double riskDist, const double price, const int dir)
  {
   double lots = 0.0;
   if(InpRiskPercent <= 0.0) lots = InpFixedLots;
   else
     {
      double rm = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0.0 || ts <= 0.0) return 0.0;
      double perLot = riskDist / ts * tv;
      if(perLot <= 0.0) return 0.0;
      lots = rm / perLot;
     }
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st > 0.0) lots = MathFloor(lots / st) * st;
   if(lots > mx) lots = mx;
   return (lots < mn) ? 0.0 : lots;
  }

// trail behind a Donchian low/high + ATR buffer
void ManageOpen()
  {
   if(g_ticket == 0) return;
   if(!PositionSelectByTicket(g_ticket)) { LogClosed(); g_ticket=0; g_posID=0; g_trailActive=false; return; }

   const long type = PositionGetInteger(POSITION_TYPE);
   const double open = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl = PositionGetDouble(POSITION_SL);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   if(g_initialRisk <= 0.0) { if(sl > 0.0) g_initialRisk = MathAbs(open - sl); else return; }

   // time stop
   if(InpMaxBarsInTrade > 0 && g_barsIn >= InpMaxBarsInTrade)
     { g_trade.PositionClose(g_ticket); return; }

   const double prof = (type == POSITION_TYPE_BUY) ? (tick.bid - open) : (open - tick.ask);

   // breakeven: once profit >= InpBreakevenRR, move SL to a small buffer beyond entry
   if(InpBreakevenRR > 0.0 && prof >= InpBreakevenRR * g_initialRisk)
     {
      const double be = (type == POSITION_TYPE_BUY) ? open + PipToPrice(InpBreakevenBufferPips)
                                                    : open - PipToPrice(InpBreakevenBufferPips);
      if(type == POSITION_TYPE_BUY  && (sl == 0.0 || sl < be)) g_trade.PositionModify(g_ticket, NormalizeDouble(be, g_digits), 0.0);
      if(type == POSITION_TYPE_SELL && (sl == 0.0 || sl > be)) g_trade.PositionModify(g_ticket, NormalizeDouble(be, g_digits), 0.0);
     }

   if(!InpUseTrailing || prof < InpTrailActivateRR * g_initialRisk) return;
   if(!g_trailActive) { g_trailActive = true; Log("trailing activated"); }

   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpEntryTF, 1, InpTrailChannelLen+1, r) < InpTrailChannelLen+1) return;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 1; i <= InpTrailChannelLen; i++) { if(r[i].high > hi) hi = r[i].high; if(r[i].low < lo) lo = r[i].low; }
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1) return;
   const double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;

   if(type == POSITION_TYPE_BUY)
     {
      double cand = NormalizeDouble(lo - InpTrailATRMult * atr[0], g_digits);
      if(cand > sl && cand <= tick.bid - stopsLevel && cand < tick.bid) g_trade.PositionModify(g_ticket, cand, 0.0);
     }
   else
     {
      double cand = NormalizeDouble(hi + InpTrailATRMult * atr[0], g_digits);
      if((sl == 0.0 || cand < sl) && cand >= tick.ask + stopsLevel && cand > tick.ask) g_trade.PositionModify(g_ticket, cand, 0.0);
     }
  }

void LogClosed()
  {
   if(g_posID == 0) return;
   double net = 0.0;
   if(HistorySelectByPosition(g_posID))
     for(int i = 0; i < HistoryDealsTotal(); i++)
       { ulong d = HistoryDealGetTicket(i); if(d) net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION); }
   double r = 0.0;
   if(g_initialRisk > 0.0)
     {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double perLot = (tv>0&&ts>0) ? (g_initialRisk/ts*tv) : 0.0;
      r = (perLot > 0.0) ? net / perLot : 0.0;
     }
   Log(StringFormat("position #%I64u CLOSED - net %s%.2fR / %.2f USD", (ulong)g_posID, r>=0.0?"+":"", r, net));
  }

void Adopt()
  {
   ulong tk = 0;
   if(!HasOpenPosition(tk)) return;
   g_ticket = tk;
   if(PositionSelectByTicket(tk))
     {
      double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL);
      g_initialRisk = (sl > 0.0) ? MathAbs(open - sl) : 0.0;
      g_posID = (long)PositionGetInteger(POSITION_IDENTIFIER);
     }
  }

void Panel()
  {
   double tf[], ts[];
   long bias = 0;
   if(CopyBuffer(g_hTrF, 0, 1, 1, tf) >= 1 && CopyBuffer(g_hTrS, 0, 1, 1, ts) >= 1)
      bias = (tf[0] > ts[0]) ? +1 : (tf[0] < ts[0] ? -1 : 0);
   string s = "TRAB-Breakout v1.00 | " + _Symbol + " " + EnumToString(InpEntryTF) + "\n";
   s += StringFormat("Channel %d | Trend bias: %s | Pos: %s\n", InpChannelLen,
                     bias > 0 ? "LONG" : (bias < 0 ? "SHORT" : "FLAT"), g_ticket != 0 ? "OPEN" : "flat");
   Comment(s);
  }
//+------------------------------------------------------------------+
