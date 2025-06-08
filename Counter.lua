_addon.name = 'Counter'
_addon.author = 'wisdomcheese4'
_addon.version = '1.1.0'
_addon.commands = {'counter', 'cnt'}

-- Import necessary libraries
local texts = require('texts')
local files = require('files')
local res = require('resources')

-- Initialize variables
local tracked_items = {}
local item_counts = {}
local saved_sets = {}
local settings_file = files.new('data/settings.lua')
local debug_mode = false
local debug_all = false
local player_name = nil

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

-- Create display with nice formatting
local display = texts.new('')
display:pos(500, 300)
display:bg_alpha(200)
display:bg_visible(true)
display:font('Consolas', 11)
display:draggable(true)
display:show()

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
    -- Try to find the item in resources
    for id, item in pairs(res.items) do
        if item.name == item_name or item.name_log == item_name then
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
    end
    return false
end

-- Check if item is usable (very restrictive - only food and actual usable items)
local function is_usable_item(item_name)
    -- Try to find the item in resources
    for id, item in pairs(res.items) do
        if item.name == item_name or item.name_log == item_name then
            -- Check if it's food (has a food effect)
            if item.type == 7 then  -- Food type
                return true
            end
            
            -- Check for items that can be "used" from inventory
            -- These typically have specific flags
            if item.flags then
                local flag_value = item.flags
                -- Handle case where flags might be a table
                if type(flag_value) == "table" then
                    -- If it's a table, it might have a numeric value we need
                    if flag_value[1] then
                        flag_value = flag_value[1]
                    else
                        -- Can't determine flags, skip this check
                        flag_value = nil
                    end
                end
                
                if flag_value and type(flag_value) == "number" then
                    -- Flag 0x200 (512) indicates items that can be used from inventory
                    if bit.band(flag_value, 0x200) > 0 then
                        return true
                    end
                    
                    -- Some medicines and tools have flag 0x400 (1024)
                    if bit.band(flag_value, 0x400) > 0 then
                        -- Additional check - make sure it's not equipment
                        if item.type ~= 4 and item.type ~= 5 and item.type ~= 6 then
                            return true
                        end
                    end
                end
            end
            
            -- Check for specific item types that are always usable
            -- Type 1 is general items, but we need to be more specific
            if item.type == 1 then
                -- Check if it has a "use delay" which indicates it's usable
                if item.cast_delay and item.cast_delay > 0 then
                    return true
                end
                -- Check for specific known usable item IDs
                -- This is a fallback for items that might not have proper flags
                local usable_ids = {
                    [4146] = true, -- Panacea
                    [4148] = true, -- Antidote
                    [4150] = true, -- Eye Drops
                    [4151] = true, -- Echo Drops
                    [4164] = true, -- Prism Powder
                    [4165] = true, -- Silent Oil
                    [5419] = true, -- Electuary
                    [5328] = true, -- Hi-Elixir
                    [5411] = true, -- Elixir
                }
                if usable_ids[id] then
                    return true
                end
            end
            
            return false
        end
    end
    return false
end

-- Build name mappings from resources
local function build_name_mappings()
    full_to_short_map = {}
    short_to_full_map = {}
    
    for id, item in pairs(res.items) do
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
local function save_settings()
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
    for set_name, set_items in pairs(saved_sets) do
        data = data .. '        ["' .. set_name:gsub('"', '\\"') .. '"] = {\n'
        for item, _ in pairs(set_items) do
            data = data .. '            ["' .. item:gsub('"', '\\"') .. '"] = true,\n'
        end
        data = data .. '        },\n'
    end
    data = data .. '    },\n'
    data = data .. '    auto_add_drop = ' .. tostring(auto_add_drop) .. ',\n'
    data = data .. '    auto_add_gil = ' .. tostring(auto_add_gil) .. ',\n'
    data = data .. '    auto_add_personal = ' .. tostring(auto_add_personal) .. ',\n'
    data = data .. '    auto_add_usable = ' .. tostring(auto_add_usable) .. '\n'
    data = data .. '}'
    
    settings_file:write(data)
end

