//+------------------------------------------------------------------+
//|                                                      TRAB_EA.mq5 |
//|        M1 Trend Reversal & Accumulation Breakout Expert Advisor  |
//|                                                                  |
//| Strategy : TRAB (see TRAB_EA_Proposal.md for the formal spec)    |
//| Timeframe: M1 only (enforced)                                    |
//| Symbol   : runs on the chart symbol it is attached to            |
//|                                                                  |
//| Phase 1 (Exhaustion)     : fast band (EMA20/50) entirely above   |
//|                            or below macro band (EMA150/200) for  |
//|                            N consecutive closed M1 candles       |
//| Phase 2 (Accumulation)   : 45-candle consolidation box + 4-EMA   |
//|                            squeeze below threshold               |
//| Phase 3 (Band crossover) : both fast EMAs definitively crossed   |
//|                            to the opposite side of the macro band|
//| Entry                    : M1 candle CLOSE outside the frozen box|
//|                            in the direction of the crossover     |
//| Exit                     : SL 1 pip outside opposite box edge OR |
//|                            beyond EMA150/200 cluster (deeper one |
//|                            wins), fixed TP at 1:2 RR, trailing   |
//|                            behind EMA50 after the 1:1 mark, plus |
//|                            EMA10/EMA20 adverse-cross exit        |
//| Safety                   : spread gate, session gate, slippage   |
//|                            cap, breakout-candle spike filter,    |
//|                            hard SL cap                           |
//+------------------------------------------------------------------+
#property copyright   "TRAB"
#property link        ""
#property version     "1.05"
#property description "M1 Trend Reversal & Accumulation Breakout EA"
#property description "Sequential phase state machine: Exhaustion -> Accumulation -> Crossover -> Breakout entry."
#property description "Runs on the chart symbol. M1 timeframe only."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Indicators ==="
input int    InpFastEma1Period        = 20;      // Fast EMA 1 period (leading edge)
input int    InpFastEma2Period        = 50;      // Fast EMA 2 period (confirmation / trail ref)
input int    InpSlowEma1Period        = 150;     // Slow EMA 1 period (macro band inner)
input int    InpSlowEma2Period        = 200;     // Slow EMA 2 period (macro band outer)

input group "=== Phase Detection ==="
input int    InpExhaustionLookbackBars= 60;      // Phase 1: consecutive separated candles
input int    InpBoxLookbackBars       = 45;      // Phase 2: consolidation box lookback
input double InpSqueezeThresholdPips  = 5.0;     // Phase 2: max 4-EMA spread (pips)
input int    InpSqueezeLookbackBars   = 3;       // Phase 2: squeeze averaging window
input int    InpCrossConfirmBars      = 2;       // Phase 3: bars to confirm definitive cross
input int    InpExhaustionMaxBars     = 240;     // Max bars exhaustion state may wait for a squeeze
input int    InpAccumulationMaxBars   = 60;      // Max bars accumulation state may wait for the cross

input group "=== Entry ==="
input int    InpSetupExpiryBars       = 20;      // Primed setup lifetime (bars, frozen box)
input double InpMaxBreakoutCandlePips = 20.0;    // Max breakout candle body (pips) - spike filter

input group "=== Risk & Exits ==="
input double InpSLBoxBufferPips       = 1.0;     // SL buffer beyond box edge (pips)
input double InpSLEmaBufferPips       = 2.0;     // SL buffer beyond EMA150/200 cluster (pips)
input double InpMaxStopLossPips       = 30.0;    // Hard SL cap (pips) - trade skipped if exceeded
input double InpRiskRewardRatio       = 2.0;     // Fixed TP = RR x initial risk (1:2)
input double InpRiskPercent           = 1.0;     // Risk % of equity per trade (0 = use FixedLots)
input double InpFixedLots             = 0.10;    // Fixed lots (used when RiskPercent = 0)
input double InpTrailActivateRR       = 1.0;     // Trailing activation (x initial risk, 1.0 = 1:1)
input double InpTrailBufferPips       = 1.0;     // Trail distance beyond EMA50 (pips)
input bool   InpRemoveTPWhenTrailing  = false;   // Remove fixed TP once trailing activates

input group "=== EMA Cross Exit (profit protection) ==="
input bool   InpUseEmaCrossExit       = true;    // Exit when the exit-EMAs cross against the trade
input int    InpEmaExitFastPeriod     = 10;      // Exit-cross fast EMA period (EMA10)
input int    InpEmaExitSlowPeriod     = 20;      // Exit-cross slow EMA period (EMA20)
input int    InpEmaExitConfirmBars    = 1;       // Closed bars the adverse cross must hold
input double InpEmaExitMinProfitRR    = 0.0;     // Min profit (x initial risk) to arm exit (0 = always)

input group "=== Exit Analytics (v1.05) ==="
input bool   InpExitAnalytics         = true;    // Journal exit-reason stats (R-multiples per exit type)
input bool   InpExportTradesCSV       = false;   // Append closed-trade records to MQL5\Files\TRAB_exits_<magic>.csv

input group "=== Broker Environment ==="
input double InpMaxSpreadPips         = 1.5;     // Max live spread (pips) - hard abort gate
input double InpMaxSlippagePips       = 1.0;     // OrderSend deviation (pips, clamped to 3.0)
input int    InpLondonStartHour       = 8;       // London session start hour (inclusive)
input int    InpLondonEndHour         = 16;      // London session end hour (inclusive)
input int    InpNYStartHour           = 13;      // New York session start hour (inclusive)
input int    InpNYEndHour             = 20;      // New York session end hour (inclusive)
input bool   InpUseServerTime         = false;   // true = session hours are broker server time
input int    InpServerGMTOffset       = 2;       // Broker server GMT offset (used when above = false)

input group "=== General ==="
input long   InpMagicNumber           = 20250915;// Magic number
input string InpTradeComment          = "TRAB";  // Order comment
input bool   InpAlertOnly             = false;   // Signal alert only, no trades (false = open trades)
input bool   InpEnforceM1Only         = true;    // Disable trading when not attached to M1
input double InpPipSizeOverride       = 0.0;     // Manual pip size in price units (0 = auto; e.g. 0.1 for XAUUSD)
input bool   InpShowPanel             = true;    // Show on-chart status panel

