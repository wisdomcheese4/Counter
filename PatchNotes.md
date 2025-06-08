# Counter Addon Patch Notes

# Counter v1.1.1 Patch Notes

**Release Date:** June 8, 2025  
**Author:** wisdomcheese4

## 🐛 Bug Fixes

### Fixed Steal Detection
- **Issue:** When stealing items from enemies, the addon was incorrectly capturing the monster name along with the item name (e.g., "Maneating Hornet (Pot of Honey)" instead of just "Pot of Honey")
- **Fix:** Improved pattern matching for steal messages to prioritize items in parentheses and better extract just the item name
- **Impact:** Stolen items now display correctly in the tracking list with only their item names

### Fixed Chat Message Color
- **Issue:** Counter messages in the chat log were displaying in purple instead of the intended orange color
- **Fix:** Corrected the color calculation to use the proper additive color method for FFXI chat system
- **New Color:** RGB(255, 128, 0) - Bright orange
- **Impact:** All Counter chat messages now display in a distinct bright orange color for better visibility

## 🔧 Technical Details

### Steal Pattern Matching Improvements
- Added priority detection for items in parentheses format: `(Item Name)`
- Improved fallback patterns to avoid capturing monster names
- Better handling of various steal message formats from different game mods

### Color System Update
- Changed from incorrect color code (209) to proper additive calculation
- Formula: `123 + (255 * 256³) + (128 * 256²) + (0 * 256)`
- Ensures consistent bright orange display across all FFXI configurations

## 📝 Version Summary
- **Previous Version:** 1.1.0
- **Current Version:** 1.1.1
- **Type:** Bug Fix Release
- **Compatibility:** No breaking changes, fully backward compatible with saved settings

## 💡 User Impact
- Steal functionality now works correctly with all stolen items
- Improved readability with proper orange coloring in chat
- No action required from users - fixes apply automatically upon update

---

*No new features were added in this release. This update focuses solely on fixing the steal detection and chat color issues reported by users.*

## Version 1.1.0 (2025-06-08)

### 🎯 Major Features

#### Automatic Equipped Ammo Tracking
- **NEW**: Ammo equipped in the ammo slot is now automatically tracked
- Detects and displays stackable ammunition (shuriken, bolts, arrows, etc.)
- Updates in real-time when changing equipment or jobs
- Ammo section appears between Usable Items and Item Drops
- Shows in yellow color with inventory count only
- Cannot be manually added/removed - fully automatic

#### Enhanced Item Categorization System
- **IMPROVED**: Stricter detection for usable items
  - Now properly identifies food items (type 7)
  - Better flag detection for consumable items
  - Added fallback detection for common medicines
- **FIXED**: Items incorrectly categorized as "usable" are automatically moved to regular tracking on load

### 🐛 Bug Fixes

#### Critical Fixes
- **FIXED**: "bad argument #1 to 'band'" error when checking item flags
  - Added proper handling for flags that may be stored as tables
  - Implemented type checking before bit operations
- **FIXED**: Display window dragging functionality restored
  - `display:draggable(true)` now properly called during updates

#### Display Fixes
- **FIXED**: Increment/decrement indicators now properly show before counts
- **FIXED**: Color timing for recently changed items
- **FIXED**: Proper cleanup of old drop time entries

### 📊 Display Improvements

#### New Visual Indicators
- **NEW**: (+X) green indicators for items that increased
- **NEW**: (-X) red indicators for items that decreased
- Both indicators appear for 5 seconds after changes
- Entire line turns red when items decrease

#### Layout Enhancements
- Section headers now clearly labeled:
  - "Equipped Ammo" for ammunition
  - Consistent separator lines between sections
- Improved column width calculations for better alignment
- Fixed number padding for consistent display

### 🔧 Technical Improvements

#### Performance Optimizations
- Inventory checking now includes ammo detection in the same pass
- Reduced redundant name mapping builds
- Optimized event listeners for equipment changes

#### Code Quality
- Added `check_equipped_ammo()` function for centralized ammo detection
- Improved error handling for resource lookups
- Better separation of concerns between categories

### 📝 Command Changes

#### Modified Commands
- `//counter ammo` - Now shows currently equipped ammo (no longer manages a list)
- `//counter add <item>` - Now prevents manual adding of ammo items

#### Removed Functionality
- Ammo can no longer be manually added to tracking
- Ammo category is not saved/loaded from settings file

### 🔄 Auto-Detection Changes

- Ammo tracking is always automatic based on equipped items
- Added event listeners for:
  - Status changes
  - Job changes
  - Regular inventory updates

### 💾 Data Persistence

- Ammo items are intentionally not saved to settings
- Other categories continue to save/load normally
- Backwards compatibility maintained for v1.0.x save files

### 🎨 Color Scheme Updates

