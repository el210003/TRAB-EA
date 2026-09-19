# AGENTS.md

Guidance for AI coding agents working on **MetaTrader 5 (MQL5) Expert Advisors** in
this repository. It is intentionally generic — apply it to any `.mq5` EA in the
repo, whether the original strategy or a research prototype.

## Project Overview

- This repo contains one or more **MQL5 Expert Advisors** (`*.mq5`), each with a
  matching prebuilt `*.ex5` that is **intentionally committed** so MT5 users can
  use it without compiling. **Never hand-edit an `.ex5`** — regenerate it with the
  build command below.
- Standard library only (`<Trade\Trade.mqh>`); no external dependencies.
- `docs/` holds per-EA specs, user guides, and a research/decisions log. Read the
  relevant spec **before** changing trading logic — it records *why* defaults are
  what they are.
- `preset/*.set` holds MT5 input presets (baseline + optimizer grids).

## Build

Compile with the MetaEditor CLI (no interactive IDE needed):

```bash
"C:/Program Files/MetaTrader 5 <Broker>/MetaEditor64.exe" \
  /compile:"<absolute path>/MyEA.mq5" \
  /log:"<absolute path>/compile.log"
```

- The log is **UTF-16LE**: read it with `iconv -f UTF-16LE -t UTF-8 compile.log`.
- The build gate is **`Result: 0 errors, 0 warnings`**. Treat warnings as failures.
- Delete the temp `compile.log` afterwards (it is git-ignored anyway).
- A running MetaEditor does not block the CLI compile.

## Backtesting (headless Strategy Tester)

The MT5 Strategy Tester can be driven non-interactively via a `[Tester]` INI
config file — no GUI needed.

> **Critical gotcha:** the headless `/config` launch **cannot run while the MT5
> terminal is open**. Close `terminal64.exe` first (it may be attached to a
> live/demo chart, so do this deliberately — never kill it out from under a live
> session without asking). `ShutdownTerminal=1` closes the terminal when the
> test finishes.

**Tester config template** (`<Data Folder>\Tester\<test>.ini`):

```ini
[Tester]
Expert=MyEA.ex5                ; path relative to <Data Folder>\MQL5\Experts
Symbol=EURUSD
Period=M1
Optimization=0
Model=4                        ; 4 = "Every tick based on real ticks" (required for per-tick logic)
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
; Inline EA inputs — the reliable way to override parameters headlessly.
; Format: Name=value||start||step||stop||(N=fixed|Y=optimize)
SomeInput=false||0||0||0||N
AnotherInput=10||0||0||0||N
```

> **Gotcha:** `ExpertParameters=<path>.set` is **not** honored when the `.set`
> lives elsewhere than `<Data Folder>\MQL5\Presets\` — it silently falls back to
> the EA's compiled defaults. For headless runs pass inputs **inline via
> `[TesterInputs]`** (each `Name=value||0||0||0||N`). A `||`-style optimizer
> `.set` maps directly to this.

**Launch** (detached so it doesn't block):

```bash
cmd //c start "" '<path>\terminal64.exe' "/config:<abs path>\Tester\<test>.ini"
```

**Monitor & collect results** (all MT5 journals are UTF-16LE — convert with `iconv`):

- Progress: `iconv -f UTF-16LE -t UTF-8 <Data Folder>\Tester\logs\YYYYMMDD.log`,
  read the last simulated log line. `metatester64.exe` in `tasklist` = still
  running; both `terminal64` and `metatester64` gone = finished.
- The EA journal is mirrored under `<Data Folder>\Tester\logs\` **and**
  `<MetaQuotes Data>\Tester\<terminalId>\Agent-*\logs\`. Read the former. The log
  is **per calendar day** (rolls at midnight); subsequent runs are fast once tick
  data is cached.
- MT5's own `Report=` XML is often **not** emitted at the configured path — don't
  rely on it. Parse the **tester journal** instead: have the EA log per-trade and
  summary lines, then grep them. Common patterns:
  - Entries: `>>> (BUY|SELL)`
  - Per-trade: `position #[0-9]+ CLOSED - exit: <TP|Trail|Cross|SL|...> | net <R>R / <USD>`
  - Summary: `final exit stats - <n> trades, <R>R total | ...`
