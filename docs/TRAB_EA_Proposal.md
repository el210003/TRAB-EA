# Project Proposal

## M1 Trend Reversal & Accumulation Breakout (TRAB) Expert Advisor

**Platform:** MetaTrader 5 (MQL5)
**Strategy Type:** Mean-reversion-to-trend / breakout hybrid
**Timeframe:** M1 (fixed — EA must refuse to run on other timeframes)
**Version:** 1.3 — Decisions signed off; implementation delivered
**Status:** Approved — see Decision Log (§8) and as-built notes

---

## 1. Executive Summary

This proposal defines the design, architecture, and delivery plan for an MQL5 Expert Advisor that automates the **Trend Reversal and Accumulation Breakout (TRAB)** strategy on the 1-minute chart. The EA detects institutional-style exhaustion → accumulation → reversal sequences by monitoring the interaction of two EMA bands, primes a trade only after all three market phases are sequentially validated, and executes a breakout entry under strict broker-mechanics safety limits (spread filter, session filter, slippage cap).

The deliverable is a single self-contained EA (`TRAB_EA.mq5`) with a clear state machine, fully parameterized inputs, deterministic bar-close logic, and a documented backtesting/optimization procedure using real-tick M1 data.

---

## 2. Strategy Logic Translation

### 2.1 Indicators

The EA maintains four EMA indicator handles, all computed on M1 candles of the chart symbol, using `PRICE_CLOSE`:

| Handle | Indicator | Period | Role |
|---|---|---|---|
| `hEmaFast1` | EMA | 20 | Fast Momentum Band — leading edge |
| `hEmaFast2` | EMA | 50 | Fast Momentum Band — confirmation edge; also trailing-stop reference |
| `hEmaSlow1` | EMA | 150 | Macro Trend Band — inner boundary |
| `hEmaSlow2` | EMA | 200 | Macro Trend Band — outer boundary / dynamic S&R |

All indicator reads use **closed candles only** (shift ≥ 1). The forming candle (shift 0) is never used for signal logic, guaranteeing the EA behaves identically in backtests and live trading.

### 2.2 Market Phase State Machine

The core of the EA is a sequential state machine. A trade can only be primed by passing through all phases in order. Any phase failure resets evaluation (Phase 1 is re-checked on every evaluation cycle).

```
 IDLE ──Phase 1 valid──▶ EXHAUSTION_CONFIRMED ──Phase 2 valid──▶ ACCUMULATION_VALID
                                                                    │
                              Phase 3 valid (both fast EMAs         ▼
                              crossed to opposite side)      ACCUMULATION_PRIMED
                                                                    │
                     breakout candle closes outside box ───────────▶ IN_TRADE / RESET
```

#### Phase 1 — Exhaustion (Trend Pre-Existence)

> **Terminology note (v1.07, as-built):** the original "Exhaustion" framing overstated what this phase can know. Phase 1 certifies only that a **mature trend is in place** (trend pre-existence) — exhaustion is never assumed at this stage, since it cannot be observed yet. The EA waits for evidence (squeeze → crossover → breakout) before acting; the state machine displays this state as `TRENDING` (internal enum renamed accordingly; input identifiers keep the historical `Exhaustion...` names for `.set`-file compatibility).

- Evaluate the last **60 closed M1 candles** (lookback input, default 60).
- **Bullish exhaustion (for short setups):** for all 60 candles, *both* EMA20 and EMA50 are strictly **above** both EMA150 and EMA200.
- **Bearish exhaustion (for long setups):** for all 60 candles, *both* EMA20 and EMA50 are strictly **below** both EMA150 and EMA200.
- "Entirely above/below" is strict: no candle may have any fast EMA equal to or crossing a slow EMA within the window. A single violation invalidates the phase.
- This check is evaluated once per closed candle.

#### Phase 2 — Accumulation (Consolidation Box + Volatility Squeeze)
Two conditions must both hold on the current evaluation candle:

1. **Consolidation box:** over the last **45 closed candles** (lookback input, default 45):
   - `BoxTop = Highest High(45)`
   - `BoxBottom = Lowest Low(45)`
   - The box used by the entry trigger is recomputed from the latest 45 closed candles at the moment Phase 3 primes the setup (see §2.4), so the trade always acts on the box that was current when the setup primed.

2. **EMA squeeze:** the total spread across the four EMAs,
   `max(EMA20, EMA50, EMA150, EMA200) − min(EMA20, EMA50, EMA150, EMA200)`,
   must be **< SqueezeThresholdPips** (default 5.0 pips), measured as an average over the last **SqueezeLookback** candles (default 3) to avoid a single-tick fluke.

