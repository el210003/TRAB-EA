# KISS EA — D1 Structure Review Sheet

**Scope:** `KISS_EA.mq5` v1.07 · function `D1Structure()` (line ~177), `LogStructureState()` (~215), entry gate in `TryEnter()` (~335)
**Purpose:** the reference sheet for reviewing how the D1 bias works, day by day, before trusting its output. Nothing here changes code — it documents what is coded and lists what to verify.

---

## 1. Data and pivot detection

- Universe: the last **128 closed daily bars** (`InpBiasLookback=120` + pivot window `2×InpBiasSwingStrength+4`). Today's forming bar is excluded.
- A **daily pivot high** = a bar whose high is strictly greater than the 2 bars before *and* the 2 bars after it (`InpBiasSwingStrength=2`). Mirrored for lows. Comparison is **strict** — two *equal* daily highs disqualify both candidates (an equal high = "leaving the HH" failure).
- Anchors: `SH1/SH2` = most recent / previous confirmed swing high; `SL1/SL2` = same for lows.
- A pivot becomes visible only after **2 daily closes** exist past it (confirmation lag); the *state* reacts immediately to price crossing the last known anchor.

## 2. The eight states (exact partition)

`P` = current bid, evaluated on the first tick of every new M15 bar.

| | `SH1 > SH2` (rising highs) | `SH1 ≤ SH2` (falling/flat highs) |
|---|---|---|
| **P > SH1** | `CREATING_HH` 🐂 | `AWAY_FROM_HL` 🐂 (escaped the lower high) |
| **P ≤ SH1** | `AWAY_FROM_HH` 🐻 (rejected under the HH) | `CREATING_HL` 🐻 (lower highs forming) |

| | `SL1 > SL2` (rising lows) | `SL1 ≤ SL2` (falling/flat lows) |
|---|---|---|
| **P > SL1** | `CREATING_LH` 🐂 (higher low holds) | `AWAY_FROM_LL` 🐂 (left the lows behind) |
| **P ≤ SL1** | `AWAY_FROM_LH` 🐻 (lost the higher low) | `CREATING_LL` 🐻 (lower lows forming) |

Exactly one high-side state and one low-side state are active at all times. Notation note: in this model **LH = "low, higher"** (higher low) and **HL = "high, lower"** (lower high).

## 3. Regime and position

- **Regime = BULLISH** when both sides vote bull (`P > SH1` **and** `P > SL1`); **BEARISH** when both vote bear (`P < SH1` **and** `P < SL1`); **split** (price between the anchors) → **holds the previous regime** (sticky; starts 0 = undecided, resolves on the first evaluation because 128 bars of history are available).
- **Position** vs the previous *completed* daily bar: `ABOVE_PDH` (bull) / `BELOW_PDL` (bear) / `INSIDE` (defers to regime). Monday's "previous day" is Friday.
- **Gate:**
  - `longAllowed  = regime BULLISH && pos != BELOW_PDL`
  - `shortAllowed = regime BEARISH && pos != ABOVE_PDH`
  - Regime 0 → both directions blocked. A veto logs full context: `ENTRY ABORTED: long vs D1 BULLISH (CREATING_HH+CREATING_LH) / POS BELOW_PDL (PDH … PDL …)`.

## 4. Where it is logged

| Artefact | Content |
|---|---|
| BT journal, per M15 bar on change | `D1 STRUCTURE: BULLISH \| states CREATING_HH+CREATING_LH \| pos ABOVE_PDH` |
| BT journal, at day roll | `D1 POSITION LEVELS: PDH … PDL …` |
| Entry line echo | `… \| D1:BULL/CREATING_HH+CREATING_LH \| POS:ABOVE_PDH` |
| Trade journal CSV (new runs) | columns `D1_State`, `Pos_State` per trade |
| Chart panel | regime + active states + PDH/PDL live |

## 5. Worked example (strength = 2)

Anchors entering the week: `SH1 1.0880 > SH2 1.0840`, `SL1 1.0850 > SL2 1.0820` — regime BULLISH.