input group "=== State Colors (chart background tint) ==="
input bool   InpColorizeStates        = true;            // Tint chart background per state
input color  InpIdleBgColor           = clrNONE;         // IDLE background (clrNONE = keep original)
input color  InpExhaustedBgColor      = clrSaddleBrown;  // EXHAUSTED tint (amber/brown)
input color  InpAccumBgColor          = clrMidnightBlue; // ACCUMULATION tint (dark blue)
input color  InpPrimedLongBg          = clrDarkGreen;    // PRIMED long tint (dark green)
input color  InpPrimedShortBg         = clrDarkRed;      // PRIMED short tint (dark red)

//+------------------------------------------------------------------+
//| State machine                                                    |
//+------------------------------------------------------------------+
enum ENUM_TRAB_STATE
  {
   ST_IDLE       = 0,  // no qualified exhaustion yet
   ST_EXHAUSTED  = 1,  // Phase 1 confirmed, waiting for squeeze (Phase 2)
   ST_ACCUM      = 2,  // Phase 2 validated, waiting for crossover (Phase 3)
   ST_PRIMED     = 3   // Phase 3 confirmed, box frozen, waiting for breakout close
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade            g_trade;
int               g_hFast1          = INVALID_HANDLE;
int               g_hFast2          = INVALID_HANDLE;
int               g_hSlow1          = INVALID_HANDLE;
int               g_hSlow2          = INVALID_HANDLE;
int               g_hEmaExitFast    = INVALID_HANDLE;   // EMA cross-exit fast EMA (EMA10)
int               g_hEmaExitSlow    = INVALID_HANDLE;   // EMA cross-exit slow EMA (EMA20)

double            g_point           = 0.0;
double            g_pip             = 0.0;
int               g_digits          = 0;
double            g_slippagePips    = 0.0;
ulong             g_deviationPoints = 0;
bool              g_canTrade        = false;

ENUM_TRAB_STATE   g_state           = ST_IDLE;
int               g_dir             = 0;      // +1 long setup anticipated, -1 short setup
int               g_stateBars       = 0;
double            g_boxTop          = 0.0;
double            g_boxBottom       = 0.0;
bool              g_brokenOut       = false;
datetime          g_lastBarTime     = 0;

// bar-close data cache (index 0 = last CLOSED candle)
MqlRates          g_rates[];
double            g_f1[], g_f2[], g_s1[], g_s2[];
int               g_lastFresh       = 0;      // last fresh Phase-1 result (+1/-1/0)
double            g_lastSqueezePips = 0.0;    // last 4-EMA spread average (pips)

// open-position bookkeeping
ulong             g_ticket          = 0;
long              g_posID           = 0;
double            g_initialRisk     = 0.0;
bool              g_trailActive     = false;
bool              g_crossExitPending = false;          // EMA cross exit fired, close retry in progress
string            g_gvRiskName      = "";
double            g_lots            = 0.0;    // tracked position volume (for risk-money calc)
double            g_riskMoney       = 0.0;    // initial risk in account currency (R reference)
string            g_exitInitiated   = "";     // "" none | "CROSS" = EA cross-exit close in progress

// exit-reason analytics (v1.05) - per-session, reset on EA reload
int               g_exCnt[5];               // closes per exit type
double            g_exSumR[5];              // sum of R-multiples per exit type
int               g_exWins[5];              // profitable closes per exit type
int               g_exTotal        = 0;     // total closed trades this session
double            g_exSumRAll      = 0.0;    // total R this session

// chart background tinting
bool              g_bgSaved         = false;  // original background captured once
color             g_bgOriginal      = clrNONE;  // chart background before the EA tinted it
color             g_bgApplied       = clrNONE;  // color currently on the chart

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void Log(const string msg) { Print("TRAB: ", msg); }

double PipToPrice(const double pips) { return pips * g_pip; }

string StateName(const ENUM_TRAB_STATE s)
  {
   switch(s)
     {
      case ST_EXHAUSTED: return "EXHAUSTED";
      case ST_ACCUM:     return "ACCUMULATION";
      case ST_PRIMED:    return "PRIMED";
     }
   return "IDLE";
  }

//+------------------------------------------------------------------+
//| Exit analytics (v1.05): types, risk-money, stats, CSV export     |
//+------------------------------------------------------------------+
enum ENUM_EXIT_TYPE
  {
   EXIT_TP    = 0,   // fixed take-profit hit
   EXIT_TRAIL = 1,   // SL hit after trailing activated
   EXIT_CROSS = 2,   // EMA cross-exit market close
   EXIT_SL    = 3,   // hard SL hit (trailing never activated)
   EXIT_OTHER = 4    // manual close / stop-out / unknown
  };
#define EXIT_TYPE_COUNT 5

string ExitTypeName(const int t)
  {
   switch(t)
     {
      case EXIT_TP:    return "TP";
      case EXIT_TRAIL: return "Trail";
      case EXIT_CROSS: return "Cross";
      case EXIT_SL:    return "SL";
     }
   return "Other";
  }

// initial risk converted to account currency for a given volume
double RiskMoneyFor(const double lots)
  {
   if(g_initialRisk <= 0.0 || lots <= 0.0)
      return 0.0;
   const double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSize <= 0.0)
      return 0.0;
   return g_initialRisk / tickSize * tickVal * lots;
  }

string ExitStatsString()
  {
   string s = StringFormat("%d trade%s, %s%.2fR total", g_exTotal, (g_exTotal == 1 ? "" : "s"),
                           g_exSumRAll >= 0.0 ? "+" : "", g_exSumRAll);
   for(int t = 0; t < EXIT_TYPE_COUNT; t++)
      if(g_exCnt[t] > 0)
         s += StringFormat(" | %s %d (%s%.2fR, %d%% win)",
                           ExitTypeName(t), g_exCnt[t], g_exSumR[t] >= 0.0 ? "+" : "", g_exSumR[t],
                           (int)MathRound(100.0 * g_exWins[t] / g_exCnt[t]));
   return s;
  }

void UpdateExitStats(const int type, const double rMult)
  {
   g_exCnt[type]++;
   g_exSumR[type] += rMult;
   if(rMult > 0.0)
      g_exWins[type]++;
   g_exTotal++;
   g_exSumRAll += rMult;
   Log("exit stats: " + ExitStatsString());
  }

