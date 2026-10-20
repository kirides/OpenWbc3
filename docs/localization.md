# Localisation

How the original selects a language and what openwbc3 needs to support arbitrary
localisation with runtime selection, without breaking save games. Behaviour is read
from the original game binary and from the files the GOG install ships.

## The original: two independent axes

The original sets the language once at startup, before any of the data is read. There is
no in-session switch. Two values follow from the chosen language:

1. **A language folder** (`"English\"`, `"German\"`, `"French\"` …) — holds the localised
   text files and the per-language `.xcr` archives.
2. **A two-letter abbreviation** (`en`, `fr`, `ge`, `sp`, `it`, `ko`, `ta`, `ru`, `po`,
   `ja`) — used as a *file suffix* on asset catalogues and as the voice-archive suffix.

The original knows ten languages, in the fixed order the table below gives. Detection
probes `<Lang>/Credits.xml` for each folder and takes the first that exists, so the
install decides the language.

| # | name | folder | abbrev |
|---|------|--------|--------|
| 0 | English | `English` | `en` |
| 1 | French | `French` | `fr` |
| 2 | German | `German` | `ge` |
| 3 | Spanish | `Spanish` | `sp` |
| 4 | Italian | `Italian` | `it` |
| 5 | Korean | `Korean` | `ko` |
| 6 | Taiwanese | `Taiwanese` | `ta` |
| 7 | Polish | `Polish` | `po` |
| 8 | Russian | `Russian` | `ru` |
| 9 | Japanese | `Japanese` | `ja` |

## Which paths each axis drives

| axis | what uses it | files |
|------|----------------|-------|
| `<Lang>/` folder | localised text files and per-language archives | `XCIStrings.txt`, `Font.ini`, `Help.cfg`, `Game.txt`, `Spells.txt`, `Quest.cfg`, `Names.cfg`, `KeyMap.txt`, `Items.xcr`, `Mercenaries.xcr`, `Campaign.xcr`, `GameSpeech.xcr`, `GText.xcr` … |
| `<abbrev>` suffix | asset catalogues globbed as `Assets\Terrain\*.%s`, `Assets\Features\*.%s`, `Assets\Particles\*.%s` | `Caverns.en` / `Caverns.ge` XML catalogues |
| `Voices<En\|Ge>` | the hero's voice archives, globbed as `Assets\Sides\%s%s.xcr` | `BarbariansVoicesEn.xcr`, `…VoicesGe.xcr` |

The GOG install here has only `English` and `German` folders; `Assets/Terrain`,
`Assets/Features` and `Assets/Particles` carry `.en` / `.ge` variants, and `Assets/Sides`
carries `…VoicesEn.xcr` / `…VoicesGe.xcr`.

## What openwbc3 already has

- `core/config.lua` carries `M.language` (default `"English"`), set from `[game] language=`
  in `openwbc3.ini` or `--lang`.
- `vfs/vfs.lua` `init(root, lang)` mounts `<L>/…` archives and registers "localized" ones
  under a bare name so lookups are language-agnostic.
- `game/strings.lua` and `ui/fonts.lua` fall back to `English/` per file.
- `game/boot.lua` passes `config.language` into `vfs.init` and `interface.init`.

So the *folder* axis is mostly wired. The gaps are below.

## What is missing / wrong

1. **The abbreviation is hardcoded to en/ge in four places** and silently falls back to
   English for every other language:
   - `game/src/audio/voices.lua:16` — `config.language:lower():sub(1, 2) == "ge" and "Ge" or "En"`
   - `game/src/game/herocustom.lua:48`, `game/src/screens/herocustomize.lua:62` (same)
   - `game/src/game/editorlib.lua:37` — `({ english = "en", german = "ge" })[...] or "en"`
   These need a single first-class `config.abbrev` derived from the language (the 10-entry
   table above), not a two-case hack.

2. **No fallback for the `<Lang>/` archives or loose `<Lang>/` files** in `vfs.init` (only
   `DialogData.xcr` falls back), and `ui/xci.lua` `loadStrings` warns-but-returns-empty
   rather than falling back to English. `game/campaign.lua`, `game/campaigndata.lua`,
   `game/conversation.lua`, `screens/credits.lua`, `screens/tip.lua`,
   `screens/screenhelp.lua`, `game/scenarioinfo.lua`, `game/spells.lua` read `<Lang>/…`
   directly with no English fallback. Pick a language whose folder is absent and these break.

3. **No install detection.** The original picks the language from which folders exist;
   openwbc3 always defaults to English. Should mirror the `Credits.xml` probe.

