# Verification, "no original assets" guard, risks

Applies to every stage. Overview: `README.md`.

## 7.1 Golden-master checks (behaviour must not move)

The stages 2-4 are refactors of where data lives. The proof that nothing moved is a set of **local** snapshots taken from
the *pre-refactor* engine (commit before the stage starts) and compared after each migration step:

| snapshot | content | tool |
|---|---|---|
| `types` | every unit / building record serialised (sorted), per race: build list, production, requirements, overrides | `--dump-content` equivalent from the old `gamedata` / `rules` (a throwaway `tools/dev/snapshot.lua` run at the baseline commit) |
| `power-ups` | per code: cost, time, picture index, `bonus(side, code)` for each of the 6 stats on a fixed army set, `level / has` over a scripted purchase sequence | same |
| `spells` | per spell and success level: effect on a fixed world (3.6) | `tools/spelltest.lua` |
| `heroes` | stats of level 1..60 heroes for each race x class, spell chance table, skill descriptions | `tools/herotest.lua` |
| `sims` | `--selftest --sim <map>` summary lines (end time, kills, resources) for all 115 maps, and `world:hash()` at 30 s / 60 s / 120 s | existing `simtest` extended to print hashes |
| `saves` | a save written by the baseline engine loads in the new one (and vice versa while versions are equal) | `--sim saveload` |

Snapshots live in `<userdata>/golden/<commit>/` and are **never committed** (they are derived from the install, see 7.2).
A script `tools/dev/golden.ps1 -Baseline <commit>` builds a worktree at the baseline, writes the snapshots, then compares
against the working tree and prints a diff per snapshot; a non-empty diff is a stop sign for the migration step. The
checks run in minutes (`sims` dominates); the quick set (`types`, `power-ups`, `heroes`, `sim Bridges`) runs in seconds
and is the pre-commit habit of the stages.

## 7.2 The "no original assets in the repository" guard

Requirement: **the repository must never contain a copy of the original game's assets** (art, sound, video, text, data
files, tables copied from the original). Three layers:

1. **Static guard (works in CI, needs no install)** - `tools/dev/guard.lua`, run by `--selftest` and by a pre-commit
   script:
   - refuses tracked files with the extensions of original assets (`.xcr .ani .rle .bmp .arm .bui .ter .fea .scn .wav
     .bik .ai .uai .cfg .xci .xcg .nam .act .amb .loc .dat ...`) outside an allow-list (`docs/**/*.png` screenshots
     of the *docs* must be reviewed by hand; the allow-list names them one by one);
   - refuses `.lua` files larger than 256 KB or with long runs of numeric literals (a data-dump heuristic) outside
     `game/content/base/` and the allow-list;
   - refuses 4-letter unit / building / power-up code literals (`"(A|B|P)[A-Z0-9]{3}"`) outside `game/content/base/`,
     `game/src/import/wbc3/` and test fixtures, **after** stages 2-4 have moved them there (before then, the check
     runs in report-only mode with a ratchet: the count may only go down);
   - refuses text literals that look like game text: any string literal over 40 characters in
     `game/content/` and the engine that is not a comment (strings belong in `lang/` files authored by the project).
2. **Local content guard (needs the install)** - `tools/dev/guard-install.lua`: reads the install's text files, sprite
   names and archive entry names, builds a set of hashes of normalised lines (>= 20 characters) and of entry names,
   and scans the working tree (tracked and untracked, excluding `game/converted/`, `shots/`, `dump/` and other ignored
   folders) for matches. Only hashes are computed at run time; **no list of original text is ever stored in the
   repo**, so the guard itself cannot leak. Run before every commit that touches `game/content`, `docs` or fixtures.
3. **Process rules** (added to `CLAUDE.md` when stage 1 lands):
   - `game/content/base/` holds engine-authored data: ids, numbers verified against the original (with their origin
     comment, as today), formulas, logic. Never display names, descriptions, help text, bitmaps, sound names that are
     not ids, or tables copied from the original. Names are string references (5.2).
   - Mod examples in `docs/modding/examples/` are generated / authored art only (the sprite generator draws simple
     shapes); the guard checks them too.
   - `--dump-content` output and golden snapshots go to the user data directory and are gitignored; the dump carries a header
     "derived from your local install; do not redistribute".