Phase 2 validates only when the Phase-1 state is currently confirmed.

#### Phase 3 — Band Crossover (Directional Flip Confirmation)
The setup is **primed** when, on closed candles:

- **Long setup:** EMA20 **and** EMA50 are both now **above** both EMA150 and EMA200, while the prior trend state (Phase 1) was bearish.
- **Short setup:** EMA20 **and** EMA50 are both now **below** both EMA150 and EMA200, while the prior trend state (Phase 1) was bullish.

"Definitive cross" is defined as both fast EMAs on the opposite side for the **two most recent closed candles** (avoids one-tick crossings). Direction must be *opposite* to the exhausted trend — a crossover back into the original trend direction is not a reversal and is ignored.

### 2.3 Entry Rules (Primed → Execute)

While `ACCUMULATION_PRIMED`, on each candle **close**:

- **Long:** candle closes **above `BoxTop`** and EMA bias is bullish → market **buy**.
- **Short:** candle closes **below `BoxBottom`** and EMA bias is bearish → market **sell**.
- The breakout candle must be a genuine close: `Close(1) > BoxTop` (not merely a wick above).

**Pre-trade safety gate (all must pass or the trigger is aborted — not postponed):**

| Gate | Rule | Default |
|---|---|---|
| Spread | `(Ask − Bid) ≤ MaxSpreadPips` | 1.5 pips |
| Session | Server-time hour within London or NY session windows | see §2.6 |
| Position | No open position for this EA/magic on the symbol | — |
| Freshness | Setup has not already fired for the current box | — |
| Volatility cap | Breakout candle body ≤ `MaxBreakoutCandlePips` (blocks entering after a news spike candle; the candle that triggered is excluded) | 20 pips |

If a gate fails, the trigger is **aborted for that candle**. If the close still satisfies the breakout on the *next* candle, the EA may re-attempt (the box remains valid until refresh — §2.4).

**Slippage control:** all orders are sent with `deviation = MaxSlippagePips` (hardcoded default **1 pip**, exposed as an input but clamped so a user cannot raise it above 3 pips without editing source).

### 2.4 Box Freshness & Setup Expiry

- The box reflects the **latest 45 closed candles** at priming time (as-built: recomputed once at the `ACCUMULATION_VALID → PRIMED` transition).
- Once **primed**, the box is **frozen** for that setup.
- As-built staleness caps: the exhaustion state may wait at most `ExhaustionMaxBars` (default 240) for a squeeze and the accumulation state at most `AccumulationMaxBars` (default 60) for the crossover; both reset to IDLE when exceeded (the exhaustion wait self-extends while the 60-bar separation still holds).
- A primed setup **expires** if:
  - `SetupExpiryBars` (default 20) M1 candles pass without a valid breakout close, or
  - price closes back *inside* the box after having broken out (failed breakout → false-prime protection), or
  - either fast EMA recrosses back into the slow band.
- After a trade closes, the EA returns to `IDLE` and will not re-trade the same box (the exhausted Phase-1 condition will have reset, requiring a fresh sequence).

### 2.5 Stop Loss / Take Profit

**Stop Loss — "whichever provides safer clearance":**
For a **long**:

```
SL_box    = BoxBottom − 1 pip × SLBoxBufferPips
SL_ema    = min(EMA150, EMA200) − 1 pip × SLEmaBufferPips
SL        = min(SL_box, SL_ema)          // the LOWER of the two = greater clearance below entry
```

For a **short**, symmetric: `SL = max(BoxTop + buffer, max(EMA150, EMA200) + buffer)`.

The more distant level is chosen deliberately — on M1, a stop inside the box noise band is systematically wicked out; the deeper stop protects against stop-hunts at the box edge. A safety cap `MaxStopLossPips` (default 30) ensures the frozen-box geometry can never produce an outsized risk; if the computed SL exceeds the cap, the trade is **skipped** (no trade is better than an uncontrolled one).

**Take Profit:** fixed at **1 : 2 Risk-to-Reward** (v1.03, was 1:1.5):

```
TP = EntryPrice ± 2.0 × |EntryPrice − SL|
```