- **Usable Items**: Magenta (255,0,255)
- **Ammo**: Yellow (255,255,0) - NEW
- **Key Items**: Blue (0,150,255)
- **Item Drops**: White (255,255,255)
- **Personal Drops**: White (255,255,255)
- **Recent Increases**: Green (0,255,0)
- **Recent Decreases**: Red (255,0,0)

### 📋 Known Issues Fixed

- Resolved issue where some items would incorrectly appear in usable category
- Fixed window position not being draggable after certain updates
- Corrected increment display positioning in number columns

### 🔮 Future Considerations

This update lays groundwork for potential future features:
- Category-specific auto-add settings are now properly isolated
- Improved item type detection can be extended to other categories
- Event system can be expanded for more real-time tracking

---

### Upgrade Notes

**For users upgrading from v1.0.x:**
1. Your saved settings will be automatically converted
2. Any incorrectly categorized "usable" items will be moved to regular tracking
3. Ammo tracking will begin automatically when you equip stackable ammo
4. No action required - just load the new version!

**Breaking Changes:**
- Manual ammo management commands removed
- Ammo category behavior completely changed to automatic

## Version 1.0.1 (2025-06-07)

### Bug Fixes

**Fixed: Count Alignment Issue**
- **Problem**: When increment indicators appeared (e.g., "+2"), the total count numbers would shift to the right, causing misalignment
- **Solution**: Implemented fixed-width formatting with reserved space for increment indicators
- **Result**: Count numbers now remain in consistent column positions regardless of increment display

**Fixed: Display Width Issues**
- **Problem**: Display window was unnecessarily wide, taking up too much screen space
- **Solution**: Optimized all spacing and padding throughout the display
- **Changes**:
  - Reduced column padding from +2 to +1
  - Changed divider lines from +10 to +8 width
  - Adjusted right section from 7+4 to 6+3 character spacing
  - Removed extra spacing from auto-add labels

### New Features

**Key Item Color Coding**
- **Feature**: Items starting with "Key Item:" now display in blue color
- **Behavior**: 
  - Shows green for first 5 seconds (like all new items)
  - Changes to blue instead of white after green period expires
  - Blue color persists indefinitely for easy identification
- **Color Value**: RGB(0,150,255) for clear visibility

### User Interface Improvements

**Optimized Display Layout**
- More compact design while maintaining readability
- Better use of horizontal space
- Consistent alignment across all sections
- Cleaner visual separation between categories

**Enhanced Visual Consistency**
- Improved alignment of ON/OFF indicators in auto-add section
- Better spacing between section headers and content
- More uniform padding throughout display elements

### Technical Improvements

**Code Optimization**
- Refactored display update function for better performance
- Improved color logic handling for different item states
- More efficient string formatting for display elements
- Better memory management for color timers

**Formatting Standardization**
- Consistent use of string.format for alignment
- Standardized spacing calculations
- Unified approach to column width handling

---

## Version 1.0.0 (2025-06-06)

### Initial Release Features

**Core Tracking System**
- Implemented three-category item tracking system:
  - **Item Drops**: Manual tracking for enemy drops with customizable item lists
  - **Personal Drops**: Automatic tracking for items obtained from chests, NPCs, and quest rewards
  - **Gil**: Automatic tracking for all gil gains
- Real-time detection of items using FFXI chat message parsing
- Separate counters for each category with independent management

**Visual Display**
- Created draggable on-screen display window with:
  - Clean, organized layout with category sections
  - Auto-adjusting column widths based on longest item name
  - Color-coded status indicators (green=ON, red=OFF)
  - Player name display showing who is being tracked
- Visual feedback features:
  - 5-second green highlight for recently obtained items
  - Increment indicators showing recent gains (e.g., "+2")
  - Automatic display refresh when items are obtained

**Auto-Add Functionality**
- Configurable automatic tracking for each category:
  - Item Drops: OFF by default (manual tracking preferred)
  - Personal Drops: ON by default (auto-tracks "Obtained:" messages)
  - Gil: ON by default (always tracks gil gains)
- Per-category toggle controls with visual status indicators

**Set Management**
- Save/load system for different farming configurations
- Ability to save current drop list as named sets
- Quick switching between different tracking setups
- Set deletion functionality

**Persistent Storage**
- All data saved to local file (data/settings.lua)
- Preserves counts between game sessions
- Backward compatibility with future versions
- Automatic loading on addon startup

**Command System**
- Comprehensive command structure with //counter and //cnt aliases
- Category-specific commands (drop, personal, gil)
- Individual item management (add, remove, reset)
- Bulk operations (clear all, reset all)

**Additional Features**
- Debug mode for troubleshooting item detection
- Test commands for manual incrementing
- Show/hide display functionality
- Extensive help system