Open question D1 (README): numeric tables extracted from the binary stay in `game/content/base/` as numbers only. If the
position is ever challenged the fallback is runtime extraction; the facade design (`content` kinds filled by an
importer or by a base layer) makes that a change of the `base` layer's source, not of the engine.

## 7.3 Unit and integration tests added per stage

| stage | tests |
|---|---|
| 1 | merge / operator / removal / hash / dump / phase guards (`contenttest`) |
| 2 | importer equals golden `types`; every race loop works with a synthetic 17th race (`contenttest` creates a race and a unit in memory, runs one `--sim`-style skirmish headless); `rules.buildList` facade parity |
| 3 | `spelltest` golden hashes; a synthetic mod sphere; status hook ordering |
| 4 | `herotest`; synthetic class / skill; ability buttons for a patched unit; victory condition added by a mod ends a simulated game |
| 5 | resolver order, `override/`, PNG sprite from generated test sheets, placeholder on missing assets, no `love.graphics` in headless |
| 6 | example mods load; journal rollback; save round trip with mod ids; `nettest` mismatch refusal |

Add the new checks to `selftest.M.extra`; update the "Minimum after a code change" section of `CLAUDE.md` and the
`selftest` skill with `--content-report` and the golden script.

## 7.4 Risk register

| risk | effect | mitigation |
|---|---|---|
| Behaviour drift during data moves | parity with the original lost without anyone noticing | golden masters (7.1) after **every** step; the stages move data only; spell ports are one sphere per commit |
| Performance regression in hot paths | `unit.lua` / `economy.lua` run per tick per unit | records stay plain tables, tags become `tagSet` booleans in `finalise`, no metatables in release; measure `--sim all` time before / after |
| Mod determinism | multiplayer desync | sandbox without RNG / clock, content hash in lobby and checksum, ordered iteration helpers, review of `pairs` in effect code |
| Slots and ids drifting | scenarios, saves and hero profiles change meaning when mods change | persisted slot allocation (`slots.lua`), refusal policy in 6.5 / 6.6, ids in saves rather than positions |
| 16-race and 4-resource assumptions deeper than found | crashes with a 17th race | the synthetic-race test in stage 2 runs every screen's headless code path; `grep` list of `0, 15` / `0, 5` loops tracked as a checklist item |
| Spell closures hide state in locals | port not identical | export helpers verbatim first (3.7 step 1), recipe only where the golden hash matches |
| Importers become slow | start-up time | measure; units / buildings are small (~480 records, ms), strings lazily, sprites lazily; an optional binary cache in the user dir keyed by install file mtimes (gitignored) |
| Original text leaking via string literals in base data | legal | string-reference rule (5.2) + guard (7.2) + review checklist |
| Mod API churn | broken mods | `api` version + one-version compat shim (6.9); the registry API is the only stable promise early on |
| Scope growth (campaigns, UI, new attributes, new resources) | never finishing | each is listed as out of scope (README 6) with the stage where it plugs in; revisit only after stage 6 acceptance |

## 7.5 Definition of done (whole plan)

1. A modder can, with plain Lua files and no engine edit, add / remove / patch races, units, buildings, power-ups,
   items, spells, status effects, missiles, hero classes and skills, abilities, victory conditions, sites, AI profiles,
   sprites, sounds, icons and text (stages 1-5), enable them in a screen and use them in skirmish, saves and
   multiplayer (stage 6).
2. With **no mods enabled**, openwbc3 plays exactly as before the plan (golden masters equal).
3. `grep` for 4-letter code literals finds only the base layer, the importers and fixtures; the guard passes.
4. The repository contains no original assets (7.2), `docs/modding/` documents every kind, and the examples run in the
   selftest.
