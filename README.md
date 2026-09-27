# Johnny's Raid Comp

A World of Warcraft 3.3.5a addon for the Warmane private server. It gives you ideal-comp templates for each raid and size, matches them against your live roster, and supports manual slot assignments, class-run tank/healer picks, and GearScore and blacklist lookups. It also includes a Raid Spammer, a two-channel LFM chat timer.

## Install

1. Go to [Releases](https://github.com/JohnnyL1993/JohnnysRaidComp/releases) and download **`JohnnysRaidComp-vX.Y.zip`** from the latest release.
   Don't use GitHub's green **Code → Download ZIP** button or the "Source code" zips. Those unpack as `JohnnysRaidComp-main` or `JohnnysRaidComp-1.2`, and WoW won't load an addon whose folder name doesn't match.
2. Extract it into `World of Warcraft\Interface\AddOns\`. You should end up with `Interface\AddOns\JohnnysRaidComp\JohnnysRaidComp.toc`.
3. Restart WoW, or log out to the character screen, and make sure the addon is enabled.

## Updating

When someone you share the hidden `JohnnysAddons` channel, guild, party or raid with runs a newer version, a small banner appears in game with a link back to this page. Download the new release zip, delete the old `JohnnysRaidComp` folder, and extract the new one in its place.

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

## Optional companions

None are required - GearScore is calculated by the addon itself (same numbers as GearScoreLite). Johnny's Addon Hub, Gear Advisor, Blacklist, Raid Browser and Raid Roll each add extra features when installed.

## Releasing (maintainer notes)

1. Bump `## Version:` in `JohnnysRaidComp.toc`.
2. Commit, then `git tag vX.Y` and `git push && git push --tags`.
3. The **Release** GitHub Action builds `JohnnysRaidComp-vX.Y.zip` and attaches it to the release.
