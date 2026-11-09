# Satchel

All your bags in one window, for WoW Forever.

- One grid for the backpack and every equipped bag
- Works like the default bags: click, right-click to use, drag, shift-click to split, tooltips
- Quality borders, quest item markers, cooldowns, item lock state
- New-item glow, cleared when you hover the item
- Search by item name
- Sort button
- Item counts on tooltips across all your characters (bags, bank, equipped)
- View any character's bags or bank from anywhere: click the name in the title bar; the coin button opens the bank (a saved copy when you're away from a banker). Saved views have a blue tint and are read-only
- Sell junk button at vendors, coin marker on grey items
- Item level on gear, a "BoE" label on unbound bind-on-equip items, and a green arrow on gear that's an upgrade over what you're wearing
- Hover your gold to see every character's gold and the total
- Alt-click an item to protect it: Sell junk skips it and right-click won't sell it at a vendor
- Key button to show or hide the keyring
- Bank window for your character bank tabs (opens at the banker; closing it ends the bank visit)
- Free slot count and gold
- Opens with the normal bag keys and buttons; Escape or the X closes it

## Commands

```
/satchel               toggle bags
/satchel cols <4-36>   items per row in the bags (default 10)
/satchel bankcols <n>  items per row in the bank (default 14)
/satchel scale <x>     window scale, 0.5-2
/satchel reset         move the windows back to their default spots
/satchel ilvl | boe | upgrades | junk | counts | keys
                       toggle item level, BoE label, upgrade arrows, junk coin,
                       tooltip counts, keyring
/satchel forget <name> drop a deleted character's saved bags
/satchel errors [clear]
```

## Development

```sh
scripts/deploy.sh     # copy into the Forever AddOns folder, then /reload in game
scripts/debuglog.sh   # read SavedVariables: logged errors and the client API probe
```

Errors and blocked-action (taint) warnings are recorded in `SatchelDB.debug`
and written to disk on `/reload` or logout.

## Releasing

Push a `v*` tag. GitHub Actions runs the BigWigs packager, which attaches the
zip and a `release.json` to a GitHub release, so addon managers can pick the
build for each game client.
