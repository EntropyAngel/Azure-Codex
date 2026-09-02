# AzureCodex for HorizonXI

This version is adapted for **HorizonXI** and its 75-cap Blue Mage spell list.

## What was changed

- The spell database is filtered to **only the 107 BLU spells listed by the HorizonXI Wiki at level 75 or below**.
- The addon no longer assumes that every retail BLU spell in Ashita's resource files exists on HorizonXI.
- `ui.lua` now requires a spell to be present in `data/spells.json` before it can appear in the addon.
- The learned/known status still comes directly from Ashita's player spell data.
- The Zone Helper continues to use the existing monster/zone mappings for the retained spells.

## Usage

Place the `AzureCodex` folder in your Ashita v4 `addons` directory and load it normally.

Use:

```text
/azurecodex
/ac
```

to open or close the tracker.

## Important note about learning locations

The spell whitelist is HorizonXI-specific. The monster/zone source data in this conversion is retained from the original project for the spells that survived the filter. If you want, the next step can be to replace those monster/zone entries with a **fully HorizonXI-specific learning database** as well.

## Sources

- HorizonXI Blue Magic Spell List:
  https://horizonffxi.wiki/Blue_Magic_Spell_List
- HorizonXI Blue Magic:
  https://horizonffxi.wiki/Category:Blue_Magic

Original addon by atom0s / Ashita Development Team.

## HorizonXI location filtering

The learning-location database has also been filtered to Horizon-era zones.

The conversion excludes:
- Wings of the Goddess-era `[S]` source zones.
- Abyssea and later expansion zones.
- Adoulin / Escha / modern endgame zones.
- Other post-75-cap areas present in the original retail-oriented database.

The addon also contains a Lua-side Horizon zone whitelist, so the Zone Helper
will refuse to show a source from an excluded zone even if a future edit adds
one to `data/spells.json`.

This is intentionally conservative: if a spell has both an older valid source
and a later source, the older Horizon-era source is retained.

The HorizonXI wiki is still actively marked as under construction for parts of
Blue Magic, so this version uses the current Horizon spell/monster data where
available and avoids presenting later-expansion locations as valid learning
spots.

### Spells with no verified Horizon source

Four level-75-cap spells in the retained spell list currently have no
non-[S], non-modern source in the Horizon data we could verify:

- Corrosive Ooze
- Spiral Spin
- Asuran Claws
- Sub-Zero Smash

They remain in the spell list because they are present in the current
HorizonXI Blue Magic Spell List, but the addon intentionally does **not**
invent a monster or zone for them. Their Zone Helper source list will simply
be empty until a Horizon-verified source is available.


## Zone Helper recommendation

The Zone Helper now shows a **HorizonXI Recommended Source** for each spell. The recommendation prioritizes your current zone first, then common classic/leveling zones, while pushing Dynamis, Limbus, Sea/Sky, battlefields, and obvious endgame sources lower.

Because the local spell database contains monster names and zones but not reliable monster-level data, this is an accessibility heuristic rather than a claim that the selected monster is mathematically the lowest-level source. The full source list remains available underneath the recommendation.

## Learned-spell sound
AzureCodex can play a cheerful Kweh-style sound when Horizon confirms a Blue Magic spell was learned. The volume is adjustable in Settings. The bundled WAV is an original bird-like placeholder and is not audio extracted from a Final Fantasy game. If you own a preferred sound clip, convert it to WAV and replace that file while keeping the same filename.


## v1.3 HorizonXI verified learning sources

The recommendation and Zone Helper logic no longer falls back to the old
retail-oriented monster list.

AzureCodex now has a conservative HorizonXI monster allowlist built from the
current HorizonXI Wiki **Learned From** tables. Only those verified monster
names can appear in:

- Recommended Source
- Current-zone spell detection
- In-zone monster suggestions
- Other-zone source suggestions

If a spell has not yet been verified against the current HorizonXI Wiki,
AzureCodex displays **No HorizonXI-verified source stored yet** instead of
guessing from retail data.

This is deliberately conservative because HorizonXI's Blue Mage wiki pages
are still under active construction and some source lists include later-era
rows. The addon continues to reject later-era zone data and now additionally
requires the monster itself to be on the Horizon-verified allowlist.


## v1.3.1 Alert reliability fix

AzureCodex now uses two independent signals for Blue Magic alerts on HorizonXI:

- the incoming `0x28` battle-action packet, and
- the actual incoming battle-log text (`readies` / `uses`) as a Horizon fallback.

Learned-spell detection similarly keeps the `0x29` message packet and adds a
`You learn...` battle-log fallback. Duplicate suppression prevents the same
learn event from playing the popup / Kweh sound twice.


## v1.3.13
- Azure Sets now uses HorizonXI spell-name set-point costs instead of the retail id-based table for Horizon-era spells.
- Uses the game-reported maximum Blue Magic Points when available (including Assimilation), with Horizon level brackets as fallback.
- Affordability checks use the same corrected cost function for the list, counter, save, and apply validation.

## v1.3.14

- Deleting an Azure Sets saved set now also clears the set editor spell list, set name, selected slot, and spell search.
- Deleting a saved set does not unset the character's currently equipped Blue Magic spells.

## v1.3.15

- Azure Sets now verifies each BLU spell slot after the client accepts a change and retries missed changes up to three times.
- Set loading first clears only slots that differ, then sets the requested spells, reducing unnecessary client requests.
- A final reconciliation pass retries any slot that still does not match the saved set.
- The UI reports incomplete slots instead of claiming success when a change was dropped.
- No custom packet injection was added; the loader still uses the game's extended-equip function.


## v1.4

- Hardened incoming packet parsing to prevent native out-of-bounds reads.
- The variable-length 0x28 battle-action handler now validates every bit range before calling Ashita's native bit unpacker.
- Rejects impossible target/action counts and safely stops parsing truncated or malformed action packets.
- Added length validation to the 0x0A zone and 0x29 Blue Magic learn-message reads as well.
- No outgoing packet injection was added or changed.

## Credits

Special Thanks: **Tozura & KA Linkshell**
