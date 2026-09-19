//+------------------------------------------------------------------+
//|                                                  TRAB_Breakout.mq5 |
//|        H1 Donchian channel breakout (clean demo build, no ML)     |
//|                                                                  |
//| Strategy: enter when an H1 bar CLOSES beyond the prior N-bar      |
//|   Donchian high/low, ATR-based stop, trailing exit to let winners |
//|   run (no fixed TP). Optional H4 trend filter (off by default).    |
//|                                                                  |
//| RESEARCH CAVEAT: profitable in 2023-25 (EURUSD PF 1.19, USDCAD     |
//|   1.55, USDJPY 1.12) but REGIME-DEPENDENT - failed a 2018-2026     |
//|   window (PF ~0.85-0.96). FORWARD-TEST ON DEMO FIRST; do not go    |
//|   live on backtest results alone (see docs/RESEARCH.md).          |
//+------------------------------------------------------------------+
#property copyright   "TRAB"
#property link        ""
#property version     "1.00"
#property description "H1 Donchian channel breakout, ATR stop, trailing (trend-following)"
#include <Trade\Trade.mqh>

input group "=== Channel Breakout ==="
input ENUM_TIMEFRAMES InpEntryTF     = PERIOD_H1;    // Entry timeframe (attach chart)
input int    InpChannelLen           = 10;          // Donchian channel length (bars)
input bool   InpUseCloseBreak        = true;        // Require a close beyond channel (vs just wick)
input ENUM_TIMEFRAMES InpTrendTF     = PERIOD_H4;    // Trend-filter timeframe
input int    InpTrendEmaFast         = 20;          // Trend fast EMA
input int    InpTrendEmaSlow         = 50;          // Trend slow EMA
input bool   InpUseTrendFilter       = false;       // Only break out in the higher-TF trend direction

input group "=== Risk & Exit ==="
input int    InpATRPeriod            = 14;          // ATR period
input double InpATRMultSL            = 2.5;         // SL distance = x ATR
input double InpRiskPercent          = 1.0;         // Risk % equity (0 = fixed lots)
input double InpFixedLots            = 0.10;        // Fixed lots
input int    InpTrailChannelLen      = 10;          // Trail behind this Donchian low/high
input double InpTrailATRMult         = 2.0;         // Trail distance = x ATR beyond the trail level
input double InpTrailActivateRR      = 1.0;         // Trailing activation (x initial risk)
input bool   InpUseTrailing          = true;        // Enable trailing
input double InpMaxSpreadPips        = 2.0;         // Spread gate
input int    InpMaxBarsInTrade       = 96;          // Time-stop (bars) <0 = off

input group "=== General ==="
input long   InpMagic                = 20252001;    // Magic number
input string InpComment              = "TRAB-B";
input bool   InpShowPanel            = true;

//+------------------------------------------------------------------+
CTrade g_trade;
int    g_hATR = INVALID_HANDLE, g_hTrF = INVALID_HANDLE, g_hTrS = INVALID_HANDLE;
double g_point = 0.0, g_pip = 0.0;
int    g_digits = 0;
datetime g_lastBar = 0;
ulong  g_ticket = 0; long g_posID = 0;
double g_initialRisk = 0.0; bool g_trailActive = false;
int    g_barsIn = 0;

void Log(const string m) { Print("TRAB-B: ", m); }
double PipToPrice(double p) { return p * g_pip; }