**Trailing stop (secondary mechanism):**
- **Activation:** when unrealized profit reaches **1.0 × initial risk** (1:1 mark).
- **Mechanism:** SL is moved to `EMA50(1) ∓ TrailBufferPips` (default buffer 1 pip beyond the 50 EMA), updated on every tick, **only ever in the favorable direction** (SL never moves backward).
- The fixed TP remains in place; exit occurs at whichever level is hit first (TP or trailed SL). An optional input `RemoveTPWhenTrailing` (default **false**) allows removing the TP at activation to capture extended trends per the spec's "capture extended trends" intent — decision point flagged in §8.

**EMA cross exit (profit protection, v1.03):**
- A dedicated fast EMA pair — `EmaExitFastPeriod` = **10** × `EmaExitSlowPeriod` = **20** by default — is monitored while a position is open.
- **Trigger:** a *fresh* adverse cross on closed candles — for a long, EMA10 crosses **below** EMA20 (mirror for shorts) — held for `EmaExitConfirmBars` (default 1) closed bars. "Fresh" means the bar just before the confirmation window was still on the safe side, so a pair that was already crossed at entry never instantly flattens a new trade; only a new cross while in the trade fires the exit.
- **Action:** market close of the position. The EMA50 trailing stop and fixed TP remain active in parallel — whichever exit fires first wins. Failed close requests retry every tick until filled.
- **Profit gate:** optional `EmaExitMinProfitRR` (default **0.0** = exit at any P&L). Set e.g. 0.5 to use the cross purely as a profit-protection exit above +0.5R and let deeper trades run on SL/trail.
- Evaluated once per closed candle (bar-close logic, no intrabar noise); runs regardless of session windows, exactly like the trailing stop — live risk is never abandoned.

### 2.6 Session Management

Trading logic (priming and execution) is restricted to configurable hour windows evaluated in **broker server time**, with a `UseServerTimeInsteadOfGMT` toggle and GMT-offset input, since M1 session behavior must align with actual liquidity:

| Session | Default window (GMT) | Input |
|---|---|---|
| London | 08:00 – 16:59 | `LondonStartHour` / `LondonEndHour` |
| New York | 13:00 – 20:59 | `NYStartHour` / `NYEndHour` |

The windows overlap 13:00–16:59 (London/NY overlap — highest volume). Outside the windows: no new priming, no new entries. **Open positions are still managed** (trailing stop runs 24h) so the EA never abandons live risk.

### 2.7 Position Sizing

The spec does not fix sizing. Proposal (default active):

- **Risk-based sizing (signed off):** `RiskPercent` = **1.0 %** of current equity per trade, lot computed from SL distance, normalized to the symbol's volume step/min/max and margin-checked.
- Fallback: `FixedLots` input used when `RiskPercent = 0`.

---

## 3. MQL5 Technical Architecture

### 3.1 Structure

Single source file `TRAB_EA.mq5`, organized into clearly separated concerns:

```
TRAB_EA.mq5
├── Inputs            (all tunables, grouped & commented)
├── SState enum       (IDLE → EXHAUSTION_CONFIRMED → ACCUMULATION_VALID → PRIMED)
├── CSignalEngine     (indicator reads, phase checks, box calc — pure logic, no trading)
├── CTradeManager     (CTrade wrapper: spread gate, session gate, sizing, SL/TP calc,
│                      OrderSend with deviation, trailing stop, position state)
└── Event handlers    (OnInit / OnDeinit / OnTick / OnTradeTransaction / OnTester)
```

Key implementation decisions:

- **Event model:** signal evaluation and entries occur **only on new M1 bar open** (detected via time-series timestamp compare, equivalent to acting on the just-closed bar). Trailing stop management runs **every tick**. This keeps logic deterministic and backtest-faithful.
- **Indicator access:** handles created once in `OnInit`; values read with `CopyBuffer` into ring buffers covering the largest lookback (60 + margin). No indicator reads inside the tick loop.
- **Pip handling:** pip size derived from `_Point` and digits (3/5-digit brokers → pip = 10 × point). All pip-denominated inputs converted once in `OnInit`.
- **Magic number / symbol filter:** all position logic filtered by `MagicNumber` + `_Symbol`; the EA is safe on multi-chart setups.
- **Error handling:** every `OrderSend` result, retcode, and `CopyBuffer` count is checked; transient failures (requote/no-connection) log and allow retry on the next bar. A structured journal (`PrintFormat`) tags every state transition, gate failure, and trade event for post-trade forensics.
- **OnTradeTransaction:** detects fill and close events to update internal state (return to `IDLE`, record result) without polling.
- **State background tinting (v1.01, refined v1.02):** the chart background (`CHART_COLOR_BACKGROUND`) is re-colored on state transitions only (EXHAUSTED `clrSaddleBrown`, ACCUMULATION `clrMidnightBlue`, PRIMED `clrDarkGreen`/`clrDarkRed` by direction) for at-a-glance phase awareness. The original color is captured once and restored in `OnDeinit`; writes are suppressed unless the target color actually changes; every state color is an input (`clrNONE` = leave original). As of v1.02 the tint is also applied in `OnInit` (no tick required — works while the market is closed) and a one-time journal line confirms the feature is active. Cosmetic only — no trading logic depends on it.

