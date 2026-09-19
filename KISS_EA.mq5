//+------------------------------------------------------------------+
//|                                                       KISS_EA.mq5 |
//|     SMC/ICT liquidity sweep + pin bar / engulfing entry (M15)     |
//|                                                                   |
//| Strategy (Keep It Simple, Stupid):                                |
//|   1. Liquidity pools = the most recent CONFIRMED fractal swing    |
//|      high / low on the entry TF (resting stops = liquidity).      |
//|   2. Sweep = a closed bar that WICKS through a pool but CLOSES    |
//|      back inside it (stop hunt / liquidity grab).                 |
//|   3. Confirmation = the sweep bar itself, or the next closed bar, |
//|      printing a pin bar or engulfing bar in the reversal          |
//|      direction, holding the sweep extreme.                        |
//|   4. Enter at market on the next bar open. SL beyond the sweep    |
//|      extreme (+ATR buffer), TP at a fixed reward:risk multiple.   |
//|                                                                   |
//| Optional: higher-TF EMA bias filter, server-hour session window,  |
//|   ATR trailing after an activation RR, time stop.                 |
//|   Signals evaluate on CLOSED bars only; trailing runs per tick.   |
//+------------------------------------------------------------------+
#property copyright   "KISS"
#property link        ""
#property version     "1.01"
#property description "SMC/ICT liquidity sweep + pin bar / engulfing confirmation, M15 entry"
#include <Trade\Trade.mqh>

input group "=== Liquidity Sweep (M15) ==="
input ENUM_TIMEFRAMES InpEntryTF      = PERIOD_M15;  // Entry timeframe (attach chart)
input int    InpSwingStrength         = 3;           // Fractal strength (bars each side of swing)
input int    InpSweepLookback         = 60;          // Bars scanned for liquidity pools
input bool   InpUsePinBar             = true;        // Confirm with pin bar
input bool   InpUseEngulfing          = true;        // Confirm with engulfing bar
input double InpPinWickRatio          = 2.0;         // Pin: rejection wick >= x body
input double InpMinRangeATR           = 0.5;         // Min confirm-candle range = x ATR (noise gate)

input group "=== HTF Bias & Session (optional) ==="
input bool   InpUseBiasFilter         = true;        // Only trade with the higher-TF EMA bias
input ENUM_TIMEFRAMES InpBiasTF       = PERIOD_H1;   // Bias timeframe
input int    InpBiasEmaPeriod         = 50;          // Bias EMA period
input bool   InpUseSessionFilter      = false;       // Restrict to a server-hour window
input int    InpSessStartHour         = 7;           // Session start hour (server time)
input int    InpSessEndHour           = 20;          // Session end hour (server time, wraps midnight)

input group "=== Risk & Exit ==="
input int    InpATRPeriod             = 14;          // ATR period (entry TF)
input double InpSLBufferATRMult       = 0.25;        // SL buffer beyond sweep extreme = x ATR
input double InpMinStopATRMult        = 1.0;         // Min SL distance floor = x ATR (guards tiny sweep wicks)
input double InpRewardRR              = 2.0;         // Take profit = x risk (RR)
input double InpRiskPercent           = 1.0;         // Risk % equity (0 = fixed lots)
input double InpFixedLots             = 0.10;        // Fixed lots
input bool   InpUseTrailing           = false;       // Enable ATR trailing after activation
input double InpTrailActivateRR       = 1.0;         // Trailing activation (x initial risk)
input double InpTrailATRMult          = 1.5;         // Trail distance = x ATR behind price
input double InpMaxSpreadPips         = 1.5;         // Spread gate
input int    InpMaxBarsInTrade        = 0;           // Time-stop (entry-TF bars), 0 = off

input group "=== General ==="
input long   InpMagic                 = 20254101;    // Magic number
input string InpComment               = "KISS";      // Order comment
input bool   InpShowPanel             = true;        // Show chart panel

//+------------------------------------------------------------------+
CTrade g_trade;
int    g_hATR = INVALID_HANDLE, g_hBiasEma = INVALID_HANDLE;
double g_point = 0.0, g_pip = 0.0;
int    g_digits = 0;
datetime g_lastBar = 0;
ulong  g_ticket = 0; long g_posID = 0;
double g_initialRisk = 0.0; bool g_trailActive = false;
double g_volume = 0.0;      // position volume (for true R math incl. costs)
int    g_barsIn = 0;
string g_lastSetup = "-";   // last confirmed setup (for the panel)

void Log(const string m) { Print("KISS: ", m); }
double PipToPrice(double p) { return p * g_pip; }

