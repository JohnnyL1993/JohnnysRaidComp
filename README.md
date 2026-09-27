# Johnny's Raid Comp

A World of Warcraft 3.3.5a addon for the Warmane private server. It gives you ideal-comp templates for each raid and size, matches them against your live roster, and supports manual slot assignments, class-run tank/healer picks, and GearScore and blacklist lookups. It also includes a Raid Spammer, a two-channel LFM chat timer.

## Install

1. Go to [Releases](https://github.com/JohnnyL1993/JohnnysRaidComp/releases) and download **`JohnnysRaidComp-vX.Y.zip`** from the latest release.
   Don't use GitHub's green **Code → Download ZIP** button or the "Source code" zips. Those unpack as `JohnnysRaidComp-main` or `JohnnysRaidComp-1.2`, and WoW won't load an addon whose folder name doesn't match.
2. Extract it into `World of Warcraft\Interface\AddOns\`. You should end up with `Interface\AddOns\JohnnysRaidComp\JohnnysRaidComp.toc`.
3. Restart WoW, or log out to the character screen, and make sure the addon is enabled.

## Updating

When someone you share the hidden `JohnnysAddons` channel, guild, party or raid with runs a newer version, a gold **"Update available"** line appears in the top-left corner of the Raid Comp window (plus one chat message). Click it for a copyable link back to this page. Download the new release zip, delete the old `JohnnysRaidComp` folder, and extract the new one in its place.

`/jrc version` shows your installed version and the newest version you've seen.

## Slash commands

| Command | What it does |
| --- | --- |
| `/jrc` or `/raidcomp` | Open the Raid Comp window |
| `/jrc lfm` | Open the Raid Spammer |
| `/jrc settings` | Window scale and opacity |
| `/jrc ach` | Toggle achievement lines in tooltips |
| `/jrc launcher` | Choose a launcher style (minimap button or panel) |
| `/jrc minimap` / `hub` / `none` | Switch the launcher style directly |
| `/jrc version` | Show installed and latest seen version |

## Other Johnny's addons

None of these are required. Raid Comp works on its own, and it calculates GearScore itself (same numbers as GearScoreLite). The ones marked **★** add extra features to Raid Comp when installed.

| Addon | What it does |
| --- | --- |
| [Johnny's Warmane Addon Hub](https://github.com/JohnnyL1993/JohnnysAddonHub) ★ | Always-on-screen launcher bar with a button for each of Johnny's addons you have installed. Replaces Raid Comp's own minimap button/panel. |
| [Johnny's Blacklist](https://github.com/JohnnyL1993/JohnnysBlackList) ★ | Blacklist players, auto-ignore their whispers, and get warned when you see them. Raid Comp flags blacklisted raid members. |
| [Johnny's Gear Advisor](https://github.com/JohnnyL1993/JohnnysGearAdvisor) ★ | Shows upgrade candidates for your gear based on class, spec and hit/expertise. Raid Comp uses it for spec detection and PvP gear detection. |
| [Johnny's Raid Browser](https://github.com/JohnnyL1993/JohnnysRaidBrowser) ★ | Window listing advertised raids with role/GS filters and one-click whisper/join. Needs the RaidBrowser addon. Adds a Raid Comp launcher button. |
| [Johnny's Raid Roll](https://github.com/JohnnyL1993/JohnnysRaidRoll) ★ | Flat-skinned windows for the RaidRoll addon's rolls, loot tracker and settings. Needs RaidRoll. Adds Raid Comp launcher buttons. |
| [Johnny's Messenger](https://github.com/JohnnyL1993/JohnnysMessenger) | Teams-style whisper messenger with a conversation list and threads. |
| [Johnny's Currency Tracker](https://github.com/JohnnyL1993/JohnnysCurrencyBar) | Draggable bar tracking Honor, Arena Points, Stone Keeper's Shards, Wintergrasp marks and Emblems. |

## Releasing (maintainer notes)

1. Bump `## Version:` in `JohnnysRaidComp.toc`.
2. Commit, then `git tag vX.Y` and `git push && git push --tags`.
3. The **Release** GitHub Action builds `JohnnysRaidComp-vX.Y.zip` and attaches it to the release.
