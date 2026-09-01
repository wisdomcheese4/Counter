# Counter

A [Windower 4](https://www.windower.net/) addon for Final Fantasy XI that automatically tracks item drops, personal drops, gil, usable items, equipped ammo, and key items — with a clickable on-screen display.

## Installation

1. Copy the `Counter` folder into `Windower4/addons/`.
2. In-game, load it with:
   ```
   //lua load counter
   ```
3. To have it load automatically every time you start Windower, add `lua load counter` to your `init.txt`.

Both `//counter` and `//cnt` work as the command prefix throughout — they're interchangeable.

## What it tracks

| Category | How it's added | Notes |
|---|---|---|
| **Item Drops** | Auto-detected from "Obtained:" / "\_\_\_ obtains" messages, or added manually | The main drop counter |
| **Personal Drops** | Auto-detected (Treasure Pool, Steal, quest items) | Separate from Item Drops so quest/personal items don't mix with farming targets |
| **Usable Items** | Auto-detected (potions, ethers, etc.) | Shows inventory count only, no lifetime counter |
| **Equipped Ammo** | Auto-detected from your equipped ammo slot | Not manually removable — it just tracks whatever's equipped |
| **Key Items** | Auto-detected | Name only, no count |
| **Gil** | Auto-detected from gil gains and Mug | Shown once you've received any |

Everything is on by default except Item Drops, which starts off (`//counter auto drop on` to enable, or just `//counter add <item>` to track something specific regardless).

## The on-screen display

- **Drag** the title bar ("Item Counter:") to reposition the whole panel. Its position is remembered across `//lua reload`.
- **Left-click** a toggle row (Auto-add categories, Quiet) to flip it on/off instantly.
- **Left-click** an item row (or Session) to open a small menu — Reset Count, Remove, Set as Focus, etc.
- **Right-click** an item row to remove it from tracking instantly, skipping the menu.
- Rows briefly turn green when something increments, and the amount (`+2`, `-1`, etc.) shows next to the count for a few seconds.
- `//counter show` / `//counter hide` toggles the whole panel; hiding it is remembered across reloads too.

## Commands

### Tracking
```
//counter add <item name>              Add an item to tracking (auto-categorized)
//counter add ItemA, ItemB, ItemC      Add several items at once
//counter remove <item name>           Remove an item from tracking
//counter list                         List all tracked items in chat
//counter clear                        Clear all tracking lists
//counter reset                        Reset all counters to 0
//counter reset <item name>            Reset one item's counter to 0
```

### Auto-add toggles
```
//counter auto                         Show status for all categories
//counter auto drop on/off
//counter auto usable on/off
//counter auto gil on/off
//counter auto personal on/off
//counter auto all on/off
```

### Per-category management
```
//counter gil                          Show gil total
//counter gil reset / clear
//counter use                          Show usable items
//counter use clear / list
//counter ammo                         Show equipped ammo
//counter drop                         Show Item Drops
//counter drop reset / clear / list
//counter personal                     Show Personal Drops
//counter personal reset / clear / list
//counter key                          Show key items
//counter key clear / list
```

### Sets
Sets save your current Item Drops, Personal Drops, and Usable Items together as a named preset — handy for swapping between farming spots.
```
//counter addset <name>                Save current tracking as a set
//counter set <name>                   Load a set
//counter listsets                     List all saved sets
//counter deleteset <name>             Delete a saved set
```
Loading a set **replaces** your Item Drops list, but **merges** Personal Drops/Usable Items in without wiping unrelated items already being tracked.

### Session, Focus, and Quiet mode
```
//counter session reset                Start a new session clock (lifetime totals unaffected)
//counter focus <item name>            Pin an item at the top of the display
//counter unfocus                      Clear the focused item
//counter quiet                        Toggle quiet mode (suppresses automatic drop chat spam)
```
The focused item also gets a distinct gold chat alert (`*** FOCUS ITEM: X (+1)! ***`) whenever it drops, even in quiet mode.

### Display
```
//counter show                         Show the display window
//counter hide                         Hide the display window
//counter export                       Write a summary to a text file in the addon's data folder
```

### Debugging
```
//counter debug                        Toggle debug mode for obtain messages
//counter debugall                     Show ALL incoming chat messages (very spammy - use briefly)
//counter test <item name>             Manually simulate a drop
//counter testpersonal <item name>     Manually simulate a personal drop
//counter testgil <amount>             Manually simulate a gil gain
```
If something isn't being detected correctly, `//counter debugall` is the fastest way to see the exact raw text the game sent so the detection pattern can be corrected.

## Settings & data files

Settings are stored per-character at `Windower4/addons/Counter/data/settings-<charactername>.lua`, so alts and mules don't share drop counts. If you're updating from an older version that used a single shared file, it migrates automatically the first time you load in on each character.

`//counter export` writes to `Windower4/addons/Counter/data/export-<charactername>.txt`.

## Known limitations

- **Detection is text-based.** Drops, steals, mugs, and gil gains are recognized by matching patterns in your chat log, not by reading game packets directly. This is generally reliable, but any of these could theoretically misfire if a private server phrases a message unusually, or (rarely) if someone types a coincidentally matching sentence in party/say chat.
- **No kill-based drop-rate.** An earlier version of this addon tracked kills and showed a drop-rate percentage per item, but a single global kill counter can't meaningfully represent "how often does X drop" unless every kill in the session was the same mob — it was removed for being more misleading than useful.
- **Decrement detection is inventory-based**, not event-based: if a tracked item's count goes down between refreshes (used, sold, traded away), the display shows a red `(-n)`, but the addon can't tell *why* the count dropped.
