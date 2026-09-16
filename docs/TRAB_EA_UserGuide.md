# TRAB EA — User Guide

**File:** `TRAB_EA.mq5` / `TRAB_EA.ex5` · **Version 1.06** · **Timeframe: M1 only**
Companion documents: `TRAB_EA_Proposal.md` (formal spec & decision log).

---

## 1. Quick Start

1. In MetaEditor, confirm `TRAB_EA.mq5` compiles (already delivered as `TRAB_EA.ex5`, 0 errors / 0 warnings).
2. In MetaTrader 5, open an **M1 chart** of the symbol you want to trade. The EA is chart-symbol driven — it trades exactly the symbol of the chart it is attached to.
3. Drag `TRAB_EA` onto the chart. Enable **Algo Trading** (toolbar button).
4. Check the **Experts journal**: you should see
   `TRAB: initialized on <SYMBOL> PERIOD_M1 | pip=... | deviation=... | magic=... | risk=1.00%`
   (with `AlertOnly = true` the line ends with `| ALERT-ONLY MODE (no trades)`)
5. The on-chart panel shows the live state machine, spread, session status, and any open position. The **chart background is tinted per state** (see §2.1) so you can read the phase at a glance.

> If attached to a non-M1 chart with `EnforceM1Only = true`, the EA displays a warning and **disables trading**.

---

## 2. How It Trades (State Machine)

```
IDLE ──(60 closed bars with fast band fully on one side)──▶ EXHAUSTED
EXHAUSTED ──(4-EMA squeeze < threshold)──▶ ACCUMULATION
ACCUMULATION ──(EMA20+EMA50 fully crossed to reversal side for N bars)──▶ PRIMED
PRIMED ──(M1 candle CLOSES outside the frozen box, in reversal direction)──▶ MARKET ORDER
                                             (or an MT5 Alert, with AlertOnly = true)
```

Reset conditions (back to IDLE, logged with reason):
- exhaustion/accumulation waits exceed their staleness caps,
- the fast band returns to the original trend side without crossing,
- **while PRIMED: the fast band recrosses back into the slow band (v1.06)** — the reversal premise is dead; without this guard a stale setup could fire an entry against the EA's own trend definition,
- a wrong-side breakout, or a close back inside the box after a breakout,
- primed setup expiry (`SetupExpiryBars`),
- computed SL exceeding `MaxStopLossPips` (trade intentionally skipped).

**Journal tags to know:** `Phase 1 confirmed`, `Phase 2 validated`, `Phase 3 confirmed -> PRIMED`, `ENTRY ABORTED: ...` (spread/session/spike gates), `TRADE SKIPPED: ...` (SL cap, sizing), `>>> BUY/SELL ...` (fill), `trailing stop ACTIVATED`, `EMA cross EXIT ...` (profit-protection close, v1.03), `position ... CLOSED - exit: TP/Trail/Cross/SL/Other | net ±R` (v1.05 exit classification), `exit stats: ...` (running per-session summary, v1.05), `ALERT-ONLY: ...` (v1.04 signal fired instead of an order), `fast band recrossed - reversal premise invalid` (v1.06 primed-setup guard).

The state machine is **frozen while a position is open** — one trade at a time per symbol/magic. After the position closes it resumes at IDLE with a fresh evaluation.

### 2.1 State Colors (chart background tint)

For peripheral-vision awareness, the EA tints the chart background as the state machine advances. Defaults are standard named web colors (`clrXXX`) chosen to stay readable on black-background charts:

| State | Default background color | Meaning at a glance |
|---|---|---|
| IDLE | unchanged (`clrNONE`) | nothing happening |
| EXHAUSTED | `clrSaddleBrown` (amber/brown) | Phase 1 armed — waiting for the EMA squeeze |
| ACCUMULATION | `clrMidnightBlue` (dark blue) | Phase 2 validated — waiting for the band crossover |
| PRIMED (long setup) | `clrDarkGreen` | box frozen — waiting for the bullish breakout close |
| PRIMED (short setup) | `clrDarkRed` | box frozen — waiting for the bearish breakout close |

Behavior details:

- The tint is applied **immediately when the EA attaches** (v1.02) — no tick is required, so it works even while the market is closed. The journal shows a one-time line `state tinting active - original background R,G,B` to confirm the feature is live.
- The original background color is captured once when the EA starts and **restored automatically** when the EA is removed, recompiled, or the chart is closed.
- The chart property is written **only on state transitions** (not per tick) — no redraw spam, no performance impact.
- A color input set to `clrNONE` ("None" in the color chooser) means *"leave the original background for this state"* — this is the default for IDLE.
- The feature can be disabled entirely with `ColorizeStates = false`.
- The defaults suit **black-background charts**. On a white chart, pick pale colors from the chooser (e.g. `clrMistyRose`, `clrLightCyan`) — see the State Colors input group in §3.
- The tint is state information only — it does not affect any trading logic.

---

## 3. Inputs Reference (v1.04)

Every input with its default, what it controls, and when to change it. The defaults are the signed-off configuration — tune **one parameter at a time** and re-test.

### Indicators
| Input | Default | Usage |
|---|---|---|
| FastEma1Period | 20 | Leading edge of the fast momentum band. Present in **every** phase check: band separation (Phase 1), 4-EMA squeeze width (Phase 2), crossover confirmation (Phase 3). Lower = earlier but noisier signals. |
| FastEma2Period | 50 | Confirmation EMA of the fast band — **and the trailing-stop reference**: after the 1:1 mark the SL trails `TrailBufferPips` behind this EMA. Changing it changes trailing behavior too. |
| SlowEma1Period | 150 | Inner macro-band EMA. Together with EMA200 it defines "the trend side" in Phases 1/3 and forms the entry SL cluster. |
| SlowEma2Period | 200 | Outer macro-band EMA — the trend boundary the reversal must cross. Part of the deeper-wins SL cluster. |

> These four periods define the strategy's geometry. If you experiment, keep the fast/slow proportions (20/50 vs 150/200) roughly intact — otherwise expect fundamentally different behavior.

### Phase Detection
| Input | Default | Usage |
|---|---|---|
| ExhaustionLookbackBars | 60 | Phase 1: both fast EMAs must sit entirely above (or below) both slow EMAs for this many **consecutive closed bars**. Raise = rarer, more mature exhaustion; lower = more, earlier and riskier setups. Minimum 5. |
| BoxLookbackBars | 45 | Phase 2: lookback for the consolidation box (highest high / lowest low) frozen when the setup primes. The box defines the breakout trigger and the box-edge SL. Bigger = wider boxes → wider SLs → more SL-cap skips. Minimum 5. |
| SqueezeThresholdPips | 5.0 | Phase 2 validation: the average distance between the highest and lowest of the 4 EMAs must be below this (in pips). Scale with the symbol's volatility; assumes a correct pip definition (see `PipSizeOverride`). |
| SqueezeLookbackBars | 3 | Bars averaged for the squeeze measurement. 1 = instant snapshot (noisy); higher = smoother but lags. Minimum 1. |
| CrossConfirmBars | 2 | Phase 3: closed bars the fast band must remain fully on the reversal side before the cross counts as definitive. Raise = fewer false crossovers, later entries. Minimum 1. |
| ExhaustionMaxBars | 240 | Staleness cap for the EXHAUSTED state. The in-state counter resets while the original separation still holds, so a healthy trend extends the wait; the cap fires only once separation is lost and no squeeze has formed. |
| AccumulationMaxBars | 60 | Same cap for ACCUMULATION while waiting for the crossover. On expiry the machine resets to IDLE and re-arms from scratch. |

### Entry
| Input | Default | Usage |
|---|---|---|
| SetupExpiryBars | 20 | Lifetime of a PRIMED setup (box stays frozen). If no qualifying breakout close occurs within this many bars the setup is discarded. |
| MaxBreakoutCandlePips | 20 | Spike filter: if the closed breakout candle's body exceeds this many pips the entry aborts — **the setup stays primed** and retries on a later bar. Shields entries from news spikes at extreme prices. |