| Day | Price action | P | High-side | Low-side | Regime | Pos | Long? |
|---|---|---|---|---|---|---|---|
| 11 | rally to new high | 1.0905 | CREATING_HH | CREATING_LH | **BULL** | ABOVE_PDH | ✅ |
| 12 | pullback to 1.0860 | 1.0860 | AWAY_FROM_HH 🐻 | CREATING_LH 🐂 | split → **HOLD BULL** | **BELOW_PDL** (day-11 low 1.0890) | ❌ position veto |
| 13 | back to 1.0895 | 1.0895 | AWAY_FROM_HH 🐻 | CREATING_LH 🐂 | HOLD BULL | INSIDE | ✅ |
| 14 | closes 1.0840 (< SL1) | 1.0840 | AWAY_FROM_HH 🐻 | **CREATING_LL** 🐻 | **BEAR** (flip) | BELOW_PDL | ❌ |

After day 14 the new low confirms → `SL1 1.0840`; once price recovers above it the low-side reads `CREATING_LH` again (1.0840 > SL2 1.0820) while the high side stays `AWAY_FROM_HH` → regime stays BEARISH until price reclaims `SH1`.

## 6. Edge cases and behaviours to be aware of

1. **Pullback flip sensitivity**: one daily close below the last higher low flips the regime bearish, even in a healthy uptrend. With `Strength=2` the anchor can be a *minor* 2-day pullback low — the regime is responsive, sometimes twitchy.
2. **Intraday whipsaw**: `P` is the live bid at the first tick of each M15 bar; crossings of `SH1`/`SL1` flip the regime instantly and back. Journal records each change; entries use the momentary state. A close-based variant (evaluate on the last closed M15 bar) would be calmer — tunable, not implemented.
3. **Equal highs/lows produce no pivot at all** — the older anchor remains, so a double top can persist in the anchors until an actual break.
4. **Compression** (lower highs + higher lows): high-side CREATING_HL 🐻 + low-side CREATING_LH 🐂 → split → previous regime holds until the triangle breaks `SH1` or `SL1`. The machine goes quiet inside triangles.
5. **Inverted anchors** (`SH1 < SL1`, after a V-move): price between them gives one bull + one bear vote → sticky. Rare, benign.
6. **Confirmation-lag asymmetry**: states react instantly to price crossing an anchor; the anchor itself ratchets only after 2 daily closes. `CREATING_HH` can persist for weeks in a trend.
7. **Position veto is sharper than the regime**: a routine pullback below *yesterday's* low blocks longs for as long as it lasts — independent of the regime.

## 7. Open review items (checklist)

- [ ] Re-run EURUSD with **verified D1 inputs** — the 2026-09-20 run applied stale tester inputs (`InpBiasTF=16385/H1`, Δ=0; the journal input echo proved it) and its results are void. Always check the `initialized` line + input echo before trusting a run.
- [ ] Flip-rate review: count `D1 STRUCTURE:` changes per month in the corrected run. Weekly churning → try `BiasSwingStrength` 2 → 3 (more significant pivots, stickier regime).
- [ ] Outcome-by-state join: bucket the trades by `D1_State` (the CSV now carries it) — does `CREATING_HH+CREATING_LH` outperform `AWAY_FROM_HL` (recovery) entries?
- [ ] Position-veto audit: count `ENTRY ABORTED … POS …` kills and what those setups would have done — decide whether the veto earns its keep.
- [ ] Whipsaw decision: keep live-bid evaluation vs switch to last-closed-M15 evaluation.
- [ ] Walk-forward (2018–2022) of the final config — still outstanding from the spread review.

## 8. Change log

| Version | Change |
|---|---|
| v1.03 | H4 pivot-structure bias introduced (HH/HL vs LH/LL, most recent event decides) |
| v1.07 | **Replaced by this D1 model**: 8-state partition on daily anchors, sticky regime between anchors, PDH/PDL position veto, full state logging + entry echo. Bias TF moved H4 → D1. |

---

*Review sheet maintained alongside the code. Update the checklist as items are verified; do not edit the state definitions without bumping the EA version.*
