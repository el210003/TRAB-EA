# KISS EA — SMC/ICT Liquidity Sweep + Pin/Engulfing Entry

**M15 Expert Advisor for MetaTrader 5** · Version 1.02

KISS ("Keep It Simple, Stupid") is a minimal **Smart Money Concepts (SMC) /
Inner Circle Trader (ICT)-style** strategy: it hunts **liquidity sweeps** of the
most recent swing highs/lows and enters on the reversal **only when the sweep is
confirmed by a pin bar or an engulfing bar**. Everything else — bias, session,
trailing, time stop — is optional and off-by-default-able, so the core machine
stays four rules deep.

> **Status:** experimental / research EA. Trade on demo first. No performance
> guarantee — see the [Disclaimer](#-disclaimer).
>
> **Backtest campaign (v1.02 baseline, remote MT5 real ticks, 2023-01 →
> 2025-12, 1 % risk, bias on, no session/trailing):**
>
> | Symbol | Trades | Win % | PF(R) | sumR | Final balance |
> |---|---|---|---|---|---|
> | EURUSD | 934 | 29.9 % | **0.84** | −110 R | $3,047 (−70 %) |
> | XAUUSD | 1,115 | 34.3 % | **1.03** | +22 R | $11,091 (+11 %) |
>
> EURUSD loses consistently in **every** year (31.9 % / 27.5 % / 29.9 % win);
> XAUUSD is statistically breakeven (34.3 % ≈ the 33.3 % break-even at 1:2 +
> costs). **No durable edge at the baseline settings** — consistent with the
> cost-wall finding in [`RESEARCH.md`](RESEARCH.md). The SL floors worked as
> designed (median loss −1.00 R, p95 win +2.02 R; only gap outliers beyond
> ±3 R on gold). Next research levers: session filter (killzones), trailing,
> swing-strength/sweep lookback grids, bias TF/period.

---

## How It Trades

```
   swing high ─────────────●──────────────  ◀── buy-side liquidity (resting stops)
                                        │
   sweep bar  ──────  wick ABOVE the pool, CLOSE back below it
   confirm    ──────  bear pin / bear engulf  ──▶  SELL @ market
                                                   SL  above sweep extreme + ATR buffer
                                                   TP  entry − RewardRR × risk

   swing low ──────────────●───────────────  ◀── sell-side liquidity
                                         │
   sweep bar  ──────  wick BELOW the pool, CLOSE back above it
   confirm    ──────  bull pin / bull engulf  ──▶  BUY @ market
                                                   SL  below sweep extreme + ATR buffer
                                                   TP  entry + RewardRR × risk
```

The signal is evaluated **once, on the close of each M15 bar** (closed-bar
discipline). A setup is valid only if the *confirmation candle is the bar that
just closed* — i.e. the sweep happened on that bar itself, or on the bar
immediately before it and the pattern printed after the sweep. There is no
pending-setup state: if the confirmation doesn't print in time, the setup is
simply gone. One position at a time per symbol + magic.

## Rule Definitions (exact)

**Liquidity pool** — the most recent *confirmed* fractal swing high / low on the
entry TF: a bar whose high (low) strictly exceeds all bars within
`SwingStrength` on **both** sides, and which has at least `SwingStrength` closed
bars to its right. Only pools older than the sweep bar qualify (a sweep is a
stop hunt *of an existing* pool).

**Sweep** — a closed bar whose wick trades *through* the pool but whose **close
is back inside** it:
- bullish setup: `low < swingLow` **and** `close > swingLow` (sell-side liquidity taken),
- bearish setup: `high > swingHigh` **and** `close < swingHigh` (buy-side liquidity taken).

**Pin bar** (bullish example) — lower wick ≥ `PinWickRatio` × body **and** lower
wick ≥ upper wick; mirrored for bearish. The candle range must also be ≥
`MinRangeATR` × ATR (filters micro-candles / doji noise).

**Engulfing bar** (bullish example) — prior bar bearish, current bar bullish,
and the current *body* fully covers the prior *body* (`open ≤ prev.close` and
`close ≥ prev.open`); mirrored for bearish. Same `MinRangeATR` range gate
applies to the engulfing candle.

**Confirmation** — the sweep bar itself may confirm (a sweep-and-reject candle
that is also a valid pin/engulfing), **or** the next closed bar confirms while
*holding the sweep extreme* (`low ≥ sweep low` for longs, mirrored for shorts)
and *closing back inside the pool*. The next-bar engulfing naturally uses the
sweep bar as the engulfed candle — the classic "sweep then engulf" sequence.

**Stop / target** — the SL is the **widest** of three candidates, so the sweep
structure is respected but cost floors always dominate when they are wider:

1. *Sweep-extreme stop*: beyond the extreme of the sweep sequence (sweep and
   confirm bar, whichever is further out) plus `SLBufferATRMult` × ATR;
2. *ATR floor*: `MinStopATRMult` × ATR — guards the position size from exploding
   on degenerate sweep wicks hugging the entry;
3. *Spread floor*: the spread must stay ≤ `MaxSpreadToSLPct` % of the SL
   distance (default 15 %) — i.e. `spread / SL distance × 100 % ≤ 15 %`. This is
   **not an entry gate**: the stop is simply **widened** so the spread cost
   stays a bounded fraction of the risk (0 disables the floor).

When a floor applies, the SL may sit inside the sweep wick — the structural
stop is used only when it is the widest candidate. TP is `RewardRR` × risk.
Sizing is `RiskPercent` of equity (0 = `FixedLots`).

## Optional Filters

| Filter | Default | Behaviour |
|---|---|---|
| **HTF bias** (`UseBiasFilter`) | **on** | H1 EMA(`BiasEmaPeriod`): longs only when the last closed M15 close is above the EMA, shorts only below. ICT-style: take the reversal *toward* the higher-TF draw. |
| **Session window** (`UseSessionFilter`) | off | Restrict entries to `[SessStartHour, SessEndHour)` **broker server time** (ICT killzone analog). Wraps midnight if start > end. Server-time offset is broker-dependent — verify before use. |
| **ATR trailing** (`UseTrailing`) | off | Activates at `TrailActivateRR` × initial risk, then trails `TrailATRMult` × ATR behind price (ratchet only; TP is preserved). |
| **Time stop** (`MaxBarsInTrade`) | 0 = off | Force-close after N entry-TF bars in trade. |

## Inputs

| Input | Default | Description |
|---|---|---|
| `InpEntryTF` | `M15` | Entry/trigger timeframe (attach the EA to any chart of this TF). |
| `InpSwingStrength` | `3` | Fractal strength: bars on each side that a swing must dominate. |
| `InpSweepLookback` | `60` | How many bars back a liquidity pool may sit. |
| `InpUsePinBar` | `true` | Enable pin-bar confirmation. |
| `InpUseEngulfing` | `true` | Enable engulfing confirmation. |
| `InpPinWickRatio` | `2.0` | Pin: rejection wick ≥ ratio × body. |
| `InpMinRangeATR` | `0.5` | Min confirm-candle range in ATRs (noise gate; 0 disables). |
| `InpUseBiasFilter` | `true` | Higher-TF EMA bias gate (see table above). |
| `InpBiasTF` | `H1` | Bias timeframe. |
| `InpBiasEmaPeriod` | `50` | Bias EMA period. |
| `InpUseSessionFilter` | `false` | Restrict entries to the session window. |
| `InpSessStartHour` / `InpSessEndHour` | `7` / `20` | Window in **server** hours; wraps midnight. |
| `InpATRPeriod` | `14` | ATR period on the entry TF (SL buffer, trailing). |
| `InpSLBufferATRMult` | `0.25` | SL buffer beyond the sweep extreme (× ATR). |
| `InpMinStopATRMult` | `1.0` | SL distance floor (× ATR); widens stops that the sweep wick made too tight. |
| `InpMaxSpreadToSLPct` | `15.0` | Max spread as % of SL distance; widens the SL when needed (0 = off). Not an entry gate. |
| `InpRewardRR` | `2.0` | TP distance = reward:risk multiple. |
| `InpRiskPercent` | `1.0` | Risk % of equity per trade (0 = fixed lots). |
| `InpFixedLots` | `0.10` | Fixed lots when `RiskPercent = 0`. |
| `InpUseTrailing` | `false` | Enable ATR trailing after activation. |
| `InpTrailActivateRR` | `1.0` | Trailing activation in R. |
| `InpTrailATRMult` | `1.5` | Trail distance (× ATR behind price). |
| `InpMaxSpreadPips` | `1.5` | Entries aborted above this spread (pips). |
| `InpMaxBarsInTrade` | `0` | Time-stop in entry-TF bars; 0 = off. |
| `InpMagic` | `20254101` | Magic number. |
| `InpComment` | `KISS` | Order comment. |
| `InpShowPanel` | `true` | On-chart status panel. |

Pip size is auto-detected (3/5-digit quotes → 1 pip = 10 points, else 1 point).
The SL/TP math is ATR-based, so it scales across symbols automatically; only
`MaxSpreadPips` needs per-symbol tuning (see the gold preset).

## Presets

- `preset/KISS_baseline_FX.set` — 5-digit FX baseline (EURUSD, GBPUSD, …).
- `preset/KISS_baseline_XAUUSD.set` — gold baseline (spread gate widened for
  metal quotes where 1 "pip" = 1 point = 0.01).

## Journal Forensics

For headless backtest parsing the EA logs:

- entries: `>>> BUY 0.12 | SL … | TP … | risk 12.3 pips | sell-side sweep of swing 1.08321 @ 2024.03.05 10:15 | bull pin`
- SL widened by a floor: `SL widened to floor: 2.2 -> 6.7 pips (spread 1.0 pips = 15% of SL)`
- per-trade: `position #N CLOSED - net +1.87R / 43.10 USD`
- rejections: `ENTRY ABORTED: spread …` / `ENTRY ABORTED: outside session …` /
  `ENTRY ABORTED: long against PERIOD_H1 EMA50 bias (…)` /
  `TRADE SKIPPED: invalid SL geometry vs sweep extreme` / `TRADE SKIPPED: lot size …`

## Backtesting

Use the standard headless recipe in [`../AGENTS.md`](../AGENTS.md) — **Model = 4
("every tick based on real ticks")**, chart/tester period M15 or M1 (the EA
keys off M15 bars internally regardless of the chart period). Test windows and
results will be recorded in [`RESEARCH.md`](RESEARCH.md) as the campaign
progresses.

## ⚠️ Disclaimer

This EA is a research prototype for the Strategy Tester and demo accounts.
Nothing here is financial advice; past backtest performance does not predict
live results. Use at your own risk.
