# Satchel

All your bags in one window, for WoW Forever.

- One grid for the backpack and every equipped bag
- Works like the default bags: click, right-click to use, drag, shift-click to split, tooltips
- Quality borders, quest item markers, cooldowns, item lock state
- Search by item name
- Free slot count and gold
- Opens with the normal bag keys and buttons; Escape or the X closes it

## Commands

```
/satchel               toggle bags
/satchel cols <4-36>   items per row (default 10)
/satchel scale <x>     window scale, 0.5-2
/satchel reset         move the window back to the default spot
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
