# Q-Link order investigation — XL3 2×8 knobs → MPC 3.10.1 `qlinks[0..15]`

**Question:** which API index (`mpc.controlSurface.qlinks[i]`, 0-based, `GetNumQLinks()==16`) does each
of the XL3's 16 top knobs (2 rows × 8) have to drive so that a knob lands on the slot where the MPC's
Q-Link screen shows it?

**Verdict (derived, not guessed):**

```lua
local QLINK_ORDER = { 12, 13, 14, 15, 8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3 }
```

Formula equivalent (1-based knob number `k`, row-major: row 1 = knobs 1–8, row 2 = knobs 9–16):

```lua
local p = k - 1                       -- 0-based knob index
local qlinkIndex = (3 - (p // 4)) * 4 + (p % 4)
```

Knob row 1 = the screen's TOP half (slots labelled Q-Link 9–16), knob row 2 = the BOTTOM half
(Q-Link 1–8). Both failed builds are explained by this geometry; both official MPK scripts and the
LPP3/LPMK3 device-verified page groups reconcile to it exactly (§3, §5).

---

## 1. Findings per source

### 1.1 Official Akai script: `mpkMiniMkIV.lua` (mpc310-kit, shipped on fw 3.10.1 stick)

- `mpkMiniMkIV.lua:247-257` — the knob→qlink formula:

  ```lua
  local function getQLinkIndexForKnob(knobIndex)
      local row = knobIndex // 4;
      local rowOffset = 1 - ((row % 2) * 2);
      local qlinkIndex = (row + rowOffset) * 4 + (knobIndex % 4);
      return qlinkIndex;
  end
  ```

  Arithmetic: knobIndex 0–3 (top knob row) → **4,5,6,7**; knobIndex 4–7 (bottom knob row) → **0,1,2,3**.
  Left-to-right order is preserved within each row; the rows are "vertically flipped" only relative to
  *linear* index order.

- `mpkMiniMkIV.lua:598` — screen label convention: `updateScreenTextTop("Q-Link " .. getQLinkIndexForKnob(listenedKnob) + 1, ...)`
  → slot labels are **1-based linear**: "Q-Link n" = API index n−1.

- `mpkMiniMkIV.lua:408` — the 16 Q-Links are paged as two labelled halves of 8:
  `knobBankString = tostring(1 + knobBank * 8) .. "-" .. tostring(8 + knobBank * 8)` →
  "**Q-Links 1-8**" / "**Q-Links 9-16**" (`knobBank` 0/1, `mpkMiniMkIV.lua:991-1000`).

- `mpkMiniMkIV.lua:262` — bound to the same API: `mpc.controlSurface.qlinks.GetNumQLinks()`, `qlinks[i]` 0-based.

### 1.2 Official Akai script: `mpkMiniPlusII.lua`

- `mpkMiniPlusII.lua:268-279` — **byte-identical** `getQLinkIndexForKnob` (same flip formula).
- `mpkMiniPlusII.lua:607` — same "Q-Link " .. index+1 screen label.
- `mpkMiniPlusII.lua:427, 1093-1102` — same 1-8 / 9-16 bank paging of 8.
- Two independent official surfaces, same formula ⇒ the flip is an Akai convention, not an accident.

### 1.3 Device-verified LPP3 script: `LaunchpadProMK3.lua` (user's controller)

- `LaunchpadProMK3.lua:901-908` — the key device evidence, verbatim:

  > The order follows the MPC's Q-Link screen, which lists the 16 slots **column-major** with each
  > bank/page running in reverse index order: its **page 1 is Q-Links 12,8,4,0**, page 2 is 13,9,5,1,
  > page 3 is 14,10,6,2, page 4 is 15,11,7,3 (**device-verified twice over**: the Kill EQ page lives at
  > 0,4,8,12 and the Beat Repeat page at 1,5,9,13, each reading **newest slot first on the screen**).

- `LaunchpadProMK3.lua:909-912`:

  ```lua
  local QLINK_PAGE_GROUPS = {
      [0] = { { 12, 8, 4, 0 }, { 13, 9, 5, 1 } }, -- MPC pages 1+2
      [1] = { { 14, 10, 6, 2 }, { 15, 11, 7, 3 } }, -- MPC pages 3+4
  }
  ```