// append one closed-trade record to MQL5\Files\TRAB_exits_<magic>.csv
void ExportClosedTradeCSV(const int type, const double rMult, const double net, const double exitPrice)
  {
   const string name = StringFormat("TRAB_exits_%I64d.csv", InpMagicNumber);
   const int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
   if(h == INVALID_HANDLE)
     {
      Log(StringFormat("exit CSV: cannot open %s (error %d)", name, GetLastError()));
      return;
     }
   if(FileSize(h) == 0)
      FileWrite(h, "close_time", "symbol", "ticket", "exit_type", "R_multiple",
                "net_pnl", "currency", "exit_price");
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), _Symbol,
             StringFormat("%I64u", g_ticket), ExitTypeName(type),
             DoubleToString(rMult, 3), DoubleToString(net, 2),
             AccountInfoString(ACCOUNT_CURRENCY), DoubleToString(exitPrice, g_digits));
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Chart background tint per state (InpColorizeStates)              |
//+------------------------------------------------------------------+
color StateBgColor(const ENUM_TRAB_STATE s)
  {
   if(s == ST_PRIMED)
      return (g_dir > 0 ? InpPrimedLongBg : InpPrimedShortBg);
   switch(s)
     {
      case ST_EXHAUSTED: return InpExhaustedBgColor;
      case ST_ACCUM:     return InpAccumBgColor;
     }
   return InpIdleBgColor;
  }

void ApplyStateColor()
  {
   if(!InpColorizeStates)
      return;

   if(!g_bgSaved)                               // capture original exactly once
     {
      g_bgOriginal = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
      g_bgSaved    = true;
      g_bgApplied  = g_bgOriginal;
      Log(StringFormat("state tinting active - original background %s",
                       ColorToString(g_bgOriginal)));
     }

   color target = StateBgColor(g_state);
   if(target == g_bgApplied)                    // nothing changed -> no-op
      return;

   if(target == clrNONE)                        // "keep original" for this state
      target = g_bgOriginal;

   ChartSetInteger(0, CHART_COLOR_BACKGROUND, target);
   ChartRedraw();
   g_bgApplied = target;
  }

void RestoreBgColor()
  {
   if(g_bgSaved && g_bgApplied != g_bgOriginal)
     {
      ChartSetInteger(0, CHART_COLOR_BACKGROUND, g_bgOriginal);
      g_bgApplied = g_bgOriginal;
     }
  }

