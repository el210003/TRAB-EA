# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project Overview

**TRAB EA** — a MetaTrader 5 Expert Advisor (MQL5) implementing a three-phase reversal
strategy on M1 charts: Trend (EMA stack in place) → Crack (EMA20/50 flip) → Sweep (EMA20 beyond all EMAs) → Retest entry (EMA150 retest + pin bar).
Single-file EA (`TRAB_EA.mq5`), no external dependencies beyond the standard library
(`<Trade\Trade.mqh>`).

- `TRAB_EA.ex5` — prebuilt binary, **intentionally committed** so MT5 users can use it
  without compiling. Never edit by hand; regenerate via the build command below.
- `docs/TRAB_EA_Proposal.md` — formal strategy spec & decision log (read before changing
  trading logic; it records *why* defaults are what they are).
- `docs/TRAB_EA_UserGuide.md` — end-user manual with a per-input usage reference.
- `preset/*.set` — MT5 input presets (baseline FX, baseline XAUUSD, walk-forward optimizer).

## Build

Compile with the MetaEditor CLI (no interactive IDE needed):

```bash
"C:/Program Files/MetaTrader 5 IC Markets Global/MetaEditor64.exe" \
  /compile:"<absolute path>/TRAB_EA.mq5" \
  /log:"<absolute path>/compile.log"
```

- The log is **UTF-16LE**: read it with `iconv -f UTF-16LE -t UTF-8 compile.log`.
- The build gate is **`Result: 0 errors, 0 warnings`**. Treat warnings as failures.
- Delete the temp `compile.log` afterwards (it is git-ignored anyway).
- If MetaEditor is running interactively, the CLI compile still works.

## Backtesting (headless Strategy Tester)

The MT5 Strategy Tester can be driven non-interactively from the CLI via a
`[Tester]` INI config file — no GUI needed.

> **Critical gotcha:** the headless `/config` launch **cannot run while the MT5
> terminal is open**. Close `terminal64.exe` first (it's usually attached to a
> live/demo chart, so do this deliberately, never `taskkill` it out from under a
> live session without asking). `ShutdownTerminal=1` makes the terminal close
> itself when the test finishes.

**Tester config template** (`<Data Folder>\Tester\trab_backtest.ini`):

```ini
[Tester]
Expert=EMA-Trading\TRAB_EA.ex5   ; path relative to <Data Folder>\MQL5\Experts
Symbol=EURUSD
Period=M1
Optimization=0
Model=4                          ; 4 = "Every tick based on real ticks" (REQUIRED for per-tick trailing)
FromDate=2023.01.01
ToDate=2025.12.31
ForwardMode=0
Deposit=10000
Currency=USD
Leverage=100
ExecutionMode=0
Visual=0
ShutdownTerminal=1

[TesterInputs]
; Inline EA inputs — the ONLY reliable way to override parameters headlessly.
; Format: Name=value||start||step||stop||(N=fixed|Y=optimize)
InpUseEmaCrossExit=false||0||0||0||N
InpTrailActivateRR=999.0||0||0||0||N
```

> **Gotcha (learned the hard way):** `ExpertParameters=<path>.set` is **NOT**
> honored when the `.set` lives in the repo `preset/` folder — it silently falls
> back to the EA's compiled defaults. MT5 only resolves a `.set` from
> `<Data Folder>\MQL5\Presets\`. For headless runs, pass inputs **inline via the
> `[TesterInputs]` section** instead (each `Name=value||0||0||0||N`). The
> `TRAB_optimize_walkforward.set` `||`-format maps directly to this.
> To build a variant: `sed` a base preset into a new `.set`, then feed it through
> the same `[TesterInputs]` transform.

**Launch** (detached so it doesn't block):

```bash
cmd //c start "" '<path>\terminal64.exe' "/config:<abs path>\Tester\trab_backtest.ini"
```

**Monitor & collect results** (all logs are UTF-16LE — convert with `iconv`):

- Progress: `iconv -f UTF-16LE -t UTF-8 <Data Folder>\Tester\logs\YYYYMMDD.log`
  and read the last simulated `TRAB:` timestamp. `metatester64.exe` running in
  `tasklist` = still processing; both gone = finished.
- The EA journal is mirrored to `<Data Folder>\Tester\logs\YYYYMMDD.log` **and**
  `<MetaQuotes Data>\Tester\<terminalId>\Agent-*\logs\YYYYMMDD.log`. Read the
  former. Note the log is **per calendar day** (it rolls at midnight) and the
  tester can also spin up faster on subsequent runs once tick data is cached
  (a cached 3-yr M1 run takes ~5s, not ~5min).
- MT5's own `Report=` XML/HTML **was not** emitted at the configured path in this
  setup — don't rely on it. Parse the **tester journal** instead: the EA logs
  its own per-trade and summary lines there.
- Journal lines to grep (same journal as above):
  - Entries: `>>> (BUY|SELL)`
  - Per-trade result: `position #[0-9]+ CLOSED - exit: <TP|Trail|Cross|SL|Other> | net <R>R / <USD>`
  - Session summary: `exit stats:` and the final `final exit stats - <n> trades,
    <R>R total | TP ... | Trail ... | Cross ... | SL ...`
