 Counter Addon for Windower

**Version:** 1.0 
**Author:** wisdomcheese4  
**Last Updated:** 2025-06-06

## Overview

Counter is a comprehensive item tracking addon for Final Fantasy XI that monitors and counts item drops, personal drops (from chests/NPCs), and gil obtained during gameplay. It features persistent storage, customizable tracking lists, and a clean visual display with color-coded notifications.

## Features

- **Three Tracking Categories:**
  - **Item Drops** - Enemy drops that you manually track
  - **Personal Drops** - Items obtained from chests, NPCs, or quest rewards (auto-tracked)
  - **Gil** - Automatically tracks gil obtained
  
- **Visual Display Window:**
  - Draggable on-screen counter display
  - Green highlighting for recently obtained items (5 seconds)
  - Auto-adjusting column width for clean formatting
  - Color-coded auto-add status indicators

- **Persistent Storage:**
  - All counts saved between sessions
  - Customizable item sets for different activities
  - Backward compatible with older versions

## Installation

1. Download the `Counter.lua` file
2. Place it in your Windower addons folder: `Windower/addons/Counter/`
3. Load the addon in-game with: `//lua load counter`
4. Add to autoload by editing `Windower/scripts/init.txt` and adding: `lua load counter`

## Commands

All commands can use either `//counter` or `//cnt` prefix.

### Basic Item Management

| Command | Description |
|---------|-------------|
| `//cnt add <item name>` | Add an item to manual tracking list |
| `//cnt remove <item name>` | Remove an item from tracking |
| `//cnt list` | Display all tracked items in chat |
| `//cnt clear` | Clear ALL lists (drops, personal, gil) |
| `//cnt reset` | Reset ALL counters to 0 |
| `//cnt reset <item name>` | Reset a specific item's count to 0 |

### Category-Specific Commands

#### Item Drops (Manual Tracking)
| Command | Description |
|---------|-------------|
| `//cnt drop` | Show all tracked drops in chat |
| `//cnt drop list` | List all tracked drops with counts |
| `//cnt drop reset` | Reset all drop counts to 0 |
| `//cnt drop clear` | Clear the entire drop list |

#### Personal Drops (Auto-Tracked from "Obtained:" messages)
| Command | Description |
|---------|-------------|
| `//cnt personal` | Show all personal drops in chat |
| `//cnt personal list` | List all personal drops with counts |
| `//cnt personal reset` | Reset all personal drop counts to 0 |
| `//cnt personal clear` | Clear the entire personal drops list |

#### Gil Tracking
| Command | Description |
|---------|-------------|
| `//cnt gil` | Show total gil obtained |
| `//cnt gil reset` | Reset gil counter to 0 |
| `//cnt gil clear` | Clear gil counter (same as reset) |

### Auto-Add Settings

Control automatic tracking for each category:

| Command | Description |
|---------|-------------|
| `//cnt auto` | Show auto-add status for all categories |
| `//cnt auto drop on/off` | Toggle auto-add for enemy drops |
| `//cnt auto personal on/off` | Toggle auto-add for personal drops |
| `//cnt auto gil on/off` | Toggle auto-add for gil |
| `//cnt auto all on/off` | Toggle all categories at once |

### Set Management

Save and load custom tracking lists:

| Command | Description |
|---------|-------------|
| `//cnt addset <name>` | Save current drop list as a named set |
| `//cnt set <name>` | Load a saved set |
| `//cnt listsets` | List all saved sets |
| `//cnt deleteset <name>` | Delete a saved set |

### Display Controls

| Command | Description |
|---------|-------------|
| `//cnt show` | Show the counter display window |
| `//cnt hide` | Hide the counter display window |

### Debug Commands

| Command | Description |
|---------|-------------|
| `//cnt debug` | Toggle debug mode for obtained items |
| `//cnt debugall` | Show ALL chat messages (very spammy!) |
| `//cnt test <item>` | Manually increment a tracked item |
| `//cnt testpersonal <item>` | Manually add a personal drop |
| `//cnt testgil <amount>` | Manually add gil |

### Help

| Command | Description |
|---------|-------------|
| `//cnt help` | Show all available commands |

## Usage Examples

### Basic Tracking Setup