### Risk & Exits
| Input | Default | Usage |
|---|---|---|
| SLBoxBufferPips | 1.0 | Initial SL distance beyond the opposite box edge. |
| SLEmaBufferPips | 2.0 | SL distance beyond the EMA150/200 cluster. Whichever level is **deeper** (box edge vs EMA cluster) wins, giving the trade the more defensive stop. |
| MaxStopLossPips | 30 | Hard SL cap. If the box + EMA geometry needs more, the trade is skipped and the setup reset — the EA never stretches risk to force a trade. Raise consciously on volatile symbols. |
| RiskRewardRatio | 2.0 | Fixed take-profit = RR × initial risk (2.0 = 1:2). Interacts with trailing: after the 1:1 mark the trail or the EMA-cross exit can close the trade before the TP. |
| RiskPercent | 1.0 | Position sized so a full-SL loss ≈ this % of current **equity**. Volume is floored to the lot step, capped at the symbol max, and margin-checked (limited to 90 % of free margin). `0` = switch to FixedLots. |
| FixedLots | 0.10 | Volume used only when `RiskPercent = 0`. For very small accounts or pure signal testing. |
| TrailActivateRR | 1.0 | Trailing arms once unrealized profit reaches this multiple of the initial risk (1.0 = at the 1:1 mark). Raise to give winners more room before the trail tightens. |
| TrailBufferPips | 1.0 | Distance the SL keeps behind the last closed `FastEma2Period` EMA (EMA50) while trailing. The SL only ever tightens and respects the broker stops level. |
| RemoveTPWhenTrailing | false | `false` = keep the fixed 2R TP even after trailing activates. `true` = TP is removed when the trail arms, letting extended trends run (exits then come from the trail or the EMA cross exit). |

### EMA Cross Exit (profit protection, v1.03)
| Input | Default | Usage |
|---|---|---|
| UseEmaCrossExit | true | Master switch. On each closed M1 candle while a trade is open, a **fresh** adverse cross of the exit pair closes the position at market (SL/TP/trailing stay active in parallel; failed close requests retry on every tick). "Fresh" = the bar just before the confirmation window was still on the safe side, so a pair already crossed at entry never instantly flattens a new trade. |
| EmaExitFastPeriod | 10 | Fast EMA of the exit pair. Deliberately separate from the 20/50 band so band-internal wobble can't flatten open trades. |
| EmaExitSlowPeriod | 20 | Slow EMA of the exit pair. |
| EmaExitConfirmBars | 1 | Closed bars the adverse relation must hold before the exit fires. Minimum 1. |
| EmaExitMinProfitRR | 0.0 | Profit gate in R multiples. `0` = exit at any P&L (also cuts early losers). E.g. `0.5` = the cross exit only arms once the trade is +0.5R — pure profit protection. |

> The panel position line shows `emaX armed / CLOSING / off` so you can see the cross-exit state at a glance.

### Exit Analytics (v1.05)
| Input | Default | Usage |
|---|---|---|
| ExitAnalytics | true | On every close, the EA classifies the exit and logs `position #... CLOSED - exit: TP/Trail/Cross/SL/Other | net +x.xxR / money`, followed by a running per-session summary line `exit stats: ...` (count, total R and win% per exit type). Types: **TP** = fixed take-profit hit · **Trail** = SL hit after trailing activated · **Cross** = EMA10×20 cross-exit market close · **SL** = hard SL (trailing never armed) · **Other** = manual close / stop-out / unknown. R-multiple = net P&L ÷ initial risk in money (falls back to price-distance R if the risk reference is unavailable). Stats are **per session** (reset when the EA is reloaded); a final summary is printed on removal and at the end of a tester run |
| ExportTradesCSV | false | Also append each close as a row to `MQL5\Files\TRAB_exits_<magic>.csv` (`;`-separated: close time, symbol, ticket, exit type, R-multiple, net P&L, currency, exit price). Header written automatically; safe to open in Excel while the EA runs. Use it after backtests/walk-forwards to analyze the exit mix — e.g. whether Cross exits scratch would-be 2R winners, or the EMA50 trail caps winners near +1R |

> The panel shows a `Closed this session: ...` line whenever at least one trade has closed this session.