- The `.tst` file in `<Data Folder>\Tester\cache\` is the raw test result
  (`TRAB_EA.EURUSD.M1.<from>_<to>.4.<hash>.tst`) — a good success indicator.
- **Isolating one run from another in the shared daily log:** snapshot the
  `grep -c "position #[0-9]+ CLOSED"` count just before the launch, then after the
  run take only lines `N0+1..N1` (chronological). Each single-parameter run adds
  exactly the same signal count, so compare `Trades`, win %, `sumR`, and the
  per-exit breakdown (`TP/Trail/Cross/SL`).

> **Model matters:** `Model=4` (real ticks) is required for this EA — the
> trailing stop and the EMA cross-exit run per-tick, which other models don't
> model faithfully. The tester's `Alert()` does **not** fire in the tester, so
> validate alert-only behavior on a live/demo chart.

## Code Conventions

Follow the existing style exactly — this file is one large, deliberately flat module:

- Inputs: `InpPascalCase`, declared in `input group "=== Name ==="` blocks, each with a
  trailing `// comment` (MT5 shows these comments as the input label in the UI).
- Globals: `g_pascalCase`. Constants/enum values: `ST_*` for the state machine
  (`ENUM_TRAB_STATE`). Helpers live in the "Small helpers" section.
- Logging: use the `Log()` wrapper (prefixes `TRAB: `) — never raw `Print()`.
- Every function carries a `//+---+` comment box with a one-line purpose.
- Entry gating happens in `TryEnter()`; each rejection logs a distinct reason
  (`ENTRY ABORTED: ...`, `TRADE SKIPPED: ...`) — preserve this forensics style.
- Signals are evaluated **only on closed M1 bars** (`EvaluateOnBarClose`), except trailing
  and the cross-exit retry which run per tick. Do not introduce intra-bar logic into the
  state machine.

## When You Change Things

1. **New/changed input** → add it to the matching `input group`, to the `OnInit()`
   validation chain (if it has constraints), **and to the table in
   `docs/TRAB_EA_UserGuide.md` §3** with a usage description.
2. **Behavior change** → document it in the UserGuide (and Proposal decision log if it
   alters strategy semantics).
3. **Version bump** → `#property version "X.XX"` *and* the panel string in `UpdatePanel()`
   must stay in sync.
4. **Recompile** and confirm 0 errors / 0 warnings before committing; commit the
   refreshed `TRAB_EA.ex5` together with the source.
5. Commit directly to `main` (`git add -A && git commit && git push`) — repo:
   `https://github.com/el210003/TRAB-EA`.

## Platform Gotchas (learned the hard way)

- The MT5 Experts journal (`<Data Folder>\MQL5\Logs\YYYYMMDD.log`) is **UTF-16LE** —
  plain `grep` finds nothing. Convert with `iconv` first. Tester journals live in
  `<Data Folder>\Tester\logs\` and stamp EA messages with *simulated* time.
- `Alert()` is **not executed** in the Strategy Tester — alert-only behavior must be
  validated on a live/demo chart.
- Pip size is symbol-dependent: 3/5-digit quotes → 10 points/pip, else 1 point;
  `InpPipSizeOverride` exists for gold/indices. Any pips-based math must go through
  `g_pip` / `PipToPrice()`.
- Session hours are GMT by default (`InpUseServerTime = false` + `InpServerGMTOffset`);
  don't "fix" timezone math without checking which base the inputs refer to.
- The state machine is frozen while a position is open, and `HasOpenPosition()` filters
  by symbol **and** magic — keep both filters on any new position scan.

## Validation Checklist Before Handing Back

- [ ] Compiles: 0 errors, 0 warnings
- [ ] `#property version` == panel version string
- [ ] New inputs documented in UserGuide §3 (and validated in `OnInit`)
- [ ] No strategy-behavior change without a UserGuide/Proposal note
- [ ] Committed source + refreshed `.ex5` together, pushed to `main`
