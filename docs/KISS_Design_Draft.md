# KISS EA — Redesign Draft

**Status: DRAFT v0.1 — FOR DISCUSSION. Nothing implemented. No code exists yet.**

This document restarts the KISS EA design from a clean slate, carrying forward only
what the v1.01–v1.08 campaign actually earned, and lays out the research plan that
must be passed *before* the EA is trusted again.

---

## 1. Post-mortem of v1.01–v1.08 (what the campaign proved)

| Finding | Evidence | Verdict for the redesign |
|---|---|---|
| Raw sweep+pin on M15 majors **loses** without context filters | 7 majors, PF 0.78–0.90, win 29–31% vs 33.3% break-even | Context filters are not optional; they are the strategy |
| **Killzone session filter** was the single biggest lever (EURUSD −77R → +22R alone) | v1.06 staged experiments | Keep; possibly refine to sub-windows |
| **Pins-only** beat pins+engulfing (bear engulf −49R worst cell) | trade-journal cell analysis | Engulfing off by default, kept as an option |
| **Time-stop hurt** (TS-96: PF 1.15 → 1.11) | A/B run | Excluded from the design |
| **Spread guard works and is needed**; floor insensitive 10–20%, gate monotonic (tighter better), Δ (modeled cost) up to Δ0.5 improved results via wider forced stops | v1.06 spread review | Keep as a named design pillar |
| **D1 structure regime** (8-state anchor model + PDH/PDL veto) — never validly tested (the one run used stale inputs) | — | Redesign cleanly, test properly this time |
| **60% of losses were fast rejects** (stopped ≤1h) | 219-loss case review | New design element: early-invalidation exit |
| **Slippage negligible** (0.07 pips avg on SL fills) | loss review | No slippage machinery needed |
| **Remote demo tick archive only covers 2026.04+** — 2023–25 runs ran on M1-synthesized ticks | journal `ticks data begins` lines | Data foundation must be decided up front (§8) |
| Everything was **in-sample**; the walk-forward was never run | — | Research plan with hard promotion/kill gates (§7) |

---

## 2. Trading thesis (the hypothesis we are testing)

> During the London/NY windows, price routinely sweeps a visible M15 liquidity pool
> (fractal swing high/low) and rejects. When the rejection is confirmed by a
> dominant-wick pin bar, and the *daily* structure agrees with the reversal while
> the intraday position does not contradict it (PDH/PDL), a fixed-R continuation
> trade has positive expectancy — *provided* the spread is a bounded fraction of
> the stop.

Each element is a falsifiable claim the research plan must test:
1. Sweeps during killzones reject more often than sweeps during off-hours (session filter earns its keep).
2. Rejection candles with dominant wicks mark turns more reliably than body-based patterns (pins-only).
3. Daily-structure agreement filters out counter-trend reversals (D1 regime gate earns its keep).
4. Bounding spread ≤ N% of stop keeps the cost hurdle survivable across pairs.

---

## 3. Architecture — five layers

```
L1 CONTEXT    D1 structure regime (8 anchor states) + PDH/PDL position   → direction permission
L2 SETUP      M15 liquidity sweep of a fractal pool (wick through, close back inside) → event
L3 TRIGGER    pin bar confirmation (engulfing optional)                  → actionability
L4 EXECUTION  spread-aware stop (widest of structural / ATR / spread floor), fixed-R target
L5 MANAGEMENT early-invalidation exit (new), nothing else — no trailing, no time stop
```

One position per symbol+magic. All decisions on closed M15 bars; the L1 state
re-evaluates per bar and is logged on change.

---

## 4. Component specs (draft rules + open questions)

### 4.1 L1 — D1 structure regime
The v1.07 eight-state partition on daily swing anchors `SH1/SH2`, `SL1/SL2` (last/previous
confirmed daily fractal pivots, strict, strength 2):

| | `SH1 > SH2` | `SH1 ≤ SH2` |
|---|---|---|
| **P > SH1** | CREATING_HH 🐂 | AWAY_FROM_HL 🐂 |
| **P ≤ SH1** | AWAY_FROM_HH 🐻 | CREATING_HL 🐻 |

