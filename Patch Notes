
### Display Elements Explained:
- **Item Name** - The name of the tracked item
- **(+/-)** - Recent increment/decrement (shows for 5 seconds)
- **Number** - Total drops counted (not shown for usable/ammo)
- **[Number]** - Current inventory count across all bags

## Item Categories

### 🟢 Item Drops (White)
- Items dropped by defeated enemies
- Shows both drop count and inventory count
- Format: `ItemName (±change)DropCount[Inventory]`

### 🟣 Usable Items (Magenta)
- Food items (type 7)
- Items with "use" flags (medicines, tools)
- Shows only inventory count
- Format: `ItemName (±change)[Inventory]`

### 🟡 Equipped Ammo (Yellow)
- Currently equipped stackable ammunition
- Automatically detected and updated
- Shows only inventory count
- Format: `AmmoName (±change)[Inventory]`

### ⚪ Personal Drops (White)
- Items from "Obtained:" messages
- Treasure chests, quests, NPCs
- Shows both obtained count and inventory
- Format: `ItemName (±change)ObtainedCount[Inventory]`

### 💰 Gil (White)
- Total gil obtained during session
- Shows cumulative total
- Format: `Gil: (±change)Total`

### 🔵 Key Items (Blue)
- Special key items obtained
- No inventory count (key items don't stack)
- Format: `KeyItemName`

## Auto-Add Behavior

Each category has its own auto-add setting:

- **Drops** (Default: OFF) - Automatically track items dropped from enemies
- **Usable** (Default: ON) - Automatically categorize usable items
- **Personal** (Default: ON) - Automatically track "Obtained:" items
- **Gil** (Default: ON) - Always tracks gil when obtained

## Special Features

### Ammo Tracking
- Automatically detects equipped ammo
- Only tracks stackable ammo (stack > 1)
- Updates when changing equipment or jobs
- Cannot be manually added or removed

### Inventory Monitoring
- Checks all storage locations:
  - Inventory, Safe, Storage, Locker
  - Satchel, Sack, Case, Wardrobes 1-8
- Updates every second
- Shows decreases with red highlighting

### Name Handling
- Accepts both short and full item names
- Example: "100 Byne Bill" or "One Hundred Byne Bill"
- Automatically normalizes capitalization

### Data Persistence
- Settings saved to: `Windower/addons/Counter/data/settings.lua`
- Preserves tracked items between sessions
- Auto-add preferences remembered
- Item sets saved permanently

## Tips & Tricks

1. **Quick Setup**: Use `//cnt auto all on` to track everything automatically
2. **Clean Display**: Use category-specific clear commands to remove unwanted items
3. **Farming Sessions**: Create sets for different farming locations with `//cnt addset`
4. **Inventory Management**: Red numbers show when items are being used/sold
5. **Window Position**: Click and drag the display to your preferred location

## Troubleshooting

- **Items not tracking**: Check if auto-add is enabled for that category
- **Wrong category**: Some items may need manual adding to correct category
- **Display not updating**: Try `//cnt show` to refresh the display
- **Ammo not showing**: Ensure ammo is equipped and stackable

## Version History

### v1.1.0 (2025)
- Added automatic equipped ammo tracking
- Improved usable item detection with stricter criteria
- Fixed draggable window functionality
- Enhanced item categorization
- Added increment/decrement indicators
- Improved inventory monitoring across all bags

### v1.0.0 (Initial Release)
- Basic item tracking functionality
- Multiple category support
- Auto-add features
- Set management

## Author

Created by **wisdomcheese4**  
Version 1.1.0  
For FFXI Windower

## License

This addon is provided as-is for use with FFXI Windower. Feel free to modify and distribute.

---

*Note: This addon tracks items during your current session. Drop counts reset when you reload the addon or restart the game, but tracked item lists are preserved.*
