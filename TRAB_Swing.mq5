//+------------------------------------------------------------------+
//|                                                      TRAB_Swing.mq5 |
//|        H4-trend + M15-entry Swing Expert Advisor                  |
//|                                                                  |
//| Strategy : multi-timeframe swing. H4 EMA regime sets the trend    |
//|            direction; M15 bar-close signals time the entry IN     |
//|            that direction (trend-following, not a reversal).      |
//|            ATR-based SL, trailing behind the M15 fast EMA to      |
//|            let winners run (no fixed TP).                         |
//| Timeframe: attach to the ENTRY timeframe chart (M15).             |
//+------------------------------------------------------------------+
#property copyright   "TRAB"
#property link        ""
#property version     "1.00"
#property description "H4 trend + M15 entry swing EA (trend-following pullback/momentum)"
#include <Trade\Trade.mqh>

input group "=== Trend (H4) ==="
input ENUM_TIMEFRAMES InpTrendTF    = PERIOD_H4;  // Trend timeframe
input int    InpTrendFastPeriod     = 20;       // Trend fast EMA
input int    InpTrendSlowPeriod     = 50;       // Trend slow EMA
input bool   InpRequireMatureTrend  = true;     // Also require trend EMA50 > EMA200

input group "=== Entry (M15) ==="
input ENUM_TIMEFRAMES InpEntryTF    = PERIOD_M15; // Entry timeframe (attach chart)
input int    InpEntryFastPeriod     = 20;       // Entry fast EMA
input int    InpEntrySlowPeriod     = 50;       // Entry slow EMA
input bool   InpUseMomentumEntry    = true;     // true = M15 momentum turn; false = pullback continuation
input double InpMinPullbackPips     = 20.0;     // Min pullback (pips) required before a fresh entry
input int    InpMaturePeriod        = 200;      // M15 slow-bound EMA for pullback-zone reference

input group "=== Risk & Exit ==="
input int    InpATRPeriod           = 14;       // ATR period (entry TF)
input double InpATRMultSL           = 3.0;      // SL distance = x ATR (wider = fewer stop-outs)
input int    InpMinBarsBetween      = 8;       // Min entry-TF bars between trades (0 = off)
input double InpRiskPercent         = 1.0;      // Risk % of equity per trade (0 = FixedLots)
input double InpFixedLots           = 0.10;     // Fixed lots
input bool   InpUseTrailing         = true;     // Trail behind TREND fast EMA
input double InpTrailActivateRR     = 1.0;      // Trailing activation (x initial risk)
input double InpTrailATRMult        = 4.0;      // Trail distance = x ATR beyond the trend EMA
input double InpMaxSpreadPips       = 2.0;      // Spread gate (pips)
input double InpMaxSlippagePips     = 1.0;      // OrderSend deviation (pips)

input group "=== General ==="
input long   InpMagic               = 20251001; // Magic number
input string InpTradeComment        = "TRAB-S";
input bool   InpShowPanel           = true;    // On-chart status panel

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade g_trade;
int    g_hTrF     = INVALID_HANDLE;
int    g_hTrS     = INVALID_HANDLE;
int    g_hTrM     = INVALID_HANDLE;   // mature EMA (trend slow bound, e.g. 200 on H4)
int    g_hEnF     = INVALID_HANDLE;   // entry fast EMA
int    g_hEnS     = INVALID_HANDLE;   // entry slow EMA
int    g_hATR     = INVALID_HANDLE;
double g_point    = 0.0, g_pip = 0.0;
int    g_digits   = 0;
double g_slippage = 0.0;
ulong  g_dev      = 0;
bool   g_canTrade = true;

datetime g_lastBar = 0;
long     g_dir     = 0;   // +1 long bias, -1 short bias
double   g_e20M    = 0.0, g_e50M = 0.0;   // panel display (entry TF)
double   g_e20H    = 0.0, g_e50H = 0.0;