-- Load settings from file  
local function load_settings()
    if settings_file:exists() then
        local loaded = loadfile(windower.addon_path..'data/settings.lua')
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
                
                -- Re-check all usable items with the stricter criteria
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
                    windower.add_to_chat(207, 'Counter: Moved "' .. item_name .. '" from usable to regular tracking (not directly usable).')
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
local function update_display()
    -- Find the longest item name across all sections (using display names)
    local max_item_len = 12  -- Start with minimum
    
    -- Check all categories
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
    
    -- Build display text with color codes
    local text = '\\cs(255,255,255)Item Counter:\\cr\n'
    text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
    
    -- Show player name if available
    if player_name then
        text = text .. '\\cs(255,255,255)Tracking: ' .. player_name .. '\\cr\n'
    end
    
    -- Show auto-add status vertically with colors, aligned right
    local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    
    text = text .. '\\cs(255,255,255)Auto-add:\\cr\n'
    text = text .. string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Drop:') .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr\n'
    text = text .. string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Usable:') .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr\n'
    text = text .. string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Personal:') .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr\n'
    text = text .. string.format('\\cs(255,255,255)%-' .. (column_width - 7) .. 's', ' Gil:') .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr\n'
    
    local has_content = false
    
    -- Usable Items section (FIRST)
    local sorted_usable = {}
    for item_name, _ in pairs(usable_items) do
        table.insert(sorted_usable, item_name)
    end
    
    if #sorted_usable > 0 then
        if has_content then
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        else
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        end
        text = text .. '\\cs(255,255,255)Usable Items:\\cr\n'
        has_content = true
        
        sorted_usable = sort_items_alphabetically(sorted_usable)
        
        local current_time = os.time()
        
        for _, item_name in ipairs(sorted_usable) do
            local display_name = get_display_name(item_name)
            local inv_count = get_inventory_count(item_name)
            
            -- Check if this item should be green
            local color_start = '\\cs(255,0,255)'  -- Default magenta for usable
            if usable_drop_times[item_name] then
                local time_since_drop = current_time - usable_drop_times[item_name]
                if time_since_drop <= GREEN_DURATION then
                    color_start = '\\cs(0,255,0)'  -- Green
                else
                    -- Clean up old entries
                    usable_drop_times[item_name] = nil
                end
            end
            
            -- Check for recent increment/decrement to show
            local increment_text = ""
            local increment_color = ""
            if recent_increments[item_name] then
                local time_since_change = current_time - recent_increments[item_name].time
                if time_since_change <= GREEN_DURATION then
                    local amount = recent_increments[item_name].amount
                    if amount > 0 then
                        increment_text = "(+" .. amount .. ")"
                        increment_color = color_start  -- Use current color
                    else
                        increment_text = "(" .. amount .. ")"
                        increment_color = "\\cs(255,0,0)"  -- Red for decrements
                        color_start = '\\cs(255,0,0)'  -- Make whole line red for decrements
                    end
                else
                    -- Clean up old entries
                    recent_increments[item_name] = nil
                end
            end
            
            -- Format with fixed positions (no counter, just inventory)
            local base_text = string.format('%-' .. column_width .. 's', display_name)
            local inv_text = string.format('[%d]', inv_count)
            
            -- Build the numbers section with increment BEFORE inventory
            local numbers_section
            if increment_text ~= "" then
                numbers_section = string.format('%-7s%s', increment_text, inv_text)
            else
                numbers_section = string.format('%7s%s', "", inv_text)
            end
            local numbers_padded = string.format('%' .. numbers_width .. 's', numbers_section)
            
            text = text .. color_start .. base_text .. increment_color .. numbers_padded .. '\\cr\n'
        end
    end
    
    -- Ammo section (SECOND - between Usable and Item Drops)
    local sorted_ammo = {}
    for item_name, _ in pairs(ammo_items) do
        table.insert(sorted_ammo, item_name)
    end
    
    if #sorted_ammo > 0 then
        if has_content then
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        else
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        end
        text = text .. '\\cs(255,255,255)Equipped Ammo:\\cr\n'
        has_content = true
        
        sorted_ammo = sort_items_alphabetically(sorted_ammo)
        
        local current_time = os.time()
        
        for _, item_name in ipairs(sorted_ammo) do
            local display_name = get_display_name(item_name)
            local inv_count = get_inventory_count(item_name)
            
            -- Check if this item should be green
            local color_start = '\\cs(255,255,0)'  -- Default yellow for ammo
            if ammo_drop_times[item_name] then
                local time_since_drop = current_time - ammo_drop_times[item_name]
                if time_since_drop <= GREEN_DURATION then
                    color_start = '\\cs(0,255,0)'  -- Green
                else
                    -- Clean up old entries
                    ammo_drop_times[item_name] = nil
                end
            end
            
            -- Check for recent increment/decrement to show
            local increment_text = ""
            local increment_color = ""
            if recent_increments[item_name] then
                local time_since_change = current_time - recent_increments[item_name].time
                if time_since_change <= GREEN_DURATION then
                    local amount = recent_increments[item_name].amount
                    if amount > 0 then
                        increment_text = "(+" .. amount .. ")"
                        increment_color = color_start  -- Use current color
                    else
                        increment_text = "(" .. amount .. ")"
                        increment_color = "\\cs(255,0,0)"  -- Red for decrements
                        color_start = '\\cs(255,0,0)'  -- Make whole line red for decrements
                    end
                else
                    -- Clean up old entries
                    recent_increments[item_name] = nil
                end
            end
            
            -- Format with fixed positions (no counter, just inventory)
            local base_text = string.format('%-' .. column_width .. 's', display_name)
            local inv_text = string.format('[%d]', inv_count)
            
            -- Build the numbers section with increment BEFORE inventory
            local numbers_section
            if increment_text ~= "" then
                numbers_section = string.format('%-7s%s', increment_text, inv_text)
            else
                numbers_section = string.format('%7s%s', "", inv_text)
            end
            local numbers_padded = string.format('%' .. numbers_width .. 's', numbers_section)
            
            text = text .. color_start .. base_text .. increment_color .. numbers_padded .. '\\cr\n'
        end
    end
    
    -- Item Drops section
    local sorted_drops = {}
    for item_name, _ in pairs(tracked_items) do
        table.insert(sorted_drops, item_name)
    end
    
    if #sorted_drops > 0 then
        if has_content then
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        else
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        end
        text = text .. '\\cs(255,255,255)Item Drops:\\cr\n'
        has_content = true
        
        sorted_drops = sort_items_alphabetically(sorted_drops)
        
        local current_time = os.time()
        
        for _, item_name in ipairs(sorted_drops) do
            local display_name = get_display_name(item_name)
            local count = item_counts[item_name] or 0
            local inv_count = get_inventory_count(item_name)
            
            -- Check if this item should be green
            local color_start = '\\cs(255,255,255)'  -- Default white
            if item_drop_times[item_name] then
                local time_since_drop = current_time - item_drop_times[item_name]
                if time_since_drop <= GREEN_DURATION then
                    color_start = '\\cs(0,255,0)'  -- Green
                else
                    -- Clean up old entries
                    item_drop_times[item_name] = nil
                end
            end
            
            -- Check for recent increment/decrement to show
            local increment_text = ""
            local increment_color = ""
            if recent_increments[item_name] then
                local time_since_change = current_time - recent_increments[item_name].time
                if time_since_change <= GREEN_DURATION then
                    local amount = recent_increments[item_name].amount
                    if amount > 0 then
                        increment_text = "(+" .. amount .. ")"
                        increment_color = color_start  -- Use current color
                    else
                        increment_text = "(" .. amount .. ")"
                        increment_color = "\\cs(255,0,0)"  -- Red for decrements
                        color_start = '\\cs(255,0,0)'  -- Make whole line red for decrements
                    end
                else
                    -- Clean up old entries
                    recent_increments[item_name] = nil
                end
            end
            
            -- Format with fixed positions
            local base_text = string.format('%-' .. column_width .. 's', display_name)
            local count_text = string.format('%d[%d]', count, inv_count)
            
            -- Build the numbers section with increment BEFORE count
            local numbers_section
            if increment_text ~= "" then
                numbers_section = string.format('%-7s%s', increment_text, count_text)
            else
                numbers_section = string.format('%7s%s', "", count_text)
            end
            local numbers_padded = string.format('%' .. numbers_width .. 's', numbers_section)
            
            text = text .. color_start .. base_text .. increment_color .. numbers_padded .. '\\cr\n'
        end
    end
    
    -- Personal Drops section
    local sorted_personal = {}
    for item_name, _ in pairs(personal_items) do
        table.insert(sorted_personal, item_name)
    end
    
    if #sorted_personal > 0 then
        if has_content then
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        else
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        end
        text = text .. '\\cs(255,255,255)Personal Drops:\\cr\n'
        has_content = true
        
        sorted_personal = sort_items_alphabetically(sorted_personal)
        
        local current_time = os.time()
        
        for _, item_name in ipairs(sorted_personal) do
            local display_name = get_display_name(item_name)
            local count = personal_counts[item_name] or 0
            local inv_count = get_inventory_count(item_name)
            
            -- Determine color
            local color_start = '\\cs(255,255,255)'  -- Default white
            
            if personal_drop_times[item_name] then
                local time_since_drop = current_time - personal_drop_times[item_name]
                if time_since_drop <= GREEN_DURATION then
                    color_start = '\\cs(0,255,0)'  -- Green
                else
                    -- Clean up old entries
                    personal_drop_times[item_name] = nil
                end
            end
            
            -- Check for recent increment/decrement to show
            local increment_text = ""
            local increment_color = ""
            if recent_increments[item_name] then
                local time_since_change = current_time - recent_increments[item_name].time
                if time_since_change <= RED_DURATION then
                    local amount = recent_increments[item_name].amount
                    if amount > 0 then
                        increment_text = "(+" .. amount .. ")"
                        increment_color = color_start  -- Use current color
                    else
                        increment_text = "(" .. amount .. ")"
                        increment_color = "\\cs(255,0,0)"  -- Red for decrements
                        color_start = '\\cs(255,0,0)'
                    end
                else
                    -- Clean up old entries
                    recent_increments[item_name] = nil
                end
            end
            
            -- Format with fixed positions
            local base_text = string.format('%-' .. column_width .. 's', display_name)
            local count_text = string.format('%d[%d]', count, inv_count)
            
            -- Build the numbers section with increment BEFORE count
            local numbers_section
            if increment_text ~= "" then
                numbers_section = string.format('%-7s%s', increment_text, count_text)
            else
                numbers_section = string.format('%7s%s', "", count_text)
            end
            local numbers_padded = string.format('%' .. numbers_width .. 's', numbers_section)
            
            text = text .. color_start .. base_text .. increment_color .. numbers_padded .. '\\cr\n'
        end
    end
    
    -- Gil section (only show if any gil obtained)
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        if has_content then
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        else
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        end
        has_content = true
        
        local color_start = '\\cs(255,255,255)'  -- Default white
        if item_drop_times["Gil"] then
            local time_since_drop = os.time() - item_drop_times["Gil"]
            if time_since_drop <= GREEN_DURATION then
                color_start = '\\cs(0,255,0)'  -- Green
            end
        end
        
        -- Check for recent gil increment
        local increment_text = ""
        if recent_increments["Gil"] then
            local time_since_increment = os.time() - recent_increments["Gil"].time
            if time_since_increment <= GREEN_DURATION then
                increment_text = "(+" .. recent_increments["Gil"].amount .. ")"
            else
                recent_increments["Gil"] = nil
            end
        end
        
        -- Format with fixed positions
        local base_text = string.format('%-' .. column_width .. 's', 'Gil:')
        local numbers_section
        if increment_text ~= "" then
            numbers_section = string.format('%-10s%d', increment_text, gil)
        else
            numbers_section = tostring(gil)
        end
        local numbers_padded = string.format('%' .. numbers_width .. 's', numbers_section)
        
        text = text .. color_start .. base_text .. numbers_padded .. '\\cr\n'
    end
    
    -- Key Items section (LAST)
    local sorted_keys = {}
    for item_name, _ in pairs(key_items) do
        table.insert(sorted_keys, item_name)
    end
    
    if #sorted_keys > 0 then
        if has_content then
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        else
            text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width + numbers_width) .. '\\cr\n'
        end
        text = text .. '\\cs(255,255,255)Key Items:\\cr\n'
        has_content = true
        
        sorted_keys = sort_items_alphabetically(sorted_keys)
        
        local current_time = os.time()
        
        for _, item_name in ipairs(sorted_keys) do
            -- Remove "Key Item: " prefix for display
            local display_name = item_name:gsub("^Key Item:%s*", "")
            
            -- Key items are always blue
            local color_start = '\\cs(0,150,255)'  -- Blue for key items
            if key_drop_times[item_name] then
                local time_since_drop = current_time - key_drop_times[item_name]
                if time_since_drop <= GREEN_DURATION then
                    color_start = '\\cs(0,255,0)'  -- Green overrides blue
                else
                    -- Clean up old entries
                    key_drop_times[item_name] = nil
                end
            end
            
            -- Format without any numbers
            local base_text = string.format('%-' .. column_width .. 's', display_name)
            
            text = text .. color_start .. base_text .. '\\cr\n'
        end
    end
    
    display:text(text)
    -- Ensure the display is draggable
    display:draggable(true)
