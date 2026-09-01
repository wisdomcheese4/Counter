_addon.name = 'Counter'
_addon.author = 'wisdomcheese4'
_addon.version = '1.1.1'
_addon.commands = {'counter', 'cnt'}

-- Import necessary libraries
local texts = require('texts')
local files = require('files')
local res = require('resources')

-- Initialize variables
local tracked_items = {}
local item_counts = {}
local saved_sets = {}
local debug_mode = false
local debug_all = false
local player_name = nil

-- Settings are stored per-character once we know who's logged in (falls
-- back to a shared file before that, or if the name can't be determined).
-- This is computed fresh each time rather than cached in a variable so it
-- automatically starts pointing at the right file the moment player_name
-- becomes known.
local function get_settings_filename()
    if player_name then
        return 'data/settings-' .. player_name:lower() .. '.lua'
    end
    return 'data/settings.lua'
end

-- Separate categories for items
local usable_items = {}
local ammo_items = {}
local key_items = {}
local personal_items = {}
local personal_counts = {}

-- Separate auto-add settings for each category
local auto_add_drop = false
local auto_add_personal = true  -- Personal drops are auto-tracked by default
local auto_add_gil = true  -- Gil is always auto-tracked
local auto_add_usable = true  -- Usable items are auto-tracked by default

-- Suppresses automatic drop/steal/mug/obtain chat announcements when true
-- (commands typed by the user still get their normal confirmation messages)
local quiet_mode = false

-- Remembered window position, so it survives a //lua reload
local window_x = nil
local window_y = nil

-- The currently "focused" item, pinned to the top of the display
local focus_item_name = nil
local focus_item_category = nil

-- Session tracking: a snapshot of lifetime counts taken when the session
-- was last (re)started, so per-item rows can show "this session/lifetime"
local session_start_time = os.time()
local session_gil = 0
local session_counts = {}            -- item_name -> lifetime count at session start
local session_personal_counts = {}   -- item_name -> lifetime count at session start

-- Color tracking for recently dropped items
local item_drop_times = {}  -- Tracks when each item was last obtained
local GREEN_DURATION = 5    -- Seconds to stay green
local RED_DURATION = 5      -- Seconds to stay red for decrements

-- Tables for personal drops
local personal_drop_times = {}
local usable_drop_times = {}
local ammo_drop_times = {}
local key_drop_times = {}

-- New table to track recent increments
local recent_increments = {}  -- Stores {amount = X, time = os.time()} for each item

-- Cache for inventory counts
local inventory_cache = {}
local last_inventory_check = 0
local INVENTORY_CHECK_INTERVAL = 1  -- Check inventory every 1 second

-- Track previous inventory counts for decrease detection
local previous_inventory_counts = {}

-- Create a mapping of full names to short names
local full_to_short_map = {}
local short_to_full_map = {}

-- Track last equipped ammo
local last_equipped_ammo = nil

-- Define bright orange color code for Counter messages
-- Using additive color method: start with base color 123, add RGB values
local COUNTER_COLOR = 123 + (255 * 256 * 256 * 256) + (128 * 256 * 256) + (0 * 256)

-- Forward declaration: update_display is defined further down, but the
-- drag callback registered in get_row() needs to call it, and Lua locals
-- are only visible to code that comes after their declaration.
local update_display

