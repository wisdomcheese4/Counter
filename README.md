# Counter v1.1.0 - FFXI Windower Addon

A comprehensive item tracking addon for Final Fantasy XI that monitors drops, inventory, and various item categories with real-time updates and visual feedback.

## Overview

Counter is a powerful tracking tool that automatically categorizes and monitors items you obtain in FFXI. It provides a customizable on-screen display showing drop counts, inventory totals, and recent changes across multiple item categories.

## Features

### 🎯 Automatic Item Categorization
- **Item Drops** - Tracks items dropped from enemies with cumulative counts
- **Usable Items** - Auto-detects food, medicines, and tools (magenta color)
- **Equipped Ammo** - Automatically tracks currently equipped stackable ammo (yellow color)
- **Personal Drops** - Items obtained from chests, quests, and NPCs
- **Gil** - Tracks total gil obtained during your session
- **Key Items** - Monitors key items obtained (blue color)

### 📊 Real-Time Display
- **Draggable Window** - Click and drag to position anywhere on screen
- **Color-Coded Categories** - Different colors for different item types
- **Dynamic Updates** - Shows recent changes with (+) and (-) indicators
- **Green Highlights** - Recently obtained items flash green for 5 seconds
- **Red Highlights** - Items that decreased show red for 5 seconds
- **Alphabetical Sorting** - All items sorted alphabetically within categories

### 🔧 Advanced Features
- **Auto-Add Options** - Toggle automatic tracking for each category
- **Inventory Monitoring** - Shows current inventory count for all items
- **Item Sets** - Save and load custom tracking lists
- **Name Normalization** - Handles both short and full item names
- **Multi-Character Support** - Tracks drops per character

## Installation

1. Download the `Counter.lua` file
2. Place it in your Windower addons folder: `Windower/addons/Counter/`
3. Load in-game with: `//lua load counter`
4. Or add to your init.txt: `lua load counter`

## Commands

All commands can use either `//counter` or `//cnt` prefix.

### Basic Commands
| Command | Description |
|---------|-------------|
| `//counter help` | Display all available commands |
| `//counter show` | Show the display window |
| `//counter hide` | Hide the display window |
| `//counter list` | List all tracked items in chat |

### Item Management
| Command | Description |
|---------|-------------|
| `//counter add <item>` | Add item to tracking (auto-categorized) |
| `//counter remove <item>` | Remove item from tracking |
| `//counter clear` | Clear all tracking lists |
| `//counter reset` | Reset all counters to 0 |
| `//counter reset <item>` | Reset specific item counter to 0 |

### Auto-Add Settings
| Command | Description |
|---------|-------------|
| `//counter auto` | Show auto-add status for all categories |
| `//counter auto drop on/off` | Toggle auto-add for enemy drops |
| `//counter auto usable on/off` | Toggle auto-add for usable items |
| `//counter auto personal on/off` | Toggle auto-add for personal drops |
| `//counter auto gil on/off` | Toggle auto-add for gil |
| `//counter auto all on/off` | Toggle all auto-add settings |

### Category-Specific Commands

#### Gil Commands
| Command | Description |
|---------|-------------|
| `//counter gil` | Show total gil obtained |
| `//counter gil reset` | Reset gil counter to 0 |
| `//counter gil clear` | Clear gil tracking |

#### Drops Commands
| Command | Description |
|---------|-------------|
| `//counter drop` | Show dropped items list |
| `//counter drop list` | List all dropped items in chat |
| `//counter drop reset` | Reset all drop counters to 0 |
| `//counter drop clear` | Clear dropped items list |

#### Usable Items Commands
| Command | Description |
|---------|-------------|
| `//counter use` | Show usable items list |
| `//counter use list` | List all usable items in chat |
| `//counter use clear` | Clear usable items list |

#### Personal Drops Commands
| Command | Description |
|---------|-------------|
| `//counter personal` | Show personal drops list |
| `//counter personal list` | List all personal drops in chat |
| `//counter personal reset` | Reset personal drop counters to 0 |
| `//counter personal clear` | Clear personal drops list |

#### Ammo Commands
| Command | Description |
|---------|-------------|
| `//counter ammo` | Show currently equipped ammo info |

#### Key Items Commands
| Command | Description |
|---------|-------------|
| `//counter key` | Show key items list |
| `//counter key list` | List all key items in chat |
| `//counter key clear` | Clear key items list |

### Set Management
| Command | Description |
|---------|-------------|
| `//counter addset <name>` | Save current drop list as a set |
| `//counter set <name>` | Load a saved set |
| `//counter listsets` | List all saved sets |
| `//counter deleteset <name>` | Delete a saved set |

### Debug Commands
| Command | Description |
|---------|-------------|
| `//counter debug` | Toggle debug mode for obtain messages |
| `//counter debugall` | Show ALL chat messages (very spammy!) |
| `//counter test <item>` | Manually increment a tracked item |
| `//counter testpersonal <item>` | Test adding a personal drop |
| `//counter testgil <amount>` | Test adding gil |

## Display Format

The on-screen display shows information in this format:

Item Counter ───────────────────── Tracking: YourName Auto-add: Drop: OFF Usable: ON Personal: ON Gil: ON ───────────────────── Usable Items: Hi-Potion (+5)[120] Remedy [45] ───────────────────── Equipped Ammo: Shuriken (-10)[990] ───────────────────── Item Drops: Beehive Chip (+1)15[23] Silk Thread 8[156] ───────────────────── Personal Drops: Crystal: Fire (+1)3[45] Scroll of Cure 1[2] ───────────────────── Gil: (+100)2,450 ───────────────────── Key Items: Airship Pass

Code

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