### Broker Environment
| Input | Default | Usage |
|---|---|---|
| MaxSpreadPips | 1.5 | Live spread measured at the entry moment; above this the entry aborts (setup stays primed for retry). M1 entries are spread-sensitive — keep tight on FX majors. |
| MaxSlippagePips | 1.0 | Max deviation for the market order. **Hard-clamped to 3.0** in code regardless of the input. |
| LondonStartHour / LondonEndHour | 8 / 16 | London window, end hour inclusive → 08:00–16:59. Gates Phase-1 arming, squeeze validation, crossover priming **and** the breakout entry. |
| NYStartHour / NYEndHour | 13 / 20 | New York window, end hour inclusive → 13:00–20:59. Together with London (overlap 13–16) the gate is effectively 08:00–20:59. To run 24 h: `LondonStartHour = 0`, `LondonEndHour = 23`. |
| UseServerTime | false | Which clock the hour inputs refer to. `false` = hours are **GMT**: the EA converts the chart's server clock with `ServerGMTOffset` before comparing. `true` = hours are compared **directly against the chart clock** (broker server time) and `ServerGMTOffset` is ignored — simplest, and stable relative to what you see on screen. |
| ServerGMTOffset | 2 | Broker's server offset from GMT, used only when `UseServerTime = false`. IC Markets: 2 in winter, 3 during US DST — verify by comparing the Market Watch clock with GMT. |

Session filter gates **priming and entry only** — open positions are still managed 24 h (trailing and the EMA cross exit never sleep).

### General
| Input | Default | Usage |
|---|---|---|
| MagicNumber | 20250915 | Isolates this EA's orders/positions and keys the Global Variable that persists the initial-risk reference across restarts (`TRAB_<magic>_<ticket>_R`). Run a second instance on the same symbol only with a different magic. |
| TradeComment | TRAB | Comment written on entry orders — useful for filtering the account history. |
| AlertOnly | false | **Signal mode (v1.04).** `false` = open trades normally. `true` = no orders are ever sent: at a valid breakout the EA raises an MT5 **Alert** (popup + sound, journal line `ALERT-ONLY: ...`) with direction, entry, SL, TP, risk and RR, then resets to IDLE — one alert per setup, no spam. All entry gates (spread, session, spike filter, SL cap) still run, so each alert matches exactly what would have been traded. Note: MT5 does **not** execute `Alert()` in the Strategy Tester — validate this mode on a live/demo chart. |
| EnforceM1Only | true | Hard M1 guard: on any other timeframe the EA warns in the journal and disables evaluation/trading. The phase geometry is M1-specific — leave `true` unless you deliberately re-purpose the phases to a bigger bar size. |
| PipSizeOverride | 0.0 | Pip size in price units for **all** `-Pips` inputs. `0` = auto: 10×point on 3/5-digit quotes, else 1×point. Set `0.1` for XAUUSD-style quoting if auto gives wrong pip values (symptom: `TRADE SKIPPED: SL cap` on every trade). |
| ShowPanel | true | On-chart status panel (state, frozen box, squeeze, spread, session, position, alert-mode banner). `false` = clean chart; the journal still logs everything. |

### State Colors (chart background tint)
| Input | Default | Usage |
|---|---|---|
| ColorizeStates | true | Master toggle for the per-state background tint (see §2.1). |
| IdleBgColor | clrNONE | IDLE background (`clrNONE` = keep original). |
| ExhaustedBgColor | clrSaddleBrown | EXHAUSTED tint (amber/brown). |
| AccumBgColor | clrMidnightBlue | ACCUMULATION tint (dark blue). |
| PrimedLongBg | clrDarkGreen | PRIMED long tint (dark green). |
| PrimedShortBg | clrDarkRed | PRIMED short tint (dark red). |

All colors are ordinary MQL5 `color` inputs — type any `clrXXX` web-color name or pick from the color chooser in the EA dialog. `None` in the chooser = `clrNONE` = leave the original background. The original background is always restored when the EA is removed.

---

## 4. Backtesting Recommendations

