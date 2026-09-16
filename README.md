# TRAB EA — Trend Reversal & Accumulation Breakout

**M1 Expert Advisor for MetaTrader 5** · Version 1.06

TRAB is a three-phase reversal strategy for M1 charts. It hunts for exhausted trends, waits for an accumulation squeeze, then trades the definitive reversal breakout — with fully rule-based entries, exits, and risk management.

> **Status:** experimental / research EA. Trade on demo first. No performance guarantee — see [Disclaimer](#-disclaimer).

---

## How It Trades

```
IDLE ──(fast band fully on one side for 60 closed bars)──▶ EXHAUSTED
EXHAUSTED ──(4-EMA squeeze < 5 pips)──▶ ACCUMULATION
ACCUMULATION ──(fast band definitively crossed to reversal side)──▶ PRIMED
PRIMED ──(M1 candle CLOSES outside the frozen box)──▶ MARKET ORDER
                                                       (or an Alert with AlertOnly = true)
```

| Phase | What it detects |
|---|---|
| **1 · Exhaustion** | EMA20/50 band entirely above (or below) the EMA150/200 macro band for N consecutive closed M1 candles — a stretched, exhausted trend |
| **2 · Accumulation** | A 45-candle consolidation box plus a 4-EMA squeeze below a pip threshold — the market is coiling |
| **3 · Crossover** | Both fast EMAs definitively cross to the *opposite* side of the macro band — the reversal candidate |
| **Entry** | First M1 candle **close** outside the frozen box, in the direction of the crossover |

**Exits:** SL 1 pip beyond the opposite box edge *or* beyond the EMA150/200 cluster (deeper wins), fixed TP at 1:2 RR, trailing stop behind EMA50 after the 1:1 mark, plus an EMA10/EMA20 adverse-cross profit-protection exit.

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
2. Compile in MetaEditor (**F7**) — or use the prebuilt `TRAB_EA.ex5` (v1.06, compiled 0 errors / 0 warnings).
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
| Phase Detection | 60-bar exhaustion lookback · 45-bar box · 5-pip squeeze threshold · 2-bar cross confirmation |
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
- Walk-forward the most impactful inputs first: `SqueezeThresholdPips`, `ExhaustionLookbackBars`, `BoxLookbackBars`, `TrailActivateRR`, `RiskRewardRatio`, `EmaExitMinProfitRR`

---

## Repository Layout

```
TRAB-EA/
├── TRAB_EA.mq5                     # Full source (MQL5)
├── TRAB_EA.ex5                     # Prebuilt v1.06 (drop into MQL5\Experts)
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