- `LaunchpadProMK3.lua:915-918` — slot-to-column correspondence confirmed against a live screen:
  "An unassigned slot keeps its column as a dark gap **exactly where the MPC screen shows it**
  (device-verified: the user's page 1 reads **unmapped, High, Mid, Low**)" — i.e. page 1's first
  displayed slot = index 12, then 8, 4, 0.
- `LaunchpadProMK3.lua:796-798, 897-899` — API "bank" = `floor(i/4)` (4 banks of 4: 0-3, 4-7, 8-11,
  12-15), colour-coded. Note: an MPC **screen page** (`{12,8,4,0}`) cuts across all four API banks.

### 1.4 Device-verified LPMK3 script: `LaunchpadMiniMK3.lua` (user's other controller)

- `LaunchpadMiniMK3.lua:933-941` — identical `QLINK_PAGE_GROUPS` and identical "device-verified on the
  Pro build" comment, including the same "unmapped, High, Mid, Low" page-1 reading.
- `LaunchpadMiniMK3.lua:929-931` — same `floor(i/4)+1` bank colouring.
- Same order verified twice on the same MPC firmware ⇒ the page groups are a property of the MPC's
  Q-Link screen, not of one controller script.

### 1.5 MPC 3.1.0 kit content: plugin `Q-Links.json` skins (Akai-authored, independent of our scripts)

- `Akai/Content/Synths/Akai Professional - MPC - LP Shelving Filter/Plugin Skins/Q-Links.json` —
  slots are labelled **"Q-Link 1" … "Q-Link 16"** (linear, 1-based ⇒ index = label−1) and the layout
  metadata reads **`"Bank Direction": "Column"`** — MPC Q-Link banks advance in the **column**
  direction of the screen grid.
- Same file binds the plugin's params to labels 5, 9, 13 (indices 4, 8, 12); Distortion Fuzz binds
  2, 5, 6, 9, 10, 13, 14 (indices 1, 4, 5, 8, 9, 12, 13); Tremolo binds 5, 9, 13. The assigned sets
  (4, 8, 12 / 1, 4, 5, 8, 9, 12, 13) are exactly the **screen page-1 column {0,4,8,12}** and
  **page-2 column {1,5,9,13}** of §2 — matching the LPP3 note "the Kill EQ page lives at 0,4,8,12"
  (the LP Shelving Filter *is* that EQ), with the highest index reading first (top) on screen.

### 1.6 Community reference: `references/mpc_tools/controllers/APC Mini mk2/apcMiniMk2.lua`

- No Q-Link usage at all (no `qlink`/`knob`/`encoder` matches). It maps the 8 faders to track volume
  and the grid to the clip matrix (`apcMiniMk2.lua:3-20`) — **no evidence either way**; it does not
  contradict anything.

### 1.7 Current XL3 script: `LaunchControlXL3.lua`

- `LaunchControlXL3.lua:93` — `QLINK_ORDER = { 12, 8, 4, 0, 13, 9, 5, 1, 14, 10, 6, 2, 15, 11, 7, 3 }`
  (failed attempt 2), consumed by `qlinkIndexOfKnob(row, col) = QLINK_ORDER[row * 8 + col + 1]`
  (`:95-97`), i.e. the array is indexed by 0-based knob number, row-major.
- Driver paths using it: `handleControlEncoder` (`:2038-2053`), `handleEncoderAbs` (`:2091-2098`),
  `paintControlEncoders` (`:1774-1792`), `mapQlinks` native routing (`:1368-1427`, currently OFF),
  screen labels `"Q-Link " .. (i + 1)` (`:2052`) — the Akai linear labelling.
- Driver itself is device-proven (dot-form Twist, `:1309-1350`); the user's complaints were about
  **which slot** each knob hits, not about motion — the driver is orthogonal to this fix.
- `docs/MAPPING.md:66-72` and `CHANGELOG.md:36-41` record attempt 2's rationale (it copied the LPP3
  *page-group listing order* onto the knob rows).

### 1.8 Docs sweep

- `docs/RECOMMENDATIONS.md:266` — "MPC has 16 Q-Links and the XL 3 has exactly 16 upper encoders — no
  [banking]" ⇒ one static table must cover all 16; the MPK-style 8-per-bank paging is unnecessary here.
- `mpc-launchpad-pro-mk3/docs/MAPPING.md:169-177` — repeats the column-major/page-group evidence.
- `mpc-launchpad-pro-mk3/tests/test-qlink.lua:49-71` — pins page 1 = columns 1-4 = 12,8,4,0 / page 2
  first slot = 14, as executable regression tests.