ulong  g_ticket = 0;
long   g_posID  = 0;
double g_initialRisk = 0.0;
bool   g_trailActive = false;
datetime g_lastEntry = 0;   // for entry spacing

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void Log(const string msg) { Print("TRAB-S: ", msg); }
double PipToPrice(const double pips) { return pips * g_pip; }

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = (g_digits == 3 || g_digits == 5) ? g_point * 10.0 : g_point;
   if(g_point <= 0.0 || g_pip <= 0.0) { Log("INIT FAILED: bad point/pip"); return(INIT_FAILED); }

   if(InpTrendFastPeriod <= 0 || InpTrendSlowPeriod <= 0 || InpMaturePeriod <= 0 ||
      InpEntryFastPeriod <= 0 || InpEntrySlowPeriod <= 0 || InpATRPeriod <= 0 ||
      InpATRMultSL <= 0.0 || InpTrailActivateRR <= 0.0 || InpRiskPercent < 0.0 ||
      InpFixedLots <= 0.0 || InpMaxSpreadPips <= 0.0)
     { Log("INIT FAILED: invalid inputs"); return(INIT_PARAMETERS_INCORRECT); }

   g_hTrF = iMA(_Symbol, InpTrendTF, InpTrendFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hTrS = iMA(_Symbol, InpTrendTF, InpTrendSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hTrM = iMA(_Symbol, InpTrendTF, InpMaturePeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEnF = iMA(_Symbol, InpEntryTF, InpEntryFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEnS = iMA(_Symbol, InpEntryTF, InpEntrySlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   if(g_hTrF == INVALID_HANDLE || g_hTrS == INVALID_HANDLE || g_hTrM == INVALID_HANDLE ||
      g_hEnF == INVALID_HANDLE || g_hEnS == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     { Log("INIT FAILED: indicator handles"); return(INIT_FAILED); }

   g_slippage = MathMin(InpMaxSlippagePips, 3.0);
   g_dev      = (ulong)MathRound(g_slippage * g_pip / g_point);
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints(g_dev);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   Adopt();
   Log(StringFormat("initialized on %s crt=%s | trend EMA%d/%d | entry EMA%d/%d | SL %.1fxATR | trail %.1fxATR",
                    _Symbol, EnumToString(InpEntryTF), InpTrendFastPeriod, InpTrendSlowPeriod,
                    InpEntryFastPeriod, InpEntrySlowPeriod, InpATRMultSL, InpTrailATRMult));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_hTrF != INVALID_HANDLE) IndicatorRelease(g_hTrF);
   if(g_hTrS != INVALID_HANDLE) IndicatorRelease(g_hTrS);
   if(g_hTrM != INVALID_HANDLE) IndicatorRelease(g_hTrM);
   if(g_hEnF != INVALID_HANDLE) IndicatorRelease(g_hEnF);
   if(g_hEnS != INVALID_HANDLE) IndicatorRelease(g_hEnS);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   Comment("");
  }

//+------------------------------------------------------------------+
//| New bar on the entry timeframe                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   const datetime t = iTime(_Symbol, InpEntryTF, 0);
   if(t == 0 || t == g_lastBar) return false;
   g_lastBar = t;
   return true;
  }

//+------------------------------------------------------------------+
//| HasOpenPosition (this EA + symbol)                                |
//+------------------------------------------------------------------+
bool HasOpenPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
        { ticket = t; return true; }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Trend bias from the H4 EMA regime (last closed H4 bar)            |
//+------------------------------------------------------------------+
long TrendBias(double &f, double &s, double &m)
  {
   double tf[], ts[], tm[];
   ArraySetAsSeries(tf, true); ArraySetAsSeries(ts, true); ArraySetAsSeries(tm, true);
   if(CopyBuffer(g_hTrF, 0, 1, 1, tf) < 1 || CopyBuffer(g_hTrS, 0, 1, 1, ts) < 1 ||
      CopyBuffer(g_hTrM, 0, 1, 1, tm) < 1)
      return 0;
   f = tf[0]; s = ts[0]; m = tm[0];
   if(!InpRequireMatureTrend)
      return (f > s) ? +1 : (f < s ? -1 : 0);
   if(f > s && s > m) return +1;
   if(f < s && s < m) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Tick: manage per-tick, signal on the entry-TF bar close           |
//+------------------------------------------------------------------+
void OnTick()
  {
   ManageOpen();
   if(IsNewBar())
      Evaluate();
   if(InpShowPanel) Panel();
  }

//+------------------------------------------------------------------+
//| Signal evaluation on M15 bar close                                |
//+------------------------------------------------------------------+
void Evaluate()
  {
   ulong ticket = 0;
   if(HasOpenPosition(ticket)) return;

   double fH, sH, mH;
   const long bias = TrendBias(fH, sH, mH);
   if(bias == 0) return;

   double enF[], enS[];
   ArraySetAsSeries(enF, true); ArraySetAsSeries(enS, true);
   if(CopyBuffer(g_hEnF, 0, 1, 2, enF) < 2) return;
   if(CopyBuffer(g_hEnS, 0, 1, 2, enS) < 2) return;
   const double e20 = enF[0], e50 = enS[0], e20p = enF[1], e50p = enS[1];

   int dir = 0;
   if(InpUseMomentumEntry)
     {
      // fresh M15 EMA20/EMA50 cross in the trend direction
      const bool freshUp = (e20 > e50) && (e20p <= e50p);
      const bool freshDn = (e20 < e50) && (e20p >= e50p);
      if(bias > 0 && freshUp)      dir = +1;
      else if(bias < 0 && freshDn) dir = -1;
     }
   else
     {
      // pullback-continuation: price dipped to the entry slow EMA, then closed back strongly
      MqlRates r[]; ArraySetAsSeries(r, true);
      if(CopyRates(_Symbol, InpEntryTF, 1, 3, r) < 3) return;
      const double lo = MathMin(r[0].low, r[1].low);
      const double hi = MathMax(r[0].high, r[1].high);
      const double cl = r[0].close;
      if(bias > 0 && e20 > e50 && cl > e20 && lo <= e50)      dir = +1;  // pulled back to EMA50, closed back above EMA20
      else if(bias < 0 && e20 < e50 && cl < e20 && hi >= e50) dir = -1;
     }
   if(dir == 0) return;

   // entry spacing: no new trade until InpMinBarsBetween entry-TF bars have passed
   if(InpMinBarsBetween > 0 && g_lastEntry != 0)
     {
      const int barsSince = (int)iBarShift(_Symbol, InpEntryTF, g_lastEntry);
      if(barsSince >= 0 && barsSince < InpMinBarsBetween)
         return;
     }

   TryEnter(dir);
  }

//+------------------------------------------------------------------+
//| Entry with gates + ATR SL + sizing + no fixed TP (trailing)      |
//+------------------------------------------------------------------+
void TryEnter(const int dir)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   const double spreadPips = (tick.ask - tick.bid) / g_pip;
   if(spreadPips > InpMaxSpreadPips) { Log("ENTRY ABORTED: spread " + DoubleToString(spreadPips,1) + " pips"); return; }

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1) { Log("ENTRY ABORTED: no ATR"); return; }
   const double atrVal = atr[0];
   if(atrVal <= 0.0) { Log("ENTRY ABORTED: bad ATR"); return; }

   double entry, sl;
   if(dir > 0) { entry = tick.ask; sl = entry - InpATRMultSL * atrVal; }
   else        { entry = tick.bid; sl = entry + InpATRMultSL * atrVal; }

   const double risk = MathAbs(entry - sl);
   if(risk <= 0.0) { Log("TRADE SKIPPED: non-positive risk"); return; }

   const double lots = ComputeLots(risk, entry, dir);
   if(lots <= 0.0) { Log("TRADE SKIPPED: no valid lots"); return; }

   const double slN = NormalizeDouble(sl, g_digits);
   const bool sent = (dir > 0)
                     ? g_trade.Buy(lots, _Symbol, 0.0, slN, 0.0, InpTradeComment)
                     : g_trade.Sell(lots, _Symbol, 0.0, slN, 0.0, InpTradeComment);
   const uint ret = g_trade.ResultRetcode();
   if(sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
     {
      ulong tk = 0;
      if(HasOpenPosition(tk))
        {
         g_ticket = tk;
         if(PositionSelectByTicket(tk))
           {
            const double open = PositionGetDouble(POSITION_PRICE_OPEN);
            g_initialRisk = MathAbs(open - slN);
            g_posID = (long)PositionGetInteger(POSITION_IDENTIFIER);
            g_lastEntry = iTime(_Symbol, InpEntryTF, 0);
           }
         g_trailActive = false;
        }
      Log(StringFormat(">>> %s %s (bias) | SL %.5f | risk %.1f pips",
                       dir > 0 ? "BUY" : "SELL", DoubleToString(lots,2), slN, risk/g_pip));
     }
   else
      Log(StringFormat("OrderSend FAILED ret=%u (%s)", ret, g_trade.ResultRetcodeDescription()));
  }

double ComputeLots(const double riskDist, const double price, const int dir)
  {
   double lots = 0.0;
   if(InpRiskPercent <= 0.0) lots = InpFixedLots;
   else
     {
      const double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
      const double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      const double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0.0 || ts <= 0.0) return 0.0;
      const double lossPerLot = riskDist / ts * tv;
      if(lossPerLot <= 0.0) return 0.0;
      lots = riskMoney / lossPerLot;
     }
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0.0) lots = MathFloor(lots / step) * step;
   if(lots > maxLot) lots = maxLot;
   if(lots < minLot) { Log("sizing below min - skipped"); return 0.0; }
   double margin = 0.0;
   if(!OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, margin)) return 0.0;
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
     {
      double reduced = lots * (AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9) / margin;
      if(step > 0.0) reduced = MathFloor(reduced / step) * step;
      if(reduced < minLot) return 0.0;
      lots = reduced;
     }
   return lots;
  }