//+------------------------------------------------------------------+
//| Init / deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = (g_digits == 3 || g_digits == 5) ? g_point * 10.0 : g_point;
   if(g_point <= 0.0 || g_pip <= 0.0) { Log("INIT FAILED: point/pip"); return INIT_FAILED; }
   if(InpSwingStrength < 1 || InpSweepLookback < 2 * InpSwingStrength + 3 ||
      InpATRPeriod <= 0 || InpRewardRR <= 0.0 || InpRiskPercent < 0.0 || InpFixedLots <= 0.0 ||
      InpSLBufferATRMult < 0.0 || InpMinStopATRMult < 0.0 || InpPinWickRatio <= 0.0 || InpMinRangeATR < 0.0 ||
      InpMaxSpreadPips <= 0.0 || InpBiasEmaPeriod <= 0 ||
      InpTrailActivateRR <= 0.0 || InpTrailATRMult <= 0.0 || InpMaxBarsInTrade < 0)
     { Log("INIT FAILED: invalid inputs"); return INIT_PARAMETERS_INCORRECT; }
   if(!InpUsePinBar && !InpUseEngulfing)
     { Log("INIT FAILED: at least one confirmation pattern (pin/engulfing) must be enabled"); return INIT_PARAMETERS_INCORRECT; }
   if(InpUseSessionFilter && (InpSessStartHour < 0 || InpSessStartHour > 23 || InpSessEndHour < 0 || InpSessEndHour > 23 || InpSessStartHour == InpSessEndHour))
     { Log("INIT FAILED: session hours"); return INIT_PARAMETERS_INCORRECT; }
   g_hATR = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   g_hBiasEma = iMA(_Symbol, InpBiasTF, InpBiasEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hATR == INVALID_HANDLE || g_hBiasEma == INVALID_HANDLE)
     { Log("INIT FAILED: handles"); return INIT_FAILED; }
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   Log(StringFormat("initialized | %s sweep + pin/engulf @ %s | swing %d, lookback %d | bias %s EMA%d %s | SL buf %.2f ATR (floor %.1f), TP %.1fR | trail %s",
                    EnumToString(InpEntryTF), _Symbol, InpSwingStrength, InpSweepLookback,
                    EnumToString(InpBiasTF), InpBiasEmaPeriod, InpUseBiasFilter ? "ON" : "off",
                    InpSLBufferATRMult, InpMinStopATRMult, InpRewardRR, InpUseTrailing ? "on" : "off"));
   Adopt();
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int r)
  {
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hBiasEma != INVALID_HANDLE) IndicatorRelease(g_hBiasEma);
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
//| Session window (server time; wraps midnight if start > end)      |
//+------------------------------------------------------------------+
bool InSession(const datetime t)
  {
   MqlDateTime dt; TimeToStruct(t, dt);
   if(InpSessStartHour < InpSessEndHour) return (dt.hour >= InpSessStartHour && dt.hour < InpSessEndHour);
   return (dt.hour >= InpSessStartHour || dt.hour < InpSessEndHour);
  }