- `Akai/SME0/Resources/ACVS/layout/MainQLinks.json` — the desktop Q-Link panel is a 265×265 **square**
  (a 4×4 knob grid) but carries no slot order; no other doc in the repos states the slot order.

---

## 2. Reconciled MPC 3.10.1 Q-Link screen geometry

Three facts must hold simultaneously:

1. **Page groups (device-verified, LPP3+LPMK3):** page 1 = {12,8,4,0} top-to-bottom, page 2 =
   {13,9,5,1}, page 3 = {14,10,6,2}, page 4 = {15,11,7,3}; pages sit side by side in numeric order.
2. **"column-major" + Akai "Bank Direction": "Column":** the pages/banks are the **columns** of a
   4-wide × 4-tall grid; reading the screen column-major (down col 1, down col 2, …) yields exactly
   the page groups above.
3. **MPK official formula:** top knob row → {4,5,6,7}, bottom knob row → {0,1,2,3}, columns preserved.

These give one geometry. Screen position of API index `i`:
**column** = `i % 4` (left→right), **row from top** = `3 − (i // 4)` (bank 0 sits at the BOTTOM row;
within a column the index descends by 4 going down, so the screen reads the newest-assigned slot
first — matching the LPP3 note).

```
MPC 3.10.1 Q-Link screen (4 columns × 4 rows; each column = an MPC "page/bank")

              page 1   page 2   page 3   page 4
row 1 (top)   i=12     i=13     i=14     i=15      (labels Q-Link 13 14 15 16)
row 2         i= 8     i= 9     i=10     i=11      (labels Q-Link  9 10 11 12)
row 3         i= 4     i= 5     i= 6     i= 7      (labels Q-Link  5  6  7  8)
row 4 (bot)   i= 0     i= 1     i= 2     i= 3      (labels Q-Link  1  2  3  4)

read column-major (page 1 top→bottom, then page 2 …) = 12,8,4,0 / 13,9,5,1 / 14,10,6,2 / 15,11,7,3
read row-major   (top-left → bottom-right)           = 12,13,14,15 / 8,9,10,11 / 4,5,6,7 / 0,1,2,3
```

**Reconciling the MPK formula with the page groups — the arithmetic:**
the MPK's 2×4 knob field covers the screen's **bottom-left 2×4 region**, copying it as-is:
top knob row = screen row 3 = {4,5,6,7} ✓, bottom knob row = screen row 4 = {0,1,2,3} ✓, and page-1
column read top-to-bottom = {12,8,4,0} with 4 and 0 in the MPK's rows ✓. The MPK formula's
"vertical flip" (`row + rowOffset`) is not an extra twist — it is precisely "the API stores the grid
bottom-up (bank 0 at the bottom row) while physical knobs are described top-down". Generalised, the
invariant is: *top physical row = upper screen slots; within a screen row indices run left-to-right;
the screen's row stack is inverted relative to linear index order.* The XL3 table in §5 is this same
mirror with the full 4×4 screen folded 2:1 onto 2×8.

**Falsification check — why pages are columns, not rows:** if pages were the screen's ROWS (screen
row-major = 12,8,4,0 / 13,9,5,1 / 14,10,6,2 / 15,11,7,3), then (a) attempt 2 would have been the
exact screen mirror and would have passed acceptance — it failed with all 16 slots assigned; (b) the
MPK formula would map its rows to screen *columns* 3 and 4 rotated 90°, which is geometric nonsense
for an official mirror; (c) "column-major" in two device-verified scripts and `"Bank Direction":
"Column"` in Akai's own skins would both be misdescriptions. All three argue against rows-as-pages.

---

## 3. Candidate arrangements for the XL3 2×8 field

