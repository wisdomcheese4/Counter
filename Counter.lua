_addon.name = 'Counter'
_addon.author = 'wisdomcheese4'
_addon.version = '1.0'
_addon.commands = {'counter', 'cnt'}

-- Import necessary libraries
local texts = require('texts')
local files = require('files')

-- Initialize variables
local tracked_items = {}
local item_counts = {}
local saved_sets = {}
local settings_file = files.new('data/settings.lua')
local debug_mode = false
local debug_all = false
local player_name = nil

-- Separate auto-add settings for each category
local auto_add_drop = false
local auto_add_personal = true  -- Personal drops are auto-tracked by default
local auto_add_gil = true  -- Gil is always auto-tracked

-- Color tracking for recently dropped items
local item_drop_times = {}  -- Tracks when each item was last obtained
local GREEN_DURATION = 5    -- Seconds to stay green

-- Tables for personal drops (formerly obtained items)
local personal_items = {}
local personal_counts = {}
local personal_drop_times = {}

-- Track messages we've already processed to avoid duplicates
local processed_messages = {}
local message_cleanup_time = 0

-- Get player name
local function get_player_name()
    local player = windower.ffxi.get_player()
    if player then
        player_name = player.name
        return true
    end
    return false
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
    -- Save both old and new names for backward compatibility
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
    data = data .. '    auto_add_personal = ' .. tostring(auto_add_personal) .. '\n'
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
                -- Load personal items (check both old and new names)
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
                    auto_add_personal = data.auto_add_personal or data.auto_add_obtain or true  -- Check both names
                end
                return true
            end
        end
    end
    return false
end

-- Create display with nice formatting
local display = texts.new('')
display:pos(500, 300)
display:bg_alpha(200)
display:bg_visible(true)
display:font('Consolas', 11)
display:draggable(true)
display:show()

-- Update the display
local function update_display()
    -- Find the longest item name across all sections
    local max_item_len = 12  -- Start with minimum
    
    -- Check drop items
    for item_name, _ in pairs(tracked_items) do
        if #item_name > max_item_len then
            max_item_len = #item_name
        end
    end
    
    -- Check personal items
    for item_name, _ in pairs(personal_items) do
        if #item_name > max_item_len then
            max_item_len = #item_name
        end
    end
    
    -- Add some padding
    local column_width = max_item_len + 4
    
    -- Build display text with color codes
    local text = '\\cs(255,255,255)Item Counter:\\cr\n'
    text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width) .. '\\cr\n'
    
    -- Show player name if available
    if player_name then
        text = text .. '\\cs(255,255,255)Tracking: ' .. player_name .. '\\cr\n'
    end
    
    -- Show auto-add status vertically with colors, aligned right
    local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    
    text = text .. '\\cs(255,255,255)Auto-add:\\cr\n'
    text = text .. string.format('\\cs(255,255,255)%-' .. (column_width - 3) .. 's', '  Drop:') .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr\n'
    text = text .. string.format('\\cs(255,255,255)%-' .. (column_width - 3) .. 's', '  Personal:') .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr\n'
    text = text .. string.format('\\cs(255,255,255)%-' .. (column_width - 3) .. 's', '  Gil:') .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr\n'
    text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width) .. '\\cr\n'
    
    -- Item Drops section (moved before Gil)
    text = text .. '\\cs(255,255,255)Item Drops:\\cr\n'
    
    -- Create a sorted list of drop items
    local sorted_drops = {}
    for item_name, _ in pairs(tracked_items) do
        table.insert(sorted_drops, item_name)
    end
    table.sort(sorted_drops)
    
    -- Display drop items
    if #sorted_drops > 0 then
        local current_time = os.time()
        
        for _, item_name in ipairs(sorted_drops) do
            local count = item_counts[item_name] or 0
            
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
            
            -- Use string.format to ensure exact positioning
            text = text .. color_start .. string.format('%-' .. (column_width - 4) .. 's%4d', item_name, count) .. '\\cr\n'
        end
    else
        text = text .. '\\cs(255,255,255)No items tracked\\cr\n'
    end
    
    -- Personal Drops section
    text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width) .. '\\cr\n'
    text = text .. '\\cs(255,255,255)Personal Drops:\\cr\n'
    
    -- Create a sorted list of personal items
    local sorted_personal = {}
    for item_name, _ in pairs(personal_items) do
        table.insert(sorted_personal, item_name)
    end
    table.sort(sorted_personal)
    
    -- Display personal items
    if #sorted_personal > 0 then
        local current_time = os.time()
        
        for _, item_name in ipairs(sorted_personal) do
            local count = personal_counts[item_name] or 0
            
            -- Check if this item should be green
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
            
            -- Use same formatting as drop items for consistent alignment
            text = text .. color_start .. string.format('%-' .. (column_width - 4) .. 's%4d', item_name, count) .. '\\cr\n'
        end
    else
        text = text .. '\\cs(255,255,255)No personal drops\\cr\n'
    end
    
    -- Gil section last (always show if any gil obtained)
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        text = text .. '\\cs(255,255,255)' .. string.rep('─', column_width) .. '\\cr\n'
        local color_start = '\\cs(255,255,255)'  -- Default white
        if item_drop_times["Gil"] then
            local time_since_drop = os.time() - item_drop_times["Gil"]
            if time_since_drop <= GREEN_DURATION then
                color_start = '\\cs(0,255,0)'  -- Green
            end
        end
        text = text .. color_start .. string.format('%-' .. (column_width - 4) .. 's%4d', 'Gil:', gil) .. '\\cr\n'
    end
    
    display:text(text)