| | `SL1 > SL2` | `SL1 ≤ SL2` |
|---|---|---|
| **P > SL1** | CREATING_LH 🐂 | AWAY_FROM_LL 🐂 |
| **P ≤ SL1** | AWAY_FROM_LH 🐻 | CREATING_LL 🐻 |

Regime: bullish above both anchors, bearish below both, between them sticky.

**Open questions (OQ-1):**
- (a) Pivot strength on D1: 2 (responsive) vs 3 (significant). v1.07 used 2 — flip-rate unknown.
- (b) Live-bid vs last-closed-M15 evaluation of `P` (intraday whipsaw across anchors).
- (c) Should the regime *age* matter (e.g. ignore states older than X pivots)?

### 4.2 L1 — PDH/PDL position
`ABOVE_PDH` bull / `BELOW_PDL` bear / inside = defer to regime. Veto: long blocked below PDL,
short blocked above PDH.

**OQ-2:** keep the veto strict, or soften to "inside the range always allows"?

### 4.3 L2 — M15 liquidity sweep
- Pools: last confirmed M15 fractal swing high/low (strength 3 default), within a lookback (60 bars).
- Sweep: a closed bar wicks through the pool and **closes back inside** (close-back-inside is what
  distinguishes a stop hunt from a breakout).
- Only pools older than the sweep bar qualify.

### 4.4 L3 — trigger
- **Pin bar** (default on): rejection wick ≥ 2× body, wick ≥ opposite wick, range ≥ 0.5×ATR.
- **Engulfing** (default **off**, retained as an option): body-coverage engulf of the prior candle.
- Confirmation candle = the sweep bar itself, or the next closed bar holding the sweep extreme
  and closing back inside the pool.

### 4.5 L4 — stop construction (the spread pillar)
`SL = widest of`:
1. structural: beyond the sweep-sequence extreme + 0.25×ATR
2. ATR floor: ≥ 1.0×ATR from entry
3. **spread floor**: SL ≥ `spread_model / MinSpreadToSLPct` (default 15% → SL ≥ 6.67× modeled spread)

`spread_model = live spread + SpreadAdjustPips` (Δ). Δ models non-raw accounts
(Δ ≈ your spread − raw-feed avg − commission you no longer pay).

### 4.6 L4 — target
Fixed TP = `RewardRR × risk` (default 2.0). RR is a first-class research lever
(high-spread pairs may need 2.5–3.0 to keep the cost hurdle sane: `p* = (1+s/L)/(1+RR)`).

### 4.7 L5 — early-invalidation exit (NEW, addresses the 60% fast-reject finding)
Design options (to be chosen, then A/B-tested):
- **(a) Close-basis invalidation**: if a closed M15 bar closes back beyond the swept pool
  (below the swept low for longs) within `InvalidationBars` (e.g. 4 bars = 1h), exit at market.
  Thesis-dead exit, not a time stop — slow winners are untouched (unlike TS-96 which hurt).
- **(b) Touch-basis invalidation**: exit the moment price touches the pool level again (tighter).
- **(c) Do nothing** in v2.0 and let the loss review decide after real data.

**Recommendation:** implement (a) behind `InpUseInvalidation=false` (off by default), A/B in
stage 2. The v1.x journal gives the baseline to beat: 132 fast rejects × 1R.

### 4.8 L1 — session
Killzone window(s) in server hours. Default single window 07–20 (proved). Option for two
refined windows (London 08–12, NY 14–19) — hour analysis showed 07–08h and 19h weak.

### 4.9 L4.5 — risk
1% equity per trade, risk-based lots, one position per symbol+magic, no recovery/martingale
machinery of any kind.

### 4.10 Instrumentation (non-negotiable, designed in from day one)
- `D1 STRUCTURE:` state-change lines **with anchor prices** (SH1/SH2/SL1/SL2) + day-roll PDH/PDL lines
- Entry lines echo `adj`, `D1:regime/states`, `POS:`
- Trade journal CSV per run (25+ columns incl. spread at entry, slippage, D1 state)
- Loss-review generator (archetype tagging: fast-reject, repeated-sweep, slippage, weak-hour…)
- `initialized` line + input echo are part of the *verification* protocol: **a run is void unless
  the echoed inputs match the intended settings** (the stale-input lesson).