//+------------------------------------------------------------------+
//| Filling mode detection                                           |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFilling()
  {
   const uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // pip size: 3/5-digit quotes -> 10 points per pip; otherwise 1 point
   g_pip = (g_digits == 3 || g_digits == 5) ? g_point * 10.0 : g_point;
   if(InpPipSizeOverride > 0.0)
      g_pip = InpPipSizeOverride;

   if(g_point <= 0.0 || g_pip <= 0.0)
     {
      Log("INIT FAILED: invalid point/pip size for symbol " + _Symbol);
      return(INIT_FAILED);
     }

   // --- input validation ------------------------------------------------
   if(InpFastEma1Period <= 0 || InpFastEma2Period <= 0 ||
      InpSlowEma1Period <= 0 || InpSlowEma2Period <= 0 ||
      InpExhaustionLookbackBars < 5 || InpBoxLookbackBars < 5 ||
      InpSqueezeLookbackBars  < 1 || InpCrossConfirmBars   < 1 ||
      InpSqueezeThresholdPips <= 0 || InpRiskRewardRatio   <= 0 ||
      InpMaxStopLossPips      <= 0 || InpRiskPercent       <  0 ||
      InpFixedLots            <= 0 || InpMaxSpreadPips     <= 0 ||
      InpSetupExpiryBars      <  1 || InpTrailActivateRR   <= 0 ||
      InpEmaExitFastPeriod    <= 0 || InpEmaExitSlowPeriod <= 0 ||
      InpEmaExitConfirmBars   <  1 || InpEmaExitMinProfitRR <  0)
     {
      Log("INIT FAILED: invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // --- indicator handles -------------------------------------------------
   g_hFast1 = iMA(_Symbol, PERIOD_CURRENT, InpFastEma1Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hFast2 = iMA(_Symbol, PERIOD_CURRENT, InpFastEma2Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow1 = iMA(_Symbol, PERIOD_CURRENT, InpSlowEma1Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow2 = iMA(_Symbol, PERIOD_CURRENT, InpSlowEma2Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaExitFast = iMA(_Symbol, PERIOD_CURRENT, InpEmaExitFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaExitSlow = iMA(_Symbol, PERIOD_CURRENT, InpEmaExitSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hFast1 == INVALID_HANDLE || g_hFast2 == INVALID_HANDLE ||
      g_hSlow1 == INVALID_HANDLE || g_hSlow2 == INVALID_HANDLE ||
      g_hEmaExitFast == INVALID_HANDLE || g_hEmaExitSlow == INVALID_HANDLE)
     {
      Log("INIT FAILED: could not create EMA indicator handles");
      return(INIT_FAILED);
     }

   // --- timeframe enforcement ------------------------------------------------
   g_canTrade = true;
   if(InpEnforceM1Only && _Period != PERIOD_M1)
     {
      g_canTrade = false;
      Log("WARNING: attached to a non-M1 chart - trading DISABLED (EnforceM1Only=true)");
     }

   // --- trade object -----------------------------------------------------
   g_slippagePips    = MathMin(InpMaxSlippagePips, 3.0);          // hard clamp per spec
   g_deviationPoints = (ulong)MathRound(g_slippagePips * g_pip / g_point);
   g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   g_trade.SetDeviationInPoints(g_deviationPoints);
   g_trade.SetTypeFilling(GetFilling());
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // --- adopt an existing position (EA restart while in trade) -------------
   AdoptExistingPosition();

   // --- reset state ------------------------------------------------------
   g_state     = ST_IDLE;
   g_dir       = 0;
   g_stateBars = 0;
   g_brokenOut = false;
   g_crossExitPending = false;

   Log(StringFormat("initialized on %s %s | pip=%s | deviation=%u pts | magic=%I64d | risk=%.2f%%%s",
                    _Symbol, EnumToString(_Period), DoubleToString(g_pip, g_digits),
                    g_deviationPoints, InpMagicNumber, InpRiskPercent,
                    InpAlertOnly ? " | ALERT-ONLY MODE (no trades)" : ""));

   ApplyStateColor();      // tint immediately on attach (no tick needed - works when market is closed)
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hFast1 != INVALID_HANDLE) IndicatorRelease(g_hFast1);
   if(g_hFast2 != INVALID_HANDLE) IndicatorRelease(g_hFast2);
   if(g_hSlow1 != INVALID_HANDLE) IndicatorRelease(g_hSlow1);
   if(g_hSlow2 != INVALID_HANDLE) IndicatorRelease(g_hSlow2);
   if(g_hEmaExitFast != INVALID_HANDLE) IndicatorRelease(g_hEmaExitFast);
   if(g_hEmaExitSlow != INVALID_HANDLE) IndicatorRelease(g_hEmaExitSlow);
   if(g_exTotal > 0)
      Log("final exit stats - " + ExitStatsString());
   RestoreBgColor();
   Comment("");
  }

//+------------------------------------------------------------------+
//| Tick handler: trailing every tick, signals on bar close only     |
//+------------------------------------------------------------------+
void OnTick()
  {
   ManageOpenPosition();

   const bool newBar = IsNewBar();

   // bar-close profit-protection exit (retries every tick while a close is pending)
   if(newBar || g_crossExitPending)
      CheckEmaCrossExit();

   if(newBar && g_canTrade)
      EvaluateOnBarClose();

   if(InpShowPanel)
      UpdatePanel();

   ApplyStateColor();       // no-op unless the state (and thus tint) changed
  }

//+------------------------------------------------------------------+
//| New M1 bar detection                                             |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   const datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t == 0 || t == g_lastBarTime)
      return false;
   g_lastBarTime = t;
   return true;
  }

//+------------------------------------------------------------------+
//| Fetch closed-candle rates + EMA values (index 0 = last closed)   |
//+------------------------------------------------------------------+
bool FetchMarketData(const int count)
  {
   ArraySetAsSeries(g_rates, true);
   ArraySetAsSeries(g_f1, true);
   ArraySetAsSeries(g_f2, true);
   ArraySetAsSeries(g_s1, true);
   ArraySetAsSeries(g_s2, true);

   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, count, g_rates) < count) return false;
   if(CopyBuffer(g_hFast1, 0, 1, count, g_f1) < count)               return false;
   if(CopyBuffer(g_hFast2, 0, 1, count, g_f2) < count)               return false;
   if(CopyBuffer(g_hSlow1, 0, 1, count, g_s1) < count)               return false;
   if(CopyBuffer(g_hSlow2, 0, 1, count, g_s2) < count)               return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Band separation helpers (index i over the closed-candle cache)   |
//+------------------------------------------------------------------+
bool FastAbove(const int i)
  {
   return (g_f1[i] > g_s1[i] && g_f1[i] > g_s2[i] &&
           g_f2[i] > g_s1[i] && g_f2[i] > g_s2[i]);
  }

bool FastBelow(const int i)
  {
   return (g_f1[i] < g_s1[i] && g_f1[i] < g_s2[i] &&
           g_f2[i] < g_s1[i] && g_f2[i] < g_s2[i]);
  }

//+------------------------------------------------------------------+
//| Phase 1 (fresh): fast band fully on one side for N closed bars.  |
//| Returns +1 (downtrend exhausted -> long setup), -1 (uptrend      |
//| exhausted -> short setup) or 0 (no qualified exhaustion).        |
//+------------------------------------------------------------------+
int FreshPhase1()
  {
   bool allAbove = true, allBelow = true;
   for(int i = 1; i <= InpExhaustionLookbackBars && (allAbove || allBelow); i++)
     {
      if(!FastAbove(i)) allAbove = false;
      if(!FastBelow(i)) allBelow = false;
     }
   if(allAbove) return -1;   // exhausted uptrend  -> short reversal anticipated
   if(allBelow) return +1;   // exhausted downtrend -> long reversal anticipated
   return 0;
  }

//+------------------------------------------------------------------+
//| Phase 2: average 4-EMA spread over the squeeze window (price)    |
//+------------------------------------------------------------------+
double SqueezeAvgPrice()
  {
   double sum = 0.0;
   for(int i = 1; i <= InpSqueezeLookbackBars; i++)
     {
      const double hi = MathMax(MathMax(g_f1[i], g_f2[i]), MathMax(g_s1[i], g_s2[i]));
      const double lo = MathMin(MathMin(g_f1[i], g_f2[i]), MathMin(g_s1[i], g_s2[i]));
      sum += (hi - lo);
     }
   return sum / InpSqueezeLookbackBars;
  }

bool SqueezeValid() { return SqueezeAvgPrice() < PipToPrice(InpSqueezeThresholdPips); }

//+------------------------------------------------------------------+
//| Full separation of both fast EMAs held for CrossConfirmBars.     |
//| oppositeSide=true  -> separation on the REVERSAL side (Phase 3)  |
//| oppositeSide=false -> separation on the ORIGINAL trend side      |
//+------------------------------------------------------------------+
bool SeparationHeld(const int setupDir, const bool oppositeSide)
  {
   for(int i = 1; i <= InpCrossConfirmBars; i++)
     {
      const bool wantAbove = (oppositeSide ? (setupDir > 0) : (setupDir < 0));
      const bool ok        = wantAbove ? FastAbove(i) : FastBelow(i);
      if(!ok)
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Consolidation box over the box lookback (frozen at priming)      |
//+------------------------------------------------------------------+
bool ComputeBox()
  {
   double top = -DBL_MAX, bot = DBL_MAX;
   for(int i = 1; i <= InpBoxLookbackBars; i++)
     {
      top = MathMax(top, g_rates[i].high);
      bot = MathMin(bot, g_rates[i].low);
     }
   if(top <= bot)
      return false;
   g_boxTop    = top;
   g_boxBottom = bot;
   return true;
  }

//+------------------------------------------------------------------+
//| Session filter (London / New York windows)                       |
//+------------------------------------------------------------------+
bool SessionOK()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   if(!InpUseServerTime)
     {
      hour -= InpServerGMTOffset;                  // convert server time -> GMT
      hour  = ((hour % 24) + 24) % 24;
     }
   const bool london = (hour >= InpLondonStartHour && hour <= InpLondonEndHour);
   const bool ny     = (hour >= InpNYStartHour     && hour <= InpNYEndHour);
   return (london || ny);
  }

//+------------------------------------------------------------------+
//| Reset the state machine to IDLE                                  |
//+------------------------------------------------------------------+
void ResetToIdle(const string reason)
  {
   if(g_state != ST_IDLE)
      Log(StringFormat("state %s -> IDLE (%s)", StateName(g_state), reason));
   g_state     = ST_IDLE;
   g_dir       = 0;
   g_stateBars = 0;
   g_boxTop    = 0.0;
   g_boxBottom = 0.0;
   g_brokenOut = false;
  }

//+------------------------------------------------------------------+
//| Open position scan (this EA + this symbol only)                  |
//+------------------------------------------------------------------+
bool HasOpenPosition(ulong &ticket, long &posId)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         ticket = t;
         posId  = PositionGetInteger(POSITION_IDENTIFIER);
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Adopt an existing position after EA restart                      |
//+------------------------------------------------------------------+
void AdoptExistingPosition()
  {
   ulong ticket = 0;
   long  posId  = 0;
   if(!HasOpenPosition(ticket, posId))
      return;

   g_ticket     = ticket;
   g_posID      = posId;
   g_gvRiskName = StringFormat("TRAB_%I64d_%I64u_R", InpMagicNumber, ticket);

   if(PositionSelectByTicket(ticket))
     {
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl   = PositionGetDouble(POSITION_SL);
      g_lots            = PositionGetDouble(POSITION_VOLUME);
      if(GlobalVariableCheck(g_gvRiskName))
         g_initialRisk = GlobalVariableGet(g_gvRiskName);
      else if(sl > 0.0)
         g_initialRisk = MathAbs(open - sl);
     }
   g_riskMoney        = RiskMoneyFor(g_lots);
   g_exitInitiated    = "";
   g_trailActive      = false;
   g_crossExitPending = false;
   Log(StringFormat("adopted existing position #%I64u (posID %I64d), initial risk %s",
                    ticket, posId, DoubleToString(g_initialRisk, g_digits)));
  }

//+------------------------------------------------------------------+
//| Core state machine - runs once per new M1 bar (on bar close)     |
//+------------------------------------------------------------------+
void EvaluateOnBarClose()
  {
   // the state machine is frozen while a position is open
   ulong ticket = 0;
   long  posId  = 0;
   if(HasOpenPosition(ticket, posId))
      return;

   // enough closed bars for the largest lookback plus safety margin
   const int need = MathMax(InpExhaustionLookbackBars, InpBoxLookbackBars) +
                    MathMax(InpCrossConfirmBars, InpSqueezeLookbackBars) + 5;
   if(!FetchMarketData(need))
     {
      Log("history/indicator data not ready - evaluation skipped");
      return;
     }

   g_lastFresh       = FreshPhase1();
   g_lastSqueezePips = SqueezeAvgPrice() / g_pip;

   switch(g_state)
     {
      // --------------------------------------------------------------
      case ST_IDLE:
        {
         if(g_lastFresh != 0 && SessionOK())
           {
            g_state     = ST_EXHAUSTED;
            g_dir       = g_lastFresh;
            g_stateBars = 0;
            Log(StringFormat("Phase 1 confirmed (%s exhaustion) -> EXHAUSTED, waiting for accumulation squeeze",
                             g_dir > 0 ? "downtrend" : "uptrend"));
           }
         break;
        }

      // --------------------------------------------------------------
      case ST_EXHAUSTED:
        {
         if(g_lastFresh != 0 && g_lastFresh != g_dir)
           {
            g_dir       = g_lastFresh;
            g_stateBars = 0;
            Log("exhaustion direction flipped - re-armed");
           }
         else if(g_lastFresh == g_dir)
            g_stateBars = 0;                       // trend still intact, keep waiting

         if(SessionOK() && SqueezeValid())
           {
            g_state     = ST_ACCUM;
            g_stateBars = 0;
            Log(StringFormat("Phase 2 validated (EMA spread %.1f < %.1f pips) -> ACCUMULATION",
                             g_lastSqueezePips, InpSqueezeThresholdPips));
            break;
           }

         g_stateBars++;
         if(g_stateBars > InpExhaustionMaxBars)
            ResetToIdle("exhaustion wait expired without a squeeze");
         break;
        }

      // --------------------------------------------------------------
      case ST_ACCUM:
        {
         if(g_lastFresh != 0 && g_lastFresh != g_dir)
           {
            g_state     = ST_EXHAUSTED;
            g_dir       = g_lastFresh;
            g_stateBars = 0;
            Log("fresh opposite exhaustion - re-anchored");
            break;
           }

         if(SessionOK() && SeparationHeld(g_dir, true))          // Phase 3: reversal side
           {
            if(ComputeBox())
              {
               g_state     = ST_PRIMED;
               g_stateBars = 0;
               g_brokenOut = false;
               Log(StringFormat("Phase 3 confirmed (%s crossover) -> PRIMED | box %s .. %s",
                                g_dir > 0 ? "bullish" : "bearish",
                                DoubleToString(g_boxBottom, g_digits),
                                DoubleToString(g_boxTop, g_digits)));
              }
            break;
           }

         if(SeparationHeld(g_dir, false))                        // back to original side
           {
            ResetToIdle("squeeze failed - fast band returned to original side");
            break;
           }

         g_stateBars++;
         if(g_stateBars > InpAccumulationMaxBars)
            ResetToIdle("accumulation wait expired without a crossover");
         break;
        }

      // --------------------------------------------------------------
      case ST_PRIMED:
        {
         const double c1        = g_rates[0].close;
         const bool   brokeUp   = (c1 > g_boxTop);
         const bool   brokeDown = (c1 < g_boxBottom);

         if(brokeUp || brokeDown)
            g_brokenOut = true;

         if(g_dir > 0 && brokeUp)
            TryEnter(+1);
         else if(g_dir < 0 && brokeDown)
            TryEnter(-1);
         else if((g_dir > 0 && brokeDown) || (g_dir < 0 && brokeUp))
           {
            ResetToIdle("wrong-side breakout - setup invalidated");
            break;
           }

         if(g_ticket != 0)                       // entry executed inside TryEnter
           {
            ResetToIdle("trade opened");
            break;
           }
         if(g_state != ST_PRIMED)                // setup invalidated inside TryEnter
            break;

         if(g_brokenOut && !brokeUp && !brokeDown)
           {
            ResetToIdle("price closed back inside the box (failed breakout)");
            break;
           }

         g_stateBars++;
         if(g_stateBars >= InpSetupExpiryBars)
            ResetToIdle("primed setup expired");
         break;
        }
     }
  }

//+------------------------------------------------------------------+
//| Breakout entry with all safety gates                             |
//+------------------------------------------------------------------+
void TryEnter(const int dir)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   // --- gate 1: live spread -------------------------------------------------
   const double spreadPips = (tick.ask - tick.bid) / g_pip;
   if(spreadPips > InpMaxSpreadPips)
     {
      Log(StringFormat("ENTRY ABORTED: spread %.1f pips > max %.1f pips", spreadPips, InpMaxSpreadPips));
      return;
     }

   // --- gate 2: session window -----------------------------------------------
   if(!SessionOK())
     {
      Log("ENTRY ABORTED: outside London/New York session windows");
      return;
     }

   // --- gate 3: breakout candle spike filter (the closed breakout candle) -----
   const double bodyPips = MathAbs(g_rates[0].close - g_rates[0].open) / g_pip;
   if(bodyPips > InpMaxBreakoutCandlePips)
     {
      Log(StringFormat("ENTRY ABORTED: breakout candle body %.1f pips > max %.1f pips",
                       bodyPips, InpMaxBreakoutCandlePips));
      return;
     }

   // --- gate 4: no open position (defensive double-check) ----------------------
   ulong ticket = 0;
   long  posId  = 0;
   if(HasOpenPosition(ticket, posId))
     {
      Log("ENTRY ABORTED: position already open");
      return;
     }

   const double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;

   // --- SL: box edge vs EMA150/200 cluster - the deeper level wins -------------
   double entry, sl, risk;
   if(dir > 0)
     {
      entry      = tick.ask;
      const double slBox = g_boxBottom - PipToPrice(InpSLBoxBufferPips);
      const double slEma = MathMin(g_s1[0], g_s2[0]) - PipToPrice(InpSLEmaBufferPips);
      sl   = MathMin(slBox, slEma);
      risk = entry - sl;
     }
   else
     {
      entry      = tick.bid;
      const double slBox = g_boxTop + PipToPrice(InpSLBoxBufferPips);
      const double slEma = MathMax(g_s1[0], g_s2[0]) + PipToPrice(InpSLEmaBufferPips);
      sl   = MathMax(slBox, slEma);
      risk = sl - entry;
     }

   if(risk <= 0.0)
     {
      Log("TRADE SKIPPED: non-positive stop distance");
      return;
     }
   if(risk > PipToPrice(InpMaxStopLossPips))
     {
      Log(StringFormat("TRADE SKIPPED: computed SL %.1f pips exceeds cap %.1f pips",
                       risk / g_pip, InpMaxStopLossPips));
      ResetToIdle("SL cap exceeded");
      return;
     }
   if(risk < minDist || InpRiskRewardRatio * risk < minDist)
     {
      Log("TRADE SKIPPED: SL/TP inside broker stops level");
      return;
     }

   const double tp = (dir > 0) ? entry + InpRiskRewardRatio * risk
                               : entry - InpRiskRewardRatio * risk;

   // --- alert-only mode: report the signal instead of sending the order --------
   if(InpAlertOnly)
     {
      const string sig = StringFormat("%s %s | entry ~%s | SL %s | TP %s | risk %.1f pips | RR 1:%.2f",
                                      dir > 0 ? "BUY" : "SELL", _Symbol,
                                      DoubleToString(entry, g_digits),
                                      DoubleToString(sl, g_digits),
                                      DoubleToString(tp, g_digits),
                                      risk / g_pip, InpRiskRewardRatio);
      Alert("TRAB SIGNAL: ", sig);
      Log("ALERT-ONLY: " + sig);
      ResetToIdle("signal alerted (alert-only mode)");
      return;
     }

   const double lots = ComputeLots(risk, entry, dir);
   if(lots <= 0.0)
     {
      Log("TRADE SKIPPED: position sizing produced no valid volume");
      return;
     }

   const double slN = NormalizeDouble(sl, g_digits);
   const double tpN = NormalizeDouble(tp, g_digits);

   const bool sent = (dir > 0)
                     ? g_trade.Buy(lots, _Symbol, 0.0, slN, tpN, InpTradeComment)
                     : g_trade.Sell(lots, _Symbol, 0.0, slN, tpN, InpTradeComment);
   const uint ret = g_trade.ResultRetcode();

   if(sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
     {
      ulong tk = 0;
      long  pi = 0;
      if(HasOpenPosition(tk, pi))
        {
         g_ticket     = tk;
         g_posID      = pi;
         g_gvRiskName = StringFormat("TRAB_%I64d_%I64u_R", InpMagicNumber, tk);
         if(PositionSelectByTicket(tk))
           {
            const double open = PositionGetDouble(POSITION_PRICE_OPEN);
            g_initialRisk = MathAbs(open - slN);
            GlobalVariableSet(g_gvRiskName, g_initialRisk);
            g_lots = PositionGetDouble(POSITION_VOLUME);
           }
         g_riskMoney        = RiskMoneyFor(g_lots);
         g_exitInitiated    = "";
         g_trailActive      = false;
         g_crossExitPending = false;
        }
      Log(StringFormat(">>> %s %s %s @ %s | SL %s | TP %s | risk %.1f pips | RR 1:%.2f",
                       dir > 0 ? "BUY" : "SELL", DoubleToString(lots, 2), _Symbol,
                       DoubleToString(g_trade.ResultPrice(), g_digits),
                       DoubleToString(slN, g_digits), DoubleToString(tpN, g_digits),
                       risk / g_pip, InpRiskRewardRatio));
     }
   else
     {
      Log(StringFormat("OrderSend FAILED: retcode=%u (%s) - setup stays primed for retry",
                       ret, g_trade.ResultRetcodeDescription()));
     }
  }

//+------------------------------------------------------------------+
//| Position sizing: risk % of equity (or fixed lots) + margin check |
//+------------------------------------------------------------------+
double ComputeLots(const double riskDist, const double price, const int dir)
  {
   double lots = 0.0;

   if(InpRiskPercent <= 0.0)
      lots = InpFixedLots;
   else
     {
      const double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
      const double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickVal <= 0.0 || tickSize <= 0.0)
         return 0.0;
      const double lossPerLot = riskDist / tickSize * tickVal;   // account currency per 1.0 lot
      if(lossPerLot <= 0.0)
         return 0.0;
      lots = riskMoney / lossPerLot;
     }

   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step > 0.0)
      lots = MathFloor(lots / step) * step;
   if(lots > maxLot)
      lots = maxLot;

   if(lots < minLot)
     {
      Log(StringFormat("sizing: computed volume %s below minimum %s - trade skipped (risk control)",
                       DoubleToString(lots, 2), DoubleToString(minLot, 2)));
      return 0.0;
     }

   // --- margin safety --------------------------------------------------------
   double margin = 0.0;
   if(!OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, margin))
      return 0.0;
   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin * 0.9)
     {
      double reduced = lots * (freeMargin * 0.9) / margin;
      if(step > 0.0)
         reduced = MathFloor(reduced / step) * step;
      if(reduced < minLot)
        {
         Log("sizing: insufficient free margin - trade skipped");
         return 0.0;
        }
      Log(StringFormat("sizing: volume reduced %s -> %s to respect free margin",
                       DoubleToString(lots, 2), DoubleToString(reduced, 2)));
      lots = reduced;
     }
   return lots;
  }

//+------------------------------------------------------------------+
//| Per-tick position management: trailing stop behind EMA50         |
//| Activates when unrealized profit reaches TrailActivateRR x risk  |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(g_ticket == 0)
      return;

   if(!PositionSelectByTicket(g_ticket))
     {
      LogClosedPosition();                       // position no longer exists -> closed
      if(g_gvRiskName != "")
        {
         GlobalVariableDel(g_gvRiskName);
         g_gvRiskName = "";
        }
      g_ticket           = 0;
      g_posID            = 0;
      g_initialRisk      = 0.0;
      g_lots             = 0.0;
      g_riskMoney        = 0.0;
      g_exitInitiated    = "";
      g_trailActive      = false;
      g_crossExitPending = false;
      return;
     }

   const long   type = PositionGetInteger(POSITION_TYPE);
   const double open = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl   = PositionGetDouble(POSITION_SL);
   const double tp   = PositionGetDouble(POSITION_TP);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   // recover the initial risk reference after an EA restart
   if(g_initialRisk <= 0.0)
     {
      if(g_gvRiskName != "" && GlobalVariableCheck(g_gvRiskName))
         g_initialRisk = GlobalVariableGet(g_gvRiskName);
      else if(sl > 0.0)
         g_initialRisk = MathAbs(open - sl);
      else
         return;                                 // no risk reference - cannot trail safely
     }

   const double profitDist = (type == POSITION_TYPE_BUY) ? (tick.bid - open) : (open - tick.ask);
   if(profitDist < InpTrailActivateRR * g_initialRisk)
      return;                                    // 1:1 mark not reached yet

   if(!g_trailActive)
     {
      g_trailActive = true;
      Log(StringFormat("trailing stop ACTIVATED at %.2fR (profit %.1f pips vs risk %.1f pips)",
                       profitDist / g_initialRisk, profitDist / g_pip, g_initialRisk / g_pip));
      if(InpRemoveTPWhenTrailing && tp != 0.0)
        {
         g_trade.PositionModify(g_ticket, sl, 0.0);
         Log("fixed TP removed to capture extended trends");
        }
     }

   // candidate SL just behind the EMA50 of the last CLOSED candle
   double e[];
   if(CopyBuffer(g_hFast2, 0, 1, 1, e) < 1)
      return;
   const double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   const double newTP      = InpRemoveTPWhenTrailing ? 0.0 : tp;

   if(type == POSITION_TYPE_BUY)
     {
      const double cand = NormalizeDouble(e[0] - PipToPrice(InpTrailBufferPips), g_digits);
      if(cand > sl && cand <= tick.bid - stopsLevel && cand < tick.bid)
         g_trade.PositionModify(g_ticket, cand, newTP);
     }
   else
     {
      const double cand = NormalizeDouble(e[0] + PipToPrice(InpTrailBufferPips), g_digits);
      if((sl == 0.0 || cand < sl) && cand >= tick.ask + stopsLevel && cand > tick.ask)
         g_trade.PositionModify(g_ticket, cand, newTP);
     }
  }