| # | Arrangement | Table (knobs 1-8 / 9-16) | Verdict |
|---|---|---|---|
| 1 | **Linear row-major** (attempt 1) | `{0..7}` / `{8..15}` | Rejected by user data: row 1 "dead", row 2 hit. Right order on screen would require row 1 = 8-15 (labels 9-16) |
| 2 | **LPP3 page-listing order** (attempt 2, current) | `{12,8,4,0,13,9,5,1}` / `{14,10,6,2,15,11,7,3}` | This is the pages-as-screen-ROWS mirror — falsified by the device failure and inconsistent with the MPK geometry. Knob 1 happens to land right (12 = screen top-left); knob 2 lands one screen ROW down instead of one column right — "wrong coordinates" |
| 3 | **Screen mirror, 2:1 vertical fold** (recommended) | `{12,13,14,15,8,9,10,11}` / `{4,5,6,7,0,1,2,3}` | Knob row 1 = screen rows 1-2, knob row 2 = screen rows 3-4; column-wise it reproduces the LPP3 page groups exactly (page 1 top-to-bottom = knobs 1,5,9,13) |
| 4 | MPK per-group flip continued (row 1 = {4,5,6,7,12,13,14,15}, row 2 = {0,1,2,3,8,9,10,11}) | — | Rejected: treats the MPK's 2-row parity flip as a per-8-group rule; on the screen this interleaves screen row 3 with row 1 within one knob row — no coherent screen reading |
| 5 | Column-pair mirror (row 1 = {12,8,13,9,14,10,15,11}, row 2 = {4,0,5,1,6,2,7,3}) | — | Geometrically possible (each 2×2 knob block = one screen column) but has no Akai precedent, contradicts the MPK precedent (rows map to screen rows), and would put knob row 1 on two different screen rows — rejected |

Why #3 over #5 (both are valid 1:1 mirrors of the column geometry): the only authoritative sample of
how Akai maps a 2-row physical knob grid onto this screen — the MPK formula — maps **rows to screen
rows** and preserves left-to-right. #3 generalises exactly that (each knob row = two screen rows,
upper half above lower half); #5 invents a pairing no official script uses. #3 also matches the
MPK's bank paging halves: knob row 2 = labels "Q-Links 1-8", knob row 1 = "Q-Links 9-16" — the exact
two halves Akai pages between (`mpkMiniMkIV.lua:408`).

---

## 4. Both user data points, explained by the recommendation

**Geometry recap:** screen top half (rows 1-2) = indices 8-15 = labels **Q-Link 9-16**; screen bottom
half = indices 0-7 = labels **Q-Link 1-8**.

**Data point 1 — LINEAR build (`{0..15}`):** user: *"only qlink 9-16 are mapped on the track"*; row-2
knobs (linear → indices 8-15) hit their assignments, row-1 knobs (indices 0-7) appeared dead.
Under the geometry: the slots labelled 9-16 **are the screen's top half**. The user assigned the top
half of the Q-Link screen (what they see first / what reads "9-16"), i.e. exactly indices 8-15.
Linear row 2 = 8-15 → hit ✓; linear row 1 = 0-7 = the bottom half → unassigned → dead ✓.
Note the inversion that this data point itself forces: the *upper* half of the screen holds the
*high* indices (8-15). Any geometry in which labels 9-16 sit in the screen's bottom half (a naive
linear screen) would predict the opposite failure (row 1 alive, row 2 dead) — so data point 1
independently confirms the bottom-up API ↔ top-down screen stack.

**Data point 2 — attempt 2 (`{12,8,4,0,13,9,5,1,14,10,6,2,15,11,7,3}`), all 16 slots assigned:**
user: *"still no luck … you are using the wrong coordinates … especially the qlink order"*; knobs
land on the wrong slots relative to the screen. Under the geometry, attempt 2 sends knob 2 to index
8 = screen row 2 column 1 (directly BELOW knob 1's slot) instead of screen row 1 column 2 (to its
RIGHT); only 4 of 16 knobs (1, 6, 11, 16) coincidentally match the correct table. Every knob moves a
real parameter (driver proven), but the knob↔slot map is a transposed reading of the screen —
exactly "wrong coordinates / wrong qlink order".

**What the user's screen shows for each knob under the recommendation:**

```
XL3 knob grid          MPC screen slot it lands on (label)
row 1:  k1  k2  k3  k4  k5  k6  k7  k8        k1 → Q-Link 13 (screen row1 col1)
 [12][13][14][15][ 8][ 9][10][11]             k4 → Q-Link 16 (screen row1 col4)
row 2:  k9 k10 k11 k12 k13 k14 k15 k16        k5 → Q-Link  9 (screen row2 col1)
 [ 4][ 5][ 6][ 7][ 0][ 1][ 2][ 3]             k8 → Q-Link 12 (screen row2 col4)
                                              k9 → Q-Link  5 (screen row3 col1)
                                              k13 → Q-Link  1 (screen row4 col1)
                                              k16 → Q-Link  4 (screen row4 col4)
```

Each MPC page-column read top-to-bottom = one knob column position across the two rows: page 1 =
knobs 1, 5, 9, 13 (i.e. knob column 1 of row 1, then knob column 5 of row 1, then column 1 / 5 of
row 2) — verified to equal {12,8,4,0} exactly (script check in §5). The user turning the top-left
knob sees the screen's top-left slot move; the fold is 2:1 down the screen.