//+------------------------------------------------------------------+
//| Per-tick trailing behind the entry fast EMA after activation      |
//+------------------------------------------------------------------+
void ManageOpen()
  {
   if(g_ticket == 0) return;
   if(!PositionSelectByTicket(g_ticket))
     {
      LogClosed();
      g_ticket = 0; g_posID = 0; g_trailActive = false; return;
     }

   const long type = PositionGetInteger(POSITION_TYPE);
   const double open = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl = PositionGetDouble(POSITION_SL);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   if(g_initialRisk <= 0.0) { if(sl > 0.0) g_initialRisk = MathAbs(open - sl); else return; }

   const double profitDist = (type == POSITION_TYPE_BUY) ? (tick.bid - open) : (open - tick.ask);
   if(profitDist < InpTrailActivateRR * g_initialRisk) return;

   if(!g_trailActive) { g_trailActive = true; Log("trailing activated"); }

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1) return;
   const double atrVal = atr[0];
   double enF[];
   ArraySetAsSeries(enF, true);
   if(CopyBuffer(g_hEnF, 0, 1, 1, enF) < 1) return;

   const double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   // trail behind the TREND fast EMA (captures the swing, avoids M15 noise)
   double trF[];
   ArraySetAsSeries(trF, true);
   if(CopyBuffer(g_hTrF, 0, 1, 1, trF) < 1) return;
   if(type == POSITION_TYPE_BUY)
     {
      const double cand = NormalizeDouble(trF[0] - InpTrailATRMult * atrVal, g_digits);
      if(cand > sl && cand <= tick.bid - stopsLevel && cand < tick.bid)
         g_trade.PositionModify(g_ticket, cand, 0.0);
     }
   else
     {
      const double cand = NormalizeDouble(trF[0] + InpTrailATRMult * atrVal, g_digits);
      if((sl == 0.0 || cand < sl) && cand >= tick.ask + stopsLevel && cand > tick.ask)
         g_trade.PositionModify(g_ticket, cand, 0.0);
     }
  }