//+------------------------------------------------------------------+
//| Most recent confirmed fractal swing at/older than array index    |
//| `fromIdx`. Series array r[] (r[0] = last CLOSED bar). A pivot    |
//| strictly dominates all bars within InpSwingStrength on both      |
//| sides; needs `strength` closed bars to its right (confirmed).    |
//+------------------------------------------------------------------+
bool FindSwing(const MqlRates &r[], const int n, const int fromIdx, const bool wantHigh, int &idx)
  {
   for(int a = MathMax(fromIdx, InpSwingStrength); a <= n - 1 - InpSwingStrength; a++)
     {
      bool ok = true;
      for(int k = 1; k <= InpSwingStrength && ok; k++)
        {
         if(wantHigh) { if(r[a].high <= r[a - k].high || r[a].high <= r[a + k].high) ok = false; }
         else         { if(r[a].low  >= r[a - k].low  || r[a].low  >= r[a + k].low)  ok = false; }
        }
      if(ok) { idx = a; return true; }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Pin bar: dominant rejection wick (>= ratio x body, >= other      |
//| wick) in the trade direction, range >= MinRangeATR x ATR.        |
//+------------------------------------------------------------------+
bool IsPinBar(const MqlRates &c, const int dir, const double atr)
  {
   const double range = c.high - c.low;
   if(range <= 0.0 || range < InpMinRangeATR * atr) return false;
   const double body = MathAbs(c.close - c.open);
   const double upW = c.high - MathMax(c.open, c.close);
   const double loW = MathMin(c.open, c.close) - c.low;
   if(dir > 0) return (loW >= InpPinWickRatio * body && loW >= upW);
   return (upW >= InpPinWickRatio * body && upW >= loW);
  }

//+------------------------------------------------------------------+
//| Engulfing: opposite-color prior bar whose body is fully covered  |
//| by the current bar's body (same color as the trade).             |
//+------------------------------------------------------------------+
bool IsEngulfing(const MqlRates &cur, const MqlRates &prev, const int dir, const double atr)
  {
   const double range = cur.high - cur.low;
   if(range < InpMinRangeATR * atr) return false;
   if(dir > 0) return (prev.close < prev.open && cur.close > cur.open &&
                       cur.open <= prev.close && cur.close >= prev.open);
   return (prev.close > prev.open && cur.close < cur.open &&
           cur.open >= prev.close && cur.close <= prev.open);
  }

//+------------------------------------------------------------------+
//| Confirmation candle at array index a (pin or engulfing).         |
//+------------------------------------------------------------------+
bool ConfirmPattern(const MqlRates &r[], const int n, const int a, const int dir, const double atr, string &name)
  {
   if(a + 1 >= n) return false;
   if(InpUsePinBar && IsPinBar(r[a], dir, atr)) { name = (dir > 0) ? "bull pin" : "bear pin"; return true; }
   if(InpUseEngulfing && IsEngulfing(r[a], r[a + 1], dir, atr)) { name = (dir > 0) ? "bull engulf" : "bear engulf"; return true; }
   return false;
  }

//+------------------------------------------------------------------+
//| One setup candidate: sweep of a swing pool at series offset sa   |
//| (0 = last closed bar, 1 = the bar before it), direction dir.     |
//| Sweep: wick through the pool, close back inside. Confirm: the    |
//| sweep bar itself, or the next closed bar holding the extreme.    |
//+------------------------------------------------------------------+
bool DetectSetup(const MqlRates &r[], const int n, const int sa, const int dir, const double atr,
                 double &sweepLevel, double &extreme, string &pattern)
  {
   int pi = -1;                                   // liquidity pool = most recent confirmed swing OLDER than the sweep bar
   if(!FindSwing(r, n, sa + 1, dir < 0, pi)) return false;
   const double L = (dir > 0) ? r[pi].low : r[pi].high;
   const bool swept = (dir > 0) ? (r[sa].low < L && r[sa].close > L)     // wick below the pool, close back above
                                : (r[sa].high > L && r[sa].close < L);   // wick above the pool, close back below
   if(!swept) return false;
   if(ConfirmPattern(r, n, sa, dir, atr, pattern))                          // same-bar confirmation
     { sweepLevel = L; extreme = (dir > 0) ? r[sa].low : r[sa].high; return true; }
   if(sa == 1)                                                              // next-bar confirmation (bar after the sweep)
     {
      const bool held   = (dir > 0) ? (r[0].low >= r[1].low) : (r[0].high <= r[1].high);
      const bool inside = (dir > 0) ? (r[0].close > L)       : (r[0].close < L);
      if(held && inside && ConfirmPattern(r, n, 0, dir, atr, pattern))
        { sweepLevel = L; extreme = (dir > 0) ? MathMin(r[1].low, r[0].low) : MathMax(r[1].high, r[0].high); return true; }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Signal: liquidity sweep + pin/engulfing confirmation             |
//+------------------------------------------------------------------+
void Evaluate()
  {
   ulong tk = 0; if(HasOpen(tk)) return;
   const int n = InpSweepLookback + 2 * InpSwingStrength + 2;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpEntryTF, 1, n, r) < n) return;
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) return;
   double sweepLevel = 0.0, extreme = 0.0; string pattern = ""; datetime sweepTime = 0;
   int dir = 0;
   for(int sa = 0; sa <= 1 && dir == 0; sa++)                       // freshest sweep event wins
      for(int d = -1; d <= 1 && dir == 0; d += 2)
         if(DetectSetup(r, n, sa, d, atr[0], sweepLevel, extreme, pattern)) { dir = d; sweepTime = r[sa].time; }
   if(dir == 0) return;
   g_lastSetup = StringFormat("%s %s of swing %s | %s",
                              dir > 0 ? "BUY" : "SELL", dir > 0 ? "sell-side sweep" : "buy-side sweep",
                              DoubleToString(sweepLevel, g_digits), pattern);
   TryEnter(dir, sweepLevel, extreme, pattern, sweepTime, r[0].close);
  }

//+------------------------------------------------------------------+
//| Entry gate: spread / session / bias / geometry / sizing          |
//+------------------------------------------------------------------+
void TryEnter(const int dir, const double sweepLevel, const double extreme, const string pattern,
              const datetime sweepTime, const double lastClose)
  {
   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) return;
   const double spread = (tick.ask - tick.bid) / g_pip;
   if(spread > InpMaxSpreadPips)
     { Log(StringFormat("ENTRY ABORTED: spread %.1f pips > %.1f limit", spread, InpMaxSpreadPips)); return; }
   if(InpUseSessionFilter && !InSession(TimeCurrent()))
     { MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
       Log(StringFormat("ENTRY ABORTED: outside session %02d-%02dh (server hour %02d)", InpSessStartHour, InpSessEndHour, dt.hour)); return; }
   if(InpUseBiasFilter)
     {
      double be[]; ArraySetAsSeries(be, true);
      if(CopyBuffer(g_hBiasEma, 0, 1, 1, be) < 1) return;
      const bool longOk = lastClose > be[0], shortOk = lastClose < be[0];
      if((dir > 0 && !longOk) || (dir < 0 && !shortOk))
        { Log(StringFormat("ENTRY ABORTED: %s against %s EMA%d bias (%.5f)", dir > 0 ? "long" : "short",
                           EnumToString(InpBiasTF), InpBiasEmaPeriod, be[0])); return; }
     }
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) return;
   double entry, sl;
   if(dir > 0) { entry = tick.ask; sl = extreme - InpSLBufferATRMult * atr[0]; }
   else        { entry = tick.bid; sl = extreme + InpSLBufferATRMult * atr[0]; }
   double risk = MathAbs(entry - sl);
   if(risk <= 0.0 || (dir > 0 && sl >= entry) || (dir < 0 && sl <= entry))
     { Log("TRADE SKIPPED: invalid SL geometry vs sweep extreme"); return; }
   const double atrFloor = InpMinStopATRMult * atr[0];               // degenerate guard: a sweep wick hugging the
   if(risk < atrFloor)                                               // entry must not blow up the lot size
     { Log(StringFormat("SL widened to ATR floor: %.1f -> %.1f pips", risk / g_pip, atrFloor / g_pip));
       sl = (dir > 0) ? entry - atrFloor : entry + atrFloor; risk = atrFloor; }
   const double tp = (dir > 0) ? entry + InpRewardRR * risk : entry - InpRewardRR * risk;
   const double lots = ComputeLots(risk);
   if(lots <= 0.0)
     { Log("TRADE SKIPPED: lot size below broker minimum (risk too small)"); return; }
   const double slN = NormalizeDouble(sl, g_digits), tpN = NormalizeDouble(tp, g_digits);
   bool sent = (dir > 0) ? g_trade.Buy(lots, _Symbol, 0.0, slN, tpN, InpComment)
                         : g_trade.Sell(lots, _Symbol, 0.0, slN, tpN, InpComment);
   uint ret = g_trade.ResultRetcode();
   if(sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
     {
      ulong t2 = 0;
      if(HasOpen(t2))
        { g_ticket = t2;
          if(PositionSelectByTicket(t2)) { g_initialRisk = MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - slN); g_posID = (long)PositionGetInteger(POSITION_IDENTIFIER); g_volume = PositionGetDouble(POSITION_VOLUME); }
          g_trailActive = false; g_barsIn = 0; }
      Log(StringFormat(">>> %s %.2f | SL %s | TP %s | risk %.1f pips | %s sweep of swing %s @ %s | %s",
                       dir > 0 ? "BUY" : "SELL", lots, DoubleToString(slN, g_digits), DoubleToString(tpN, g_digits),
                       risk / g_pip, dir > 0 ? "sell-side" : "buy-side", DoubleToString(sweepLevel, g_digits),
                       TimeToString(sweepTime, TIME_DATE | TIME_MINUTES), pattern));
     }
   else Log("OrderSend FAILED " + IntegerToString(ret));
  }

