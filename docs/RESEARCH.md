# TRAB — Backtesting Research Summary

**Scope:** an honest account of a multi-month headless backtesting campaign
(local + remote MT5) into the TRAB trading idea, and what it did and did not
demonstrate. **Everything here is research, not a recommendation to trade.**

---

## Method

- Reproducible **headless MT5 Strategy Tester** runs, **Model = 4 ("every tick
  based on real ticks")**, on an M1-first strategy plus a set of M15/H1
  prototypes.
- Run **locally** and on a **remote MT5 box over SSH** (scheduled-task launch +
  UTF-16 journal parsing). See `AGENTS.md → Backtesting` for the exact recipe
  (config `[Tester]`/`[TesterInputs]`, launch, log decode, cleanup).
- Data: broker M1/ticks (auto-downloaded by the tester). Windows tested:
  **2023–01 → 2025-12** (main) and **2018-01 → 2026-08** (robustness check).
- ~**100+ configurations** across entry signal, retest source, exit, pin
  definition, reward ratio, multi-timeframe filters, and an ML entry filter.

## Results by strategy

| Strategy | Most profitable result | Robustness |
|---|---|---|
| **TRAB_EA — M1 EMA reversal + retest pin** | never profitable; best near-breakeven (M15 trend filter, **PF ≈ 0.85**, low trades) | no edge |
| **TRAB_Swing — H4 trend + M15 entry** | lost (PF 0.46–0.88) | — |
| **TRAB_SnR — H4 S/R + M1 EMA** | lost (reversal PF 0.75, break PF 0.66) | — |
| **TRAB_Breakout — H1 Donchian breakout** | **PF 1.19 (EURUSD), 1.55 (USDCAD), 1.12 (USDJPY)** + trailing | **fails 2018–2026 (PF ~0.85–0.96)** |

## Key findings

1. **M1 reversal premise has no edge.** The entry win rate stayed ~18–33% —
   below the ~33% break-even for a 1:2 system — across every retest source
   (EMA / Fib / breakout / swing), exit, pin and reward variant.

2. **M1/M15 entries are cost-dominated.** Small ATR stops incur ~0.3R of
   spread/slippage per trade. **Only a wide-SL H1 breakout escapes the cost
   wall.** This is structural, not a tunable knob.

3. **Trend-following beats mean-reversion**, consistent with modern practice.
   The **H1 Donchian breakout (channel 10, no trend filter, ATR stop, trailing
   exit)** was the only profitable config.

4. **Trailing-only is the best exit.** Pure trailing beat every fixed-TP,
   breakeven and hit-and-run (TP 1.5/2/2.5R, BE, TP+trail) variant: PF 1.19 vs
   0.88–1.12.

5. **⚠️ The edge is regime-dependent, not durable.** Extending EURUSD to
   **2018–2026** dropped PF from **1.19 → ~0.85–0.96** (a loss). The 2023–25
   profit came from a strongly trending regime; it does not hold across the
   full cycle (2018–21 chop, 2020/2022 volatility). This is the classic
   signature of **curve-fitting to a favourable backtest window**.

6. **ML/feature filters provide no robust lift.** A gradient-boosted entry
   filter (pooled profitable pairs, 12–18 features: ADX, RSI, EMA slope,
   volatility regime, channel position, ATR, …) improved out-of-sample PF on
   the 2023–25 window (**AUC ≈ 0.576**, filtered PF ≈ 1.9), but the
   discriminator is **weak (AUC ≈ 0.58)**, **more features overfit** (AUC drops
   to ≈ 0.53), and it was built on a strategy **that does not survive a longer
   window** — so any gain is period-specific.

## Honest verdict

**No strategy tested demonstrates a durable, robust statistical edge.** The one
profitable config (H1 Donchian breakout) is very likely **regime-dependent**:
its "profit" is best understood as exposure to a trending regime, not persistent
alpha. **This blocks live deployment** (see `docs/TRAB_EA_Proposal.md →
Research findings`).

## Recommendation

- **Do not treat any single backtest window as proof of alpha.** The 2023–25
  profit should be treated as regime exposure.
- The only meaningful forward validation is a **multi-month demo forward-test**
  (e.g., the **USDCAD** breakout — PF 1.55, low drawdown), ideally gated behind
  a **trend-regime filter** that itself survives out-of-sample.
- **Do not allocate live capital on backtest results alone.**

## Reproducibility

- Headless-run recipe + remote-SSH method: **`AGENTS.md → Backtesting`**.
- Strategy specs / decision log: **`docs/TRAB_EA_Proposal.md`** (as-built +
  research findings).
- The H1 breakout preset used: `preset/TRAB_baseline_breakout.set`.