end

-- Normalize item name for consistent storage
local function normalize_item_name(item_name)
    -- Capitalize first letter of each word
    return item_name:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
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
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    if tracked_items[item_name] then
        windower.add_to_chat(207, 'Counter: "' .. item_name .. '" is already being tracked.')
    else
        tracked_items[item_name] = true
        item_counts[item_name] = 0
        windower.add_to_chat(207, 'Counter: Now tracking "' .. item_name .. '".')
        save_settings()
        update_display()
    end
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
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    if tracked_items[item_name] then
        tracked_items[item_name] = nil
        item_counts[item_name] = nil
        item_drop_times[item_name] = nil  -- Clean up drop time
        windower.add_to_chat(207, 'Counter: Stopped tracking "' .. item_name .. '".')
        save_settings()
        update_display()
    else
        windower.add_to_chat(207, 'Counter: "' .. item_name .. '" is not being tracked.')
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
    
    -- Normalize the item name
    item_name = normalize_item_name(item_name)
    
    if tracked_items[item_name] then
        item_counts[item_name] = 0
        item_drop_times[item_name] = nil  -- Clear color timer
        windower.add_to_chat(207, 'Counter: Reset count for "' .. item_name .. '" to 0.')
        save_settings()
        update_display()
    else
        windower.add_to_chat(207, 'Counter: "' .. item_name .. '" is not being tracked.')
    end
end

-- List all tracked items
local function list_items()
    windower.add_to_chat(207, 'Counter: Currently tracking:')
    
    -- Show dropped items
    windower.add_to_chat(207, '  Item Drops:')
    local sorted_drops = {}
    for item_name, _ in pairs(tracked_items) do
        table.insert(sorted_drops, item_name)
    end
    table.sort(sorted_drops)
    
    if #sorted_drops > 0 then
        for i, item_name in ipairs(sorted_drops) do
            local item_count = item_counts[item_name] or 0
            windower.add_to_chat(207, '    ' .. i .. '. ' .. item_name .. ' (Count: ' .. item_count .. ')')
        end
    else
        windower.add_to_chat(207, '    No items being tracked.')
    end
    
    -- Show personal drops
    windower.add_to_chat(207, '  Personal Drops:')
    local sorted_personal = {}
    for item_name, _ in pairs(personal_items) do
        table.insert(sorted_personal, item_name)
    end
    table.sort(sorted_personal)
    
    if #sorted_personal > 0 then
        for i, item_name in ipairs(sorted_personal) do
            local item_count = personal_counts[item_name] or 0
            windower.add_to_chat(207, '    ' .. i .. '. ' .. item_name .. ' (Count: ' .. item_count .. ')')
        end
    else
        windower.add_to_chat(207, '    No personal drops.')
    end
    
    -- Show gil last
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        windower.add_to_chat(207, '  Gil: ' .. gil)
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
    item_drop_times = {}  -- Clear all color timers
    
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
    -- Based on the hex dump: 1F XX and 1E XX are formatting codes
    text = text:gsub(string.char(0x1F)..'[%z\1-\255]', '')  -- Remove 1F + any byte
    text = text:gsub(string.char(0x1E)..'[%z\1-\255]', '')  -- Remove 1E + any byte
    text = text:gsub(string.char(0x7F)..'[%z\1-\255]', '')  -- Remove 7F + any byte
    
    -- Remove any other control characters
    text = text:gsub('%c', '')
    
    return text
end