//+------------------------------------------------------------------+
//| Log a closed position (net P&L + R)                              |
//+------------------------------------------------------------------+
void LogClosed()
  {
   if(g_posID == 0) return;
   double net = 0.0;
   if(HistorySelectByPosition(g_posID))
     {
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         const ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
        }
     }
   double r = 0.0;
   if(g_initialRisk <= 0.0) r = 0.0;
   else
     {
      const double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      const double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double perLot = (tv > 0.0 && ts > 0.0) ? (g_initialRisk / ts * tv) : 0.0;
      r = (perLot > 0.0) ? net / perLot : 0.0;
     }
   Log(StringFormat("position #%I64u CLOSED - net %s%.2fR / %.2f USD",
                    (ulong)g_posID, r >= 0.0 ? "+" : "", r, net));
  }

//+------------------------------------------------------------------+
//| Adopt an existing position after restart                          |
//+------------------------------------------------------------------+
void Adopt()
  {
   ulong tk = 0;
   if(!HasOpenPosition(tk)) return;
   g_ticket = tk;
   if(PositionSelectByTicket(tk))
     {
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl = PositionGetDouble(POSITION_SL);
      g_initialRisk = (sl > 0.0) ? MathAbs(open - sl) : 0.0;
      g_posID = (long)PositionGetInteger(POSITION_IDENTIFIER);
     }
   g_trailActive = false;
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void Panel()
  {
   double fH, sH, mH;
   const long bias = TrendBias(fH, sH, mH);
   string s = "TRAB-Swing v0.10 | " + _Symbol + " " + EnumToString(InpEntryTF) + "\n";
   s += StringFormat("H4 bias: %s | H4 EMA20 %.5f  EMA50 %.5f  EMA200 %.5f\n",
                     bias > 0 ? "LONG" : (bias < 0 ? "SHORT" : "FLAT"), fH, sH, mH);
   s += StringFormat("Entry mode: %s\n", InpUseMomentumEntry ? "momentum" : "pullback");
   s += StringFormat("Position: %s\n", g_ticket != 0 ? "OPEN" : "flat");
   Comment(s);
  }
//+------------------------------------------------------------------+