int OnInit()
  {
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = (g_digits == 3 || g_digits == 5) ? g_point * 10.0 : g_point;
   if(g_point <= 0.0 || g_pip <= 0.0) { Log("INIT FAILED: point/pip"); return INIT_FAILED; }
   if(InpATRPeriod <= 0 || InpChannelLen < 2 || InpRiskPercent < 0.0 || InpFixedLots <= 0.0 ||
      InpATRMultSL <= 0.0 || InpTrailActivateRR <= 0.0 || InpMaxSpreadPips <= 0.0)
     { Log("INIT FAILED: invalid inputs"); return INIT_PARAMETERS_INCORRECT; }
   g_hATR = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   g_hTrF = iMA(_Symbol, InpTrendTF, InpTrendEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hTrS = iMA(_Symbol, InpTrendTF, InpTrendEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hATR == INVALID_HANDLE || g_hTrF == INVALID_HANDLE || g_hTrS == INVALID_HANDLE)
     { Log("INIT FAILED: handles"); return INIT_FAILED; }
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   Log(StringFormat("initialized | channel %d | %s @ %s | SL %.1f ATR | trail %.1f ATR",
                    InpChannelLen, EnumToString(InpTrendTF), EnumToString(InpEntryTF), InpATRMultSL, InpTrailATRMult));
   Adopt();
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int r)
  {
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hTrF != INVALID_HANDLE) IndicatorRelease(g_hTrF);
   if(g_hTrS != INVALID_HANDLE) IndicatorRelease(g_hTrS);
   Comment("");
  }
bool IsNewBar() { datetime t = iTime(_Symbol, InpEntryTF, 0); if(t == 0 || t == g_lastBar) return false; g_lastBar = t; return true; }
bool HasOpen(ulong &tk)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     { ulong t = PositionGetTicket(i); if(t == 0) continue;
       if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic) { tk = t; return true; } }
   return false;
  }
void OnTick() { ManageOpen(); if(IsNewBar()) { if(g_ticket != 0) g_barsIn++; Evaluate(); } if(InpShowPanel) Panel(); }

//+------------------------------------------------------------------+
//| Signal: close beyond the prior-N-bar Donchian channel            |
//+------------------------------------------------------------------+
void Evaluate()
  {
   ulong tk = 0; if(HasOpen(tk)) return;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpEntryTF, 1, InpChannelLen + 1, r) < InpChannelLen + 1) return;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 1; i <= InpChannelLen; i++) { if(r[i].high > hi) hi = r[i].high; if(r[i].low < lo) lo = r[i].low; }
   const double cl = r[0].close;
   int dir = 0;
   if(InpUseCloseBreak && cl > hi) dir = +1;
   else if(InpUseCloseBreak && cl < lo) dir = -1;
   if(dir == 0) return;
   if(InpUseTrendFilter)
     {
      double tf[], ts[]; ArraySetAsSeries(tf, true); ArraySetAsSeries(ts, true);
      if(CopyBuffer(g_hTrF, 0, 1, 1, tf) < 1 || CopyBuffer(g_hTrS, 0, 1, 1, ts) < 1) return;
      const long bias = (tf[0] > ts[0]) ? +1 : (tf[0] < ts[0] ? -1 : 0);
      if(bias == 0 || bias != dir) return;
     }
   TryEnter(dir);
  }

void TryEnter(const int dir)
  {
   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) return;
   const double spread = (tick.ask - tick.bid) / g_pip;
   if(spread > InpMaxSpreadPips) { Log("ENTRY ABORTED: spread " + DoubleToString(spread,1)); return; }
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) return;
   double entry, sl;
   if(dir > 0) { entry = tick.ask; sl = entry - InpATRMultSL * atr[0]; }
   else        { entry = tick.bid; sl = entry + InpATRMultSL * atr[0]; }
   const double risk = MathAbs(entry - sl);
   if(risk <= 0.0) return;
   const double lots = ComputeLots(risk, entry, dir);
   if(lots <= 0.0) return;
   const double slN = NormalizeDouble(sl, g_digits);
   bool sent = (dir > 0) ? g_trade.Buy(lots, _Symbol, 0.0, slN, 0.0, InpComment)
                         : g_trade.Sell(lots, _Symbol, 0.0, slN, 0.0, InpComment);
   uint ret = g_trade.ResultRetcode();
   if(sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
     {
      ulong t2 = 0; if(HasOpen(t2)) { g_ticket = t2; if(PositionSelectByTicket(t2)) { g_initialRisk = MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - slN); g_posID = (long)PositionGetInteger(POSITION_IDENTIFIER); } g_trailActive = false; g_barsIn = 0; }
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
      const double rm = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
      const double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      const double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0.0 || ts <= 0.0) return 0.0;
      const double perLot = riskDist / ts * tv;
      if(perLot <= 0.0) return 0.0;
      lots = rm / perLot;
     }
   const double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st > 0.0) lots = MathFloor(lots / st) * st;
   if(lots > mx) lots = mx;
   return (lots < mn) ? 0.0 : lots;
  }