end

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
        windower.add_to_chat(207, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to add gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(207, 'Counter: Gil is automatically tracked and cannot be manually added.')
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
        windower.add_to_chat(207, 'Counter: "' .. full_name .. '" is already being tracked.')
        return
    end
    
    -- Don't allow manual adding of ammo - it's auto-detected from equipped
    if is_ammo_item(full_name) then
        windower.add_to_chat(207, 'Counter: Ammo is automatically tracked when equipped. Cannot manually add.')
        return
    end
    
    -- Determine category based on item type
    if is_usable_item(full_name) then
        -- Add to usable items
        usable_items[full_name] = true
        windower.add_to_chat(207, 'Counter: Now tracking "' .. full_name .. '" as a usable item.')
    else
        -- Add to regular tracked items
        tracked_items[full_name] = true
        item_counts[full_name] = 0
        windower.add_to_chat(207, 'Counter: Now tracking "' .. full_name .. '".')
    end
    
    save_settings()
    update_display()
end

-- Remove item from tracking list
local function remove_item(item_name)
    if not item_name or item_name == '' then
        windower.add_to_chat(207, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to remove gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(207, 'Counter: Gil cannot be manually removed.')
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
        windower.add_to_chat(207, 'Counter: Stopped tracking "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif usable_items[full_name] then
        usable_items[full_name] = nil
        usable_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(207, 'Counter: Stopped tracking usable item "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif ammo_items[full_name] then
        windower.add_to_chat(207, 'Counter: Cannot manually remove equipped ammo. Unequip it to stop tracking.')
    elseif personal_items[full_name] then
        personal_items[full_name] = nil
        personal_counts[full_name] = nil
        personal_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(207, 'Counter: Stopped tracking personal item "' .. full_name .. '".')
        save_settings()
        update_display()
    elseif key_items[full_name] then
        key_items[full_name] = nil
        key_drop_times[full_name] = nil
        windower.add_to_chat(207, 'Counter: Stopped tracking key item "' .. full_name .. '".')
        save_settings()
        update_display()
    else
        windower.add_to_chat(207, 'Counter: "' .. full_name .. '" is not being tracked.')
    end
end

-- Reset count for a specific item
local function reset_item(item_name)
    if not item_name or item_name == '' then
        windower.add_to_chat(207, 'Counter: Please specify an item name.')
        return
    end
    
    -- Check if trying to reset gil
    if item_name:lower() == 'gil' then
        windower.add_to_chat(207, 'Counter: Use "//cnt gil reset" to reset gil.')
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
        windower.add_to_chat(207, 'Counter: Reset count for "' .. full_name .. '" to 0.')
        save_settings()
        update_display()
    elseif personal_items[full_name] then
        personal_counts[full_name] = 0
        personal_drop_times[full_name] = nil
        recent_increments[full_name] = nil
        windower.add_to_chat(207, 'Counter: Reset count for personal item "' .. full_name .. '" to 0.')
        save_settings()
        update_display()
    else
        windower.add_to_chat(207, 'Counter: "' .. full_name .. '" is not being tracked with a counter.')
    end
end

-- List all tracked items
local function list_items()
    windower.add_to_chat(207, 'Counter: Currently tracking:')
    
    -- Show usable items
    if next(usable_items) then
        windower.add_to_chat(207, '  Usable Items:')
        local sorted_usable = {}
        for item_name, _ in pairs(usable_items) do
            table.insert(sorted_usable, item_name)
        end
        sorted_usable = sort_items_alphabetically(sorted_usable)
        
        for i, item_name in ipairs(sorted_usable) do
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(207, string.format('    %d. %s (Inventory: %d)', i, item_name, inv_count))
        end
    end
    
    -- Show ammo
    if next(ammo_items) then
        windower.add_to_chat(207, '  Equipped Ammo:')
        local sorted_ammo = {}
        for item_name, _ in pairs(ammo_items) do
            table.insert(sorted_ammo, item_name)
        end
        sorted_ammo = sort_items_alphabetically(sorted_ammo)
        
        for i, item_name in ipairs(sorted_ammo) do
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(207, string.format('    %d. %s (Inventory: %d)', i, item_name, inv_count))
        end
    end
    
    -- Show dropped items
    if next(tracked_items) then
        windower.add_to_chat(207, '  Item Drops:')
        local sorted_drops = {}
        for item_name, _ in pairs(tracked_items) do
            table.insert(sorted_drops, item_name)
        end
        sorted_drops = sort_items_alphabetically(sorted_drops)
        
        for i, item_name in ipairs(sorted_drops) do
            local item_count = item_counts[item_name] or 0
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(207, string.format('    %d. %s (Count: %d, Inventory: %d)', i, item_name, item_count, inv_count))
        end
    end
    
    -- Show personal drops
    if next(personal_items) then
        windower.add_to_chat(207, '  Personal Drops:')
        local sorted_personal = {}
        for item_name, _ in pairs(personal_items) do
            table.insert(sorted_personal, item_name)
        end
        sorted_personal = sort_items_alphabetically(sorted_personal)
        
        for i, item_name in ipairs(sorted_personal) do
            local item_count = personal_counts[item_name] or 0
            local inv_count = get_inventory_count(item_name)
            windower.add_to_chat(207, string.format('    %d. %s (Count: %d, Inventory: %d)', i, item_name, item_count, inv_count))
        end
    end
    
    -- Show gil
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        windower.add_to_chat(207, '  Gil: ' .. gil)
    end
    
    -- Show key items
    if next(key_items) then
        windower.add_to_chat(207, '  Key Items:')
        local sorted_keys = {}
        for item_name, _ in pairs(key_items) do
            table.insert(sorted_keys, item_name)
        end
        sorted_keys = sort_items_alphabetically(sorted_keys)
        
        for i, item_name in ipairs(sorted_keys) do
            local display_name = item_name:gsub("^Key Item:%s*", "")
            windower.add_to_chat(207, string.format('    %d. %s', i, display_name))
        end
    end
end

-- Save current tracked items as a set
local function save_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(207, 'Counter: Please specify a set name.')
        return
    end
    
    -- Check if there are items to save
    local count = 0
    for _ in pairs(tracked_items) do
        count = count + 1
    end
    
    if count == 0 then
        windower.add_to_chat(207, 'Counter: No items to save. Add items before creating a set.')
        return
    end
    
    -- Save the current tracked items
    saved_sets[set_name] = {}
    for item, _ in pairs(tracked_items) do
        saved_sets[set_name][item] = true
    end
    
    windower.add_to_chat(207, 'Counter: Saved set "' .. set_name .. '" with ' .. count .. ' items.')
    save_settings()
end

-- Load a saved set
local function load_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(207, 'Counter: Please specify a set name.')
        return
    end
    
    if not saved_sets[set_name] then
        windower.add_to_chat(207, 'Counter: Set "' .. set_name .. '" not found.')
        return
    end
    
    -- Clear current tracking
    tracked_items = {}
    item_drop_times = {}
    recent_increments = {}
    
    -- Load the set
    local count = 0
    for item, _ in pairs(saved_sets[set_name]) do
        tracked_items[item] = true
        if not item_counts[item] then
            item_counts[item] = 0
        end
        count = count + 1
    end
    
    windower.add_to_chat(207, 'Counter: Loaded set "' .. set_name .. '" with ' .. count .. ' items.')
    save_settings()
    update_display()
end

-- List all saved sets
local function list_sets()
    windower.add_to_chat(207, 'Counter: Saved sets:')
    
    -- Create a sorted list of set names
    local sorted_sets = {}
    for set_name, _ in pairs(saved_sets) do
        table.insert(sorted_sets, set_name)
    end
    table.sort(sorted_sets)
    
    if #sorted_sets > 0 then
        for i, set_name in ipairs(sorted_sets) do
            local item_count = 0
            for _ in pairs(saved_sets[set_name]) do
                item_count = item_count + 1
            end
            windower.add_to_chat(207, '  ' .. i .. '. ' .. set_name .. ' (' .. item_count .. ' items)')
        end
    else
        windower.add_to_chat(207, '  No saved sets.')
    end
end

-- Delete a saved set
local function delete_set(set_name)
    if not set_name or set_name == '' then
        windower.add_to_chat(207, 'Counter: Please specify a set name.')
        return
    end
    
    if saved_sets[set_name] then
        saved_sets[set_name] = nil
        windower.add_to_chat(207, 'Counter: Deleted set "' .. set_name .. '".')
        save_settings()
    else
        windower.add_to_chat(207, 'Counter: Set "' .. set_name .. '" not found.')
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
        windower.add_to_chat(207, string.format('DEBUG ALL: Mode=%d, Message=%s', mode, message))
    end
    
    -- Strip formatting for all messages
    local clean_message = strip_format(message)
    
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
                windower.add_to_chat(207, string.format('Counter DEBUG: Found personal drop: "%s" -> "%s"', obtained_item, item_name))
            end
            
            -- Check if it's a key item
            if item_name:find("^Key Item:") then
                if not key_items[item_name] then
                    key_items[item_name] = true
                    key_drop_times[item_name] = os.time()
                    windower.add_to_chat(207, 'Counter: Key item obtained - ' .. item_name:gsub("^Key Item:%s*", "") .. '!')
                end
            -- Check if it's a usable item
            elseif auto_add_usable and is_usable_item(item_name) then
                if not usable_items[item_name] then
                    usable_items[item_name] = true
                    usable_drop_times[item_name] = os.time()
                    track_increment(item_name, 1)
                    windower.add_to_chat(207, 'Counter: Usable item obtained - ' .. item_name .. '!')
                end
            else
                -- Regular personal item
                if not personal_items[item_name] then
                    personal_items[item_name] = true
                end
                
                personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
                personal_drop_times[item_name] = os.time()
                track_increment(item_name, 1)
                windower.add_to_chat(207, 'Counter: Personal drop - ' .. item_name .. '! Total: ' .. personal_counts[item_name])
            end
            
            save_settings()
            update_display()
            return
        end
    end
    
    -- Special handling for mode 127 (drops)
    if mode == 127 then
        if debug_mode then
            windower.add_to_chat(207, string.format('Counter DEBUG: Mode 127 detected!'))
            windower.add_to_chat(207, string.format('Counter DEBUG: Cleaned message: "%s"', clean_message))
            if player_name then
                windower.add_to_chat(207, string.format('Counter DEBUG: Tracking drops for: %s', player_name))
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
                        windower.add_to_chat(207, 'Counter: Gained ' .. gil_amount .. ' gil! Total: ' .. item_counts["Gil"])
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
                        windower.add_to_chat(207, string.format('Counter DEBUG: Drop by %s ignored (not %s)', player, player_name))
                    end
                    return
                end
                
                -- Remove any trailing punctuation or whitespace
                item_match = item_match:gsub("[%.!%?]+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                
                -- Normalize the item name
                local normalized_item = normalize_item_name(item_match)
                
                if debug_mode then
                    windower.add_to_chat(207, string.format('Counter DEBUG: Found - Player: "%s", Item: "%s" -> "%s"', player, item_match, normalized_item))
                end
                
                -- Check if it's a usable item and auto-add is on
                if auto_add_usable and is_usable_item(normalized_item) and not usable_items[normalized_item] then
                    usable_items[normalized_item] = true
                    usable_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    windower.add_to_chat(207, 'Counter: Auto-added "' .. normalized_item .. '" to usable items.')
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
                        windower.add_to_chat(207, 'Counter: Auto-added ammo "' .. normalized_item .. '" to item drops.')
                    else
                        tracked_items[normalized_item] = true
                        item_counts[normalized_item] = 0
                        windower.add_to_chat(207, 'Counter: Auto-added "' .. normalized_item .. '" to tracking list.')
                    end
                end
                
                -- Check if we're tracking this item
                if tracked_items[normalized_item] then
                    item_counts[normalized_item] = (item_counts[normalized_item] or 0) + 1
                    item_drop_times[normalized_item] = os.time()  -- Record drop time for color
                    track_increment(normalized_item, 1)
                    windower.add_to_chat(207, 'Counter: ' .. normalized_item .. ' dropped! Total: ' .. item_counts[normalized_item])
                    save_settings()
                    update_display()
                elseif usable_items[normalized_item] then
                    usable_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    windower.add_to_chat(207, 'Counter: Usable item ' .. normalized_item .. ' dropped!')
                    save_settings()
                    update_display()
                elseif ammo_items[normalized_item] then
                    ammo_drop_times[normalized_item] = os.time()
                    track_increment(normalized_item, 1)
                    windower.add_to_chat(207, 'Counter: Ammo ' .. normalized_item .. ' dropped!')
                    save_settings()
                    update_display()
                else
                    if debug_mode then
                        windower.add_to_chat(207, 'Counter DEBUG: Item "' .. normalized_item .. '" not in tracking list')
                        windower.add_to_chat(207, 'Counter DEBUG: Tracked items:')
                        for tracked, _ in pairs(tracked_items) do
                            windower.add_to_chat(207, '  - "' .. tracked .. '"')
                        end
                    end
                end
            elseif debug_mode then
                windower.add_to_chat(207, 'Counter DEBUG: Failed to parse obtain message')
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
            get_player_name()
            if player_name then
                windower.add_to_chat(207, 'Counter: Now tracking drops for ' .. player_name)
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
                            windower.add_to_chat(207, 'Counter: Auto-add for drops is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_drop = false
                            windower.add_to_chat(207, 'Counter: Auto-add for drops is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(207, 'Counter: Use "//counter auto drop on" or "//counter auto drop off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(207, 'Counter: Auto-add for drops is currently ' .. color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'usable' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_usable = true
                            windower.add_to_chat(207, 'Counter: Auto-add for usable items is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_usable = false
                            windower.add_to_chat(207, 'Counter: Auto-add for usable items is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(207, 'Counter: Use "//counter auto usable on" or "//counter auto usable off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(207, 'Counter: Auto-add for usable items is currently ' .. color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'gil' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_gil = true
                            windower.add_to_chat(207, 'Counter: Auto-add for gil is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_gil = false
                            windower.add_to_chat(207, 'Counter: Auto-add for gil is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(207, 'Counter: Use "//counter auto gil on" or "//counter auto gil off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(207, 'Counter: Auto-add for gil is currently ' .. color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'personal' or category == 'obtain' then  -- Support both for backward compatibility
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_personal = true
                            windower.add_to_chat(207, 'Counter: Auto-add for personal drops is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_personal = false
                            windower.add_to_chat(207, 'Counter: Auto-add for personal drops is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(207, 'Counter: Use "//counter auto personal on" or "//counter auto personal off".')
                        end
                        save_settings()
                        update_display()
                    else
                        local color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(207, 'Counter: Auto-add for personal drops is currently ' .. color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                elseif category == 'all' then
                    if setting then
                        setting = setting:lower()
                        if setting == 'on' then
                            auto_add_drop = true
                            auto_add_gil = true
                            auto_add_personal = true
                            auto_add_usable = true
                            windower.add_to_chat(207, 'Counter: Auto-add for all categories is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_drop = false
                            auto_add_gil = false
                            auto_add_personal = false
                            auto_add_usable = false
                            windower.add_to_chat(207, 'Counter: Auto-add for all categories is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(207, 'Counter: Use "//counter auto all on" or "//counter auto all off".')
                        end
                        save_settings()
                        update_display()
                    else
                        windower.add_to_chat(207, 'Counter: Auto-add status:')
                        local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(207, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(207, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(207, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(207, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                else
                    windower.add_to_chat(207, 'Counter: Valid auto categories: drop, usable, gil, personal, all')
                    windower.add_to_chat(207, 'Counter: Example: "//counter auto drop on" or "//counter auto all off"')
                end
            else
                windower.add_to_chat(207, 'Counter: Auto-add status:')
                local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                windower.add_to_chat(207, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(207, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(207, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(207, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(207, 'Counter: Use "//counter auto <category> on/off" where category is: drop, usable, gil, personal, or all')
            end
        elseif command == 'ammo' then
            -- For ammo, just show what's currently equipped
            windower.add_to_chat(207, 'Counter: Equipped Ammo:')
            if next(ammo_items) then
                for item_name, _ in pairs(ammo_items) do
                    local inv_count = get_inventory_count(item_name)
                    windower.add_to_chat(207, string.format('  %s (Inventory: %d)', item_name, inv_count))
                end
            else
                windower.add_to_chat(207, '  No ammo currently equipped.')
            end
            windower.add_to_chat(207, 'Counter: Ammo is automatically tracked when equipped.')
        elseif command == 'gil' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    item_counts["Gil"] = 0
                    item_drop_times["Gil"] = nil
                    recent_increments["Gil"] = nil
                    windower.add_to_chat(207, 'Counter: Gil reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    item_counts["Gil"] = 0
                    item_drop_times["Gil"] = nil
                    recent_increments["Gil"] = nil
                    windower.add_to_chat(207, 'Counter: Gil cleared.')
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(207, 'Counter: Unknown gil command. Use "reset" or "clear".')
                end
            else
                local gil = item_counts["Gil"] or 0
                windower.add_to_chat(207, 'Counter: Gil obtained: ' .. gil)
            end
        elseif command == 'use' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'clear' then
                    usable_items = {}
                    usable_drop_times = {}
                    -- Clear increments for usable items
                    for item, _ in pairs(recent_increments) do
                        if usable_items[item] then
                            recent_increments[item] = nil
                        end
                    end
                    windower.add_to_chat(207, 'Counter: Usable items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(207, 'Counter: Usable Items:')
                    local sorted = {}
                    for item_name, _ in pairs(usable_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(207, string.format('  %d. %s (Inventory: %d)', i, item_name, inv_count))
                        end
                    else
                        windower.add_to_chat(207, '  No usable items tracked.')
                    end
                else
                    windower.add_to_chat(207, 'Counter: Unknown use command. Use "clear" or "list".')
                end
            else
                -- Show usable list
                windower.add_to_chat(207, 'Counter: Usable Items:')
                local sorted = {}
                for item_name, _ in pairs(usable_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(207, string.format('  %d. %s (Inventory: %d)', i, item_name, inv_count))
                    end
                else
                    windower.add_to_chat(207, '  No usable items tracked.')
                end
            end
        elseif command == 'key' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'clear' then
                    key_items = {}
                    key_drop_times = {}
                    windower.add_to_chat(207, 'Counter: Key items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(207, 'Counter: Key Items:')
                    local sorted = {}
                    for item_name, _ in pairs(key_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local display_name = item_name:gsub("^Key Item:%s*", "")
                            windower.add_to_chat(207, string.format('  %d. %s', i, display_name))
                        end
                    else
                        windower.add_to_chat(207, '  No key items tracked.')
                    end
                else
                    windower.add_to_chat(207, 'Counter: Unknown key command. Use "clear" or "list".')
                end
            else
                -- Show key list
                windower.add_to_chat(207, 'Counter: Key Items:')
                local sorted = {}
                for item_name, _ in pairs(key_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local display_name = item_name:gsub("^Key Item:%s*", "")
                        windower.add_to_chat(207, string.format('  %d. %s', i, display_name))
                    end
                else
                    windower.add_to_chat(207, '  No key items tracked.')
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
                    windower.add_to_chat(207, 'Counter: All dropped item counts reset to 0.')
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
                    windower.add_to_chat(207, 'Counter: Dropped items list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(207, 'Counter: Item Drops:')
                    local sorted = {}
                    for item_name, _ in pairs(tracked_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local count = item_counts[item_name] or 0
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(207, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                        end
                    else
                        windower.add_to_chat(207, '  No items tracked.')
                    end
                else
                    windower.add_to_chat(207, 'Counter: Unknown drop command. Use "reset", "clear", or "list".')
                end
            else
                -- Show drop list
                windower.add_to_chat(207, 'Counter: Item Drops:')
                local sorted = {}
                for item_name, _ in pairs(tracked_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local count = item_counts[item_name] or 0
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(207, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                    end
                else
                    windower.add_to_chat(207, '  No items tracked.')
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
                    windower.add_to_chat(207, 'Counter: All personal drop counts reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    personal_items = {}
                    personal_counts = {}
                    personal_drop_times = {}
                    -- Clear increments for personal items
                    for item, _ in pairs(recent_increments) do
                        if personal_items[item] then
                            recent_increments[item] = nil
                        end
                    end
                    windower.add_to_chat(207, 'Counter: Personal drops list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(207, 'Counter: Personal Drops:')
                    local sorted = {}
                    for item_name, _ in pairs(personal_items) do
                        table.insert(sorted, item_name)
                    end
                    sorted = sort_items_alphabetically(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local count = personal_counts[item_name] or 0
                            local inv_count = get_inventory_count(item_name)
                            windower.add_to_chat(207, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                        end
                    else
                        windower.add_to_chat(207, '  No personal drops.')
                    end
                else
                    windower.add_to_chat(207, 'Counter: Unknown personal command. Use "reset", "clear", or "list".')
                end
            else
                -- Show personal list
                windower.add_to_chat(207, 'Counter: Personal Drops:')
                local sorted = {}
                for item_name, _ in pairs(personal_items) do
                    table.insert(sorted, item_name)
                end
                sorted = sort_items_alphabetically(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local count = personal_counts[item_name] or 0
                        local inv_count = get_inventory_count(item_name)
                        windower.add_to_chat(207, string.format('  %d. %s: %d (Inventory: %d)', i, item_name, count, inv_count))
                    end
                else
                    windower.add_to_chat(207, '  No personal drops.')
                end
            end
        elseif command == 'add' then
            local item_name = table.concat(args, ' ')
            add_item(item_name)
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
            windower.add_to_chat(207, 'Counter: All lists cleared.')
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
                windower.add_to_chat(207, 'Counter: All counters reset to 0.')
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
        elseif command == 'debug' then
            debug_mode = not debug_mode
            debug_all = false
            windower.add_to_chat(207, 'Counter: Debug mode ' .. (debug_mode and 'ON' or 'OFF'))
        elseif command == 'debugall' then
            debug_all = not debug_all
            debug_mode = false
            windower.add_to_chat(207, 'Counter: Debug ALL mode ' .. (debug_all and 'ON - showing all messages' or 'OFF'))
        elseif command == 'testpersonal' or command == 'testobtain' then  -- Support both
            -- Test command to manually add a personal drop
            local item_name = table.concat(args, ' ')
            if item_name ~= '' then
                item_name = normalize_item_name(item_name)
                personal_items[item_name] = true
                personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
                personal_drop_times[item_name] = os.time()
                track_increment(item_name, 1)
                windower.add_to_chat(207, 'Counter: TEST - Added personal drop ' .. item_name .. '. Total: ' .. personal_counts[item_name])
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
                windower.add_to_chat(207, 'Counter: TEST - Added ' .. amount .. ' gil. Total: ' .. item_counts["Gil"])
                save_settings()
                update_display()
            else
                windower.add_to_chat(207, 'Counter: TEST - Please specify an amount: //cnt testgil 100')
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
                    windower.add_to_chat(207, 'Counter: TEST - Incremented ' .. full_name .. ' to ' .. item_counts[full_name])
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(207, 'Counter: TEST - Item "' .. full_name .. '" not tracked')
                end
            end
        elseif command == 'show' then
            display:show()
            windower.add_to_chat(207, 'Counter: Display shown.')
        elseif command == 'hide' then
            display:hide()
            windower.add_to_chat(207, 'Counter: Display hidden.')
        elseif command == 'help' then
            windower.add_to_chat(207, '=== Counter Commands ===')
            windower.add_to_chat(207, '  //counter add <item name> - Add item to tracking (auto-categorized)')
            windower.add_to_chat(207, '  //counter remove <item name> - Remove item from tracking')
            windower.add_to_chat(207, '  //counter list - List all tracked items in chat')
            windower.add_to_chat(207, '  //counter clear - Clear all lists')
            windower.add_to_chat(207, '  //counter reset - Reset all counters to 0')
            windower.add_to_chat(207, '  //counter reset <item name> - Reset specific item counter to 0')
            windower.add_to_chat(207, '  //counter resetitem <item name> - Reset specific item counter to 0')
            windower.add_to_chat(207, '  //counter auto - Show auto-add status for all categories')
            windower.add_to_chat(207, '  //counter auto drop on/off - Toggle auto-add for drops')
            windower.add_to_chat(207, '  //counter auto usable on/off - Toggle auto-add for usable items')
            windower.add_to_chat(207, '  //counter auto gil on/off - Toggle auto-add for gil')
            windower.add_to_chat(207, '  //counter auto personal on/off - Toggle auto-add for personal drops')
            windower.add_to_chat(207, '  //counter auto all on/off - Toggle auto-add for all categories')
            windower.add_to_chat(207, '  //counter gil - Show gil total')
            windower.add_to_chat(207, '  //counter gil reset/clear - Reset/clear gil')
            windower.add_to_chat(207, '  //counter use - Show usable items')
            windower.add_to_chat(207, '  //counter use clear/list - Manage usable items')
            windower.add_to_chat(207, '  //counter ammo - Show equipped ammo')
            windower.add_to_chat(207, '  //counter drop - Show dropped items')
            windower.add_to_chat(207, '  //counter drop reset/clear/list - Manage dropped items')
            windower.add_to_chat(207, '  //counter personal - Show personal drops')
            windower.add_to_chat(207, '  //counter personal reset/clear/list - Manage personal drops')
            windower.add_to_chat(207, '  //counter key - Show key items')
            windower.add_to_chat(207, '  //counter key clear/list - Manage key items')
            windower.add_to_chat(207, '  //counter addset <name> - Save current tracking list as a set')
            windower.add_to_chat(207, '  //counter set <name> - Load a saved set')
            windower.add_to_chat(207, '  //counter listsets - List all saved sets')
            windower.add_to_chat(207, '  //counter deleteset <name> - Delete a saved set')
            windower.add_to_chat(207, '  //counter debug - Toggle debug mode for obtain messages')
            windower.add_to_chat(207, '  //counter debugall - Show ALL chat messages (warning: spammy!)')
            windower.add_to_chat(207, '  //counter test <item name> - Manually increment counter')
            windower.add_to_chat(207, '  //counter testpersonal <item name> - Test personal drop')
            windower.add_to_chat(207, '  //counter testgil <amount> - Test gil addition')
            windower.add_to_chat(207, '  //counter show - Show the display window')
            windower.add_to_chat(207, '  //counter hide - Hide the display window')
            windower.add_to_chat(207, '  //counter help - Show this help message')
            windower.add_to_chat(207, '  Note: You can also use //cnt instead of //counter')
            windower.add_to_chat(207, '  Note: Usable items appear in magenta, ammo in yellow, key items in blue')
            windower.add_to_chat(207, '  Note: Items are sorted alphabetically within each category')
            windower.add_to_chat(207, '  Note: Ammo is automatically tracked when equipped')
        else
            windower.add_to_chat(207, 'Counter: Unknown command "' .. command .. '". Use //counter help for commands.')
        end
    else
        windower.add_to_chat(207, 'Counter: Use //counter help for commands.')
    end
end)

-- Load settings on startup
if load_settings() then
    local count = 0
    for _ in pairs(tracked_items) do
        count = count + 1
    end
    if count > 0 then
        windower.add_to_chat(207, 'Counter: Loaded ' .. count .. ' tracked items from previous session.')
    end
    
    local usable_count = 0
    for _ in pairs(usable_items) do
        usable_count = usable_count + 1
    end
    if usable_count > 0 then
        windower.add_to_chat(207, 'Counter: Loaded ' .. usable_count .. ' usable items from previous session.')
    end
    
    local personal_count = 0
    for _ in pairs(personal_items) do
        personal_count = personal_count + 1
    end
    if personal_count > 0 then
        windower.add_to_chat(207, 'Counter: Loaded ' .. personal_count .. ' personal drops from previous session.')
    end
    
    local key_count = 0
    for _ in pairs(key_items) do
        key_count = key_count + 1
    end
    if key_count > 0 then
        windower.add_to_chat(207, 'Counter: Loaded ' .. key_count .. ' key items from previous session.')
    end
    
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        windower.add_to_chat(207, 'Counter: Loaded gil total: ' .. gil)
    end
    
    -- Show auto-add status with colors
    windower.add_to_chat(207, 'Counter: Auto-add status:')
    local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local usable_color = auto_add_usable and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    windower.add_to_chat(207, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(207, '  Usable: ' .. usable_color .. (auto_add_usable and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(207, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(207, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
end

-- Try to get player name on load
get_player_name()
if player_name then
    windower.add_to_chat(207, 'Counter: Tracking drops for ' .. player_name)
end

-- Check for equipped ammo on load
check_equipped_ammo()

-- Initialize display
update_display()

windower.add_to_chat(207, 'Counter loaded successfully! Use //counter help for commands.')