---

## 5. Lean input budget (target ≤ 16 inputs)

v1.08 had drifted to 30. The redesign caps the surface:

| # | Input | Default |
|---|---|---|
| 1 | EntryTF | M15 |
| 2 | SwingStrength (M15 pools) | 3 |
| 3 | SweepLookback | 60 |
| 4 | UsePinBar | true |
| 5 | UseEngulfing | false |
| 6 | PinWickRatio | 2.0 |
| 7 | MinRangeATR | 0.5 |
| 8 | UseD1Gate | true |
| 9 | D1SwingStrength | 2 |
| 10 | Session on/off + hours | on, 07–20 |
| 11 | ATRPeriod | 14 |
| 12 | SLBufferATRMult | 0.25 |
| 13 | MinSpreadToSLPct | 15 |
| 14 | SpreadAdjustPips | per account |
| 15 | RewardRR | 2.0 |
| 16 | RiskPercent | 1.0 |

Dropped vs v1.08: ATR stop floor (fold into SLBufferATRMult decision), time stop, trailing,
dual gates, magic/comment surfaced as inputs (constants suffice per-symbol).

---

## 6. Data foundation (decide before the first backtest)

- **Local tester** (IC Markets Global, C: data folder): holds **real recorded ticks** for
  2023–2025 from the TRAB campaigns. → primary research rig.
- **Remote tester**: real ticks only from 2026.04+; 2023–25 = M1-synthesized. → acceptable for
  scale/OOS *with a caveat stamp on every result*, not for final validation.
- Rule: **no config gets promoted on synthesized-tick evidence alone.**

---

## 7. Research & validation plan (stages with promotion/kill gates)

| Stage | Window / data | What is tested | Promote if | Kill if |
|---|---|---|---|---|
| S1 baseline matrix | 2023–25, local real ticks | core config ± one-factor variants (pins/engulf, floor 10/15/20, gate 0.8/1.0/1.5, RR 2/3) | PF ≥ 1.15 **and** every year ≥ −0.5R | PF < 1.0 overall |
| S2 robustness | same, ±20% perturbation of every numeric input | parameter sensitivity | no input ±20% flips PF below 1.0 | any single knob is make-or-break |
| S3 walk-forward | 2018–2022 OOS, same config (frozen) | out-of-sample durability | PF ≥ 1.05 OOS | PF < 1.0 OOS |
| S4 forward demo | ≥ 8 weeks demo, live spread logger running | execution reality | positive R drift, slippage ≈ modeled | materially worse than modeled |
| S5 multi-pair | the 7 majors, S1 config frozen | generality | ≥ 4/7 pairs PF ≥ 1.0 | edge exists on 1 pair only |

Every stage writes its journals to `E:\tmp\<campaign>\` per AGENTS.md; every run's
`initialized` line must be verified against intended inputs (void otherwise).

---

## 8. Deliberately excluded

Trailing stops, time stops, partial TPs, break-even moves, multi-symbol correlation rules,
news filters (v2 candidate at most), martingale/recovery, order-block/FVG entries (future
research, not core), off-killzone trading.

---

## 9. Open questions for the owner

1. **Engulfing**: confirm off-by-default (data says yes)?
2. **Early-invalidation exit**: implement (a) close-basis in v2.0, or defer to stage-2 A/B?
3. **D1 pivot strength**: 2 or 3? (Flip-rate data will answer — do we care enough to instrument both?)
4. **Session**: single 07–20 window, or the two refined windows (08–12 / 14–19)?
5. **Δ for your live account**: what does your EURUSD spread typically read? (locks the cost model)
6. **Name**: stay "KISS EA"?

---

*This draft is the discussion artifact. No MQL5 file exists. Implementation starts only after
the open questions above are answered and this document is agreed.*