-- Forward declarations: remove_item and reset_item are defined further
-- down (they're used by //counter remove/reset), but the item context
-- menu built near update_display needs to call them too.
local remove_item
local reset_item

-- Forward declaration: save_settings is defined further down, but
-- save_window_position (used by the row-pool/drag code above it) needs
-- to call it whenever the window is moved.
local save_settings

-- Forward declaration: build_name_mappings also now builds a name->resource
-- cache (see below) that is_ammo_item/is_usable_item need, but it's
-- defined after them since it was originally a "mappings only" helper.
local build_name_mappings

-- Cache of item name (short or full/name_log) -> resource entry and id,
-- built once by build_name_mappings() instead of being re-scanned from
-- res.items (several thousand entries) on every lookup.
local item_by_name = {}
local item_id_by_name = {}
local name_cache_built = false

-- Create display with nice formatting
-- NOTE: Instead of one big multi-line text block, the display is built from a
-- pool of individually positioned text objects (one per row). This is
-- required to make individual lines clickable: Windower's texts library only
-- supports hover/click hit-testing per whole text object, not per line
-- within one block, so each clickable row needs to be its own object.
local row_pool = {}       -- reusable texts objects, indexed by row number
local row_meta = {}       -- click metadata for the CURRENT frame's rows, same indices as row_pool
local menu_pool = {}      -- reusable texts objects for the context menu
local menu_meta = {}      -- click metadata for the CURRENT context menu
local menu_open = false
local display_visible = true

-- Measure the real pixel line height for our font/size once, rather than
-- guessing a hardcoded value, so rows stack without gaps or overlap.
local LINE_HEIGHT
do
    local probe = texts.new('Ag')
    probe:font('Consolas', 11)
    probe:size(11)
    probe:visible(false)
    local _, h = probe:extents()
    LINE_HEIGHT = (h and h > 0) and (h + 1) or 15
    probe:destroy()
end

-- Returns (creating if necessary) the pooled text object for a given row
-- index. Row 1 is the only draggable element; every other row repositions
-- itself relative to row 1's live position each refresh, so dragging the
-- title effectively drags the whole panel.
local function get_row(index)
    local t = row_pool[index]
    if not t then
        t = texts.new('')
        t:font('Consolas', 11)
        t:bg_alpha(200)
        t:bg_visible(true)
        t:draggable(index == 1)
        if index == 1 then
            t:pos(window_x or 500, window_y or 300)
            -- Re-render immediately while dragging so the rest of the
            -- panel follows the title smoothly instead of snapping into
            -- place on the next unrelated refresh.
            t:register_event('drag', function()
                update_display()
            end)
        end
        row_pool[index] = t
    end
    return t
end

-- Persists the title row's current position, if it has changed, so the
-- window shows up where it was left after a //lua reload.
local function save_window_position()
    local anchor = row_pool[1]
    if not anchor then
        return
    end
    local x, y = anchor:pos()
    if x ~= window_x or y ~= window_y then
        window_x, window_y = x, y
        save_settings()
    end
end

-- Hides every pooled row/menu object without discarding them, so toggling
-- the display off/on doesn't require recreating anything.
local function hide_all_rows()
    for _, t in pairs(row_pool) do
        t:hide()
    end
end

-- Get player name
local function get_player_name()
    local player = windower.ffxi.get_player()
    if player then
        player_name = player.name
        return true
    end
    return false
end

-- Normalize item name for consistent storage
local function normalize_item_name(item_name)
    -- Capitalize first letter of each word
    return item_name:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
end

-- Convert short name to full name if mapping exists
local function get_full_name(item_name)
    -- First check if we have a direct mapping
    local full_name = short_to_full_map[item_name]
    if full_name then
        return full_name
    end
    
    -- Check normalized version
    local normalized = normalize_item_name(item_name)
    full_name = short_to_full_map[normalized]
    if full_name then
        return full_name
    end
    
    -- Return original if no mapping found
    return item_name
end

-- Get short name for display
local function get_display_name(full_name)
    -- Check if we have a mapping to short name
    local short_name = full_to_short_map[full_name]
    if short_name then
        return short_name
    end
    
    -- Check normalized version
    local normalized = normalize_item_name(full_name)
    short_name = full_to_short_map[normalized]
    if short_name then
        return short_name
    end
    
    -- Return original if no mapping
    return full_name
end

-- Check equipped ammo and update tracking
local function check_equipped_ammo()
    local equipment = windower.ffxi.get_items().equipment
    if equipment and equipment.ammo and equipment.ammo > 0 then
        local item = windower.ffxi.get_items(equipment.ammo_bag, equipment.ammo)
        if item and item.id > 0 then
            local item_resource = res.items[item.id]
            if item_resource then
                -- Check if it's stackable ammo
                if item_resource.stack and item_resource.stack > 1 then
                    local full_name = item_resource.name_log or item_resource.name
                    
                    -- If this is different ammo than before, clear old ammo tracking
                    if last_equipped_ammo and last_equipped_ammo ~= full_name then
                        ammo_items = {}
                        ammo_drop_times = {}
                    end
                    
                    -- Track the new ammo
                    ammo_items[full_name] = true
                    last_equipped_ammo = full_name
                    return true
                end
            end
        end
    end
    
    -- No ammo equipped, clear ammo tracking if we had something before
    if last_equipped_ammo then
        ammo_items = {}
        ammo_drop_times = {}
        last_equipped_ammo = nil
    end
    
    return false
end

-- Check if item is ammo
local function is_ammo_item(item_name)
    build_name_mappings()
    local item = item_by_name[item_name]
    if not item then
        return false
    end

    -- Check if it's ammo (type 10)
    if item.type == 10 then
        return true
    end

    -- Check for ranged items that are consumable (like shurikens)
    if item.type == 11 and item.stack and item.stack > 1 then
        return true
    end

    return false
end

-- Expanded list of known usable item IDs. Built once as a module-level
-- constant instead of being re-created inside is_usable_item on every call.
local USABLE_ITEM_IDS = {
    -- Medicines
    [4146] = true, -- Panacea
    [4148] = true, -- Antidote
    [4150] = true, -- Eye Drops
    [4151] = true, -- Echo Drops
    [4154] = true, -- Holy Water
    [4155] = true, -- Remedy
    [4157] = true, -- Poison Potion
    [4164] = true, -- Prism Powder
    [4165] = true, -- Silent Oil
    [5419] = true, -- Electuary
    [5328] = true, -- Hi-Elixir
    [5411] = true, -- Elixir

    -- Ethers and Potions
    [4128] = true, -- Ether
    [4129] = true, -- Ether +1
    [4130] = true, -- Ether +2
    [4131] = true, -- Ether +3
    [4144] = true, -- Hi-Ether
    [4145] = true, -- Hi-Ether +1
    [4112] = true, -- Potion
    [4113] = true, -- Potion +1
    [4114] = true, -- Potion +2
    [4115] = true, -- Potion +3
    [4116] = true, -- Hi-Potion
    [4117] = true, -- Hi-Potion +1
    [4118] = true, -- Hi-Potion +2
    [4119] = true, -- Hi-Potion +3
    [4120] = true, -- X-Potion
    [4121] = true, -- X-Potion +1
    [4122] = true, -- X-Potion +2
    [4123] = true, -- X-Potion +3

    -- Tools
    [5869] = true, -- Ram Mantle
    [5314] = true, -- Toolbag (Shihei)
    [5315] = true, -- Toolbag (Uchitake)
    [5316] = true, -- Toolbag (Tsurara)
    [5317] = true, -- Toolbag (Kawahori-Ogi)
    [5318] = true, -- Toolbag (Makibishi)
    [5319] = true, -- Toolbag (Hiraishin)
    [5734] = true, -- Toolbag (Sanjaku-Tenugui)

    -- Other consumables
    [4172] = true, -- Reraiser
    [5685] = true, -- Rabbit's Foot
    [5686] = true, -- Cheer
}

-- Check if item is usable (items that show as yellow in inventory)
local function is_usable_item(item_name)
    build_name_mappings()
    local item = item_by_name[item_name]
    if not item then
        return false
    end
    local id = item_id_by_name[item_name]

    -- Check if it's food (has a food effect) - type 7
    if item.type == 7 then
        return true
    end

    -- Check for items with yellow inventory color
    -- Yellow items typically have specific flags
    if item.flags then
        local flag_value = item.flags
        -- Handle case where flags might be a table
        if type(flag_value) == "table" then
            if flag_value[1] then
                flag_value = flag_value[1]
            else
                flag_value = nil
            end
        end

        if flag_value and type(flag_value) == "number" then
            -- Flag 0x200 (512) indicates usable items
            -- Flag 0x400 (1024) indicates some consumables
            -- Flag 0x800 (2048) indicates other usables
            if bit.band(flag_value, 0x200) > 0 or
               bit.band(flag_value, 0x400) > 0 or
               bit.band(flag_value, 0x800) > 0 then
                -- Additional check - make sure it's not equipment
                if item.type ~= 4 and item.type ~= 5 and item.type ~= 6 then
                    return true
                end
            end
        end
    end

    -- Check for specific item types that are always usable
    -- Type 1 is general items, type 2 is usable items
    if item.type == 1 or item.type == 2 then
        -- Check if it has a "use delay" which indicates it's usable
        if item.cast_delay and item.cast_delay > 0 then
            return true
        end

        -- Check if item has a recast delay (another indicator)
        if item.recast_delay and item.recast_delay > 0 then
            return true
        end

        -- Check for items that can be "used" based on their category
        -- Category 57 is often usable items
        if item.category and item.category == 57 then
            return true
        end
    end

    if USABLE_ITEM_IDS[id] then
        return true
    end

    return false
end

-- Build name mappings from resources, plus a name->resource cache used by
-- is_ammo_item/is_usable_item. This used to re-scan the entire res.items
-- table (several thousand entries) on every call - now it only does that
-- scan once per addon load and every other call is a no-op.
function build_name_mappings()
    if name_cache_built then
        return
    end

    full_to_short_map = {}
    short_to_full_map = {}
    item_by_name = {}
    item_id_by_name = {}

    for id, item in pairs(res.items) do
        if item.name then
            item_by_name[item.name] = item
            item_id_by_name[item.name] = id
        end
        if item.name_log then
            item_by_name[item.name_log] = item
            item_id_by_name[item.name_log] = id
        end

        if item.name and item.name_log and item.name ~= item.name_log then
            -- name = short name (in inventory)
            -- name_log = full name (in drop messages)
            full_to_short_map[item.name_log] = item.name
            short_to_full_map[item.name] = item.name_log

            -- Also store normalized versions
            local full_normalized = normalize_item_name(item.name_log)
            local short_normalized = normalize_item_name(item.name)
            full_to_short_map[full_normalized] = item.name
            short_to_full_map[short_normalized] = item.name_log
        end
    end

    -- Add some common manual mappings that might not be in resources
    full_to_short_map["One Hundred Byne Bill"] = "100 Byne Bill"
    short_to_full_map["100 Byne Bill"] = "One Hundred Byne Bill"

    full_to_short_map["One Byne Bill"] = "1 Byne Bill"
    short_to_full_map["1 Byne Bill"] = "One Byne Bill"

    full_to_short_map["Ten Thousand Byne Bill"] = "10000 Byne Bill"
    short_to_full_map["10000 Byne Bill"] = "Ten Thousand Byne Bill"

    full_to_short_map["Lungo-Nango Jadeshell"] = "L. Jadeshell"
    short_to_full_map["L. Jadeshell"] = "Lungo-Nango Jadeshell"

    name_cache_built = true
end

-- Get total count of item across all inventory types
local function get_inventory_count(item_name)
    -- Return cached value if recent
    local current_time = os.time()
    if current_time - last_inventory_check < INVENTORY_CHECK_INTERVAL then
        return inventory_cache[item_name] or 0
    end
    
    -- Save previous counts before updating
    previous_inventory_counts = {}
    for k, v in pairs(inventory_cache) do
        previous_inventory_counts[k] = v
    end
    
    -- Update cache and mappings
    last_inventory_check = current_time
    inventory_cache = {}
    build_name_mappings()
    
    -- Check equipped ammo while we're updating inventory
    check_equipped_ammo()
    
    -- All bag IDs to check
    local bags = {
        0,  -- Inventory
        1,  -- Safe
        2,  -- Storage
        3,  -- Temporary
        4,  -- Locker
        5,  -- Satchel
        6,  -- Sack
        7,  -- Case
        8,  -- Wardrobe
        9,  -- Safe 2
        10, -- Wardrobe 2
        11, -- Wardrobe 3
        12, -- Wardrobe 4
        13, -- Wardrobe 5
        14, -- Wardrobe 6
        15, -- Wardrobe 7
        16, -- Wardrobe 8
    }
    
    -- Count all items across all bags
    for _, bag_id in ipairs(bags) do
        local bag = windower.ffxi.get_items(bag_id)
        if bag and bag.enabled then
            for i = 1, bag.max do
                local item = bag[i]
                if item and item.id and item.id > 0 and item.count > 0 then
                    local item_resource = res.items[item.id]
                    if item_resource then
                        local short_name = item_resource.name
                        local full_name = item_resource.name_log or short_name
                        
                        -- Add to count
                        inventory_cache[full_name] = (inventory_cache[full_name] or 0) + item.count
                        
                        -- Also store under normalized full name
                        local full_normalized = normalize_item_name(full_name)
                        if full_normalized ~= full_name then
                            inventory_cache[full_normalized] = inventory_cache[full_name]
                        end
                    end
                end
            end
        end
    end
    
    -- Check for decreases and track them
    for item_name, current_count in pairs(inventory_cache) do
        local prev_count = previous_inventory_counts[item_name] or 0
        if current_count < prev_count then
            local decrease = prev_count - current_count
            recent_increments[item_name] = {amount = -decrease, time = os.time()}
        end
    end
    
    -- Check for items that were in inventory but are now gone
    for item_name, prev_count in pairs(previous_inventory_counts) do
        if not inventory_cache[item_name] and prev_count > 0 then
            recent_increments[item_name] = {amount = -prev_count, time = os.time()}
        end
    end
    
    return inventory_cache[item_name] or 0
end

-- Save settings to file
function save_settings()
    local data = 'return {\n'
    data = data .. '    tracked_items = {\n'
    for item, _ in pairs(tracked_items) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
    end
    data = data .. '    },\n'
    data = data .. '    item_counts = {\n'
    for item, count in pairs(item_counts) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = ' .. count .. ',\n'
    end
    data = data .. '    },\n'
    data = data .. '    usable_items = {\n'
    for item, _ in pairs(usable_items) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
    end
    data = data .. '    },\n'
    data = data .. '    key_items = {\n'
    for item, _ in pairs(key_items) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
    end
    data = data .. '    },\n'
    data = data .. '    personal_items = {\n'
    for item, _ in pairs(personal_items) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
    end
    data = data .. '    },\n'
    data = data .. '    personal_counts = {\n'
    for item, count in pairs(personal_counts) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = ' .. count .. ',\n'
    end
    data = data .. '    },\n'
    data = data .. '    saved_sets = {\n'
    for set_name, set_data in pairs(saved_sets) do
        data = data .. '        ["' .. set_name:gsub('"', '\\"') .. '"] = {\n'
        for _, category in ipairs({'drop', 'personal', 'usable'}) do
            data = data .. '            ' .. category .. ' = {\n'
            for item, _ in pairs(set_data[category] or {}) do
                data = data .. '                ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
            end
            data = data .. '            },\n'
        end
        data = data .. '        },\n'
    end
    data = data .. '    },\n'
    data = data .. '    auto_add_drop = ' .. tostring(auto_add_drop) .. ',\n'
    data = data .. '    auto_add_gil = ' .. tostring(auto_add_gil) .. ',\n'
    data = data .. '    auto_add_personal = ' .. tostring(auto_add_personal) .. ',\n'
    data = data .. '    auto_add_usable = ' .. tostring(auto_add_usable) .. ',\n'
    data = data .. '    quiet_mode = ' .. tostring(quiet_mode) .. ',\n'
    data = data .. '    window_x = ' .. tostring(window_x) .. ',\n'
    data = data .. '    window_y = ' .. tostring(window_y) .. ',\n'
    data = data .. '    display_visible = ' .. tostring(display_visible) .. ',\n'
    data = data .. '    focus_item_name = ' .. (focus_item_name and ('"' .. focus_item_name:gsub('"', '\\"') .. '"') or 'nil') .. ',\n'
    data = data .. '    focus_item_category = ' .. (focus_item_category and ('"' .. focus_item_category .. '"') or 'nil') .. ',\n'
    data = data .. '    session_start_time = ' .. tostring(session_start_time) .. ',\n'
    data = data .. '    session_gil = ' .. tostring(session_gil) .. ',\n'
    data = data .. '    session_counts = {\n'
    for item, count in pairs(session_counts) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = ' .. count .. ',\n'
    end
    data = data .. '    },\n'
    data = data .. '    session_personal_counts = {\n'
    for item, count in pairs(session_personal_counts) do
        data = data .. '        ["' .. item:gsub('"', '\\"') .. '"] = ' .. count .. ',\n'
    end
    data = data .. '    }\n'
    data = data .. '}'

    local file = files.new(get_settings_filename())
    file:write(data)
end

-- Load settings from file. Tries the per-character file first; if that
-- doesn't exist yet but the old shared file does, it migrates from the
-- shared file once (so upgrading doesn't look like losing your data).
-- Pass silent=true to suppress the migration chat message (used when
-- re-loading after the player's name becomes known post-login).
local function load_settings(silent)
    local filename = get_settings_filename()
    local file = files.new(filename)
    local used_legacy = false

    if not file:exists() and player_name then
        local legacy = files.new('data/settings.lua')
        if legacy:exists() then
            filename = 'data/settings.lua'
            file = legacy
            used_legacy = true
        end
    end

    if file:exists() then
        local loaded = loadfile(windower.addon_path .. filename)
        if loaded then
            local success, data = pcall(loaded)
            if success and data then
                tracked_items = data.tracked_items or {}
                item_counts = data.item_counts or {}
                usable_items = data.usable_items or {}
                -- Don't load ammo_items from file since we auto-detect equipped ammo
                key_items = data.key_items or {}
                personal_items = data.personal_items or data.obtained_items or {}
                personal_counts = data.personal_counts or data.obtained_counts or {}
                saved_sets = data.saved_sets or {}
                -- Migrate old flat-format sets ({item = true, ...}) to the
                -- new {drop = {...}, personal = {...}, usable = {...}}
                -- structure. A set from before this update won't have any
                -- of those three sub-tables, so treat its entries as drops.
                for existing_set_name, set_data in pairs(saved_sets) do
                    if not (set_data.drop or set_data.personal or set_data.usable) then
                        saved_sets[existing_set_name] = {drop = set_data, personal = {}, usable = {}}
                    end
                end
                -- Load auto-add settings, maintaining backward compatibility
                if data.auto_add ~= nil then
                    -- Old single auto_add setting - apply to drops only
                    auto_add_drop = data.auto_add
                else
                    -- New separate settings
                    auto_add_drop = data.auto_add_drop or false
                    auto_add_gil = data.auto_add_gil ~= false  -- Default true
                    auto_add_personal = data.auto_add_personal or data.auto_add_obtain or true
                    auto_add_usable = data.auto_add_usable ~= false  -- Default true
                end
                quiet_mode = data.quiet_mode or false
                window_x = data.window_x
                window_y = data.window_y
                if data.display_visible ~= nil then
                    display_visible = data.display_visible
                end
                focus_item_name = data.focus_item_name
                focus_item_category = data.focus_item_category
                session_start_time = data.session_start_time or os.time()
                session_gil = data.session_gil or 0
                session_counts = data.session_counts or {}
                session_personal_counts = data.session_personal_counts or {}

                -- Convert any short names to full names in tracked items
                build_name_mappings()
                local items_to_convert = {}
                for item_name, _ in pairs(tracked_items) do
                    local full_name = get_full_name(item_name)
                    if full_name ~= item_name then
                        items_to_convert[item_name] = full_name
                    end
                end

                -- Convert tracked items
                for short_name, full_name in pairs(items_to_convert) do
                    tracked_items[short_name] = nil
                    tracked_items[full_name] = true

                    -- Also move counts
                    if item_counts[short_name] then
                        item_counts[full_name] = (item_counts[full_name] or 0) + item_counts[short_name]
                        item_counts[short_name] = nil
                    end
                end

                -- Do the same for personal items
                items_to_convert = {}
                for item_name, _ in pairs(personal_items) do
                    local full_name = get_full_name(item_name)
                    if full_name ~= item_name then
                        items_to_convert[item_name] = full_name
                    end
                end

                for short_name, full_name in pairs(items_to_convert) do
                    personal_items[short_name] = nil
                    personal_items[full_name] = true

                    if personal_counts[short_name] then
                        personal_counts[full_name] = (personal_counts[full_name] or 0) + personal_counts[short_name]
                        personal_counts[short_name] = nil
                    end
                end

                -- Re-check all usable items with the improved criteria
                local items_to_move = {}
                for item_name, _ in pairs(usable_items) do
                    if not is_usable_item(item_name) then
                        items_to_move[item_name] = true
                    end
                end

                -- Move misclassified items to tracked_items
                for item_name, _ in pairs(items_to_move) do
                    usable_items[item_name] = nil
                    tracked_items[item_name] = true
                    if not item_counts[item_name] then
                        item_counts[item_name] = 0
                    end
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Moved "' .. item_name .. '" from usable to regular tracking (not directly usable).')
                end

                if used_legacy and player_name and not silent then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Migrated shared settings to a per-character file for ' .. player_name .. '.')
                    save_settings()
                end

                return true
            end
        end
    end
    return false
end

-- Sort items alphabetically
local function sort_items_alphabetically(item_list)
    table.sort(item_list, function(a, b)
        local display_a = get_display_name(a)
        local display_b = get_display_name(b)
        return display_a:lower() < display_b:lower()
    end)
    return item_list
end

-- Update the display
function update_display()
    -- Find the longest item name across all sections (using display names)
    local max_item_len = 12  -- Start with minimum

    for item_name, _ in pairs(usable_items) do
        local display_name = get_display_name(item_name)
        if #display_name > max_item_len then
            max_item_len = #display_name
        end
    end

    for item_name, _ in pairs(ammo_items) do
        local display_name = get_display_name(item_name)
        if #display_name > max_item_len then
            max_item_len = #display_name
        end
    end

    for item_name, _ in pairs(tracked_items) do
        local display_name = get_display_name(item_name)
        if #display_name > max_item_len then
            max_item_len = #display_name
        end
    end

    for item_name, _ in pairs(personal_items) do
        local display_name = get_display_name(item_name)
        if #display_name > max_item_len then
            max_item_len = #display_name
        end
    end

    for item_name, _ in pairs(key_items) do
        local display_name = item_name:gsub("^Key Item:%s*", "")
        if #display_name > max_item_len then
            max_item_len = #display_name
        end
    end

    -- Add minimal padding
    local column_width = max_item_len + 1

    -- Fixed width for the numbers section (count[inv] plus increment)
    local numbers_width = 15  -- Enough space for "(-999)999[999]"

    -- Reset this frame's click metadata. The underlying pooled text objects
    -- in row_pool persist and get reused; only the bookkeeping of "which
    -- row is at which index this frame" is rebuilt on every call.
    row_meta = {}
    local row_index = 0

    -- Row 1 (the title) is the only draggable row; every other row is
    -- positioned relative to its current position each refresh, so
    -- dragging the title drags the whole panel.
    local anchor_t = get_row(1)
    local anchor_x, anchor_y = anchor_t:pos()

    local function emit_row(str, click_info)
        row_index = row_index + 1
        local t = get_row(row_index)
        t:text(str)
        if row_index > 1 then
            t:pos(anchor_x, anchor_y + (row_index - 1) * LINE_HEIGHT)
        end
        if click_info then
            click_info.obj = t
            row_meta[row_index] = click_info
            t:bg_color(25, 35, 55)  -- subtle tint hints "this is clickable"
        else
            t:bg_color(0, 0, 0)
        end
        if display_visible then
            t:show()
        else
            t:hide()
        end
    end

    -- Shared row formatter for Usable Items, Equipped Ammo, Item Drops, and
    -- Personal Drops - the four sections that share the same "colored name,
    -- optional lifetime count, inventory count, recent +/- highlight"
    -- layout and only differ in a few small settings. Key Items and Gil
    -- have different enough layouts (no numbers, or a single bespoke row)
    -- that they're kept as their own bespoke code below instead.
    local function emit_item_row(item_name, category, current_time)
        local default_color, drop_times, increment_duration, count_table, clickable
        if category == 'usable' then
            default_color, drop_times, increment_duration, clickable =
                '\\cs(255,0,255)', usable_drop_times, GREEN_DURATION, true
        elseif category == 'ammo' then
            default_color, drop_times, increment_duration, clickable =
                '\\cs(255,255,0)', ammo_drop_times, GREEN_DURATION, false
        elseif category == 'drop' then
            default_color, drop_times, increment_duration, count_table, clickable =
                '\\cs(255,255,255)', item_drop_times, GREEN_DURATION, item_counts, true
        elseif category == 'personal' then
            default_color, drop_times, increment_duration, count_table, clickable =
                '\\cs(255,255,255)', personal_drop_times, RED_DURATION, personal_counts, true
        end

        local display_name = get_display_name(item_name)
        local inv_count = get_inventory_count(item_name)

        -- "Just changed" highlight: the whole line goes green for
        -- GREEN_DURATION seconds after a drop, regardless of category.
        local color_start = default_color
        if drop_times[item_name] then
            local time_since_drop = current_time - drop_times[item_name]
            if time_since_drop <= GREEN_DURATION then
                color_start = '\\cs(0,255,0)'
            else
                drop_times[item_name] = nil
            end
        end

        -- "(+n)" / "(-n)" indicator, shown for increment_duration seconds
        -- (Personal Drops uses the longer RED_DURATION here; everything
        -- else uses GREEN_DURATION, matching the pre-refactor behavior).
        local increment_text, increment_color = "", ""
        if recent_increments[item_name] then
            local time_since_change = current_time - recent_increments[item_name].time
            if time_since_change <= increment_duration then
                local amount = recent_increments[item_name].amount
                if amount > 0 then
                    increment_text = "(+" .. amount .. ")"
                    increment_color = color_start
                else
                    increment_text = "(" .. amount .. ")"
                    increment_color = "\\cs(255,0,0)"
                    color_start = '\\cs(255,0,0)'
                end
            else
                recent_increments[item_name] = nil
            end
        end

        local base_text = string.format('%-' .. column_width .. 's', display_name)
        local count_text
        if count_table then
            count_text = string.format('%d[%d]', count_table[item_name] or 0, inv_count)
        else
            count_text = string.format('[%d]', inv_count)
        end
        local numbers_section
        if increment_text ~= "" then
            numbers_section = string.format('%-7s%s', increment_text, count_text)
        else
            numbers_section = string.format('%7s%s', "", count_text)
        end
        local numbers_padded = string.format('%' .. numbers_width .. 's', numbers_section)

        local click_info = clickable and {kind = 'item', item_name = item_name, category = category} or nil
        emit_row(color_start .. base_text .. increment_color .. numbers_padded .. '\\cr', click_info)
    end

    emit_row('\\cs(255,255,255)Item Counter:\\cr')
    emit_row('\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr')

    -- Show player name if available
    if player_name then
        emit_row('\\cs(255,255,255)Tracking: ' .. player_name .. '\\cr')
    end

    -- Session clock, clickable to reset it.
    local session_elapsed = os.time() - session_start_time
    local session_hours = math.floor(session_elapsed / 3600)
    local session_minutes = math.floor((session_elapsed % 3600) / 60)
    local session_label = session_hours > 0
        and string.format('%dh %dm', session_hours, session_minutes)
        or string.format('%dm', session_minutes)
    emit_row('\\cs(255,255,255)Session: ' .. session_label .. '\\cr',
        {kind = 'item', item_name = 'Session', category = 'session'})

    -- Show auto-add status vertically with colors; each line is clickable
    -- and toggles that category on/off directly.
    local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local quiet_color = quiet_mode and '\\cs(0,255,0)' or '\\cs(255,0,0)'

    emit_row('\\cs(255,255,255)Auto-add:\\cr')
    emit_row(string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Drop:') .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr',
        {kind = 'toggle', category = 'drop'})
    emit_row(string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Usable:') .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr',
        {kind = 'toggle', category = 'usable'})
    emit_row(string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Personal:') .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr',
        {kind = 'toggle', category = 'personal'})
    emit_row(string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Gil:') .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr',
        {kind = 'toggle', category = 'gil'})
    emit_row(string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Quiet:') .. quiet_color .. (quiet_mode and 'ON' or 'OFF') .. '\\cr',
        {kind = 'toggle', category = 'quiet'})

    -- Focus item: pinned highlighted near the top, in addition to its
    -- normal listing further down in its own category section.
    if focus_item_name then
        local fname, fcat = focus_item_name, focus_item_category
        local exists = (fcat == 'drop' and tracked_items[fname])
            or (fcat == 'personal' and personal_items[fname])
            or (fcat == 'usable' and usable_items[fname])
            or (fcat == 'key' and key_items[fname])

        if exists then
            local fdisplay_name = (fcat == 'key') and fname:gsub("^Key Item:%s*", "") or get_display_name(fname)
            local finv_count = get_inventory_count(fname)
            local fline
            if fcat == 'drop' then
                fline = string.format('%-' .. column_width .. 's%d[%d]', fdisplay_name, item_counts[fname] or 0, finv_count)
            elseif fcat == 'personal' then
                fline = string.format('%-' .. column_width .. 's%d[%d]', fdisplay_name, personal_counts[fname] or 0, finv_count)
            elseif fcat == 'usable' then
                fline = string.format('%-' .. column_width .. 's[%d]', fdisplay_name, finv_count)
            else
                fline = string.format('%-' .. column_width .. 's', fdisplay_name)
            end
            emit_row('\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr')
            emit_row('\\cs(255,215,0)Focus:\\cr')
            emit_row('\\cs(255,215,0)' .. fline .. '\\cr',
                {kind = 'item', item_name = fname, category = fcat})
        else
            -- The focused item is no longer tracked in that category; drop
            -- the stale pin quietly rather than showing a broken row.
            focus_item_name = nil
            focus_item_category = nil
        end
    end

    -- Usable Items section (FIRST)
    local sorted_usable = {}
    for item_name, _ in pairs(usable_items) do
        table.insert(sorted_usable, item_name)
    end

    if #sorted_usable > 0 then
        emit_row('\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr')
        emit_row('\\cs(255,255,255)Usable Items:\\cr')

        sorted_usable = sort_items_alphabetically(sorted_usable)
        local current_time = os.time()

        for _, item_name in ipairs(sorted_usable) do
            emit_item_row(item_name, 'usable', current_time)
        end
    end

    -- Ammo section (SECOND - between Usable and Item Drops)
    local sorted_ammo = {}
    for item_name, _ in pairs(ammo_items) do
        table.insert(sorted_ammo, item_name)
    end

    if #sorted_ammo > 0 then
        emit_row('\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr')
        emit_row('\\cs(255,255,255)Equipped Ammo:\\cr')

        sorted_ammo = sort_items_alphabetically(sorted_ammo)
        local current_time = os.time()

        for _, item_name in ipairs(sorted_ammo) do
            -- Ammo is auto-tracked from equipment and can't be manually
            -- removed, so there's nothing a menu could usefully do here -
            -- emit_item_row leaves it non-interactive on purpose.
            emit_item_row(item_name, 'ammo', current_time)
        end
    end

    -- Item Drops section
    local sorted_drops = {}
    for item_name, _ in pairs(tracked_items) do
        table.insert(sorted_drops, item_name)
    end

    if #sorted_drops > 0 then
        emit_row('\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr')
        emit_row('\\cs(255,255,255)Item Drops:\\cr')

        sorted_drops = sort_items_alphabetically(sorted_drops)
        local current_time = os.time()

        for _, item_name in ipairs(sorted_drops) do
            emit_item_row(item_name, 'drop', current_time)
        end
    end

    -- Personal Drops section
    local sorted_personal = {}
    for item_name, _ in pairs(personal_items) do
        table.insert(sorted_personal, item_name)
    end

    if #sorted_personal > 0 then
        emit_row('\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr')
        emit_row('\\cs(255,255,255)Personal Drops:\\cr')

        sorted_personal = sort_items_alphabetically(sorted_personal)
        local current_time = os.time()

        for _, item_name in ipairs(sorted_personal) do
            emit_item_row(item_name, 'personal', current_time)
        end
    end

    -- Gil section (only show if any gil obtained) - kept bespoke since
    -- it's a single row, not a list, and doesn't fit emit_item_row's shape.
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        emit_row('\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr')

        local color_start = '\\cs(255,255,255)'
        if item_drop_times["Gil"] then
            local time_since_drop = os.time() - item_drop_times["Gil"]
            if time_since_drop <= GREEN_DURATION then
                color_start = '\\cs(0,255,0)'
            end
        end

        local increment_text = ""
        if recent_increments["Gil"] then
            local time_since_increment = os.time() - recent_increments["Gil"].time
            if time_since_increment <= GREEN_DURATION then
                increment_text = "(+" .. recent_increments["Gil"].amount .. ")"
            else
                recent_increments["Gil"] = nil
            end
        end

        local base_text = string.format('%-' .. column_width .. 's', 'Gil:')
        local numbers_section
        if increment_text ~= "" then
            numbers_section = string.format('%-10s%d', increment_text, gil)
        else
            numbers_section = tostring(gil)
        end
        local numbers_padded = string.format('%' .. numbers_width .. 's', numbers_section)

        emit_row(color_start .. base_text .. numbers_padded .. '\\cr',
            {kind = 'item', item_name = 'Gil', category = 'gil'})
    end

    -- Key Items section (LAST) - kept bespoke since key items have no
    -- inventory/lifetime count or increment indicator at all.
    local sorted_keys = {}
    for item_name, _ in pairs(key_items) do
        table.insert(sorted_keys, item_name)
    end

    if #sorted_keys > 0 then
        emit_row('\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr')
        emit_row('\\cs(255,255,255)Key Items:\\cr')

        sorted_keys = sort_items_alphabetically(sorted_keys)
        local current_time = os.time()

        for _, item_name in ipairs(sorted_keys) do
            local display_name = item_name:gsub("^Key Item:%s*", "")

            local color_start = '\\cs(0,150,255)'  -- Blue for key items
            if key_drop_times[item_name] then
                local time_since_drop = current_time - key_drop_times[item_name]
                if time_since_drop <= GREEN_DURATION then
                    color_start = '\\cs(0,255,0)'
                else
                    key_drop_times[item_name] = nil
                end
            end

            local base_text = string.format('%-' .. column_width .. 's', display_name)

            emit_row(color_start .. base_text .. '\\cr',
                {kind = 'item', item_name = item_name, category = 'key'})
        end
    end

    -- Hide any pooled rows left over from a previous, longer refresh.
    for i = row_index + 1, #row_pool do
        row_pool[i]:hide()
    end
end

-- Hides the context menu (if any) without discarding its pooled objects.
local function close_menu()
    for _, t in pairs(menu_pool) do
        t:hide()
    end
    menu_meta = {}
    menu_open = false
end

-- Reads/writes an auto-add category by name, shared between the typed
-- "//counter auto <category> on/off" command and clicking a toggle row.
-- Also doubles as the getter/setter for quiet mode, since it's displayed
-- and clicked the same way as the other toggles.
local function get_auto_add(category)
    if category == 'drop' then return auto_add_drop
    elseif category == 'usable' then return auto_add_usable
    elseif category == 'gil' then return auto_add_gil
    elseif category == 'personal' then return auto_add_personal
    elseif category == 'quiet' then return quiet_mode
    end
    return false
end

local function set_auto_add(category, value)
    local label
    if category == 'drop' then auto_add_drop = value; label = 'drops'
    elseif category == 'usable' then auto_add_usable = value; label = 'usable items'
    elseif category == 'gil' then auto_add_gil = value; label = 'gil'
    elseif category == 'personal' then auto_add_personal = value; label = 'personal drops'
    elseif category == 'quiet' then
        quiet_mode = value
        local color = value and '\\cs(0,255,0)' or '\\cs(255,0,0)'
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Quiet mode is now ' .. color .. (value and 'ON' or 'OFF') .. '\\cr.')
        save_settings()
        update_display()
        return
    else return
    end
    local color = value and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for ' .. label .. ' is now ' .. color .. (value and 'ON' or 'OFF') .. '\\cr.')
    save_settings()
    update_display()
end

-- Only prints when quiet mode is off. Used for automatic drop/steal/mug/
-- obtain detection messages; commands the user types always get their
-- normal confirmation via windower.add_to_chat directly, quiet mode or not.
local function announce(msg)
    if not quiet_mode then
        windower.add_to_chat(COUNTER_COLOR, msg)
    end
end

-- Snapshots current lifetime totals as the new session baseline and resets
-- the session clock, without touching any lifetime counters.
local function reset_session()
    session_start_time = os.time()
    session_gil = item_counts["Gil"] or 0
    session_counts = {}
    for item, count in pairs(item_counts) do
        session_counts[item] = count
    end
    session_personal_counts = {}
    for item, count in pairs(personal_counts) do
        session_personal_counts[item] = count
    end
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Session reset. Lifetime totals are unaffected.')
    save_settings()
    update_display()
end

-- Opens a small context menu of commands near (x, y) for the given item.
-- Which actions appear depends on the item's category, since e.g. usable
-- items can't be reset (they have no counter) and ammo isn't clickable
-- at all (handled by simply never tagging ammo rows as clickable).
-- category can also be 'session' for its header row, which gets its own
-- action list instead of item actions.
local function open_menu(item_name, category, x, y)
    close_menu()

    local actions = {}
    if category == 'session' then
        table.insert(actions, {label = 'Reset Session', fn = reset_session})
    elseif category == 'drop' or category == 'personal' then
        table.insert(actions, {label = 'Reset Count', fn = function() reset_item(item_name) end})
        table.insert(actions, {label = 'Remove', fn = function() remove_item(item_name) end})
    elseif category == 'usable' or category == 'key' then
        table.insert(actions, {label = 'Remove', fn = function() remove_item(item_name) end})
    elseif category == 'gil' then
        table.insert(actions, {label = 'Reset Gil', fn = function()
            item_counts["Gil"] = 0
            item_drop_times["Gil"] = nil
            recent_increments["Gil"] = nil
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil reset to 0.')
            save_settings()
            update_display()
        end})
    end

    -- Pin/unpin as the focused item, shown highlighted at the top of the
    -- display. Available for any real tracked item (not the session/kills
    -- header rows, and not ammo since that's never clickable to begin with).
    if category == 'drop' or category == 'personal' or category == 'usable' or category == 'key' then
        if focus_item_name == item_name and focus_item_category == category then
            table.insert(actions, {label = 'Remove Focus', fn = function()
                focus_item_name = nil
                focus_item_category = nil
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Focus cleared.')
                save_settings()
                update_display()
            end})
        else
            table.insert(actions, {label = 'Set as Focus', fn = function()
                focus_item_name = item_name
                focus_item_category = category
                windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. item_name .. '" is now focused.')
                save_settings()
                update_display()
            end})
        end
    end

    table.insert(actions, {label = 'Cancel', fn = function() end})

    for i, action in ipairs(actions) do
        local t = menu_pool[i]
        if not t then
            t = texts.new('')
            t:font('Consolas', 11)
            t:bg_alpha(230)
            t:draggable(false)
            menu_pool[i] = t
        end
        t:bg_color(50, 50, 50)
        t:color(255, 255, 255)
        t:text('  ' .. action.label .. '  ')
        t:pos(x, y + (i - 1) * LINE_HEIGHT)
        t:show()
        menu_meta[i] = {obj = t, fn = action.fn}
    end

    -- Hide any pooled menu rows left over from a menu with more options.
    for i = #actions + 1, #menu_pool do
        menu_pool[i]:hide()
    end

    menu_open = true
end

-- Routes mouse clicks to either the open context menu, an auto-add toggle
-- row, or an item row (which opens its context menu). Consumes the click
-- (returns true) whenever it lands on one of our UI elements, so it
-- doesn't also pass through to the game underneath.
windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if blocked then
        return false
    end

    -- Left-click release: piggyback on this to persist the window position
    -- if the title was just dragged (cheap to check on every release since
    -- clicks are infrequent compared to mouse-move events).
    if mtype == 2 then
        save_window_position()
        return false
    end

    -- Right-click-down: instantly remove an item, skipping the menu, for
    -- the common "I don't need this tracked anymore" case. Only applies to
    -- categories remove_item actually supports (not ammo, not Session).
    if mtype == 4 then
        for _, meta_row in pairs(row_meta) do
            if meta_row.kind == 'item' and meta_row.obj:hover(x, y) then
                local category = meta_row.category
                if category == 'drop' or category == 'personal' or category == 'usable' or category == 'key' then
                    remove_item(meta_row.item_name)
                    return true
                end
                return false
            end
        end
        return false
    end

    -- Only left-click-down (type 1) opens/interacts with our UI.
    if mtype ~= 1 then
        return false
    end

    if menu_open then
        for _, m in pairs(menu_meta) do
            if m.obj:hover(x, y) then
                m.fn()
                close_menu()
                return true
            end
        end
        -- Clicked outside the menu: close it, then fall through so a
        -- click directly on a different item still opens its menu in
        -- the same click instead of requiring a second click.
        close_menu()
    end

    for _, meta_row in pairs(row_meta) do
        if meta_row.obj:hover(x, y) then
            if meta_row.kind == 'toggle' then
                set_auto_add(meta_row.category, not get_auto_add(meta_row.category))
            elseif meta_row.kind == 'item' then
                -- 'item' covers real tracked items as well as the Session
                -- header row, which uses category = 'session' to get its
                -- own action list from open_menu.
                open_menu(meta_row.item_name, meta_row.category, x, y)
            end
            return true
        end
    end

    return false
end)

-- Track recent increment
local function track_increment(item_name, amount)
    if recent_increments[item_name] then
        -- If there's already a recent increment, add to it
        local current_time = os.time()
        if current_time - recent_increments[item_name].time <= GREEN_DURATION then
            recent_increments[item_name].amount = recent_increments[item_name].amount + amount
            recent_increments[item_name].time = current_time
        else
            recent_increments[item_name] = {amount = amount, time = current_time}
        end
    else
        recent_increments[item_name] = {amount = amount, time = os.time()}
    end

    -- Focus item alert: every drop/obtain/steal/mug path funnels through
    -- here, so this is the one place that needs to know about it, rather
    -- than adding a check at each individual detection site.
    if amount > 0 and focus_item_name == item_name then
        windower.add_to_chat(COUNTER_COLOR, '\\cs(255,215,0)*** FOCUS ITEM: ' .. item_name .. ' (+' .. amount .. ')! ***\\cr')
    end
end

-- Determine which category an item belongs to
local function get_item_category(item_name)
    if usable_items[item_name] then
        return "usable"
    elseif ammo_items[item_name] then
        return "ammo"
    elseif tracked_items[item_name] then
        return "drop"
    elseif personal_items[item_name] then
        return "personal"
    elseif key_items[item_name] then
        return "key"
    end
    return nil
end

-- Add item to tracking list
local function add_item(item_name)
    if not item_name or item_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to add gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil is automatically tracked and cannot be manually added.')
        return
    end
    
    -- Build mappings if needed
    build_name_mappings()
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    -- Convert to full name if it's a short name
    local full_name = get_full_name(item_name)
    
    -- Check if item is already tracked anywhere
    if tracked_items[full_name] or usable_items[full_name] or ammo_items[full_name] or personal_items[full_name] or key_items[full_name] then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is already being tracked.')
        return
    end
    
    -- Don't allow manual adding of ammo - it's auto-detected from equipped
    if is_ammo_item(full_name) then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Ammo is automatically tracked when equipped. Cannot manually add.')
        return
    end
    
    -- Determine category based on item type
    if is_usable_item(full_name) then
        -- Add to usable items
        usable_items[full_name] = true
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Now tracking "' .. full_name .. '" as a usable item.')
    else
        -- Add to regular tracked items
        tracked_items[full_name] = true
        item_counts[full_name] = 0
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Now tracking "' .. full_name .. '".')
    end
    
    save_settings()
    update_display()
end

-- Remove item from tracking list
function remove_item(item_name)
    if not item_name or item_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to remove gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil cannot be manually removed.')
        return
    end
    
    -- Build mappings if needed
    build_name_mappings()
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    -- Convert to full name if it's a short name
    local full_name = get_full_name(item_name)
    
    -- Check all categories
    if tracked_items[full_name] then
        tracked_items[full_name] = nil
        item_counts[full_name] = nil
        item_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Stopped tracking "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif usable_items[full_name] then
        usable_items[full_name] = nil
        usable_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Stopped tracking usable item "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif ammo_items[full_name] then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Cannot manually remove equipped ammo. Unequip it to stop tracking.')
    elseif personal_items[full_name] then
        personal_items[full_name] = nil
        personal_counts[full_name] = nil
        personal_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Stopped tracking personal item "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif key_items[full_name] then
        key_items[full_name] = nil
        key_drop_times[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Stopped tracking key item "' .. full_name .. '".')
        save_settings()
        update_display()
    else
        windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is not being tracked.')
    end
end

-- Reset count for a specific item
function reset_item(item_name)
    if not item_name or item_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to reset gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//cnt gil reset" to reset gil.')
        return
    end
    
    -- Build mappings if needed
    build_name_mappings()
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    -- Convert to full name if it's a short name
    local full_name = get_full_name(item_name)
    
    if tracked_items[full_name] then
        item_counts[full_name] = 0
        item_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Reset count for "' .. full_name .. '" to 0.')
        save_settings()
        update_display()
    elseif personal_items[full_name] then
        personal_counts[full_name] = 0
        personal_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Reset count for personal item "' .. full_name .. '" to 0.')
        save_settings()
        update_display()
    else
        windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is not being tracked with a counter.')
    end
end

-- List all tracked items
local function list_items()
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Currently tracking:')
    
    -- Show usable items
    if next(usable_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Usable Items:')
        local sorted_usable = {}
        for item_name, _ in pairs(usable_items) do
            table.insert(sorted_usable, item_name)
        end
        sorted_usable = sort_items_alphabetically(sorted_usable)
        
        for i, item_name in ipairs(sorted_usable) do
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s (Inventory: %d)', i, item_name, inv_count))
        end
    end
    
    -- Show ammo
    if next(ammo_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Equipped Ammo:')
        local sorted_ammo = {}
        for item_name, _ in pairs(ammo_items) do
            table.insert(sorted_ammo, item_name)
        end
        sorted_ammo = sort_items_alphabetically(sorted_ammo)
        
        for i, item_name in ipairs(sorted_ammo) do
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s (Inventory: %d)', i, item_name, inv_count))
        end
    end
    
    -- Show dropped items
    if next(tracked_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Item Drops:')
        local sorted_drops = {}
        for item_name, _ in pairs(tracked_items) do
            table.insert(sorted_drops, item_name)
        end
        sorted_drops = sort_items_alphabetically(sorted_drops)
        
        for i, item_name in ipairs(sorted_drops) do
            local item_count = item_counts[item_name] or 0
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s (Count: %d, Inventory: %d)', i, item_name, item_count, inv_count))
        end
    end
    
    -- Show personal drops
    if next(personal_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Personal Drops:')
        local sorted_personal = {}
        for item_name, _ in pairs(personal_items) do
            table.insert(sorted_personal, item_name)
        end
        sorted_personal = sort_items_alphabetically(sorted_personal)
        
        for i, item_name in ipairs(sorted_personal) do
            local item_count = personal_counts[item_name] or 0
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s (Count: %d, Inventory: %d)', i, item_name, item_count, inv_count))
        end
    end
    
    -- Show gil
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        windower.add_to_chat(COUNTER_COLOR, '  Gil: ' .. gil)
    end
    
    -- Show key items
    if next(key_items) then
        windower.add_to_chat(COUNTER_COLOR, '  Key Items:')
        local sorted_keys = {}
        for item_name, _ in pairs(key_items) do
            table.insert(sorted_keys, item_name)
        end
        sorted_keys = sort_items_alphabetically(sorted_keys)
        
        for i, item_name in ipairs(sorted_keys) do
            local display_name = item_name:gsub("^Key Item:%s*", "")
            windower.add_to_chat(COUNTER_COLOR, string.format('    %d. %s', i, display_name))
        end
    end
end

-- Save current tracked items as a set
-- Sets store three categories together: Item Drops, Personal Drops, and
-- Usable Items, so a single "farming loadout" can include more than just
-- what enemies drop.
local function save_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify a set name.')
        return
    end

    local drop_snapshot, personal_snapshot, usable_snapshot = {}, {}, {}
    local count = 0
    for item in pairs(tracked_items) do
        drop_snapshot[item] = true
        count = count + 1
    end
    for item in pairs(personal_items) do
        personal_snapshot[item] = true
        count = count + 1
    end
    for item in pairs(usable_items) do
        usable_snapshot[item] = true
        count = count + 1
    end

    if count == 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: No items to save. Add items before creating a set.')
        return
    end

    saved_sets[set_name] = {drop = drop_snapshot, personal = personal_snapshot, usable = usable_snapshot}

    windower.add_to_chat(COUNTER_COLOR, 'Counter: Saved set "' .. set_name .. '" with ' .. count .. ' items (drops/personal/usable).')
    save_settings()
end

-- Load a saved set. Item Drops are replaced (matching the original
-- behavior, so switching farming spots doesn't accumulate old targets).
-- Personal Drops and Usable Items are merged in additively instead of
-- replacing, since those categories are often auto-populated and a set
-- shouldn't wipe tracking that has nothing to do with it.
local function load_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify a set name.')
        return
    end

    local set_data = saved_sets[set_name]
    if not set_data then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Set "' .. set_name .. '" not found.')
        return
    end

    tracked_items = {}
    item_drop_times = {}
    recent_increments = {}

    local count = 0
    for item in pairs(set_data.drop or {}) do
        tracked_items[item] = true
        if not item_counts[item] then
            item_counts[item] = 0
        end
        count = count + 1
    end
    for item in pairs(set_data.personal or {}) do
        if not personal_items[item] then
            personal_items[item] = true
            if not personal_counts[item] then
                personal_counts[item] = 0
            end
            count = count + 1
        end
    end
    for item in pairs(set_data.usable or {}) do
        if not usable_items[item] then
            usable_items[item] = true
            count = count + 1
        end
    end

    windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded set "' .. set_name .. '" (' .. count .. ' items - drops replaced, personal/usable merged in).')
    save_settings()
    update_display()
end

-- List all saved sets
local function list_sets()
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Saved sets:')
    
    -- Create a sorted list of set names
    local sorted_sets = {}
    for set_name, _ in pairs(saved_sets) do
        table.insert(sorted_sets, set_name)
    end
    table.sort(sorted_sets)
    
    if #sorted_sets > 0 then
        for i, set_name in ipairs(sorted_sets) do
            local set_data = saved_sets[set_name]
            local drop_count, personal_count, usable_count = 0, 0, 0
            for _ in pairs(set_data.drop or {}) do drop_count = drop_count + 1 end
            for _ in pairs(set_data.personal or {}) do personal_count = personal_count + 1 end
            for _ in pairs(set_data.usable or {}) do usable_count = usable_count + 1 end
            windower.add_to_chat(COUNTER_COLOR, '  ' .. i .. '. ' .. set_name .. ' (drops: ' .. drop_count .. ', personal: ' .. personal_count .. ', usable: ' .. usable_count .. ')')
        end
    else
        windower.add_to_chat(COUNTER_COLOR, '  No saved sets.')
    end
end

-- Delete a saved set
local function delete_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Please specify a set name.')
        return
    end
    
    if saved_sets[set_name] then
        saved_sets[set_name] = nil
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Deleted set "' .. set_name .. '".')
        save_settings()
    else
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Set "' .. set_name .. '" not found.')
    end
end

-- Strip FFXI text formatting codes
local function strip_format(text)
    -- Remove auto-translate brackets and other formatting
    text = text:gsub(string.char(0xEF)..string.char(0x27), '')
    text = text:gsub(string.char(0xEF)..string.char(0x28), '')
    
    -- Remove color codes and other formatting codes
    text = text:gsub(string.char(0x1F)..'[%z\1-\255]', '')
    text = text:gsub(string.char(0x1E)..'[%z\1-\255]', '')
    text = text:gsub(string.char(0x7F)..'[%z\1-\255]', '')
    
    -- Remove any other control characters
    text = text:gsub('%c', '')
	    return text
end

-- Parse text for item drops
local function check_for_drops(message, mode)
    -- Skip our own messages and debug messages
    if message:find("^Counter:") or message:find("^DEBUG ALL:") or message:find("^Counter DEBUG:") then
        return
    end
    
    -- Try to get player name if we don't have it yet
    if not player_name then
        get_player_name()
    end
    
    -- Debug all messages if enabled
    if debug_all then
        windower.add_to_chat(COUNTER_COLOR, string.format('DEBUG ALL: Mode=%d, Message=%s', mode, message))
    end
    
    -- Strip formatting for all messages
    local clean_message = strip_format(message)
    local lower_message = clean_message:lower()

    -- More flexible Steal detection - look for "steal" and item pattern
    -- Uses word-boundary frontiers so this only matches the standalone word
    -- "steal"/"steals", not substrings like "stealthy".
    if lower_message:find("%f[%a]steals?%f[%A]") and auto_add_personal then
        -- Try various patterns that might contain steal
        local item_name = nil
        
        -- Look for parentheses first (most reliable for item names)
        item_name = clean_message:match("%(([^%)]+)%)")
        
        if not item_name then
            -- Pattern: "steal <item> from"
            item_name = clean_message:match("[Ss]teals?%s+(.-)%s+from")
        end
        
        if not item_name then
            -- Pattern: Looking for text between "steal" and a mob name pattern
            local steal_part = clean_message:match("[Ss]teal%s+(.+)")
            if steal_part then
                -- Try to identify where the mob name starts (usually contains hyphens or specific patterns)
                item_name = steal_part:match("^(.-)%s+%w+%-?%w*$")
                if not item_name then
                    -- If no mob pattern found, just take the first few words
                    item_name = steal_part:match("^([%w%s]+)")
                end
            end
        end
        
        if item_name then
            -- Clean up the item name
            item_name = item_name:gsub("[%.!%?]+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
            
            -- Skip if empty or if it's the player name
            if item_name ~= "" and item_name ~= player_name then
                item_name = normalize_item_name(item_name)
                
                if debug_mode then
                    windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Steal detected: "%s"', item_name))
                end
                
                -- Check if it's a usable item
                if auto_add_usable and is_usable_item(item_name) then
                    if not usable_items[item_name] then
                        usable_items[item_name] = true
                    end
                    usable_drop_times[item_name] = os.time()
                    track_increment(item_name, 1)
                    announce('Counter: Stole usable item - ' .. item_name .. '!')
                else
                    -- Add to personal drops
                    if not personal_items[item_name] then
                        personal_items[item_name] = true
                    end
                    
                    personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
                    personal_drop_times[item_name] = os.time()
                    track_increment(item_name, 1)
                    announce('Counter: Steal - ' .. item_name .. '! Total: ' .. personal_counts[item_name])
                end
                
                save_settings()
                update_display()
                return
            end
        end
    end
    
    -- More flexible Mug detection - look for "mug" and gil amount
    -- Uses word-boundary frontiers so "smug"/"mugwort"/etc. don't false-trigger
    -- (plain string.find("smug", "mug") would otherwise match).
    if lower_message:find("%f[%a]mugs?%f[%A]") and auto_add_gil then
        -- Try to find gil amount near "mug"
        local gil_amount = nil
        
        -- Pattern 1: number followed by gil
        gil_amount = clean_message:match("(%d[%d,]*) gil")
        if not gil_amount then
            -- Pattern 2: gil followed by number
            gil_amount = clean_message:match("gil%s*:%s*(%d[%d,]*)")
        end
        if not gil_amount then
            -- Pattern 3: just a number near mug
            gil_amount = clean_message:match("[Mm]ug%s*:?%s*(%d[%d,]*)")
        end
        
        if gil_amount then
            -- Remove commas from gil amount
            local clean_gil = gil_amount:gsub(",", "")
            gil_amount = tonumber(clean_gil)
            
            if gil_amount and gil_amount > 0 then
                if debug_mode then
                    windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Mug detected: %d gil', gil_amount))
                end
                
                item_counts["Gil"] = (item_counts["Gil"] or 0) + gil_amount
                item_drop_times["Gil"] = os.time()
                track_increment("Gil", gil_amount)
                announce('Counter: Mugged ' .. gil_amount .. ' gil! Total: ' .. item_counts["Gil"])
                save_settings()
                update_display()
                return
            end
        end
    end
    
    -- Check for "You obtain (x) <item>" pattern
    local obtain_count, obtain_item = clean_message:match("^You obtain (%d+) (.+)%.$")
    if not obtain_count then
        obtain_count, obtain_item = clean_message:match("^You obtain (%d+) (.+)$")
    end
    
    if obtain_count and obtain_item and auto_add_personal then
        local count = tonumber(obtain_count)
        if count then
            local item_name = normalize_item_name(obtain_item)
            
            if debug_mode then
                windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: You obtain %d %s', count, item_name))
            end
            
            -- Check if it's a usable item
            if auto_add_usable and is_usable_item(item_name) then
                if not usable_items[item_name] then
                    usable_items[item_name] = true
                end
                usable_drop_times[item_name] = os.time()
                track_increment(item_name, count)
                announce('Counter: Obtained ' .. count .. ' usable item - ' .. item_name .. '!')
            else
                -- Add to personal drops
                if not personal_items[item_name] then
                    personal_items[item_name] = true
                end
                
                personal_counts[item_name] = (personal_counts[item_name] or 0) + count
                personal_drop_times[item_name] = os.time()
                track_increment(item_name, count)
                announce('Counter: Obtained ' .. count .. ' ' .. item_name .. '! Total: ' .. personal_counts[item_name])
            end
            
            save_settings()
            update_display()
            return
        end
    end
    
    -- Check for "Obtained:" items (from chests/NPCs) - handle various formats
    if auto_add_personal then
        local obtained_item = nil
        
        -- Try different patterns
        obtained_item = clean_message:match("^Obtained:%s*(.+)$")
        if not obtained_item then
            obtained_item = clean_message:match("^You obtained:%s*(.+)$")
        end
        if not obtained_item then
            obtained_item = clean_message:match("^Obtained%s+(.+)$")
        end
        
        if obtained_item then
            -- Clean up the item name
            obtained_item = obtained_item:gsub("%.+$", "")
            obtained_item = obtained_item:gsub("!+$", "")
            obtained_item = obtained_item:gsub("^%s+", "")
            obtained_item = obtained_item:gsub("%s+$", "")
            
            -- Skip if it's empty or just punctuation
            if obtained_item == "" or obtained_item:match("^[%.!%s]+$") then
                return
            end
            
            local item_name = normalize_item_name(obtained_item)
            
            if debug_mode and not message:find("^Counter:") then
                windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Found personal drop: "%s" -> "%s"', obtained_item, item_name))
            end
            
            -- Check if it's a key item
            if item_name:find("^Key Item:") then
                if not key_items[item_name] then
                    key_items[item_name] = true
                    key_drop_times[item_name] = os.time()
                    announce('Counter: Key item obtained - ' .. item_name:gsub("^Key Item:%s*", "") .. '!')
                end
            -- Check if it's a usable item
            elseif auto_add_usable and is_usable_item(item_name) then
                if not usable_items[item_name] then
                    usable_items[item_name] = true
                    usable_drop_times[item_name] = os.time()
                    track_increment(item_name, 1)
                    announce('Counter: Usable item obtained - ' .. item_name .. '!')
                end
            else
                -- Regular personal item
                if not personal_items[item_name] then
                    personal_items[item_name] = true
                end
                
                personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
                personal_drop_times[item_name] = os.time()
                track_increment(item_name, 1)
                announce('Counter: Personal drop - ' .. item_name .. '! Total: ' .. personal_counts[item_name])
            end
            
            save_settings()
            update_display()
            return
        end
    end
    
    -- Special handling for mode 127 (drops)
    if mode == 127 then
        if debug_mode then
            windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Mode 127 detected!'))
            windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Cleaned message: "%s"', clean_message))
            if player_name then
                windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Tracking drops for: %s', player_name))
            end
        end
        
        -- Check if this is an obtain message
        if clean_message:lower():find("obtain") then
            -- Check for gil first
            local gil_amount = nil
            local player = nil
            
            -- Try different gil patterns
            player, gil_amount = clean_message:match("^(%w+) obtains? ([%d,]+) gil%.?$")
            if not player then
                gil_amount = clean_message:match("^You obtain ([%d,]+) gil%.?$")
                player = player_name
            end
            
            if gil_amount and player then
                -- Only count if it's our character's drops and auto-add gil is on
                if player_name and player == player_name and auto_add_gil then
                    -- Remove commas from gil amount
                    local clean_gil = gil_amount:gsub(",", "")
                    -- Convert to number without passing the count from gsub
                    gil_amount = tonumber(clean_gil)
                    if gil_amount then
                        item_counts["Gil"] = (item_counts["Gil"] or 0) + gil_amount
                        item_drop_times["Gil"] = os.time()
                        track_increment("Gil", gil_amount)
                        announce('Counter: Gained ' .. gil_amount .. ' gil! Total: ' .. item_counts["Gil"])
                        save_settings()
                        update_display()
                    end
                end
                return
            end
            
            -- Try to extract player name and item
            local item_match = nil
            player, item_match = clean_message:match("^(%w+) obtains? an? (.+)%.$")
            if not player then
                player, item_match = clean_message:match("^(%w+) obtains? (.+)%.$")
            end
            if not player then
                player, item_match = clean_message:match("^(%w+) obtains? an? (.+)$")
            end
            if not player then
                player, item_match = clean_message:match("^(%w+) obtains? (.+)$")
            end
            
            if player and item_match then
                -- Only count if it's our character's drops
                if player_name and player ~= player_name then
                    if debug_mode then
                        windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Drop by %s ignored (not %s)', player, player_name))
                    end
                    return
                end
                
                -- Remove any trailing punctuation or whitespace
                item_match = item_match:gsub("[%.!%?]+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                
                -- Normalize the item name
                local normalized_item = normalize_item_name(item_match)
                
                if debug_mode then
                    windower.add_to_chat(COUNTER_COLOR, string.format('Counter DEBUG: Found - Player: "%s", Item: "%s" -> "%s"', player, item_match, normalized_item))
                end
                
                -- Check if it's a usable item and auto-add is on
                if auto_add_usable and is_usable_item(normalized_item) and not usable_items[normalized_item] then
                    usable_items[normalized_item] = true
                    usable_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    announce('Counter: Auto-added "' .. normalized_item .. '" to usable items.')
                    save_settings()
                    update_display()
                    return
                end
                
                -- Auto-add functionality for drops
                if auto_add_drop and not tracked_items[normalized_item] and not usable_items[normalized_item] and not ammo_items[normalized_item] then
                    -- Check if it's ammo - ammo dropped from enemies goes to item drops with auto-add
                    if is_ammo_item(normalized_item) then
                        tracked_items[normalized_item] = true
                        item_counts[normalized_item] = 0
                        announce('Counter: Auto-added ammo "' .. normalized_item .. '" to item drops.')
                    else
                        tracked_items[normalized_item] = true
                        item_counts[normalized_item] = 0
                        announce('Counter: Auto-added "' .. normalized_item .. '" to tracking list.')
                    end
                end
                
                -- Check if we're tracking this item
                if tracked_items[normalized_item] then
                    item_counts[normalized_item] = (item_counts[normalized_item] or 0) + 1
                    item_drop_times[normalized_item] = os.time()  -- Record drop time for color
                    track_increment(normalized_item, 1)
                    announce('Counter: ' .. normalized_item .. ' dropped! Total: ' .. item_counts[normalized_item])
                    save_settings()
                    update_display()
                elseif usable_items[normalized_item] then
                    usable_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    announce('Counter: Usable item ' .. normalized_item .. ' dropped!')
                    save_settings()
                    update_display()
                elseif ammo_items[normalized_item] then
                    ammo_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    announce('Counter: Ammo ' .. normalized_item .. ' dropped!')
                    save_settings()
                    update_display()
                else
                    if debug_mode then
                        windower.add_to_chat(COUNTER_COLOR, 'Counter DEBUG: Item "' .. normalized_item .. '" not in tracking list')
                        windower.add_to_chat(COUNTER_COLOR, 'Counter DEBUG: Tracked items:')
                        for tracked, _ in pairs(tracked_items) do
                            windower.add_to_chat(COUNTER_COLOR, '  - "' .. tracked .. '"')
                        end
                    end
                end
            elseif debug_mode then
                windower.add_to_chat(COUNTER_COLOR, 'Counter DEBUG: Failed to parse obtain message')
            end
        end
    end
end

-- Timer to update display colors
windower.register_event('time change', function()
    -- Check if any items need color updates
    local needs_update = false
    local current_time = os.time()
    
    for item_name, drop_time in pairs(item_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, drop_time in pairs(personal_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, drop_time in pairs(usable_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, drop_time in pairs(ammo_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, drop_time in pairs(key_drop_times) do
        if current_time - drop_time > GREEN_DURATION then
            needs_update = true
            break
        end
    end
    
    for item_name, increment_data in pairs(recent_increments) do
        if current_time - increment_data.time > RED_DURATION then
            needs_update = true
            break
        end
    end
    
    -- Also update if inventory might have changed
    if current_time - last_inventory_check >= INVENTORY_CHECK_INTERVAL then
        needs_update = true
    end
    
    if needs_update then
        update_display()
    end
end)

-- Register for incoming text event
windower.register_event('incoming text', function(original, modified, original_mode, modified_mode)
    check_for_drops(original, original_mode)
end)

-- Register for login event to get player name
windower.register_event('login', function()
    -- Delay slightly to ensure player data is available
    windower.send_command('@wait 1; lua i counter get_player_name')
end)

-- Register for equipment change event to update ammo tracking
windower.register_event('status change', function()
    -- Check equipped ammo whenever status changes
    check_equipped_ammo()
    update_display()
end)

-- Also check ammo on job change
windower.register_event('job change', function()
    check_equipped_ammo()
    update_display()
end)

-- Command handler
windower.register_event('addon command', function(...)
    local args = {...}
    local command = args[1]
    
    if command then
        command = command:lower()
        table.remove(args, 1)
        
        if command == 'get_player_name' then
            -- Internal command to get player name after login
            local had_name = player_name ~= nil
            get_player_name()
            if player_name then
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Now tracking drops for ' .. player_name)
                if not had_name then
                    -- We loaded before the character was known and used the
                    -- shared fallback file; now that we know who this is,
                    -- switch to (and possibly migrate into) their own file.
                    load_settings(true)
                end
                update_display()
            end
        elseif command == 'auto' then
            local category = args[1]
            local setting = args[2]
            
            if category then
                category = category:lower()
                
                if category == 'drop' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_drop = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for drops is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_drop = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for drops is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto drop on" or "//counter auto drop off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for drops is currently ' .. color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'usable' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_usable = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for usable items is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_usable = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for usable items is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto usable on" or "//counter auto usable off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for usable items is currently ' .. color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'gil' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_gil = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for gil is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_gil = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for gil is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto gil on" or "//counter auto gil off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for gil is currently ' .. color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'personal' or category == 'obtain' then  -- Support both for backward compatibility
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_personal = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for personal drops is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_personal = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for personal drops is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto personal on" or "//counter auto personal off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for personal drops is currently ' .. color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'all' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_drop = true
                            auto_add_gil = true
                            auto_add_personal = true
                            auto_add_usable = true
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for all categories is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_drop = false
                            auto_add_gil = false
                            auto_add_personal = false
                            auto_add_usable = false
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add for all categories is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto all on" or "//counter auto all off".')
                        end
                        save_settings()
                        update_display()
                    else
                        windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add status:')
                        local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(COUNTER_COLOR, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(COUNTER_COLOR, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(COUNTER_COLOR, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(COUNTER_COLOR, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Valid auto categories: drop, usable, gil, personal, all')
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Example: "//counter auto drop on" or "//counter auto all off"')
                end
            else
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add status:')
                local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                windower.add_to_chat(COUNTER_COLOR, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(COUNTER_COLOR, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(COUNTER_COLOR, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(COUNTER_COLOR, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Use "//counter auto <category> on/off" where category is: drop, usable, gil, personal, or all')
            end
        elseif command == 'ammo' then
            -- For ammo, just show what's currently equipped
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Equipped Ammo:')
            if next(ammo_items) then
                for item_name, _ in pairs(ammo_items) do
                    local inv_count = get_inventory_count(item_name)
                    windower.add_to_chat(COUNTER_COLOR, string.format('  %s (Inventory: %d)', item_name, inv_count))
                end
            else
                windower.add_to_chat(COUNTER_COLOR, '  No ammo currently equipped.')
            end
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Ammo is automatically tracked when equipped.')
        elseif command == 'gil' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    item_counts["Gil"] = 0
                    item_drop_times["Gil"] = nil
                    recent_increments["Gil"] = nil
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    item_counts["Gil"] = 0
                    item_drop_times["Gil"] = nil
                    recent_increments["Gil"] = nil
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil cleared.')
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown gil command. Use "reset" or "clear".')
                end
            else
                local gil = item_counts["Gil"] or 0
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Gil obtained: ' .. gil)
            end
        elseif command == 'use' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'clear' then
                    -- Clear increments for the items being removed BEFORE
                    -- wiping usable_items, otherwise this check is always
                    -- false and recent_increments never gets cleaned up.
                    for item, _ in pairs(usable_items) do
                        recent_increments[item] = nil
                    end
                    usable_items = {}
                    usable_drop_times = {}
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Usable items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Usable Items:')
                    local sorted = {}
                    for item_name, _ in pairs(usable_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s (Inventory: %d)', i, item_name, inv_count))
                        end
                    else
                        windower.add_to_chat(COUNTER_COLOR, '  No usable items tracked.')
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown use command. Use "clear" or "list".')
                end
            else
                -- Show usable list
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Usable Items:')
                local sorted = {}
                for item_name, _ in pairs(usable_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s (Inventory: %d)', i, item_name, inv_count))
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, '  No usable items tracked.')
                end
            end
        elseif command == 'key' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'clear' then
                    key_items = {}
                    key_drop_times = {}
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Key items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Key Items:')
                    local sorted = {}
                    for item_name, _ in pairs(key_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local display_name = item_name:gsub("^Key Item:%s*", "")
                            windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s', i, display_name))
                        end
                    else
                        windower.add_to_chat(COUNTER_COLOR, '  No key items tracked.')
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown key command. Use "clear" or "list".')
                end
            else
                -- Show key list
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Key Items:')
                local sorted = {}
                for item_name, _ in pairs(key_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local display_name = item_name:gsub("^Key Item:%s*", "")
                        windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s', i, display_name))
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, '  No key items tracked.')
                end
            end
        elseif command == 'drop' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    for item in pairs(tracked_items) do
                        item_counts[item] = 0
                        item_drop_times[item] = nil
                        recent_increments[item] = nil
                    end
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: All dropped item counts reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    -- First clear the counts and timers
                    for item in pairs(tracked_items) do
                        item_counts[item] = nil
                        item_drop_times[item] = nil
                        recent_increments[item] = nil
                    end
                    -- Then clear the tracked items
                    tracked_items = {}
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Dropped items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Item Drops:')
                    local sorted = {}
                    for item_name, _ in pairs(tracked_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local count = item_counts[item_name] or 0
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                        end
                    else
                        windower.add_to_chat(COUNTER_COLOR, '  No items tracked.')
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown drop command. Use "reset", "clear", or "list".')
                end
            else
                -- Show drop list
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Item Drops:')
                local sorted = {}
                for item_name, _ in pairs(tracked_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local count = item_counts[item_name] or 0
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, '  No items tracked.')
                end
            end
        elseif command == 'personal' or command == 'obtain' then  -- Support both commands
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    for item in pairs(personal_items) do
                        personal_counts[item] = 0
                        personal_drop_times[item] = nil
                        recent_increments[item] = nil
                    end
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: All personal drop counts reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    -- Clear increments for the items being removed BEFORE
                    -- wiping personal_items, otherwise this check is always
                    -- false and recent_increments never gets cleaned up.
                    for item, _ in pairs(personal_items) do
                        recent_increments[item] = nil
                    end
                    personal_items = {}
                    personal_counts = {}
                    personal_drop_times = {}
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Personal drops list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Personal Drops:')
                    local sorted = {}
                    for item_name, _ in pairs(personal_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local count = personal_counts[item_name] or 0
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                        end
                    else
                        windower.add_to_chat(COUNTER_COLOR, '  No personal drops.')
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown personal command. Use "reset", "clear", or "list".')
                end
            else
                -- Show personal list
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Personal Drops:')
                local sorted = {}
                for item_name, _ in pairs(personal_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local count = personal_counts[item_name] or 0
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(COUNTER_COLOR, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                    end
                else
                    windower.add_to_chat(COUNTER_COLOR, '  No personal drops.')
                end
            end
        elseif command == 'add' then
            local full_arg = table.concat(args, ' ')
            if full_arg:find(',') then
                -- Batch add: "//counter add ItemA, ItemB, ItemC"
                for item_name in full_arg:gmatch('([^,]+)') do
                    item_name = item_name:gsub('^%s+', ''):gsub('%s+$', '')
                    if item_name ~= '' then
                        add_item(item_name)
                    end
                end
            else
                add_item(full_arg)
            end
        elseif command == 'remove' then
            local item_name = table.concat(args, ' ')
            remove_item(item_name)
        elseif command == 'list' then
            list_items()
        elseif command == 'clear' then
            -- Clear everything
            tracked_items = {}
            item_counts = {["Gil"] = 0}
            item_drop_times = {}
            personal_items = {}
            personal_counts = {}
            personal_drop_times = {}
            usable_items = {}
            usable_drop_times = {}
            -- Don't clear ammo_items as they're auto-detected from equipment
            key_items = {}
            key_drop_times = {}
            recent_increments = {}
            windower.add_to_chat(COUNTER_COLOR, 'Counter: All lists cleared.')
            save_settings()
            update_display()
        elseif command == 'reset' then
            -- Handle both old (reset all) and new (reset specific) functionality
            local item_name = table.concat(args, ' ')
            if item_name == '' then
                -- No item specified, reset all
                item_counts["Gil"] = 0
                item_drop_times["Gil"] = nil
                recent_increments["Gil"] = nil
                for item in pairs(tracked_items) do
                    item_counts[item] = 0
                    item_drop_times[item] = nil
                    recent_increments[item] = nil
                end
                for item in pairs(personal_items) do
                    personal_counts[item] = 0
                    personal_drop_times[item] = nil
                    recent_increments[item] = nil
                end
                windower.add_to_chat(COUNTER_COLOR, 'Counter: All counters reset to 0.')
            else
                -- Reset specific item
                reset_item(item_name)
            end
            save_settings()
            update_display()
        elseif command == 'resetitem' then
            -- Alternative command specifically for resetting single items
            local item_name = table.concat(args, ' ')
            reset_item(item_name)
        elseif command == 'addset' then
            local set_name = table.concat(args, ' ')
            save_set(set_name)
        elseif command == 'set' then
            local set_name = table.concat(args, ' ')
            load_set(set_name)
        elseif command == 'listsets' then
            list_sets()
        elseif command == 'deleteset' then
            local set_name = table.concat(args, ' ')
            delete_set(set_name)
        elseif command == 'session' then
            local subcmd = args[1]
            if subcmd and subcmd:lower() == 'reset' then
                reset_session()
            else
                local elapsed = os.time() - session_start_time
                local h = math.floor(elapsed / 3600)
                local m = math.floor((elapsed % 3600) / 60)
                windower.add_to_chat(COUNTER_COLOR, 'Counter: Current session: ' .. h .. 'h ' .. m .. 'm. Use "//counter session reset" to start a new one.')
            end
        elseif command == 'quiet' then
            set_auto_add('quiet', not quiet_mode)
        elseif command == 'focus' then
            local item_name = table.concat(args, ' ')
            if item_name == '' then
                if focus_item_name then
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: Currently focused on "' .. focus_item_name .. '". Use "//counter unfocus" to clear it.')
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: No item is currently focused. Usage: //counter focus <item name>')
                end
            else
                build_name_mappings()
                item_name = normalize_item_name(item_name)
                local full_name = get_full_name(item_name)
                local category = nil
                if tracked_items[full_name] then category = 'drop'
                elseif personal_items[full_name] then category = 'personal'
                elseif usable_items[full_name] then category = 'usable'
                elseif key_items[full_name] then category = 'key'
                end
                if category then
                    focus_item_name = full_name
                    focus_item_category = category
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is now focused.')
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: "' .. full_name .. '" is not being tracked, so it can\'t be focused.')
                end
            end
        elseif command == 'unfocus' then
            focus_item_name = nil
            focus_item_category = nil
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Focus cleared.')
            save_settings()
            update_display()
        elseif command == 'export' then
            local lines_out = {}
            table.insert(lines_out, 'Counter export for ' .. (player_name or 'unknown') .. ' - ' .. os.date('%Y-%m-%d %H:%M:%S'))
            table.insert(lines_out, string.rep('=', 50))
            table.insert(lines_out, '')
            table.insert(lines_out, 'Gil (lifetime): ' .. (item_counts["Gil"] or 0))
            table.insert(lines_out, '')

            local function dump_section(title, items, counts)
                local names = {}
                for item_name, _ in pairs(items) do
                    table.insert(names, item_name)
                end
                if #names == 0 then return end
                table.insert(lines_out, title .. ':')
                names = sort_items_alphabetically(names)
                for _, item_name in ipairs(names) do
                    local count = counts and (counts[item_name] or 0) or nil
                    local line = '  ' .. item_name
                    if count then
                        line = line .. ': ' .. count
                    end
                    table.insert(lines_out, line)
                end
                table.insert(lines_out, '')
            end

            dump_section('Item Drops', tracked_items, item_counts)
            dump_section('Personal Drops', personal_items, personal_counts)
            dump_section('Usable Items', usable_items, nil)
            dump_section('Key Items', key_items, nil)

            local export_file = files.new('data/export-' .. (player_name or 'shared') .. '.txt')
            export_file:write(table.concat(lines_out, '\n'))
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Exported to Windower/addons/Counter/data/export-' .. (player_name or 'shared') .. '.txt')
        elseif command == 'debug' then
            debug_mode = not debug_mode
            debug_all = false
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Debug mode ' .. (debug_mode and 'ON' or 'OFF'))
        elseif command == 'debugall' then
            debug_all = not debug_all
            debug_mode = false
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Debug ALL mode ' .. (debug_all and 'ON - showing all messages' or 'OFF'))
        elseif command == 'testpersonal' or command == 'testobtain' then  -- Support both
            -- Test command to manually add a personal drop
            local item_name = table.concat(args, ' ')
            if item_name ~= '' then
                item_name = normalize_item_name(item_name)
                personal_items[item_name] = true
                personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
                personal_drop_times[item_name] = os.time()
                track_increment(item_name, 1)
                windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Added personal drop ' .. item_name .. '. Total: ' .. personal_counts[item_name])
                save_settings()
                update_display()
            end
        elseif command == 'testgil' then
            -- Test command to manually add gil
            local amount = tonumber(args[1])
            if amount then
                item_counts["Gil"] = (item_counts["Gil"] or 0) + amount
                item_drop_times["Gil"] = os.time()
                track_increment("Gil", amount)
                windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Added ' .. amount .. ' gil. Total: ' .. item_counts["Gil"])
                save_settings()
                update_display()
            else
                windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Please specify an amount: //cnt testgil 100')
            end
        elseif command == 'test' then
            -- Test increment for debugging
            local item_name = table.concat(args, ' ')
            if item_name ~= '' then
                -- Build mappings if needed
                build_name_mappings()
                
                item_name = normalize_item_name(item_name)
                
                -- Convert to full name if it's a short name
                local full_name = get_full_name(item_name)
                
                if tracked_items[full_name] then
                    item_counts[full_name] = (item_counts[full_name] or 0) + 1
                    item_drop_times[full_name] = os.time()  -- Mark as recently dropped for color
                    track_increment(full_name, 1)
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Incremented ' .. full_name .. ' to ' .. item_counts[full_name])
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(COUNTER_COLOR, 'Counter: TEST - Item "' .. full_name .. '" not tracked')
                end
            end
        elseif command == 'show' then
            display_visible = true
            save_settings()
            update_display()
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Display shown.')
        elseif command == 'hide' then
            display_visible = false
            save_settings()
            hide_all_rows()
            close_menu()
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Display hidden.')
        elseif command == 'help' then
            windower.add_to_chat(COUNTER_COLOR, '=== Counter Commands ===')
            windower.add_to_chat(COUNTER_COLOR, '  //counter add <item name> - Add item to tracking (auto-categorized)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter add ItemA, ItemB, ItemC - Add multiple items at once')
            windower.add_to_chat(COUNTER_COLOR, '  //counter remove <item name> - Remove item from tracking')
            windower.add_to_chat(COUNTER_COLOR, '  //counter list - List all tracked items in chat')
            windower.add_to_chat(COUNTER_COLOR, '  //counter clear - Clear all lists')
            windower.add_to_chat(COUNTER_COLOR, '  //counter reset - Reset all counters to 0')
            windower.add_to_chat(COUNTER_COLOR, '  //counter reset <item name> - Reset specific item counter to 0')
            windower.add_to_chat(COUNTER_COLOR, '  //counter resetitem <item name> - Reset specific item counter to 0')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto - Show auto-add status for all categories')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto drop on/off - Toggle auto-add for drops')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto usable on/off - Toggle auto-add for usable items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto gil on/off - Toggle auto-add for gil')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto personal on/off - Toggle auto-add for personal drops')
            windower.add_to_chat(COUNTER_COLOR, '  //counter auto all on/off - Toggle auto-add for all categories')
            windower.add_to_chat(COUNTER_COLOR, '  //counter gil - Show gil total')
            windower.add_to_chat(COUNTER_COLOR, '  //counter gil reset/clear - Reset/clear gil')
            windower.add_to_chat(COUNTER_COLOR, '  //counter use - Show usable items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter use clear/list - Manage usable items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter ammo - Show equipped ammo')
            windower.add_to_chat(COUNTER_COLOR, '  //counter drop - Show dropped items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter drop reset/clear/list - Manage dropped items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter personal - Show personal drops')
            windower.add_to_chat(COUNTER_COLOR, '  //counter personal reset/clear/list - Manage personal drops')
            windower.add_to_chat(COUNTER_COLOR, '  //counter key - Show key items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter key clear/list - Manage key items')
            windower.add_to_chat(COUNTER_COLOR, '  //counter addset <name> - Save current drops/personal/usable as a set')
            windower.add_to_chat(COUNTER_COLOR, '  //counter set <name> - Load a set (replaces drops, merges personal/usable)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter listsets - List all saved sets')
            windower.add_to_chat(COUNTER_COLOR, '  //counter deleteset <name> - Delete a saved set')
            windower.add_to_chat(COUNTER_COLOR, '  //counter session reset - Start a new session (lifetime totals unaffected)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter quiet - Toggle quiet mode (suppresses automatic drop chat spam)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter focus <item name> - Pin an item at the top of the display')
            windower.add_to_chat(COUNTER_COLOR, '  //counter unfocus - Clear the focused item')
            windower.add_to_chat(COUNTER_COLOR, '  //counter export - Write a summary to a text file in the addon\'s data folder')
            windower.add_to_chat(COUNTER_COLOR, '  //counter debug - Toggle debug mode for obtain messages')
            windower.add_to_chat(COUNTER_COLOR, '  //counter debugall - Show ALL chat messages (warning: spammy!)')
            windower.add_to_chat(COUNTER_COLOR, '  //counter test <item name> - Manually increment counter')
            windower.add_to_chat(COUNTER_COLOR, '  //counter testpersonal <item name> - Test personal drop')
            windower.add_to_chat(COUNTER_COLOR, '  //counter testgil <amount> - Test gil addition')
            windower.add_to_chat(COUNTER_COLOR, '  //counter show - Show the display window')
            windower.add_to_chat(COUNTER_COLOR, '  //counter hide - Hide the display window')
            windower.add_to_chat(COUNTER_COLOR, '  //counter help - Show this help message')
            windower.add_to_chat(COUNTER_COLOR, '  Note: You can also use //cnt instead of //counter')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Usable items appear in magenta, ammo in yellow, key items in blue')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Items are sorted alphabetically within each category')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Ammo is automatically tracked when equipped')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Steal and Mug actions are automatically tracked')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Click any toggle row to flip it, or click an item for a menu of actions')
            windower.add_to_chat(COUNTER_COLOR, '  Note: Right-click an item to remove it instantly, skipping the menu')
        else
            windower.add_to_chat(COUNTER_COLOR, 'Counter: Unknown command "' .. command .. '". Use //counter help for commands.')
        end
    else
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Use //counter help for commands.')
    end
end)

-- Try to get player name on load (before loading settings, so we pick the
-- right per-character file immediately if the character is already known)
get_player_name()
if player_name then
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Tracking drops for ' .. player_name)
end

-- Load settings on startup
if load_settings() then
    local count = 0
    for _ in pairs(tracked_items) do
        count = count + 1
    end
    if count > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded ' .. count .. ' tracked items from previous session.')
    end
    
    local usable_count = 0
    for _ in pairs(usable_items) do
        usable_count = usable_count + 1
    end
    if usable_count > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded ' .. usable_count .. ' usable items from previous session.')
    end
    
    local personal_count = 0
    for _ in pairs(personal_items) do
        personal_count = personal_count + 1
    end
    if personal_count > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded ' .. personal_count .. ' personal drops from previous session.')
    end
    
    local key_count = 0
    for _ in pairs(key_items) do
        key_count = key_count + 1
    end
    if key_count > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded ' .. key_count .. ' key items from previous session.')
    end
    
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        windower.add_to_chat(COUNTER_COLOR, 'Counter: Loaded gil total: ' .. gil)
    end
    
    -- Show auto-add status with colors
    windower.add_to_chat(COUNTER_COLOR, 'Counter: Auto-add status:')
    local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    windower.add_to_chat(COUNTER_COLOR, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(COUNTER_COLOR, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(COUNTER_COLOR, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(COUNTER_COLOR, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
end

-- Check for equipped ammo on load
check_equipped_ammo()

-- Initialize display
update_display()

windower.add_to_chat(COUNTER_COLOR, 'Counter v1.1.1 loaded successfully! Use //counter help for commands.')