- The `.tst` file in `<Data Folder>\Tester\cache\` is the raw result — a good
  success indicator that a test ran.

**Isolating one run from another in the shared daily log:** snapshot the
`grep -c` of the per-trade pattern just before launch, then after the run take
only lines `N0+1..N1` (chronological). Each parameter run appends its trade list
to the same log, so compare counts, win %, `sumR`, and exit breakdown between
runs. For a **multi-symbol pool**, clear the daily log between runs so position
IDs don't collide across runs (or add a per-run marker line).

> **Model matters:** `Model=4` (real ticks) is required for any EA with per-tick
> trailing/stop logic. The tester does **not** execute `Alert()` — validate
> alert-only behavior on a live/demo chart.

## Remote MT5 headless backtesting (via SSH — offload compute off the local box)

A second MT5 machine is available at **`192.168.5.108`** (passwordless SSH as
`administrator`, key `~/.ssh/id_ed25519`). Use it for heavy backtests so they
don't fill the local C:.

**Find the MT5 install + data folder (Windows over SSH):**
- Install: `C:\Program Files\MetaTrader 5 ICM-01\terminal64.exe` (+ `metatester64.exe`).
- Data folder = the `MetaQuotes\Terminal\<HASH>` folder whose `origin.txt` names
  that exe. Write a small `.ps1` locally, `scp` it, run `powershell -File` to read
  each `origin.txt`. **Inline nested quoting over SSH is brittle — always ship a
  `.ps1`/`.bat` file and invoke it with `-File` / `cmd /c`.**

**Copy the EAs out:** `scp MyEA.mq5 MyEA.ex5 admin@…:…\MQL5\Experts\`.

**Data:** MT5 **auto-downloads** the needed history when the tester runs (bases
start empty; the tester pulls M1/ticks from the broker).

**Run a test (this is the reliable launch method):** a plain `Start-Process` or
`cmd start` **dies in a non-interactive SSH session**. Use a **Windows scheduled
task** instead:

```bat
schtasks /create /tn MT5Test /tr "\"C:\Program Files\MetaTrader 5 ICM-01\terminal64.exe\" /config:\"…\Tester\remote_test.ini\"" /sc once /st 00:00 /f
schtasks /run /tn MT5Test
```

The config `.ini` (written to `<data folder>\Tester\`) is the same `[Tester]` +
`[TesterInputs]` format as local. Use **backslash** Windows paths in the config
`Report=` and in the `/config:` argument (forward slashes in those two spots make
MT5 silently fail to start the test).

**Monitor + read results** (`scp` the journal and decode locally — PowerShell
`Select-String` double-encodes UTF-16, so always pull the raw `.log` and `iconv`
once):
- Check done: `ssh … "(Get-Process terminal64,metatester64 …).Count"` → `0` = finished.
- `scp …:…\Tester\logs\<date>.log` → `iconv -f UTF-16LE -t UTF-8` → grep the EA's
  per-trade / `>>> ` lines (add closed-position logging to the EA if it lacks it).

**Clean up afterwards** (on the remote): stop any `terminal64`/`metatester64`,
`schtasks /delete /tn MT5Test /f`, and `Remove-Item` the remote `Tester\cache\*.tst`,
`Tester\logs\*.log`, per-test `.ini`, and any pushed helper `.bat`/`.ps1`.
**Keep** `MQL5\Experts\MyEA*` and the downloaded `bases\` history.

## Clean up local artifacts after testing

The Strategy Tester writes large transient artifacts to `<Data Folder>\Tester\cache\`
(`.tst`, can be ~2 GB), `<Data Folder>\Tester\logs\`, and agent mirrors under
`<MetaQuotes Data>\Tester\...\Agent-*\logs\`. **When the backtest + analysis is
complete, wipe them** (C: tends to run tight). A helper is `bash /e/tmp/clean.sh`
(removes cache `.tst`, tester logs, agent mirrors, per-test `.ini`; **keeps** the
`bases\` history and the repo; refuses to run while MT5 is running). Only run it
after you've extracted the numbers you need.

## Code Conventions (MQL5)

- **Inputs:** `InpPascalCase`, declared in `input group "=== Name ==="` blocks,
  each with a trailing `// comment` (MT5 shows these as the input label).
- **Globals:** `g_camelCase`. Constants/enums uppercase (`ST_*`, `ENUM_*`). Helpers
  in a "Small helpers" section.
- **Logging:** a `Log()` wrapper with a prefix — never raw `Print()` in the EA.
- Every function gets a `//+---+` comment box with a one-line purpose.
- **Entry gating** in a dedicated `TryEnter()`; each rejection logs a distinct
  reason (`ENTRY ABORTED: ...` / `TRADE SKIPPED: ...`) — keep this forensics style.
- **Closed-bar discipline:** evaluate signals only on closed bars; only trailing
  / close-retry run per tick. Don't introduce intra-bar logic into a state machine.

## When You Change Things

1. **New/changed input** → add it to the matching `input group`, to the `OnInit()`
   validation chain if it has constraints, **and to the EA's docs table** with a
   usage description.
2. **Behavior change** → document it in the relevant doc (and decision log if it
   alters strategy semantics).
3. **Version bump** → `#property version "X.XX"` *and* any on-chart panel/comment
   string must stay in sync.
4. **Recompile** → 0 errors / 0 warnings before committing; commit the refreshed
   `*.ex5` together with the source.
5. Commit directly to `main` (`git add -A && git commit && git push`).

## Platform Gotchas (learned the hard way)

- MT5 journals (`<Data Folder>\MQL5\Logs\`, `<Data Folder>\Tester\logs\`,
  `MetaQuotes\Tester\...\Agent-*\`) and the MetaEditor build log are **UTF-16LE** —
  plain `grep` finds nothing; use `iconv`. Tester journals stamp EA messages with
  *simulated* time.
- `Alert()` is **not executed** in the Strategy Tester — alert-only behavior must be
  validated on a live/demo chart.
- **Pip size is symbol-dependent:** 3/5-digit quotes → 10 points/pip, else 1 point.
  Override inputs exist for gold/indices. Route all pips math through `g_pip` /
  a `PipToPrice()` helper.
- **Session/timezone math** is configuration-dependent (GMT vs broker server time)
  — don't "fix" it without checking which base the inputs reference.
- Position scans must filter by **symbol AND magic number**, and a state machine is
  typically frozen while a position is open.
- **Headless gotchas:** `[TesterInputs]` (not `ExpertParameters`), backslash paths
  in `Report=`/`/config:`, the scheduled-task launch over SSH, and clearing the
  daily log between runs for multi-symbol pools.

## Validation Checklist Before Handing Back

- [ ] Compiles: 0 errors, 0 warnings
- [ ] `#property version` == panel version string (if any)
- [ ] New inputs documented (and validated in `OnInit`)
- [ ] No strategy-behavior change without a doc/decision-log note
- [ ] Committed source + refreshed `.ex5` together, pushed to `main`
- [ ] Backtest artifacts cleaned up after analysis (see Clean up section)