---

## 5. Deliverable — paste-ready

In `LaunchControlXL3.lua` (replace line 93; `qlinkIndexOfKnob`'s row-major indexing stays as-is):

```lua
-- Q-Link knob order: the MPC 3.x Q-Link screen is a 4x4 grid whose COLUMNS are the four
-- Q-Link banks/pages (Akai plugin skins: "Bank Direction": "Column"; LPP3/LPMK3
-- device-verified page groups 12,8,4,0 / 13,9,5,1 / 14,10,6,2 / 15,11,7,3 top-to-bottom
-- per column), with the API's bank 0 in the BOTTOM screen row. The XL3 mirrors the
-- screen folded 2:1: knob row 1 = screen rows 1-2 (Q-Links 9-16), knob row 2 = screen
-- rows 3-4 (Q-Links 1-8), left-to-right throughout. Formula: for 0-based knob p,
-- qlinkIndex = (3 - p//4)*4 + p%4.
local QLINK_ORDER = { 12, 13, 14, 15, 8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3 }
```

One-line formula (1-based knob number `k`, row-major — drop-in for `qlinkIndexOfKnob`):

```lua
local function qlinkIndexOfKnob(row, col)
	local p = row * 8 + col
	return (3 - (p // 4)) * 4 + (p % 4) -- screen mirror: row = upper half first
end
```

**Verification arithmetic (all checked by script during this investigation):**

- `[(3 - (p//4))*4 + p%4 for p in 0..15]` = `{12,13,14,15,8,9,10,11,4,5,6,7,0,1,2,3}` ✓
- knob row 1 == screen rows 1+2 concatenated ✓; knob row 2 == screen rows 3+4 ✓
- knob columns (c+1, c+9) per screen column: page 1 top-to-bottom {12,8,4,0} = knobs 1,5,9,13 ✓;
  page 2 {13,9,5,1} = knobs 2,6,10,14 ✓; page 3 {14,10,6,2} = knobs 3,7,11,15 ✓; page 4 {15,11,7,3}
  = knobs 4,8,12,16 ✓ — i.e. the table reproduces the LPP3 device-verified page groups column-wise.
- MPK formula (`mpkMiniMkIV.lua:247-257`) = the same mirror restricted to the screen's bottom-left
  2×4 ✓.
- Data point 1: user-assigned set (labels 9-16 = indices 8-15) ⊆ recommended row 1 ✓ (all of row 1
  ∈ 8-15), row 2 ⊆ 0-7 ✓ — same assignment, knobs now sit on the screen half they control.
- Data point 2: attempt-2 table differs from the recommendation on 12 of 16 knobs ✓ (failure
  expected under the column geometry).

---

## 6. Residual risks

1. **Screen pixel layout inferred, not photographed.** "Pages = screen columns" rests on: the
   device-verified LPP3/LPMK3 comment's own wording ("column-major", pages listed in column order),
   Akai's plugin-skin metadata (`"Bank Direction": "Column"`), the MPK formula's coherence (only the
   column geometry makes the official mapping a clean screen mirror), and the falsification of the
   rows-as-pages reading by data point 2. Confidence is high (four independent lines), but the
   definitive check is one knob: **turn XL3 knob 1 (top-left)** — the MPC's Q-Link screen should move
   its **top-left** slot (Q-Link 13). If the screen instead listed pages as rows, attempt 2 would
   already have been correct, so this risk is largely self-excluded by the recorded failure.
2. **"Q-Link 9-16" wording in data point 1.** Read as Akai slot labels (linear, per
   `mpkMiniMkIV.lua:598` and the plugin skins) the story is exact; if the user instead meant "the 8
   slots I assigned visually", the geometry makes both readings the same set (screen top half) — no
   divergence.
3. **Driver untouched.** The Twist/abs-delta plumbing, acceleration, and native-routing probes are
   orthogonal and device-proven; only `QLINK_ORDER` (or `qlinkIndexOfKnob`) needs to change. Row 1's
   abs-delta path on fw 1.1.11 remains a separate, already-documented concern
   (`docs/MAPPING.md:55-58`).

**One-knob hardware confirmation test (for the next device session):** assign a known parameter to
the MPC screen's top-left Q-Link slot, turn XL3 knob 1 — that parameter must move; turn knob 13
(bottom-left) — the screen's bottom-left slot (Q-Link 1) must move.