//+------------------------------------------------------------------+
//| Bar-close profit protection: exit when the exit-EMA pair         |
//| (EMA10 x EMA20 by default) crosses against the open trade.       |
//| A FRESH adverse cross within the last ConfirmBars closed bars    |
//| triggers a market close; failed close attempts retry every tick. |
//+------------------------------------------------------------------+
void CheckEmaCrossExit()
  {
   if(!InpUseEmaCrossExit || g_ticket == 0)
      return;

   if(!PositionSelectByTicket(g_ticket))
      return;                                  // already gone - ManageOpenPosition cleans up

   const long type = PositionGetInteger(POSITION_TYPE);

   // optional profit gate: only arm the exit once profit exceeds the threshold
   if(InpEmaExitMinProfitRR > 0.0)
     {
      if(g_initialRisk <= 0.0)
         return;                               // no risk reference - gate cannot be evaluated
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
         return;
      const double open       = PositionGetDouble(POSITION_PRICE_OPEN);
      const double profitDist = (type == POSITION_TYPE_BUY) ? (tick.bid - open) : (open - tick.ask);
      if(profitDist < InpEmaExitMinProfitRR * g_initialRisk)
        {
         g_crossExitPending = false;           // gate no longer met - drop any stale retry
         return;
        }
     }

   if(!g_crossExitPending)                     // fresh signal - evaluate once per closed bar
     {
      const int need = InpEmaExitConfirmBars + 1;   // confirm window + pre-cross bar
      double ef[], es[];
      ArraySetAsSeries(ef, true);
      ArraySetAsSeries(es, true);
      if(CopyBuffer(g_hEmaExitFast, 0, 1, need, ef) < need) return;
      if(CopyBuffer(g_hEmaExitSlow, 0, 1, need, es) < need) return;

      const bool isBuy = (type == POSITION_TYPE_BUY);

      // adverse cross = exit-fast EMA on the losing side of the exit-slow EMA
      bool adverse = true;
      for(int i = 0; i < InpEmaExitConfirmBars && adverse; i++)
         adverse = isBuy ? (ef[i] < es[i]) : (ef[i] > es[i]);
      if(!adverse)
         return;

      // must be a FRESH cross: the bar before the window was still on the safe side,
      // so a pair already crossed against us at entry never instantly flattens the trade
      const bool wasSafe = isBuy
                           ? (ef[InpEmaExitConfirmBars] >= es[InpEmaExitConfirmBars])
                           : (ef[InpEmaExitConfirmBars] <= es[InpEmaExitConfirmBars]);
      if(!wasSafe)
         return;

      g_crossExitPending = true;
      Log(StringFormat("EMA cross EXIT (%s): EMA%d crossed %s EMA%d - closing position #%I64u%s",
                       isBuy ? "bearish" : "bullish",
                       InpEmaExitFastPeriod,
                       isBuy ? "below" : "above",
                       InpEmaExitSlowPeriod,
                       g_ticket,
                       InpEmaExitMinProfitRR > 0.0 ? " (profit gate passed)" : ""));
     }

   // close at market; on failure the pending flag keeps retrying every tick
   g_exitInitiated = "CROSS";                 // tag for exit-reason classification (v1.05)
   if(g_trade.PositionClose(g_ticket))
     {
      const uint ret = g_trade.ResultRetcode();
      if(ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED)
        {
         g_crossExitPending = false;
         Log(StringFormat("EMA cross EXIT executed on position #%I64u", g_ticket));
        }
     }
  }

