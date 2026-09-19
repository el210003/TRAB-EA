//+------------------------------------------------------------------+
//|                                                      TRAB_EA.mq5 |
//|        M1 Trend Reversal & Accumulation Breakout Expert Advisor  |
//|                                                                  |
//| Strategy : TRAB (see TRAB_EA_Proposal.md for the formal spec)    |
//| Timeframe: M1 only (enforced)                                    |
//| Symbol   : runs on the chart symbol it is attached to            |
//|                                                                  |
//| Phase 1 (Trend)          : full EMA stack E20>E50>E150>E200 (or  |
//|                            reverse) on closed bars - trend exists |
//| Phase 2 (Crack)          : EMA20 crosses EMA50 against the stack; |
//|                            box = price range from the crack bar   |
//|                            until before the EMA20/EMA150 cross;   |
//|                            price must never touch EMA20 (purity)  |
//| Phase 3 (Sweep)          : EMA20 sweeps beyond EMA150 AND EMA200  |
//|                            within SweepMaxBars of the crack       |
//| Entry                    : retest of EMA150 with a pin bar;       |
//|                            failed retest / no pin -> ACCUMULATION |
//| Exit                     : SL = pin-bar extreme +/- buffer, fixed |
//|                            TP at 1:2 RR, trailing behind EMA50    |
//|                            after the 1:1 mark, plus EMA10/EMA20   |
//|                            adverse-cross exit                     |
//| Safety                   : spread gate, session gate, slippage   |
//|                            cap, breakout-candle spike filter,    |
//|                            hard SL cap                           |
//+------------------------------------------------------------------+
#property copyright   "TRAB"
#property link        ""
#property version     "1.12"
#property description "M1 Trend Reversal & Accumulation Breakout EA"
#property description "Sequential EMA-configuration state machine: Stack -> Crack -> Sweep -> Retest entry."
#property description "Runs on the chart symbol. M1 timeframe only."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Retest level source (v1.11)                                       |
//+------------------------------------------------------------------+
enum ENUM_RETEST_MODE
  {
   RT_EMA     = 0,   // moving-average retest (InpRetestEmaPeriod)
   RT_FIB     = 1,   // Fibonacci retracement of the crack->sweep impulse
   RT_BREAK   = 2,   // sweep-breakout bar extreme (break-and-retest)
   RT_SWING   = 3    // recent swing (zigzag) high/low
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Indicators ==="
input int    InpFastEma1Period        = 20;      // Fast EMA 1 period (leading edge)
input int    InpFastEma2Period        = 50;      // Fast EMA 2 period (confirmation / trail ref)
input int    InpSlowEma1Period        = 150;     // Slow EMA 1 period (macro band inner)
input int    InpSlowEma2Period        = 200;     // Slow EMA 2 period (macro band outer)

input group "=== Phase Machine (v1.09) ==="
input int    InpSweepMaxBars          = 12;      // Max bars from crack to sweep; bounds retest attempts too
input bool   InpPricePurityTouch      = true;    // Sweep purity: touch of EMA20 (vs close) invalidates
input double InpPinWickRatio          = 2.0;     // Pin bar: rejection wick >= ratio x body
input int    InpRetestEmaPeriod       = 150;      // Retest EMA period for the pin-bar entry
input ENUM_RETEST_MODE InpRetestMode  = RT_EMA;    // Retest level source (EMA / Fib / breakout / swing)
input double InpRetestFib             = 0.382;     // Fib retracement fraction (RT_FIB mode)
input int    InpSwingBars             = 3;         // Swing pivot half-width, bars (RT_SWING mode)

input group "=== Multi-Timeframe Filter (v1.12) ==="
input bool   InpUseHTFConfirm         = false;    // Require higher-TF trend confirmation to enter
input ENUM_TIMEFRAMES InpHtfTimeframe = PERIOD_M15; // Filter timeframe
input int    InpHtfFastPeriod         = 20;      // Filter fast EMA period
input int    InpHtfSlowPeriod         = 50;      // Filter slow EMA period

input group "=== Entry ==="
input int    InpSetupExpiryBars       = 20;      // Primed setup lifetime (bars, frozen box)
input double InpMaxBreakoutCandlePips = 20.0;    // Max entry-candle body (pips) - spike filter

input group "=== Risk & Exits ==="
input double InpPinBufferPips         = 1.0;     // SL buffer beyond the pin-bar extreme (pips)
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
input color  InpExhaustedBgColor      = clrSaddleBrown;  // TRENDING tint (amber/brown) - input name kept for .set compat
input color  InpAccumBgColor          = clrMidnightBlue; // ACCUMULATION tint (dark blue)
input color  InpPrimedLongBg          = clrDarkGreen;    // PRIMED long tint (dark green)
input color  InpPrimedShortBg         = clrDarkRed;      // PRIMED short tint (dark red)

input group "=== Debug ==="
input bool   InpDrawCrossLines       = true;       // Debug: vline at EMA20xEMA50 & EMA20xEMA150 crosses
input color  InpCross50Color         = clrOrange;  // Vline color: EMA20 x EMA50 cross
input color  InpCross150Color        = clrMagenta; // Vline color: EMA20 x EMA150 cross

//+------------------------------------------------------------------+
//| State machine                                                    |
//+------------------------------------------------------------------+
enum ENUM_TRAB_STATE
  {
   ST_IDLE       = 0,  // no EMA stack - do nothing
   ST_TRENDING   = 1,  // full EMA stack in place (EMA20>EMA50>EMA150>EMA200 or reverse)
   ST_ACCUM      = 2,  // crack: EMA20/EMA50 flipped against the stack - awaiting sweep (or re-formation)
   ST_PRIMED     = 3   // EMA20 swept beyond all other EMAs - waiting for the EMA150 retest + pin bar
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade            g_trade;
int               g_hFast1          = INVALID_HANDLE;
int               g_hFast2          = INVALID_HANDLE;
int               g_hSlow1          = INVALID_HANDLE;
int               g_hSlow2          = INVALID_HANDLE;
int               g_hRetest         = INVALID_HANDLE;   // retest-level EMA period (InpRetestEmaPeriod)
int               g_hTfFast         = INVALID_HANDLE;   // MTF trend filter fast EMA
int               g_hTfSlow         = INVALID_HANDLE;   // MTF trend filter slow EMA
double            g_impHigh         = 0.0;    // crack->sweep impulse high (freeze at sweep; RT_FIB)
double            g_impLow          = 0.0;    // crack->sweep impulse low (freeze at sweep; RT_FIB)
double            g_breakHigh       = 0.0;    // sweep-completion bar high (RT_BREAK)
double            g_breakLow        = 0.0;    // sweep-completion bar low  (RT_BREAK)
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
bool              g_awaitRecrack    = false;  // PRIMED failed/no-pin: waiting for a fresh crack (v1.09)
bool              g_sweptOnce       = false;  // sweep completed this setup (purity scope flag)
double            g_pinHigh         = 0.0;    // pin-bar high at the EMA150 retest (SL reference)
double            g_pinLow          = 0.0;    // pin-bar low at the EMA150 retest (SL reference)
datetime          g_lastBarTime     = 0;

// bar-close data cache (index 0 = last CLOSED candle)
MqlRates          g_rates[];
double            g_f1[], g_f2[], g_s1[], g_s2[], g_r1[];
double            g_e20             = 0.0;    // last closed EMA20 (panel display)
double            g_e50             = 0.0;    // last closed EMA50 (panel display)
double            g_e150            = 0.0;    // last closed EMA150 (panel display)
double            g_e200            = 0.0;    // last closed EMA200 (panel display)

// crack / box-window / sweep tracking (v1.08)
int               g_crackBars       = 0;      // bars since the crack (EMA20/50 flip), valid in ACCUM

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
//| Retest level source (v1.11): EMA / Fib / breakout / swing          |
//+------------------------------------------------------------------+
double SwingRetestLevel()
  {
   const int look = InpSwingBars;   // pivot half-width
   const int scan = 80;             // bars to scan back for a pivot
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, scan, r) < scan)
      return 0.0;
   double best = 0.0;
   for(int i = 1; i < scan - 1; i++)
     {
      if(r[i].time == 0) continue;
      bool pivot = true;
      for(int j = i - look; j <= i + look && pivot; j++)
        {
         if(j < 0 || j >= scan) continue;
         if(g_dir > 0) { if(r[j].high > r[i].high) pivot = false; }   // pivot high
         else          { if(r[j].low  < r[i].low)  pivot = false; }   // pivot low
        }
      if(pivot)
         best = (g_dir > 0) ? r[i].high : r[i].low;   // keep most recent pivot
     }
   return best;
  }

