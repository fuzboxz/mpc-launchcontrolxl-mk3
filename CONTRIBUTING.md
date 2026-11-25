# Contributing

## Where the facts come from

| Claim family | Source | Confidence |
|---|---|---|
| MPC Lua script API, loader, signing | the sibling `mpc-launchpad-pro-mk3` project's API contract, built from `open-mpc/mpc-controllers` findings and device-verified on 3.10.0.49 / 3.10.1.8 | high (device-verified) |
| XL 3 DAW-mode wire format | Novation *Launch Control XL 3 programmer's reference guide* v1.0 (PDF) | high (vendor doc) |
| XL 3 element map, palette indices, display pacing | Ableton Live 12.3 `Launch_Control_XL_3` remote script (decompiled; `elements.py`, `colors.py`, `display.py`, `midi.py`) | high (vendor implementation) |
| Host-side conventions (blink channel, 16-char lines, sysex dedupe) | same Ableton script, plus the community SPEC in `yutsdxg/launch-control-xl3` | medium — listed for Phase-0 verification |
| MPC-side unverified items (ch-16 CC delivery, `AddInfiniteCCToQLink` signature) | inference | **must be probed before relying on them** |

Reference material lives in `references/` and is **gitignored**: drop the two Novation
PDFs and any decompiled scripts there, never commit them.

```sh
mkdir -p references
curl -o references/launch_control_xl_3_programmer_s_reference_guide.pdf \
  'https://fael-downloads-prod.focusrite.com/customer/prod/downloads/launch_control_xl_3_programmer_s_reference_guide-pdf_en.pdf'
curl -o references/launch_control_xl_3_user_guide.pdf \
  'https://fael-downloads-prod.focusrite.com/customer/prod/downloads/launch_control_xl_3_user_guide_v1_en.pdf'
```

## Workflow

1. `./tests/run-tests.sh` must pass before every commit (syntax, ini gate, manual
   freshness, docs gate, mock suite, minified-artifact suite).
2. Enable the git hooks once per clone: `git config core.hooksPath .githooks`.
3. Documentation is part of the change, not a follow-up. `docs/MANUAL.md` is generated
   from the `ACTIONS` table; `docs/MAPPING.md` is the behaviour reference and
   `docs/LIMITATIONS.md` the walls. `tools/check-docs.sh` (run by the suite) fails the
   build when the manual is stale, when the Q-Link knob order in the script is not
   quoted in `MAPPING.md`, or when a `__LCXL3_*` flag / `QFEEL` field is undocumented.
   See [Documentation is part of the change](#documentation-is-part-of-the-change).
4. Any new optional MPC API call must be pcall-guarded and log its absence exactly
   once (`H.logOnce`). Degrade, never break.
5. Device-verified facts get a `docs/DEVICE-TEST-PLAN.md` entry and a line in
   `docs/REVIEW.md`; unverified guesses get a Phase-0 probe item instead.

## Documentation is part of the change

A behaviour change that leaves the docs behind is an incomplete change — the v1.1.0
Q-Link knob order shipped wrong for two releases because `docs/MAPPING.md` was never
re-checked against `QLINK_ORDER`. Update these in the **same commit**:

| You changed | You must update |
|---|---|
| the `ACTIONS` table, a control label, a mode/page description | `docs/MANUAL.md` (regenerate: `tools/gen-manual.sh`) — the suite fails if it is stale |
| what any control does, a knob order, an LED or screen meaning, a call sequence | `docs/MAPPING.md` |
| a new device wall, unprobed API, or unverified claim | `docs/LIMITATIONS.md` (+ `docs/API-CONTRACT.md` if it is an API fact) |
| a new `__LCXL3_*` flag or `__LCXL3_QFEEL` field | `docs/MAPPING.md` "Tunables and flags" — `tools/check-docs.sh` fails otherwise |
| user-visible behaviour | `CHANGELOG.md`, in the section for the version being released |

Rules of thumb: a claim that was probed and **disproven** must be retired from the docs
in the same commit that changes the code (do not leave the old reading beside the new
one); anything still unverified must say so rather than assert a direction or a
signature. `tools/check-docs.sh` covers the mechanical part (manual freshness, the
Q-Link order rows, documented flags) — the rest is a review responsibility.

## Signing

`checksum = sha256(lua_bytes || 36-char salt)`. The salt lives XOR-obfuscated in the
MPC binary; `tools/sign_script.py` reads it from **your own** binary at run time
(`MPC_BIN=... ./script/build.sh`) or takes `MPC_SALT` directly. Never commit the salt,
never commit Akai binaries. `tools/verify_salt.py` / `tools/test-sign.sh` re-validate
the rule against Akai's shipped `mpkMiniMkIV` pairs when `XZT_DIR` points at your
extracted kit.

## Lua host limits

The MPC Lua host is Lua 5.4 and a chunk may hold at most **200 active locals**.
This script sits at the ceiling: adding one more top-level `local` makes
`luac5.4 -p` fail with "too many local variables" (the suite and the build both
stop at that gate). Mitigations already in use: state that would otherwise be
a local is kept on a `__LCXL3_*` global (e.g. `__LCXL3_IMMEDIATE`,
`__LCXL3_QDIRTY`, `__LCXL3_SWING`, `__LCXL3_SCRETRIES`), and bulk top-level
loop code is wrapped in a builder function (`buildSurfaceCC`) so the for-loop
locals live in a function scope. When adding features, prefer table fields on
existing tables or globals over new top-level locals.

## Conventions

- Lua 5.4, tabs, 100-col soft wrap; `selene` with `std = "lua53+mpc"` (`mpc.yml`
  whitelists the `mpc` and `LaunchControlXL3` globals).
- The device table must stay named `LaunchControlXL3` (it must match the file name).
- MIDI channels in code are 0-based (MPC convention); in docs they are 1-based
  (Novation convention). The constants at the top of the script carry both.
- Every control the dispatch tables handle gets an `ACTIONS` entry; every LED colour
  comes from the `PAL` palette table.
