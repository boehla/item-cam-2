# Item Cam 2
> **This is a fork (branch `py-2.1`)** of [Item Cam 2](https://mods.factorio.com/mod/item-cam-2) by HermanyAI: ported to Factorio 2.1, follows fluids and a few more things. See `changelog.txt` 0.11.0 and 0.12.0.

Follow an item around your base like in the Factorio trailer. Spiritual successor to [DaveMcW's Item Cam](https://mods.factorio.com/mod/itemcam), rewritten for 2.0 and Space Age content support.

The default hotkey is `Alt + C`, also comes with shortcut "Follow item" in hotbar. When pressed, you select what you want to start follow. If it's supported, almost all GUI elements get hidden and your journey begins.

Pressing same hotkey, or `/stop-item-cam` in chat if you're truly stuck, will stop following your item.

## Bug reporting
The mod is not exhaustively tested. **Guaranteed not to work well in multiplayer**.

If mod errors out while you're following something or it doesn't continue as you're expecting it to:
- Save just before you start following
- Enable `Debug focus tracker` in mod settings and try reproduce your issue
- Once you do, exit game, no need to save
- Post the before save and `factorio-current.log`

`Debug focus tracker` has tick-precise information on the focus tracker's behavior and will make debugging way easier.

## Things it can follow right now
- Belts, splitters, undergrounds, any and all sideload configurations, modded loaders, linked belts, lane splitters
- Inserters, chests, train cargo wagons, logistic bots picking up and delivering items
- Mining drills, assemblers, furnaces (recyclers), etc. with ability to follow specific item out of multiple results
- Space Age: Plants and how they grow, rockets and their cargo pods, space platform hubs and their cargo pods
- *Fork:* crafted fluids, including recipes with only fluid output. A fluid takes the shortest route through pipes, tanks and pumps (pumps only forward) to the next crafter using it, a rail station pump or a consumer; cam glides along at setting "Fluid speed". At a station it rides along in the fluid wagon and continues from the pump that empties it. The pipe network is highlighted with dashed, round-capped lines in the fluid's color ("Highlight fluid networks"), since the game's own pipeline visualization can't be enabled by script
- *Fork:* construction robots carrying the item to a ghost (cam rests on the new building), robots leaving a roboport, Pyanodons digosaurs
- *Fork:* setting "Skip ahead when stuck" (jump to the frontmost same item on a full belt), setting "Recipes with multiple outputs"

## Limitations
- You can't watch the cargo pod processions. It may be possible but was not visited yet
- Focus tracker doesn't know about when item spoils in container. Not yet
- Fluids (fork): only fluids that come out of a crafter are followed; the route is computed, since fluids in 2.0+ have no travel time. Fluids from offshore pumps or mining aren't a starting point

## Things that are planned to be trackable:
- Non-SA satellite's Space science pack output