-- Parse text for item drops
local function check_for_drops(message, mode)
    -- Skip our own messages and debug messages - CRITICAL: Must be at the very beginning
    if message:find("^Counter:") or message:find("^DEBUG ALL:") or message:find("^Counter DEBUG:") then
        return
    end
    
    -- Clean up old processed messages periodically
    local current_time = os.time()
    if current_time > message_cleanup_time + 60 then
        processed_messages = {}
        message_cleanup_time = current_time
    end
    
    -- Create a unique hash for this message to avoid duplicates
    local message_hash = message .. tostring(mode) .. tostring(current_time)
    if processed_messages[message_hash] then
        return
    end
    processed_messages[message_hash] = true
    
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
            obtained_item = obtained_item:gsub("%.+$", "")  -- Remove trailing periods
            obtained_item = obtained_item:gsub("!+$", "")   -- Remove trailing exclamations
            obtained_item = obtained_item:gsub("^%s+", "")  -- Remove leading spaces
            obtained_item = obtained_item:gsub("%s+$", "")  -- Remove trailing spaces
            
            -- Skip if it's empty or just punctuation
            if obtained_item == "" or obtained_item:match("^[%.!%s]+$") then
                return
            end
            
            local item_name = normalize_item_name(obtained_item)
            
            -- Only show debug if we're not already showing a Counter message
            if debug_mode and not message:find("^Counter:") then
                windower.add_to_chat(207, string.format('Counter DEBUG: Found personal drop: "%s" -> "%s"', obtained_item, item_name))
            end
            
            personal_items[item_name] = true
            personal_counts[item_name] = (personal_counts[item_name] or 0) + 1
            personal_drop_times[item_name] = os.time()
            windower.add_to_chat(207, 'Counter: Personal drop - ' .. item_name .. '! Total: ' .. personal_counts[item_name])
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
                
                -- Auto-add functionality for drops
                if auto_add_drop and not tracked_items[normalized_item] then
                    tracked_items[normalized_item] = true
                    item_counts[normalized_item] = 0
                    windower.add_to_chat(207, 'Counter: Auto-added "' .. normalized_item .. '" to tracking list.')
                end
                
                -- Check if we're tracking this item
                if tracked_items[normalized_item] then
                    item_counts[normalized_item] = (item_counts[normalized_item] or 0) + 1
                    item_drop_times[normalized_item] = os.time()  -- Record drop time for color
                    windower.add_to_chat(207, 'Counter: ' .. normalized_item .. ' dropped! Total: ' .. item_counts[normalized_item])
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
                            windower.add_to_chat(207, 'Counter: Auto-add for all categories is now \\cs(0,255,0)ON\\cr.')
                        elseif setting == 'off' then
                            auto_add_drop = false
                            auto_add_gil = false
                            auto_add_personal = false
                            windower.add_to_chat(207, 'Counter: Auto-add for all categories is now \\cs(255,0,0)OFF\\cr.')
                        else
                            windower.add_to_chat(207, 'Counter: Use "//counter auto all on" or "//counter auto all off".')
                        end
                        save_settings()
                        update_display()
                    else
                        windower.add_to_chat(207, 'Counter: Auto-add status:')
                        local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                        windower.add_to_chat(207, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(207, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                        windower.add_to_chat(207, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                    end
                    
                else
                    windower.add_to_chat(207, 'Counter: Valid auto categories: drop, gil, personal, all')
                    windower.add_to_chat(207, 'Counter: Example: "//counter auto drop on" or "//counter auto all off"')
                end
            else
                windower.add_to_chat(207, 'Counter: Auto-add status:')
                local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
                windower.add_to_chat(207, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(207, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(207, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
                windower.add_to_chat(207, 'Counter: Use "//counter auto <category> on/off" where category is: drop, gil, personal, or all')
            end
        elseif command == 'gil' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    item_counts["Gil"] = 0
                    item_drop_times["Gil"] = nil
                    windower.add_to_chat(207, 'Counter: Gil reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    item_counts["Gil"] = 0
                    item_drop_times["Gil"] = nil
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
        elseif command == 'drop' then
            local subcmd = args[1]
            if subcmd then
                subcmd = subcmd:lower()
                if subcmd == 'reset' then
                    for item in pairs(tracked_items) do
                        item_counts[item] = 0
                        item_drop_times[item] = nil
                    end
                    windower.add_to_chat(207, 'Counter: All dropped item counts reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    -- First clear the counts and timers
                    for item in pairs(tracked_items) do
                        item_counts[item] = nil
                        item_drop_times[item] = nil
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
                    table.sort(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local count = item_counts[item_name] or 0
                            windower.add_to_chat(207, '  ' .. i .. '. ' .. item_name .. ': ' .. count)
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
                table.sort(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local count = item_counts[item_name] or 0
                        windower.add_to_chat(207, '  ' .. i .. '. ' .. item_name .. ': ' .. count)
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
                    end
                    windower.add_to_chat(207, 'Counter: All personal drop counts reset to 0.')
                    save_settings()
                    update_display()
                elseif subcmd == 'clear' then
                    personal_items = {}
                    personal_counts = {}
                    personal_drop_times = {}
                    windower.add_to_chat(207, 'Counter: Personal drops list cleared.')
                    save_settings()
                    update_display()
                elseif subcmd == 'list' then
                    windower.add_to_chat(207, 'Counter: Personal Drops:')
                    local sorted = {}
                    for item_name, _ in pairs(personal_items) do
                        table.insert(sorted, item_name)
                    end
                    table.sort(sorted)
                    if #sorted > 0 then
                        for i, item_name in ipairs(sorted) do
                            local count = personal_counts[item_name] or 0
                            windower.add_to_chat(207, '  ' .. i .. '. ' .. item_name .. ': ' .. count)
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
                table.sort(sorted)
                if #sorted > 0 then
                    for i, item_name in ipairs(sorted) do
                        local count = personal_counts[item_name] or 0
                        windower.add_to_chat(207, '  ' .. i .. '. ' .. item_name .. ': ' .. count)
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
                for item in pairs(tracked_items) do
                    item_counts[item] = 0
                    item_drop_times[item] = nil
                end
                for item in pairs(personal_items) do
                    personal_counts[item] = 0
                    personal_drop_times[item] = nil
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
                item_name = normalize_item_name(item_name)
                if tracked_items[item_name] then
                    item_counts[item_name] = (item_counts[item_name] or 0) + 1
                    item_drop_times[item_name] = os.time()  -- Mark as recently dropped for color
                    windower.add_to_chat(207, 'Counter: TEST - Incremented ' .. item_name .. ' to ' .. item_counts[item_name])
                    save_settings()
                    update_display()
                else
                    windower.add_to_chat(207, 'Counter: TEST - Item "' .. item_name .. '" not tracked')
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
            windower.add_to_chat(207, '  //counter add <item name> - Add item to tracking')
            windower.add_to_chat(207, '  //counter remove <item name> - Remove item from tracking')
            windower.add_to_chat(207, '  //counter list - List all tracked items in chat')
            windower.add_to_chat(207, '  //counter clear - Clear all lists')
            windower.add_to_chat(207, '  //counter reset - Reset all counters to 0')
            windower.add_to_chat(207, '  //counter reset <item name> - Reset specific item counter to 0')
            windower.add_to_chat(207, '  //counter resetitem <item name> - Reset specific item counter to 0')
            windower.add_to_chat(207, '  //counter auto - Show auto-add status for all categories')
            windower.add_to_chat(207, '  //counter auto drop on/off - Toggle auto-add for drops')
            windower.add_to_chat(207, '  //counter auto gil on/off - Toggle auto-add for gil')
            windower.add_to_chat(207, '  //counter auto personal on/off - Toggle auto-add for personal drops')
            windower.add_to_chat(207, '  //counter auto all on/off - Toggle auto-add for all categories')
            windower.add_to_chat(207, '  //counter gil - Show gil total')
            windower.add_to_chat(207, '  //counter gil reset/clear - Reset/clear gil')
            windower.add_to_chat(207, '  //counter drop - Show dropped items')
            windower.add_to_chat(207, '  //counter drop reset/clear/list - Manage dropped items')
            windower.add_to_chat(207, '  //counter personal - Show personal drops')
            windower.add_to_chat(207, '  //counter personal reset/clear/list - Manage personal drops')
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
    
    local personal_count = 0
    for _ in pairs(personal_items) do
        personal_count = personal_count + 1
    end
    if personal_count > 0 then
        windower.add_to_chat(207, 'Counter: Loaded ' .. personal_count .. ' personal drops from previous session.')
    end
    
    local gil = item_counts["Gil"] or 0
    if gil > 0 then
        windower.add_to_chat(207, 'Counter: Loaded gil total: ' .. gil)
    end
    
    -- Show auto-add status with colors
    windower.add_to_chat(207, 'Counter: Auto-add status:')
    local drop_color = auto_add_drop and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local personal_color = auto_add_personal and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    local gil_color = auto_add_gil and '\\cs(0,255,0)' or '\\cs(255,0,0)'
    windower.add_to_chat(207, '  Drops: ' .. drop_color .. (auto_add_drop and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(207, '  Personal: ' .. personal_color .. (auto_add_personal and 'ON' or 'OFF') .. '\\cr')
    windower.add_to_chat(207, '  Gil: ' .. gil_color .. (auto_add_gil and 'ON' or 'OFF') .. '\\cr')
end

-- Try to get player name on load
get_player_name()
if player_name then
    windower.add_to_chat(207, 'Counter: Tracking drops for ' .. player_name)
end

-- Initialize display
update_display()

windower.add_to_chat(207, 'Counter loaded successfully! Use //counter help for commands.')