//+------------------------------------------------------------------+
//| Log the closed result of the tracked position                    |
//+------------------------------------------------------------------+
void LogClosedPosition()
  {
   double net        = 0.0;
   long   exitReason = -1;
   long   inType     = -1;
   double openPrice  = 0.0;
   double exitPxSum  = 0.0;
   double exitVol    = 0.0;

   if(g_posID != 0 && HistorySelectByPosition(g_posID))
     {
      const int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
        {
         const ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         net += HistoryDealGetDouble(d, DEAL_PROFIT)
              + HistoryDealGetDouble(d, DEAL_SWAP)
              + HistoryDealGetDouble(d, DEAL_COMMISSION);
         const long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN && openPrice == 0.0)
           {
            openPrice = HistoryDealGetDouble(d, DEAL_PRICE);
            inType    = HistoryDealGetInteger(d, DEAL_TYPE);   // DEAL_TYPE_BUY = long
           }
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
           {
            exitReason  = HistoryDealGetInteger(d, DEAL_REASON);
            exitPxSum  += HistoryDealGetDouble(d, DEAL_PRICE) * HistoryDealGetDouble(d, DEAL_VOLUME);
            exitVol    += HistoryDealGetDouble(d, DEAL_VOLUME);
           }
        }
     }

   // --- classify the exit (v1.05) ---
   int type = EXIT_OTHER;                                    // manual close / stop-out / unknown
   if(exitReason == DEAL_REASON_TP)
      type = EXIT_TP;
   else if(exitReason == DEAL_REASON_SL)
      type = (g_trailActive ? EXIT_TRAIL : EXIT_SL);
   else if(g_exitInitiated == "CROSS" && exitReason == DEAL_REASON_EXPERT)
      type = EXIT_CROSS;

   // --- R-multiple: money-based when available, else price-based ---
   double rMult = 0.0;
   if(g_riskMoney > 0.0)
      rMult = net / g_riskMoney;
   else if(g_initialRisk > 0.0 && exitVol > 0.0 && openPrice > 0.0)
     {
      const double exitAvg = exitPxSum / exitVol;
      rMult = ((inType == DEAL_TYPE_BUY ? exitAvg - openPrice : openPrice - exitAvg) / g_initialRisk);
     }

   Log(StringFormat("position #%I64u CLOSED - exit: %s | net %s%.2fR / %s %s",
                    g_ticket, ExitTypeName(type),
                    rMult >= 0.0 ? "+" : "", rMult,
                    DoubleToString(net, 2), AccountInfoString(ACCOUNT_CURRENCY)));

   if(InpExitAnalytics)
      UpdateExitStats(type, rMult);
   if(InpExportTradesCSV)
      ExportClosedTradeCSV(type, rMult, net, exitVol > 0.0 ? exitPxSum / exitVol : 0.0);
  }

