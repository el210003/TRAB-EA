# TRAB EA — Trend Reversal & Accumulation Breakout

**M1 Expert Advisor for MetaTrader 5** · Version 1.12

TRAB is a three-phase reversal strategy for M1 charts, built as a **pure EMA-configuration state machine with EMA20 as the protagonist**: it locks onto trending EMA stacks, waits for the momentum crack, then trades the confirmed reversal sweep — with fully rule-based entries, exits, and risk management.

> **Status:** experimental / research EA. Trade on demo first. No performance guarantee — see [Disclaimer](#-disclaimer).

> **Research status (2026):** extensive headless backtesting (see
> [`docs/TRAB_EA_Proposal.md`](docs/TRAB_EA_Project.md) → *Research findings*)
> found the M1 reversal premise has **no robust edge**. A separate **H1 Donchian
> breakout** prototype (`TRAB_Breakout.mq5`) was profitable in 2023–25
> (EURUSD PF 1.19, USDCAD 1.55, USDJPY 1.12) but **did not survive a 2018–2026
> window (PF ~0.85–0.96)** — i.e. it is **regime-dependent, not a durable edge**.
> ML feature filters also provided no robust lift. **Do not treat any of these
> backtests as proof of alpha; validate on a demo forward-test first.**

---

## How It Trades

```
IDLE ──(full EMA stack forms: E20>E50>E150>E200, or reverse)──▶ TRENDING
TRENDING ──(EMA20 crosses EMA50 against the stack = crack)──▶ ACCUMULATION
ACCUMULATION ──(EMA20 sweeps beyond EMA150 AND EMA200 within SweepMaxBars)──▶ PRIMED
PRIMED ──(price retests EMA150 and prints a pin bar)──▶ MARKET ORDER
                                                       (or an Alert with AlertOnly = true)
```

| Phase | What it detects |
|---|---|
| **1 · Trend** | Full EMA stack — EMA20>EMA50>EMA150>EMA200 (or reverse) on closed bars. A state *is* the configuration: no history windows, no maturity test |
| **2 · Crack** | EMA20 crosses EMA50 against the stack — momentum broken. The box = price range from the crack bar until just before the EMA20/EMA150 cross. **Price purity:** price must never touch EMA20 while the setup lives |
| **3 · Sweep** | EMA20 sweeps beyond EMA150 **and** EMA200 within `SweepMaxBars` bars of the crack — quick-momentum reversal confirmed |
| **Entry** | Price **retests EMA150** and prints a **pin bar** (rejection wick ≥ `PinWickRatio` × body, closing back on the sweep side) — SL beyond the pin's extreme. Failed retest / no pin → back to ACCUMULATION for a fresh cycle |

**Exits:** SL beyond the pin-bar extreme (+buffer), fixed TP at 1:2 RR, trailing stop behind EMA50 after the 1:1 mark, plus an EMA10/EMA20 adverse-cross profit-protection exit.

**Safety gates:** spread cap, London/NY session windows, breakout-candle spike filter, hard SL cap, slippage cap, margin-checked position sizing, one position at a time per symbol/magic.

---

## Features

- ✅ Pure M1 state machine — every phase transition logged to the journal
- ✅ Risk-% position sizing (or fixed lots), floored to lot step and margin-checked
- ✅ Trailing stop + optional TP removal for extended trends
- ✅ EMA cross exit (EMA10 × EMA20) with optional profit gate
- ✅ **Alert-only mode** (`AlertOnly = true`, v1.04): pop-up signal alerts instead of orders — forward-test signals manually
- ✅ **Exit analytics** (v1.05): every close classified as TP / Trail / Cross / SL / Other with R-multiple, running journal stats + optional CSV export for exit-mix analysis
- ✅ On-chart status panel + per-state chart background tinting
- ✅ Auto position adoption after EA restart (initial risk persisted via Global Variable)
- ✅ Session filter with GMT or broker-server time base

---

## Installation

1. Copy `TRAB_EA.mq5` to `<Data Folder>\MQL5\Experts\` (or open the folder directly: MetaTrader 5 → *File → Open Data Folder*).
2. Compile in MetaEditor (**F7**) — or use the prebuilt `TRAB_EA.ex5` (v1.12, compiled 0 errors / 0 warnings).
3. Attach to an **M1 chart** and enable **Algo Trading**.
4. Confirm the journal shows: `TRAB: initialized on <SYMBOL> PERIOD_M1 | pip=... | ...`

Prebuilt presets are in [`preset/`](preset/):

| File | Purpose |
|---|---|
| `TRAB_baseline_FX.set` | Baseline settings for FX majors |
| `TRAB_baseline_XAUUSD.set` | Baseline for gold (includes `PipSizeOverride = 0.1`) |
| `TRAB_optimize_walkforward.set` | Optimizer config for walk-forward testing |

---

## Key Inputs (v1.05)

| Group | Highlights |
|---|---|
| Indicators | EMA 20/50 fast band · EMA 150/200 macro band |
| Phase Machine | `SweepMaxBars` quick-momentum window (crack → sweep ≤ 12 bars) · sweep price-purity rule (no EMA20 touch) · `PinWickRatio` pin-bar definition for the EMA150 retest |
| Entry | 20-bar primed setup lifetime · 20-pip breakout-candle spike filter |
| Risk & Exits | 1% equity risk (0 = fixed 0.10 lots) · 1:2 RR · 30-pip SL cap · EMA50 trailing from 1:1 |
| EMA Cross Exit | EMA10×EMA20 adverse-cross close, optional min-profit gate |
| Broker Environment | 1.5-pip spread cap · London 08–17 + NY 13–21 (GMT) windows |
| General | **`AlertOnly = false`** — `true` = signal alerts instead of trades · M1-only enforcement · pip-size override for gold/indices |

📖 **Full parameter-by-parameter usage reference:** [`docs/TRAB_EA_UserGuide.md`](docs/TRAB_EA_UserGuide.md)
📐 **Formal strategy spec & decision log:** [`docs/TRAB_EA_Proposal.md`](docs/TRAB_EA_Proposal.md)

### Alert-Only Mode (v1.04)

Set `AlertOnly = true` to run the EA as a **signal generator**: at a valid breakout it raises an MT5 Alert (direction, entry, SL, TP, risk, RR) instead of sending an order — one alert per setup. All entry gates still apply, so every alert matches exactly what would have been traded. Note: MT5 does not execute `Alert()` in the Strategy Tester — validate on a live/demo chart.

### Session Filter

Entries are gated to the London (08:00–16:59) and New York (13:00–20:59) windows, interpreted as **GMT** by default (`UseServerTime = false` + `ServerGMTOffset`). Set `UseServerTime = true` to define hours against your broker's chart clock instead, or `LondonStartHour = 0 / LondonEndHour = 23` to trade 24 h. Open positions are managed 24 h regardless.

---

## Backtesting

- Strategy Tester mode: **"Every tick based on real ticks"** (per-tick trailing requires it)
- Download ≥ 12 months of M1 data for the chart symbol
- Start with EURUSD, GBPUSD, XAUUSD (gold needs `PipSizeOverride = 0.1` if quoting is 2/3-digit)
- Walk-forward the most impactful inputs first: `SweepMaxBars`, `RiskRewardRatio`, `TrailActivateRR`, `EmaExitMinProfitRR` — `TRAB_optimize_walkforward.set` ships this exact grid

---

## Repository Layout

```
TRAB-EA/
├── TRAB_EA.mq5                     # Full source (MQL5)
├── TRAB_EA.ex5                     # Prebuilt v1.12 (drop into MQL5\Experts)
├── docs/
│   ├── TRAB_EA_Proposal.md         # Formal spec & decision log
│   └── TRAB_EA_UserGuide.md        # Complete inputs reference + troubleshooting
└── preset/
    ├── TRAB_baseline_FX.set
    ├── TRAB_baseline_XAUUSD.set
    └── TRAB_optimize_walkforward.set
```

---

## ⚠️ Disclaimer

This software is provided for **educational and research purposes**. Trading leveraged instruments carries a high level of risk and can result in the loss of all capital. Past performance — real or backtested — does not guarantee future results. Use at your own risk; the authors accept no liability for any losses incurred.