4. **Hardcoded English strings the original reads from `<Lang>/`:**
   - `game/classes.lua` `M.RACE_NAMES` (header says they come from
     `<Lang>/WBC3HeroSelectionText.txt` but they are literal)
   - `game/quests.lua` `local NAMES = { "Aldric", … }`
   - `game/herocustom.lua` `M.VOICES` (the comment already notes "other languages offer a
     shorter list in the original" - the original switches the list on the language)

5. **`Assets/Particles` and `Assets/Features` language variants are not read at all** (only
   `Assets/Terrain` via `editorlib.tileCatalog`, and that only handles en/ge).

## Save-game safety (why it won't break)

Saves store **resolved display names and 4-letter codes**, never the language:

- `game/savegame.lua` `unitRecord` / `buildingRecord` keep `name`, `code`, `attitude` (a
  key like `"standard"`, not a display string).
- `game/campaignstate.lua` keeps journal text as captured.
- `World:hash()` (`game/world.lua`) mixes ids / coords / hp / resources only, so
  determinism is unaffected.

Consequences:

- A save made in German loads fine under English — it shows the German names captured at
  save time. This matches the original, whose save header stores the already-localised
  scenario name.
- Hero records (`game/profile.lua`) store `voice` / `avatar` / `portrait` as **numbers**;
  `voiceSpec` resolves the `En|Ge` archive from the *current* language at runtime, so a
  hero stays valid across a language change.
- Therefore "without breaking save games" = **do not store the language in saves**; keep
  names as captured. Recording the language in the save header for display consistency is
  optional and not required.

## Recommended plan (minimal, faithful)

1. Add a language table in `core/config.lua`: name → `{ folder, abbrev }` for the ten
   originals, plus `config.abbrev` and a `detect()` that probes `<Lang>/Credits.xml`. Keep it
   *arbitrary*: if a folder name isn't in the table, derive
   `abbrev = folder:lower():sub(1, 2)` so a hand-added `Portuguese/` folder still works.
2. Replace the four `== "ge"` / `{english = …}` hacks with `config.abbrev` (capitalised
   form for the voice archives, lowercase for the `*.en` / `*.ge` globs).
3. Make `vfs.init` and the `<Lang>/` readers fall back to `English/` when a requested
   file/archive is missing (one helper, used by `ui/xci.lua`, `game/campaign*.lua`,
   `screens/credits.lua`, `screens/tip.lua`, `screens/screenhelp.lua`,
   `game/scenarioinfo.lua`, `game/spells.lua`).
4. Move the hardcoded `RACE_NAMES`, quest `NAMES`, and `VOICES` lists to read
   `<Lang>/WBC3HeroSelectionText.txt` / `Names.cfg` with English fallback.
5. On "runtime selection": the original never changes language mid-game, so startup
   selection (`--lang` / ini) is faithful and already works. If in-session switching is
   wanted, the caches to invalidate are `strings.files`, `vfs.archives` / `byKey`, the
   `xci` text, `fonts.defs`, `anims.sets`, `voices.variants`, `editorlib.catalog` — i.e.
   re-run `vfs.init` + `interface.init` and clear those.

After changing this, run `pwsh tools/dev/love.ps1 -- --selftest --lua …` with `--lang German`
and `--sim saveload` to confirm the fallbacks and that a German save round-trips.

## Progress

Items 1-4 are done; item 5 (hot-reload) is deliberately **not** done - the language is
selected at startup only, as the original does. What landed:

1. `core/config.lua`: `M.LANGUAGES` (the ten language names -> abbreviation),
   `M.abbrev`, `M.abbrevFor` (unknown folder -> first two letters), `M.voiceSuffix()`
   (`Voices<En|Ge>`, capitalised the way the original's archive names are built) and `M.detect()`
   probing `<Lang>/Credits.xml` in the original's order. `[game] language=` in `openwbc3.ini`
   and `--lang` still win over detection.
2. The four en/ge hacks (`voices.lua`, `herocustom.lua`, `herocustomize.lua`, `editorlib.lua`)
   now go through `config.abbrev` / `config.voiceSuffix()`.
3. `vfs.lua`: `mountLang(rel, localized)` for `GameSpeech`, `GText`, `Items`, `Mercenaries`,
   `Campaign` archives (English fallback), `M.langFile(rel)` for loose language files, and
   `DialogData.xcr` (which lives at the install root, not in the language folder) falls back
   to the root copy. `xci.lua` `loadStrings` falls back to `English/XCIStrings.txt`. The
   loose-file readers in `campaign*.lua`, `conversation.lua`, `credits.lua`, `tip.lua`,
   `screenhelp.lua`, `scenarioinfo.lua`, `spells.lua`, `quests.lua` and `strings.lua` all
   take `<Lang>/<file>` or `English/<file>`.
4. `classes.lua` reads the race names from `WBC3HeroSelectionText.txt` (lines 34..49, verified
   against the English and German copies in the install; the original itself shows them from
   the XCI texts `TXT_RACE` / `TXT_RACE2`, so the file is openwbc3's own choice of source and
   matches both). Loaded lazily through a proxy table, with `M.RACE_COUNT` for the callers that
   used `#RACE_NAMES`. `quests.lua` reads the `[NAME]` section of `NamingSets/Standard.nam`
   (the `.nam` files' `[RULES]` section decides between a plain name list and a syllable pair, and
   the original rolls a random name from the set while openwbc3 keeps its deterministic pick).
   `herocustom.lua` gained `M.VOICES_ALT` with the non-English voice lists and `M.voiceList(race)`.
5. `screens/options.lua` has a ninth Gameplay dropdown listing the languages the install has
   (same `Credits.xml` probe). It is labelled as openwbc3's own addition: it only writes the
   choice to `openwbc3.ini`, so the language applies on the next start - nothing already loaded
   this session is reloaded. Cancel restores the language the screen was opened with.
6. `screens/battle.lua` looks speech up by bare archive name (`GameSpeech.xcr`,
   `CampaignSpeech.xcr`), which `vfs.lua` mounts with an English fallback; the female system
   voice (`SystemF<n>.wav`, English only) falls back to the male file instead of keying on
   `lang == "English"`. `CampaignSpeech.xcr` is probed for before mounting - this GOG install
   does not ship it at all, only `GameSpeech.xcr` (plus the `Assets/Sides/<Pack>Voices<En|Ge>.xcr`
   sets).

Not done: in-session language switching (cache invalidation across `strings`, `vfs`, `xci`,
`fonts`, `anims`, `voices`, `editorlib`, `quests`, `spells`, `screenhelp`, `portraits`), and
`Assets/Particles` language variants are still not read at all (item 5 of "What is missing").