double RetestLevel()
  {
   switch(InpRetestMode)
     {
      case RT_FIB:
        {
         const double span = g_impHigh - g_impLow;
         if(span <= 0.0)
            return g_r1[0];
         return (g_dir > 0) ? (g_impHigh - InpRetestFib * span)
                            : (g_impLow  + InpRetestFib * span);
        }
      case RT_BREAK:
         return (g_dir > 0) ? g_breakHigh : g_breakLow;
      case RT_SWING:
        {
         const double lvl = SwingRetestLevel();
         return (lvl > 0.0) ? lvl : g_r1[0];
        }
     }
   return g_r1[0];                                  // RT_EMA (default)
  }

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void Log(const string msg) { Print("TRAB: ", msg); }

double PipToPrice(const double pips) { return pips * g_pip; }

string StateName(const ENUM_TRAB_STATE s)
  {
   switch(s)
     {
      case ST_TRENDING:  return "TRENDING";
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
      case ST_TRENDING:  return InpExhaustedBgColor;
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
      InpRetestEmaPeriod <= 0 ||
      InpSweepMaxBars        <  1 || InpPinWickRatio      <= 0 ||
      InpRiskRewardRatio     <= 0 || InpMaxStopLossPips   <= 0 ||
      InpRiskPercent         <  0 || InpFixedLots         <= 0 ||
      InpMaxSpreadPips       <= 0 ||
      InpSetupExpiryBars     <  1 || InpTrailActivateRR   <= 0 ||
      InpEmaExitFastPeriod   <= 0 || InpEmaExitSlowPeriod <= 0 ||
      InpEmaExitConfirmBars  <  1 || InpEmaExitMinProfitRR <  0)
     {
      Log("INIT FAILED: invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // --- indicator handles -------------------------------------------------
   g_hFast1 = iMA(_Symbol, PERIOD_CURRENT, InpFastEma1Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hFast2 = iMA(_Symbol, PERIOD_CURRENT, InpFastEma2Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow1 = iMA(_Symbol, PERIOD_CURRENT, InpSlowEma1Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow2 = iMA(_Symbol, PERIOD_CURRENT, InpSlowEma2Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hRetest = iMA(_Symbol, PERIOD_CURRENT, InpRetestEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hTfFast = iMA(_Symbol, InpHtfTimeframe, InpHtfFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hTfSlow = iMA(_Symbol, InpHtfTimeframe, InpHtfSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaExitFast = iMA(_Symbol, PERIOD_CURRENT, InpEmaExitFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaExitSlow = iMA(_Symbol, PERIOD_CURRENT, InpEmaExitSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hFast1 == INVALID_HANDLE || g_hFast2 == INVALID_HANDLE ||
      g_hSlow1 == INVALID_HANDLE || g_hSlow2 == INVALID_HANDLE ||
      g_hEmaExitFast == INVALID_HANDLE || g_hEmaExitSlow == INVALID_HANDLE ||
      g_hRetest == INVALID_HANDLE || g_hTfFast == INVALID_HANDLE || g_hTfSlow == INVALID_HANDLE)
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
   g_state        = ST_IDLE;
   g_dir          = 0;
   g_stateBars    = 0;
   g_awaitRecrack = false;
   g_sweptOnce    = false;
   g_pinHigh      = 0.0;
   g_pinLow       = 0.0;
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
   if(g_hRetest != INVALID_HANDLE) IndicatorRelease(g_hRetest);
   if(g_hTfFast != INVALID_HANDLE) IndicatorRelease(g_hTfFast);
   if(g_hTfSlow != INVALID_HANDLE) IndicatorRelease(g_hTfSlow);
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

   if(newBar)                       // debug cross markers (bar-close only)
      DrawCrossLines();

   if(InpShowPanel)
      UpdatePanel();

   ApplyStateColor();       // no-op unless the state (and thus tint) changed
  }

//+------------------------------------------------------------------+
//| Debug: stamp a vline at EMA20 x EMA50 and EMA20 x EMA150 crosses |
//| Detects a sign flip of the pair separation on each closed bar vs |
//| its predecessor; chart-only, no effect on trading logic.          |
//+------------------------------------------------------------------+
void StampVLine(const datetime t, const string tag, const color col)
  {
   const string name = StringFormat("TRABX_%s_%s", tag, (string)(long)t);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_VLINE, 0, t, 0);
      ObjectSetInteger(0, name, OBJPROP_COLOR, col);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, "TRAB " + tag);
     }
  }

void DrawCrossLines()
  {
   if(!InpDrawCrossLines)
      return;
   double f1[], f2[], s1[];
   ArraySetAsSeries(f1, true);
   ArraySetAsSeries(f2, true);
   ArraySetAsSeries(s1, true);
   if(CopyBuffer(g_hFast1, 0, 1, 2, f1) < 2) return;
   if(CopyBuffer(g_hFast2, 0, 1, 2, f2) < 2) return;
   if(CopyBuffer(g_hSlow1, 0, 1, 2, s1) < 2) return;

   // index 0 = last CLOSED bar, index 1 = its predecessor
   const double d20_50   = f1[0] - f2[0];
   const double p20_50   = f1[1] - f2[1];
   const double d20_150  = f1[0] - s1[0];
   const double p20_150  = f1[1] - s1[1];

   const datetime t = iTime(_Symbol, PERIOD_CURRENT, 1);   // last closed bar time
   if(t == 0)
      return;

   if((d20_50  > 0.0) != (p20_50  > 0.0))      // EMA20 crossed EMA50
     {
      StampVLine(t, "E20xE50", InpCross50Color);
      Log(StringFormat("DEBUG cross E20xE50 @ %s", TimeToString(t, TIME_DATE | TIME_MINUTES)));
     }
   if((d20_150 > 0.0) != (p20_150 > 0.0))      // EMA20 crossed EMA150
     {
      StampVLine(t, "E20xE150", InpCross150Color);
      Log(StringFormat("DEBUG cross E20xE150 @ %s", TimeToString(t, TIME_DATE | TIME_MINUTES)));
     }
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
   ArraySetAsSeries(g_r1, true);

   if(CopyRates(_Symbol, PERIOD_CURRENT, 1, count, g_rates) < count) return false;
   if(CopyBuffer(g_hFast1, 0, 1, count, g_f1) < count)               return false;
   if(CopyBuffer(g_hFast2, 0, 1, count, g_f2) < count)               return false;
   if(CopyBuffer(g_hSlow1, 0, 1, count, g_s1) < count)               return false;
   if(CopyBuffer(g_hSlow2, 0, 1, count, g_s2) < count)               return false;
   if(CopyBuffer(g_hRetest, 0, 1, count, g_r1) < count)              return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Price purity (v1.08): the sweep must be one-way momentum.        |
//| Short sweep: price stays BELOW EMA20 (a high touching EMA20 =    |
//| touch violation). Long sweep: price stays ABOVE EMA20.           |
//| InpPricePurityTouch=false relaxes this to closes only.           |
//+------------------------------------------------------------------+
bool PurityViolated(const int dir, const double hi, const double lo,
                    const double cl, const double e20)
  {
   if(dir < 0)                                   // short sweep: price below EMA20
      return InpPricePurityTouch ? (hi >= e20) : (cl >= e20);
   return InpPricePurityTouch ? (lo <= e20) : (cl <= e20);   // long sweep: price above EMA20
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
   g_state        = ST_IDLE;
   g_dir          = 0;
   g_stateBars    = 0;
   g_awaitRecrack = false;
   g_sweptOnce    = false;
   g_pinHigh      = 0.0;
   g_pinLow       = 0.0;
   g_crackBars    = 0;
   g_impHigh      = 0.0;
   g_impLow       = 0.0;
   g_breakHigh    = 0.0;
   g_breakLow     = 0.0;
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
//+------------------------------------------------------------------+
//| Core state machine - runs once per new M1 bar (on bar close)     |
//| v1.08: pure EMA-configuration machine, EMA20 is the protagonist: |
//|   TRENDING = full stack (E20>E50>E150>E200 or reverse)           |
//|   ACCUM    = crack (E20/E50 flipped against the stack)           |
//|   PRIMED   = EMA20 swept beyond E50+E150+E200 within             |
//|              SweepMaxBars, with price purity (no EMA20 touch)    |
//+------------------------------------------------------------------+
void EvaluateOnBarClose()
  {
   // the state machine is frozen while a position is open
   ulong ticket = 0;
   long  posId  = 0;
   if(HasOpenPosition(ticket, posId))
      return;

   if(!FetchMarketData(2))          // only the last closed bar is needed
     {
      Log("history/indicator data not ready - evaluation skipped");
      return;
     }

   const double e20  = g_f1[0], e50 = g_f2[0], e150 = g_s1[0], e200 = g_s2[0];
   const double hi   = g_rates[0].high, lo = g_rates[0].low, cl = g_rates[0].close;
   g_e20 = e20; g_e50 = e50; g_e150 = e150; g_e200 = e200;   // panel display

   const bool stackUp   = (e20 > e50 && e50 > e150 && e150 > e200);
   const bool stackDown = (e20 < e50 && e50 < e150 && e150 < e200);

   switch(g_state)
     {
      // --------------------------------------------------------------
      case ST_IDLE:
        {
         if(stackUp || stackDown)
           {
            g_dir       = stackDown ? +1 : -1;  // downtrend -> long watch, uptrend -> short watch
            g_state     = ST_TRENDING;
            g_stateBars = 0;
            Log(StringFormat("Phase 1 stack confirmed (%s) -> TRENDING",
                             g_dir > 0 ? "E20<E50<E150<E200" : "E20>E50>E150>E200"));
           }
         break;
        }

      // --------------------------------------------------------------
      case ST_TRENDING:
        {
         const bool stackHolds = (g_dir > 0) ? stackDown : stackUp;
         const bool crack      = (g_dir > 0) ? (e20 > e50) : (e20 < e50);

         if(!stackHolds && crack)
           {
            g_state        = ST_ACCUM;
            g_stateBars    = 0;
            g_crackBars    = 0;
            g_awaitRecrack = false;
            g_sweptOnce    = false;
            g_impHigh      = 0.0;
            g_impLow       = 0.0;
            g_breakHigh    = 0.0;
            g_breakLow     = 0.0;
            Log(StringFormat("Phase 2 crack: EMA20 crossed %s EMA50 -> ACCUMULATION",
                             g_dir > 0 ? "above" : "below"));
            break;
           }
         if(!stackHolds)
            ResetToIdle("EMA stack broken without an EMA20/50 crack");
         break;
        }

      // --------------------------------------------------------------
      case ST_ACCUM:
        {
         g_crackBars++;

         // track the crack->sweep impulse extremes (for RT_FIB and RT_BREAK)
         if(g_impHigh == 0.0 || hi > g_impHigh)  g_impHigh = hi;
         if(g_impLow  == 0.0 || lo < g_impLow)   g_impLow  = lo;

         // sweep purity applies until the sweep completes (v1.09 scope: pre-PRIMED only -
         // the retest phase EXPECTS price to travel back through EMA20)
         if(!g_sweptOnce && PurityViolated(g_dir, hi, lo, cl, e20))
           {
            ResetToIdle("price touched/crossed EMA20 - sweep impure");
            break;
           }

         const bool beyondE50  = (g_dir > 0) ? (e20 > e50)  : (e20 < e50);
         const bool beyondE150 = (g_dir > 0) ? (e20 > e150) : (e20 < e150);
         const bool beyondE200 = (g_dir > 0) ? (e20 > e200) : (e20 < e200);

         // Phase 3 sweep complete: EMA20 beyond ALL other EMAs
         if(beyondE50 && beyondE150 && beyondE200)
           {
            if(g_crackBars > InpSweepMaxBars)
              {
               ResetToIdle(StringFormat("sweep too slow (%d bars > max %d)", g_crackBars, InpSweepMaxBars));
               break;
              }
            g_state     = ST_PRIMED;
            g_stateBars = 0;
            g_sweptOnce = true;
            g_breakHigh = hi;    // freeze the sweep-completion bar extreme (RT_BREAK)
            g_breakLow  = lo;
            Log(StringFormat("Phase 3 sweep complete: EMA20 beyond all EMAs after %d bars -> PRIMED | waiting for the EMA%d retest",
                             g_crackBars, InpRetestEmaPeriod));
            break;
           }

         // crack healed: fast pair back in trend order
         const bool healed = (g_dir > 0) ? (e20 < e50) : (e20 > e50);
         if(healed)
           {
            if(g_dir > 0 ? stackDown : stackUp)
              {
               g_state     = ST_TRENDING;
               g_stateBars = 0;
               Log("crack healed: EMA20 re-aligned with the stack -> TRENDING");
              }
            else
               ResetToIdle("crack healed but the EMA stack did not restore");
            break;
           }

         if(g_crackBars > InpSweepMaxBars)
            ResetToIdle(StringFormat("sweep too slow (%d bars > max %d)", g_crackBars, InpSweepMaxBars));
         break;
        }

      // --------------------------------------------------------------
      case ST_PRIMED:
        {
         // v1.11: retest level is configurable (InpRetestEmaPeriod), default EMA150.
         // Price is EXPECTED to travel back through EMA20 here, so the purity
         // rule no longer applies; the retest rules take over.

         // sweep undone: fast pair back to the trend side
         const bool e20Realigned = (g_dir > 0) ? (e20 < e50) : (e20 > e50);
         if(e20Realigned)
           {
            ResetToIdle("EMA20 re-crossed EMA50 - sweep undone");
            break;
           }

         const double er = RetestLevel();                             // retest level (mode-dependent)
         const bool failClose = (g_dir > 0) ? (cl < er) : (cl > er); // level recaptured
         const bool touched   = (g_dir > 0) ? (lo <= er) : (hi >= er); // price back at retest level
         const bool held      = (g_dir > 0) ? (cl > er)    : (cl < er);// closed on the sweep side

         if(failClose)
           {
            g_state        = ST_ACCUM;          // retest failed -> back to accumulation
            g_awaitRecrack = true;
            g_stateBars    = 0;
            Log("retest failed: price closed beyond retest EMA -> ACCUMULATION");
            break;
           }

         if(touched && held)
           {
            const double op        = g_rates[0].open;
            const double body      = MathAbs(cl - op);
            const double upperWick = hi - MathMax(cl, op);
            const double lowerWick = MathMin(cl, op) - lo;
            const bool   pin       = (g_dir > 0)
                                     ? (lowerWick >= InpPinWickRatio * body && cl > (hi + lo) / 2.0)
                                     : (upperWick >= InpPinWickRatio * body && cl < (hi + lo) / 2.0);
            g_pinHigh = hi;
            g_pinLow  = lo;

            if(pin)
              {
               Log(StringFormat("retest with %s pin bar -> entry",
                                g_dir > 0 ? "bullish" : "bearish"));
               TryEnter(g_dir);
              }
            else
              {
               g_state        = ST_ACCUM;      // no pin bar -> back to accumulation (v1.09)
               g_awaitRecrack = true;
               g_stateBars    = 0;
               Log("retest without a pin bar -> ACCUMULATION");
               break;
              }
           }

         if(g_ticket != 0)                       // entry executed inside TryEnter
           {
            ResetToIdle("trade opened");
            break;
           }
         if(g_state != ST_PRIMED)                // setup invalidated inside TryEnter
            break;

         g_stateBars++;
         if(g_stateBars >= InpSetupExpiryBars)
            ResetToIdle("retest window expired without an entry");
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

   // --- gate 2b: higher-timeframe trend confirmation (v1.12) ------------------
   if(InpUseHTFConfirm)
     {
      double tfF[], tfS[];
      ArraySetAsSeries(tfF, true);
      ArraySetAsSeries(tfS, true);
      if(CopyBuffer(g_hTfFast, 0, 1, 1, tfF) < 1 || CopyBuffer(g_hTfSlow, 0, 1, 1, tfS) < 1)
        {
         Log("ENTRY ABORTED: higher-TF filter data not ready");
         return;
        }
      const bool confirm = (dir > 0) ? (tfF[0] > tfS[0]) : (tfF[0] < tfS[0]);
      if(!confirm)
        {
         Log(StringFormat("ENTRY ABORTED: higher-TF filter (%s) not confirming %s",
                          EnumToString(InpHtfTimeframe), dir > 0 ? "long" : "short"));
         return;
        }
     }

   // --- gate 3: entry-candle spike filter (the pin bar) -----------------------
   const double bodyPips = MathAbs(g_rates[0].close - g_rates[0].open) / g_pip;
   if(bodyPips > InpMaxBreakoutCandlePips)
     {
      Log(StringFormat("ENTRY ABORTED: entry-candle body %.1f pips > max %.1f pips",
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

   // --- SL: beyond the pin-bar extreme (v1.09) --------------------------------
   // the entry is the EMA150-retest pin bar; its rejection wick is the risk.
   double entry, sl, risk;
   if(dir > 0)
     {
      entry = tick.ask;
      sl    = g_pinLow - PipToPrice(InpPinBufferPips);
      risk  = entry - sl;
     }
   else
     {
      entry = tick.bid;
      sl    = g_pinHigh + PipToPrice(InpPinBufferPips);
      risk  = sl - entry;
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

   string stackTxt = "mixed";
   if(g_e20 > g_e50 && g_e50 > g_e150 && g_e150 > g_e200)
      stackTxt = "UP (E20>E50>E150>E200)";
   else if(g_e20 < g_e50 && g_e50 < g_e150 && g_e150 < g_e200)
      stackTxt = "DOWN (E20<E50<E150<E200)";

   string s = "TRAB EA v1.12 | " + _Symbol + " " + EnumToString(_Period) + "\n";
   if(InpAlertOnly)
      s += ">>> ALERT-ONLY MODE: signals are alerted, NO trades are opened <<<\n";
   if(!g_canTrade)
      s += ">>> TRADING DISABLED: attach to an M1 chart (EnforceM1Only=true) <<<\n";

   s += "State: " + StateName(g_state);
   if(g_state != ST_IDLE)
      s += StringFormat(" | dir: %s | bars in state: %d",
                        g_dir > 0 ? "LONG setup" : "SHORT setup", g_stateBars);
   s += "\n";

   if(g_state == ST_ACCUM)
      s += StringFormat("Crack: %d bars ago | swept: %s | awaiting: %s\n",
                        g_crackBars,
                        g_sweptOnce ? "yes" : "no",
                        g_awaitRecrack ? "fresh crack" : "sweep completion");
   if(g_state == ST_PRIMED)
      s += StringFormat("EMA%d retest armed | bars to expiry: %d/%d\n",
                        InpRetestEmaPeriod, g_stateBars, InpSetupExpiryBars);

   s += StringFormat("EMA stack: %s\n", stackTxt);
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
