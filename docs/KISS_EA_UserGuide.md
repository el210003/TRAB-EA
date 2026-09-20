# KISS EA — SMC/ICT Liquidity Sweep + Pin/Engulfing Entry

**M15 Expert Advisor for MetaTrader 5** · Version 1.04

KISS ("Keep It Simple, Stupid") is a minimal **Smart Money Concepts (SMC) /
Inner Circle Trader (ICT)-style** strategy: it hunts **liquidity sweeps** of the
most recent swing highs/lows and enters on the reversal **only when the sweep is
confirmed by a pin bar or an engulfing bar**. Everything else — bias, session,
trailing, time stop — is optional and off-by-default-able, so the core machine
stays four rules deep.

> **Status:** experimental / research EA. Trade on demo first. No performance
> guarantee — see the [Disclaimer](#-disclaimer).
>
> **Backtest campaign (baseline, remote MT5 real ticks, 2023-01 → 2025-12,
> 1 % risk, bias on, no session/trailing):**
>
> | Symbol | Bias | Trades | Win % | PF(R) | sumR | Final balance |
> |---|---|---|---|---|---|---|
> | EURUSD | v1.02 H1 EMA50 | 934 | 29.9 % | 0.84 | −110 R | $3,047 (−70 %) |
> | EURUSD | **v1.03 H4 structure** | 1,023 | 31.0 % | **0.88** | −89 R | $3,677 (−63 %) |
> | XAUUSD | v1.02 H1 EMA50 | 1,115 | 34.3 % | 1.00 | +22 R | $11,091 (+11 %) |
> | XAUUSD | **v1.03 H4 structure** | 1,280 | 35.9 % | **1.11** | **+91 R** | $21,617 (+116 %) |
>
> The H4 structure bias improved both symbols (EURUSD PF 0.84 → 0.88 and 2023
> flipped positive; XAUUSD PF 1.00 → 1.11 with +91 R and two of three years
> positive). EURUSD still **loses overall** — 2024 chop is its killer (−78 R)
> while the same year was gold's best (+69 R): the effect is
> instrument-specific and thin (XAUUSD avg +0.07 R/trade). Not validated
> out-of-sample; do not treat as a durable edge. The SL floors worked as
> designed throughout (median loss −1.00 R, p95 win ≈ +2.0 R; only gap
> outliers beyond ±3 R on gold). **Research priority: forex majors first**
> (EURUSD, GBPUSD, USDJPY, USDCHF, AUDUSD, USDCAD, NZDUSD); XAUUSD is parked
> as a secondary experiment. Next levers: session killzones, trailing,
> bias strength/lookback grids, per-symbol deployment.
>
> **Spread realism (v1.04, EURUSD, same window):** the tester fills use the
> raw demo feed (0.28 pips avg + commission), so `InpSpreadAdjustPips` models
> other account types — the adjustment enters the spread gate, the 15 %
> floor, widens the SL and pulls the TP closer:
>
> | Δ (adj) | ≈ account | Trades | Win % | PF(R) | sumR | Final |
> |---|---|---|---|---|---|---|
> | 0.00 | raw feed (regression = v1.03) | 1,023 | 31.0 % | 0.88 | −89 R | $3,677 |
> | 0.10 | IC Markets Standard (~1.1 pip, no comm) | 999 | 31.7 % | 0.89 | −77 R | $4,207 |
> | 0.50 | ~1.6 pip standard account | 911 | 33.8 % | 0.91 | −55 R | $5,315 |
> | 1.00 | ~2.0 pip standard account | 769 | 37.8 % | 1.03 | +16 R | $11,002 |
> | 1.50 | ≥ 2.5 pip account | 0 | — | — | 0 | $10,000 (all gated; raise `MaxSpreadPips`) |
>
> Two effects, both mechanical: a larger Δ (a) gates out wide-spread ticks
> (the gate uses the modeled spread) and (b) forces wider stops via the 15 %
> floor — fewer, longer, cleaner trades with a higher win rate. The Δ=1.00
> row is nominally profitable but is **one symbol, one window, in-sample**,
> and the improvement comes from stop width, not a discovered edge. Note:
> `MaxSpreadPips` gates the *modeled* spread — when raising Δ, raise the gate
> accordingly or everything gets aborted (the Δ=1.50 row).
>
> **EURUSD focus experiments (v1.04, Δ=0.1, same window)** — variants driven
> by the trade-journal findings (pins ≫ engulfings; killzones untested;
> duration outliers):
>
> | Config | Trades | Win % | PF(R) | sumR | Final |
> |---|---|---|---|---|---|
> | baseline (ref) | 999 | 31.7 % | 0.89 | −77 R | $4,207 |
> | pins only | 649 | 32.0 % | 0.91 | −42 R | $6,139 |
> | killzone only (07–20h srv) | 691 | 35.0 % | 1.05 | +22 R | $11,566 |
> | pins + killzone | **436** | **37.2 %** | **1.15** | **+41 R** | **$14,329** |
> | pins + killzone + time-stop 96 | 444 | 36.9 % | 1.11 | +32 R | $13,113 |
> | pins + time-stop | 661 | 32.1 % | 0.89 | −51 R | $5,662 |
>
> The **killzone session filter is the decisive lever** (every config gains
> from it; it flips EURUSD positive), and pins-only adds further on top.
> The time-stop does not help — dropped. Best config:
> **pins + killzone = 436 trades, 37.2 % win at 1:2, PF 1.15, +41 R** with
> two of three years positive (2024 −5 R is the residual weak spot).
> **Caveats:** in-sample selection on one symbol/window, killzone hours are
> *server* time (validate per broker), and the config family was chosen from
> the same journal that motivated it. Required next step: out-of-sample
> walk-forward (2018–2022) before calling it an edge.
>
> **FX majors sweep (v1.03 baseline, same window, remote real ticks):**
>
> | Pair | Trades | Win % | PF(R) | sumR | Final balance | Note |
> |---|---|---|---|---|---|---|
> | EURUSD | 1,023 | 31.0 % | 0.88 | −89 R | $3,677 | full 3y |
> | GBPUSD | 1,308 | 29.2 % | 0.81 | −184 R | $1,460 | full 3y |
> | USDJPY | 1,230 | 30.8 % | 0.90 | −89 R | $3,482 | full 3y (2024 +1.9 R) |
> | USDCHF | 1,266 | 29.4 % | 0.78 | −205 R | $1,172 | full 3y |
> | AUDUSD | 993 | 30.7 % | 0.83 | −125 R | $2,588 | full 3y |
> | USDCAD | 419 | 34.6 % | 1.04 | +13 R | $10,862 | **2025 only** (broker archive starts 2025) |
> | NZDUSD | 1,245 | 29.2 % | 0.79 | −197 R | $1,290 | full 3y |
>
> **Verdict: the sweep-reversal baseline has no edge on FX majors.** Win rates
> cluster at 29–31 % vs the 33.3 % break-even at 1:2; losses are consistent
> across years and pairs, not regime luck. Only USDCAD (2025-only data, thin
> +13 R) is nominally positive — insufficient data to trust. This matches the
> cost-wall thesis in [`RESEARCH.md`](RESEARCH.md): on M15-sized stops,
> spread + commission + slippage consume ≈ 0.1–0.3 R per trade, and the entry
> win rate never clears the hurdle. Any next iteration must change the
> *economics* (killzone-only trading, wider structural stops, higher-RR
> profiles), not re-tune the same entry.

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

## Trade Lifecycle at a Glance

1. **Pool** — most recent confirmed M15 fractal swing high/low = resting-stop liquidity.
2. **Sweep** — closed bar wicks through the pool, closes back inside (stop hunt, no acceptance).
3. **Confirm** — the sweep bar itself or the next closed bar prints a pin bar or engulfing bar in the reversal direction (next-bar confirm must hold the sweep extreme and close back inside the pool).
4. **Gates** — H4 structure bias must agree; spread ≤ `MaxSpreadPips`; optional session window.
5. **Entry** — market order at the open of the next M15 bar; size = `RiskPercent` of equity ÷ stop distance.
6. **Exit** — fixed TP at `RewardRR` × risk and the SL below; nothing discretionary.

**Why these exits:** with wins paying 2 R the break-even win rate is 33.3 % —
every filter exists to push the win rate above that. There is no partial exit,
no manual break-even move and no trailing by default (KISS: results stay
attributable); trailing and a time-stop exist as optimizer levers.

### Worked example (real journal trade — EURUSD 2024.03.26)

```
00:15  sweep: low 1.08310 < swing low 1.08333, close back above   (sell-side sweep)
00:30  bull pin confirms on the next bar, holds 1.08310
00:45  >>> BUY 0.97 | SL 1.08312 | TP 1.08503 | risk 6.4 pips | bull pin
        entry ask 1.08376 · SL = sweep extreme 1.08310 + 0.25×ATR buffer → 6.4 pips
        TP = 1.08376 + 2 × 6.4 pips = 1.08503 · size = 1 % equity ÷ stop = 0.97 lots
09:30  TP hit → position CLOSED - net +1.82R / +116.39 USD
```

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
| **HTF structure bias** (`UseBiasFilter`) | **on** | **H4 fractal market structure** (no indicators): the most recent *confirmed* H4 swing event decides the regime — a swing high that made a **HH**, or a swing low that held as a **HL**, is **bullish**; a swing high that made a **LH** (or failed to exceed the prior high — "leaving the HH"), or a swing low that broke down (**LL**), is **bearish**. Longs only in bullish structure, shorts only in bearish. A fresh event flips the bias as soon as it is confirmed (`BiasSwingStrength` H4 bars have closed past it — no repaint). |
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
| `InpUseBiasFilter` | `true` | Higher-TF structure bias gate (see table above). |
| `InpBiasTF` | `H4` | Bias timeframe (fractal market structure). |
| `InpBiasSwingStrength` | `2` | Bias fractal strength (bars each side of an H4 pivot). |
| `InpBiasLookback` | `120` | Bars scanned for bias pivots (~20 days of H4). |
| `InpUseSessionFilter` | `false` | Restrict entries to the session window. |
| `InpSessStartHour` / `InpSessEndHour` | `7` / `20` | Window in **server** hours; wraps midnight. |
| `InpATRPeriod` | `14` | ATR period on the entry TF (SL buffer, trailing). |
| `InpSLBufferATRMult` | `0.25` | SL buffer beyond the sweep extreme (× ATR). |
| `InpMinStopATRMult` | `1.0` | SL distance floor (× ATR); widens stops that the sweep wick made too tight. |
| `InpMaxSpreadToSLPct` | `15.0` | Max spread as % of SL distance; widens the SL when needed (0 = off). Not an entry gate. Uses the *modeled* spread. |
| `InpSpreadAdjustPips` | `0.0` | Modeled spread adjustment (pips) for non-raw accounts: the spread gate, the 15 % floor, the SL (+) and the TP (−) all use `tick spread + adjustment`. Δ=0 reproduces the raw-feed result exactly. Pick Δ ≈ *your typical spread* − *raw-feed spread (~0.3 on majors)* − *commission you no longer pay (~0.7 pip-equiv)*. |
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
  `ENTRY ABORTED: long against PERIOD_H4 structure bias (LL 1.07430 @ 2024.02.27 12:00)` /
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