- Strategy Tester mode: **"Every tick based on real ticks"** (M1 logic + per-tick trailing require it). "1 minute OHLC" is acceptable only for smoke tests.
- Test on the chart symbol you intend to trade; download at least 12 months of M1 tick data.
- Suggested starting symbols: EURUSD, GBPUSD, XAUUSD (with `PipSizeOverride = 0.1` for gold if your broker quotes 2/3 digits).
- Walk-forward the most impactful parameters first: `SqueezeThresholdPips`, `ExhaustionLookbackBars`, `BoxLookbackBars`, `TrailActivateRR` — and since v1.03 also `RiskRewardRatio` and `EmaExitMinProfitRR`.
- `AlertOnly = true` is a strategy-tester blind spot: MT5 does not execute `Alert()` in the tester, so validate alert-only behavior on a live/demo chart and read the `ALERT-ONLY:` lines in the Experts journal.
- Enable `ExportTradesCSV` for backtest/walk-forward runs and analyze the exit mix (TP vs Trail vs Cross vs SL and their average R) — this is the key dataset for tuning the exit stack (`EmaExitMinProfitRR`, `TrailBufferPips`, `RiskRewardRatio`).
- The EA opens **one position at a time** and uses **risk-percent sizing** — backtest results scale with the tester's initial deposit.

---

## 5. Behavior Notes & Troubleshooting

| Symptom | Explanation / Fix |
|---|---|
| No trades for long stretches | Normal: all 3 phases + session + spread gates must align. Check journal for `Phase 1/2/3` messages to see how far setups get. |
| Many `ENTRY ABORTED: spread` | Spread gate doing its job on M1; consider a symbol/account with tighter spreads, or review `MaxSpreadPips`. |
| Many `TRADE SKIPPED: SL cap` | Frozen box + EMA cluster geometry too wide for `MaxStopLossPips`. Expected on volatile symbols — raise the cap consciously or reduce box lookback. |
| Zero volume computed | `RiskPercent` sizing produced lots below the symbol minimum → trade skipped by design (risk control). Use `FixedLots` mode on very small accounts. |
| Gold/indices behaving oddly | Set `PipSizeOverride` explicitly (e.g., 0.1 for gold) so pips-based inputs mean what you expect. |
| Wrong session hours | Decide the time base first: `UseServerTime = true` compares the hour inputs against the chart clock directly (no offset math — e.g. IC Markets real London open 08:00 UK ≈ 10:00 chart time), while `false` treats them as GMT and needs a correct `ServerGMTOffset` (2 winter / 3 summer on IC Markets). To disable sessions entirely set `LondonStartHour = 0` / `LondonEndHour = 23`. |
| No alerts with `AlertOnly = true` | Alerts fire only where a trade would: inside the session windows, spread ≤ `MaxSpreadPips`, breakout body ≤ `MaxBreakoutCandlePips`, SL ≤ cap. The journal shows `ALERT-ONLY:` / `ENTRY ABORTED:` reasons. Alert popups only appear while the terminal is running, and not at all in the Strategy Tester. |
| Exit CSV file not created | `ExportTradesCSV` must be `true`; the file appears under `MQL5\Files\TRAB_exits_<magic>.csv` (in the Strategy Tester: under the tester agent's `Files` folder). Check the journal for `exit CSV: cannot open ...` errors. |
| EA restarted while in a trade | Position is auto-adopted; the initial risk reference is persisted in a terminal Global Variable (`TRAB_<magic>_<ticket>_R`). |
| Background never tints at all | v1.02 applies the tint on attach — check the journal for `state tinting active`. If missing: (a) the chart is running an older `.ex5` — recompile and re-attach; (b) `ColorizeStates = false`; (c) you are attached to a chart in a **different terminal installation** than the one this source folder belongs to. |
| Chart background left tinted | The EA restores the original color on removal/recompile. If the terminal crashed while tinted, reattach and remove the EA once — or reset the color via chart **Properties → Colors**. |
| Tints hard to see / too strong | Defaults target black-background charts. On a white chart set pale colors; to opt out of a single state set its color to `clrNONE`, or turn everything off with `ColorizeStates = false`. |

**Safety defaults baked in:** slippage deviation hard-clamped to ≤ 3 pips, SL never loosened by trailing, SL/TP checked against broker stops level, margin-checked sizing, one-position limit per symbol/magic, and full journal forensics for every state transition and gate decision.