//+------------------------------------------------------------------+
//| Position sizing: risk % of equity (0 = fixed lots)               |
//+------------------------------------------------------------------+
double ComputeLots(const double riskDist)
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

//+------------------------------------------------------------------+
//| Per-tick management: time stop + optional ATR trailing           |
//+------------------------------------------------------------------+
void ManageOpen()
  {
   if(g_ticket == 0) return;
   if(!PositionSelectByTicket(g_ticket)) { LogClosed(); g_ticket = 0; g_posID = 0; g_trailActive = false; g_volume = 0.0; return; }
   const long type = PositionGetInteger(POSITION_TYPE);
   const double open = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl = PositionGetDouble(POSITION_SL);
   const double tp = PositionGetDouble(POSITION_TP);
   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) return;
   if(g_initialRisk <= 0.0) { if(sl > 0.0) g_initialRisk = MathAbs(open - sl); else return; }
   if(InpMaxBarsInTrade > 0 && g_barsIn >= InpMaxBarsInTrade) { g_trade.PositionClose(g_ticket); return; }
   if(!InpUseTrailing) return;
   const double prof = (type == POSITION_TYPE_BUY) ? (tick.bid - open) : (open - tick.ask);
   if(prof < InpTrailActivateRR * g_initialRisk) return;
   if(!g_trailActive) { g_trailActive = true; Log("trailing activated"); }
   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) return;
   const double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   if(type == POSITION_TYPE_BUY)
     { double cand = NormalizeDouble(tick.bid - InpTrailATRMult * atr[0], g_digits);
       if(cand > sl && cand <= tick.bid - stopsLevel && cand < tick.bid) g_trade.PositionModify(g_ticket, cand, tp); }
   else
     { double cand = NormalizeDouble(tick.ask + InpTrailATRMult * atr[0], g_digits);
       if((sl == 0.0 || cand < sl) && cand >= tick.ask + stopsLevel && cand > tick.ask) g_trade.PositionModify(g_ticket, cand, tp); }
  }