//+------------------------------------------------------------------+
//| On-chart status panel                                            |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   MqlTick tick;
   double spreadPips = 0.0;
   if(SymbolInfoTick(_Symbol, tick))
      spreadPips = (tick.ask - tick.bid) / g_pip;

   string freshTxt = "none";
   if(g_lastFresh > 0)
      freshTxt = "downtrend-exhausted (long setup)";
   else if(g_lastFresh < 0)
      freshTxt = "uptrend-exhausted (short setup)";

   string s = "TRAB EA v1.05 | " + _Symbol + " " + EnumToString(_Period) + "\n";
   if(InpAlertOnly)
      s += ">>> ALERT-ONLY MODE: signals are alerted, NO trades are opened <<<\n";
   if(!g_canTrade)
      s += ">>> TRADING DISABLED: attach to an M1 chart (EnforceM1Only=true) <<<\n";

   s += "State: " + StateName(g_state);
   if(g_state != ST_IDLE)
      s += StringFormat(" | dir: %s | bars in state: %d",
                        g_dir > 0 ? "LONG setup" : "SHORT setup", g_stateBars);
   s += "\n";

   if(g_state == ST_PRIMED)
      s += StringFormat("Frozen box: %s .. %s | breakout seen: %s\n",
                        DoubleToString(g_boxBottom, g_digits),
                        DoubleToString(g_boxTop, g_digits),
                        g_brokenOut ? "yes" : "no");

   s += StringFormat("Fresh P1: %s | EMA squeeze avg: %.1f pips (max %.1f)\n",
                     freshTxt, g_lastSqueezePips, InpSqueezeThresholdPips);
   s += StringFormat("Spread: %.1f pips (max %.1f) | Session: %s\n",
                     spreadPips, InpMaxSpreadPips, SessionOK() ? "OPEN" : "closed");

   if(g_ticket != 0 && PositionSelectByTicket(g_ticket))
      s += StringFormat("Position: %s %s @ %s | SL %s | TP %s | trail %s | emaX %s\n",
                        PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL",
                        DoubleToString(PositionGetDouble(POSITION_VOLUME), 2),
                        DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), g_digits),
                        DoubleToString(PositionGetDouble(POSITION_SL), g_digits),
                        DoubleToString(PositionGetDouble(POSITION_TP), g_digits),
                        g_trailActive ? "ACTIVE" : "standby",
                        g_crossExitPending ? "CLOSING" : (InpUseEmaCrossExit ? "armed" : "off"));
   else
      s += "Position: flat\n";

   if(g_exTotal > 0)
      s += StringFormat("Closed this session: %s\n", ExitStatsString());

   Comment(s);
  }
//+------------------------------------------------------------------+