### 3.2 Input Parameter Sheet (defaults)

| Group | Parameter | Default | Notes |
|---|---|---|---|
| Indicators | `FastEma1Period` / `FastEma2Period` | 20 / 50 | |
| | `SlowEma1Period` / `SlowEma2Period` | 150 / 200 | |
| Phase logic | `ExhaustionLookbackBars` | 60 | Phase 1 |
| | `BoxLookbackBars` | 45 | Phase 2 |
| | `SqueezeThresholdPips` | 5.0 | Phase 2 |
| | `SqueezeLookbackBars` | 3 | averaging window |
| | `CrossConfirmBars` | 2 | Phase 3 definitiveness |
| | `ExhaustionMaxBars` / `AccumulationMaxBars` | 240 / 60 | state staleness caps (as-built) |
| Entry | `SetupExpiryBars` | 20 | frozen-box lifetime |
| | `MaxBreakoutCandlePips` | 20 | spike filter |
| Risk | `SLBoxBufferPips` / `SLEmaBufferPips` | 1.0 / 2.0 | SL clearance buffers |
| | `MaxStopLossPips` | 30 | hard cap; skip if exceeded |
| | `RiskRewardRatio` | 2.0 | fixed TP multiple (v1.03) |
| | `RiskPercent` / `FixedLots` | **1.0** / 0.10 | §2.7 (signed off) |
| | `TrailActivateRR` | 1.0 | trailing activation at 1:1 |
| | `TrailBufferPips` | 1.0 | distance behind EMA50 |
| | `RemoveTPWhenTrailing` | false | decision point §8 |
| | `UseEmaCrossExit` | true | EMA10×EMA20 adverse-cross exit (v1.03, §2.5) |
| | `EmaExitFastPeriod` / `EmaExitSlowPeriod` | 10 / 20 | exit-cross EMA pair |
| | `EmaExitConfirmBars` / `EmaExitMinProfitRR` | 1 / 0.0 | confirm bars / min profit (× risk) to arm |
| Environment | `MaxSpreadPips` | 1.5 | hard abort gate |
| | `MaxSlippagePips` | 1.0 | OrderSend deviation (clamped ≤ 3) |
| | Session windows | per §2.6 | + GMT offset / server-time toggle |
| General | `MagicNumber` | 20250915 | |
| | `TradeComment` | "TRAB" | |
| | `EnforceM1Only` | true | warns + disables trading off-M1 |
| State colors | `ColorizeStates` | true | background tint toggle (§3.1, v1.01) |
| | `IdleBgColor` | `clrNONE` | `clrNONE` = keep original background |
| | `ExhaustedBgColor` | `clrSaddleBrown` | amber/brown |
| | `AccumBgColor` | `clrMidnightBlue` | dark blue |
| | `PrimedLongBg` / `PrimedShortBg` | `clrDarkGreen` / `clrDarkRed` | by setup direction |

---

## 4. Testing & Validation Plan

1. **Compile & smoke test** — MetaEditor compile (0 errors / 0 warnings), attach to demo chart, verify state-machine journal output matches manual chart reading.
2. **Backtest (Strategy Tester, "Every tick based on real ticks")** — minimum 12 months of M1 real-tick data on proposed symbols (EURUSD, GBPUSD, XAUUSD recommended starting set). Validate: no look-ahead, spread model active, session filter effective.
3. **Parameter sensitivity** — walk-forward optimization on the four most impactful inputs (`SqueezeThresholdPips`, `ExhaustionLookbackBars`, `BoxLookbackBars`, `TrailActivateRR`) to detect overfit; reject parameter sets that only work in-sample.
4. **Robustness checks** — vary spread model ±50 %, run with `MaxStopLossPips` tightened/loosened, confirm abort-gate behavior under news-time spreads.
5. **Forward test** — 4–8 weeks on demo/VPS before live deployment.