//+------------------------------------------------------------------+
//| Closed-trade log (R multiple + USD net, incl. swap/commission)   |
//+------------------------------------------------------------------+
void LogClosed()
  {
   if(g_posID == 0) return;
   double net = 0.0;
   if(HistorySelectByPosition(g_posID))
     for(int i = 0; i < HistoryDealsTotal(); i++)
       { ulong d = HistoryDealGetTicket(i); if(d) net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION); }
   double r = 0.0;
   if(g_initialRisk > 0.0 && g_volume > 0.0)
     { double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
       double perLot = (tv > 0 && ts > 0) ? (g_initialRisk / ts * tv) : 0.0;      // $ risk per 1 lot
       double posRisk = perLot * g_volume;                                        // $ risk of the FULL position
       r = (posRisk > 0.0) ? net / posRisk : 0.0; }
   Log(StringFormat("position #%I64u CLOSED - net %s%.2fR / %.2f USD", (ulong)g_posID, r >= 0.0 ? "+" : "", r, net));
  }

//+------------------------------------------------------------------+
//| Adopt an existing position after restart/recompile               |
//+------------------------------------------------------------------+
void Adopt()
  {
   ulong tk = 0; if(!HasOpen(tk)) return;
   g_ticket = tk;
   if(PositionSelectByTicket(tk)) { double o = PositionGetDouble(POSITION_PRICE_OPEN), s = PositionGetDouble(POSITION_SL); g_initialRisk = (s > 0.0) ? MathAbs(o - s) : 0.0; g_posID = (long)PositionGetInteger(POSITION_IDENTIFIER); g_volume = PositionGetDouble(POSITION_VOLUME); }
  }

//+------------------------------------------------------------------+
//| Chart panel: liquidity pools, bias, session, last setup          |
//+------------------------------------------------------------------+
void Panel()
  {
   double swHi = 0.0, swLo = 0.0;
   const int n = InpSweepLookback + 2 * InpSwingStrength + 2;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpEntryTF, 1, n, r) >= n)
     {
      int pi = -1;
      if(FindSwing(r, n, 0, true, pi)) swHi = r[pi].high;
      if(FindSwing(r, n, 0, false, pi)) swLo = r[pi].low;
     }
   string bias = "off";
   if(InpUseBiasFilter)
     {
      double be[]; ArraySetAsSeries(be, true);
      if(CopyBuffer(g_hBiasEma, 0, 1, 1, be) >= 1)
        { const double cl = iClose(_Symbol, InpEntryTF, 1);
          bias = (cl > be[0]) ? "long-only" : (cl < be[0] ? "short-only" : "neutral"); }
      else bias = "n/a";
     }
   string sess = "off";
   if(InpUseSessionFilter) sess = InSession(TimeCurrent()) ? "OPEN" : "closed";
   string s = "KISS-EA v1.01 | " + _Symbol + " " + EnumToString(InpEntryTF) + " SMC sweep\n";
   s += StringFormat("Liquidity: swing high %s | swing low %s\n",
                     swHi > 0.0 ? DoubleToString(swHi, g_digits) : "-", swLo > 0.0 ? DoubleToString(swLo, g_digits) : "-");
   s += StringFormat("Bias: %s | Session: %s | Pos: %s\n", bias, sess, g_ticket != 0 ? "OPEN" : "flat");
   s += "Last setup: " + g_lastSetup;
   Comment(s);
  }
//+------------------------------------------------------------------+