void ManageOpen()
  {
   if(g_ticket == 0) return;
   if(!PositionSelectByTicket(g_ticket)) { LogClosed(); g_ticket=0; g_posID=0; g_trailActive=false; return; }
   const long type = PositionGetInteger(POSITION_TYPE);
   const double open = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl = PositionGetDouble(POSITION_SL);
   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) return;
   if(g_initialRisk <= 0.0) { if(sl > 0.0) g_initialRisk = MathAbs(open - sl); else return; }
   if(InpMaxBarsInTrade > 0 && g_barsIn >= InpMaxBarsInTrade) { g_trade.PositionClose(g_ticket); return; }
   const double prof = (type == POSITION_TYPE_BUY) ? (tick.bid - open) : (open - tick.ask);
   if(!InpUseTrailing || prof < InpTrailActivateRR * g_initialRisk) return;
   if(!g_trailActive) { g_trailActive = true; Log("trailing activated"); }
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpEntryTF, 1, InpTrailChannelLen + 1, r) < InpTrailChannelLen + 1) return;
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 1; i <= InpTrailChannelLen; i++) { if(r[i].high > hi) hi = r[i].high; if(r[i].low < lo) lo = r[i].low; }
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) return;
   const double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   if(type == POSITION_TYPE_BUY)
     { double cand = NormalizeDouble(lo - InpTrailATRMult * atr[0], g_digits); if(cand > sl && cand <= tick.bid - stopsLevel && cand < tick.bid) g_trade.PositionModify(g_ticket, cand, 0.0); }
   else
     { double cand = NormalizeDouble(hi + InpTrailATRMult * atr[0], g_digits); if((sl == 0.0 || cand < sl) && cand >= tick.ask + stopsLevel && cand > tick.ask) g_trade.PositionModify(g_ticket, cand, 0.0); }
  }

void LogClosed()
  {
   if(g_posID == 0) return;
   double net = 0.0;
   if(HistorySelectByPosition(g_posID))
     for(int i = 0; i < HistoryDealsTotal(); i++) { ulong d = HistoryDealGetTicket(i); if(d) net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION); }
   double r = 0.0;
   if(g_initialRisk > 0.0)
     { double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); double perLot = (tv>0&&ts>0) ? (g_initialRisk/ts*tv) : 0.0; r = (perLot > 0.0) ? net / perLot : 0.0; }
   Log(StringFormat("position #%I64u CLOSED - net %s%.2fR / %.2f USD", (ulong)g_posID, r>=0.0?"+":"", r, net));
  }

void Adopt()
  {
   ulong tk = 0; if(!HasOpen(tk)) return;
   g_ticket = tk;
   if(PositionSelectByTicket(tk)) { double o = PositionGetDouble(POSITION_PRICE_OPEN), s = PositionGetDouble(POSITION_SL); g_initialRisk = (s > 0.0) ? MathAbs(o - s) : 0.0; g_posID = (long)PositionGetInteger(POSITION_IDENTIFIER); }
  }

void Panel()
  {
   double tf[], ts[]; long bias = 0;
   if(CopyBuffer(g_hTrF, 0, 1, 1, tf) >= 1 && CopyBuffer(g_hTrS, 0, 1, 1, ts) >= 1) bias = (tf[0] > ts[0]) ? +1 : (tf[0] < ts[0] ? -1 : 0);
   string s = "TRAB-Breakout v1.00 | " + _Symbol + " " + EnumToString(InpEntryTF) + "\n";
   s += StringFormat("Channel %d | H4 bias: %s | Pos: %s\n", InpChannelLen, bias > 0 ? "LONG" : (bias < 0 ? "SHORT" : "FLAT"), g_ticket != 0 ? "OPEN" : "flat");
   Comment(s);
  }
//+------------------------------------------------------------------+