**Success criteria (to be tuned with you):** positive expectancy after spread/commission, profit factor ≥ 1.2 out-of-sample, max drawdown ≤ agreed threshold, no state-machine anomalies in journal.

---

## 5. Deliverables

| # | Item |
|---|---|
| 1 | `TRAB_EA.mq5` — fully commented source |
| 2 | `.set` files — backtest baseline + optimization templates |
| 3 | `TRAB_EA_UserGuide.md` — inputs reference, state machine explanation, journal message dictionary |
| 4 | Backtest report + walk-forward summary |
| 5 | This proposal, updated to "as-built" spec |

---

## 6. Assumptions

- Trading account is hedging or netting MT5; EA holds **max one position** per symbol at a time regardless.
- Broker supports market execution with deviation parameter honored (deviation is advisory on some ECN feeds — the spread gate remains the primary price-quality control).
- Default pip conventions: EURUSD pip = 0.0001; JPY pairs 0.01; metals/golds handled via `SymbolInfo` tick-size-aware pip mapping (documented in user guide).
- History data quality: M1 real-tick backtests require downloaded tick data; synthetic M1 OHLC tests are used only for smoke testing.
- The EA is **symbol-agnostic**: it always trades the chart symbol it is attached to (FX majors out of the box; metals/indices via the `PipSizeOverride` input when the broker's quoting convention differs).

---

## 7. Known Risks & Mitigations

| Risk | Mitigation in design |
|---|---|
| M1 spread spikes at news abort/whipsaw entries | Hard spread gate + `MaxBreakoutCandlePips` filter + session windows exclude thinnest hours |
| Long lookback (60-bar exhaustion) delays signals | Lookback inputs exposed; walk-forward testing tunes responsiveness vs. noise |
| Frozen box invalidated by late volatility | Setup-expiry, false-breakout reset, and EMA-recross reset (§2.4) |
| Broker time ≠ GMT breaks session filter | GMT-offset/server-time toggle input |
| Deep SL on wide frozen boxes inflates risk | `MaxStopLossPips` cap → trade skipped, never oversized |

---

## 8. Decision Log (resolved)

| # | Decision | Resolution (signed off) |
|---|---|---|
| 1 | Position sizing | **Risk-based at 1.0 % of equity per trade** (`RiskPercent = 1.0`) |
| 2 | TP vs. trailing interplay | **Keep** the fixed 2R TP alongside the trailing stop (`RemoveTPWhenTrailing = false`); TP widened 1.5 → 2 in v1.03 |
| 3 | Symbol scope | **Chart-symbol driven** — the EA trades whatever symbol it is attached to |
| 4 | Session defaults | **Confirmed**: London 08:00–16:59 GMT, New York 13:00–20:59 GMT |

### As-built status
- `TRAB_EA.mq5` implemented per this spec and compiled cleanly (**0 errors / 0 warnings**, MetaEditor MQL5).
- As-built additions beyond the original spec (documented in the user guide): `ExhaustionMaxBars` / `AccumulationMaxBars` state staleness caps, `PipSizeOverride` for non-FX quoting conventions, and an on-chart status panel.
- **v1.01 as-built addition:** per-state chart background tinting (`ColorizeStates` + 5 color inputs) for visual phase tracking; original background saved/restored across EA lifecycle; cosmetic only (§3.1, §3.2).
- **v1.02 refinement:** tint colors switched from `C'r,g,b'` literals to standard named web colors (`clrSaddleBrown`, `clrMidnightBlue`, `clrDarkGreen`, `clrDarkRed`) for visibility and portability, and the tint is applied at `OnInit` so it shows immediately even when no ticks arrive (market closed); one-time journal line `state tinting active` added for verification.
- **v1.03 change:** fixed TP widened to 1:2 (`RiskRewardRatio` = 2.0; trailing still activates at the 1:1 baseline) and a new EMA10×EMA20 adverse-cross exit added as a profit-protection mechanism (§2.5) — closes the trade at market on a fresh adverse cross of the exit pair while a position is open.
- Tester presets delivered to `MQL5\Presets`: `TRAB_baseline_FX.set` (5-digit FX), `TRAB_baseline_XAUUSD.set` (gold, pip = $0.10, scaled thresholds), `TRAB_optimize_walkforward.set` (3,150-pass grid on the four key parameters).
- **v1.04–v1.09 as-built:** `AlertOnly` signal mode — MT5 Alert instead of an order (v1.04); exit-reason analytics — every close classified TP/Trail/Cross/SL/Other with R-multiple, running per-session stats, optional CSV export (v1.05); the §2.4 **EMA-recross reset implemented** (v1.06); Phase 1 relabeled `TRENDING` — trend *presence*, not exhaustion (v1.07); **v1.08 major redesign (owner-directed)** — pure EMA-configuration state machine: TRENDING = full stack (E20>E50>E150>E200 or reverse), ACCUMULATION = EMA20/50 crack against the stack, PRIMED = EMA20 sweeps beyond E150+E200 within `SweepMaxBars` bars of the crack; sweep **price purity** (no touch/cross of EMA20) required until the sweep completes; the 60/240-bar lookbacks and the 4-EMA squeeze are retired; **v1.09 entry redesign (owner-directed)** — the box-breakout entry is replaced by the **EMA150 retest + pin bar**: after the sweep, price must return to EMA150 and print a rejection pin (wick ≥ `PinWickRatio` × body, closing back on the sweep side) to trigger the entry, SL beyond the pin's extreme; a failed retest (close beyond EMA150) or a retest without a pin sends the machine back to ACCUMULATION for a fresh crack→sweep cycle; sweep purity is scoped to the pre-PRIMED phase (the retest expects price to cross EMA20); SL = pin extreme ± `PinBufferPips` (the box and the deeper-wins/nearer-wins SL logic are retired).
- **v1.10 as-built (debug):** new `=== Debug ===` input group — `DrawCrossLines` (default `true`) stamps a dotted vertical line on the chart at each closed bar where EMA20 crosses EMA50 (`Cross50Color`, orange) and where EMA20 crosses EMA150 (`Cross150Color`, magenta). Chart-only; no effect on signals/entries/exits or the state machine. Bumped `#property version` and the on-chart panel string to v1.10 (also resolved a stale v1.08 panel string).
- **v1.11 as-built (retest level source):** the retest level is now selectable via `RetestMode` — `EMA` (`RetestEmaPeriod`, default 150), `Fib` (`RetestFib` % retracement of the crack→sweep impulse), `Breakout` (sweep-completion bar extreme, break-and-retest), `Swing` (most recent zigzag pivot). The pin-bar confirmation is unchanged for every mode. New inputs `RetestMode`, `RetestEmaPeriod`, `RetestFib`, `SwingBars`. A/B backtest (EURUSD M1, 2023–2025, real ticks) found none of the alternative retest sources beat the shallow-EMA + let-winners-run config (best: EMA100 retest + trailing exit, PF ≈ 0.77, still net-negative); all remain research-phase.
- Remaining work per §4: real-tick backtests, walk-forward sensitivity runs, and 4–8 weeks of forward testing before live deployment.

### Backtest findings (EURUSD M1, real ticks, 2023-01-01 → 2025-12-31)

A headless strategy-tester run (Model=4, real ticks, $10k, 1% risk/trade,
baseline FX preset) across 3 years produced **121 trades and a net −53.8R**
(−$4,210, PF 0.44, 42% max DD). A management A/B decomposition on the same
signal set gave:

| Config | Win % | SumR | Net USD | PF |
|---|---|---|---|---|
| Baseline (trail + cross-exit) | 21.5% | −53.8 | −4,210 | 0.44 |
| **NoMgmt RR2** (best) | 27.3% | −56.2 | −4,366 | 0.51 |
| NoCross | 24.8% | −54.9 | −4,283 | 0.48 |
| NoTrail | 21.5% | −57.2 | −4,402 | 0.44 |
| NoMgmt RR3 | 19.0% | −64.1 | −4,815 | 0.50 |

**Conclusion:** the trade-management exit layer (EMA50 trailing + EMA10/20
cross-exit) is essentially **neutral** — removing it raises the win rate and
full-TP captures but slightly worsens net R. No tested configuration is
profitable because the **entry edge is statistically negative**: at RR2 the win
rate is ~27% (below the 33% breakeven) and raising the reward to RR3 merely
lowers the win rate to ~19%, so expected value stays negative at every reward.

The v1.09 entry (EMA20 sweep → EMA150 retest + pin bar) does not separate
winners from losers reliably enough to be tradeable as-is in this window. This
supersedes the viability assumption in §1/§7 and **blocks live deployment**
until a real entry-rework (a genuine filter to lift win rate above breakeven,
or a higher-reward / multi-TP structure that holds EV positive) is validated.
See AGENTS.md → Backtesting for the reproducible headless-run + parsing recipe.
