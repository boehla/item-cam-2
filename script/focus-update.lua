local const = require("const")
local utility = require("utility")
local watchdog = require("focus-watchdog")
local transfer_to = require("focus-transfer")
local follow_rules = require("focus-follow-rules")
local skip_ahead = require("skip-ahead")

local handle_invalid_map = {}
local tick_map = {}
local environment_changed_map = {}

tick_map["item-on-ground"] = function ()
    -- The item on ground ponders why it got kicked from the factory group chat.
end
--- @param focus FocusInstance
handle_invalid_map["item-on-ground"] = function (focus)
    focus.watching = transfer_to.inserter_nearby(
        focus,
        focus.surface,
        nil,
        utility.aabb_around(focus.position, const.inserter_search_d),
        focus.position,
        focus.watching.item_wl,
        {swinging_towards = true, source = nil}
    )
end

--- @type table<string, fun(handle: LuaEntity): ((LuaEntity | LuaEntity[])[])>
local belt_advance_strategy = {
    ["transport-belt"] = function (handle)
        return {handle.belt_neighbours.outputs}
    end,
    ["splitter"] = function (handle)
        return {handle, handle.belt_neighbours.outputs}
    end,
    ["lane-splitter"] = function (handle)
        return {handle, handle.belt_neighbours.outputs}
    end,
    ["underground-belt"] = function (handle)
        if handle.belt_to_ground_type == "input" then
            return {handle, handle.underground_belt_neighbour}
        else
            return {handle, handle.belt_neighbours.outputs}
        end
    end,
    ["loader"] = function (handle)
        if handle.loader_type == "output" then
            return {handle.belt_neighbours.outputs}
        else
            return {handle.loader_container}
        end
    end,
    ["linked-belt"] = function (handle)
        if handle.linked_belt_type == "output" then
            return {handle.belt_neighbours.outputs}
        else
            return {handle.linked_belt_neighbour}
        end
    end
}
belt_advance_strategy["loader-1x1"] = belt_advance_strategy["loader"]

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemOnBelt
tick_map["item-on-belt"] = function (focus, handle, pin)
    --- @type LuaEntity?
    local next_belt = handle
    --- @type integer?
    local next_line_idx = pin.line_idx

    --- @param item DetailedItemOnLine
    local seek_fn = function (item)
        return item.unique_id == pin.id
    end

    local it = utility.first_on_line(handle.get_transport_line(pin.line_idx), seek_fn)
    if it ~= nil then
        pin.it = it
        local skipped_to = skip_ahead.belt_tick(focus, handle, pin)
        if skipped_to ~= nil then
            focus.watching = skipped_to
        end
        return
    end

    local advance_lookups = belt_advance_strategy[handle.type](handle)
    for _, lookup_entry in ipairs(advance_lookups) do
        if type(lookup_entry) == "nil" then
            -- noop
        elseif lookup_entry.type == nil then
            it, next_line_idx, next_belt = utility.first_on_belts(lookup_entry, seek_fn)
        elseif const.is_belt[lookup_entry.type] then
            it, next_line_idx = utility.first_on_belt(lookup_entry, seek_fn)
            next_belt = lookup_entry
        else
            -- Loader -> container
            focus.watching = transfer_to.next(focus, lookup_entry, focus.watching.item_wl)
            return
        end

        if it ~= nil then
            assert(next_belt, "advance didn't give next belt entity")
            assert(next_line_idx, "advance didn't give item line index")
            pin.it = it
            pin.line_idx = next_line_idx
            focus.watching.handle = next_belt
            return
        end
    end

    utility.debug("watchdog changing: can't find item on belt with my id")
    focus.watching = transfer_to.inserter_nearby(
        focus,
        handle.surface,
        handle.force,
        utility.aabb_around(focus.position, const.inserter_search_d),
        focus.position,
        focus.watching.item_wl,
        utility.__no_wl
    )
end

--- @param focus FocusInstance
--- @param handle LuaEntity
tick_map["item-in-inserter-hand"] = function (focus, handle)
    if handle.held_stack.valid_for_read then
        local skipped_to = skip_ahead.inserter_tick(focus, handle)
        if skipped_to ~= nil then
            focus.watching = skipped_to
        end
        return
    end

    utility.debug("watchdog changing: held_stack.valid_for_read false")

    local dropped_into = handle.drop_target
    if dropped_into == nil then
        focus.watching =
            transfer_to.item_on_ground(
                focus,
                handle.surface,
                handle.drop_position,
                focus.watching.item_wl
            ) or transfer_to.inserter_nearby(
                focus,
                handle.surface,
                nil,
                utility.aabb_around(handle.drop_position, const.inserter_search_d),
                handle.drop_position,
                focus.watching.item_wl,
                {swinging_towards = true, source = nil}
            )
        return
    end

    focus.watching = transfer_to.next(focus, dropped_into, focus.watching.item_wl)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
tick_map["item-in-container"] = function (focus, handle)
    if handle.train and handle.train.riding_state.acceleration ~= defines.riding.acceleration.nothing
        -- In moving train. Nothing to do
        then return end

    -- Always query if item got taken.
    -- inventory.get_item_count is expensive for huge space platform cargo
    local first_taken_by = transfer_to.taken_out_of_building(focus, handle, focus.watching.item_wl)
    if first_taken_by ~= nil then
        focus.watching =  first_taken_by
        return
    end

    -- Shared with robots, towers etc. which aren't stuck just because nothing was taken out yet
    local watching_type = focus.watching.type
    if watching_type == "item-in-container" or watching_type == "item-in-container-with-cargo-hatches" then
        local skipped_to = skip_ahead.building_tick(focus, handle, focus.watching.item_wl)
        if skipped_to ~= nil then
            focus.watching = skipped_to
        end
    end
end
local item_in_container = tick_map["item-in-container"]

--- Which products of a recipe with multiple outputs to follow, see setting "multiple-outputs"
--- @param focus FocusInstance
--- @param recipe_proto LuaRecipePrototype
--- @return string[]?
local function pick_crafter_products(focus, recipe_proto)
    local items = utility.products_filtered(recipe_proto.products, {items = true})
    if items == nil or #items == 1
        then return items end

    local mode = focus.multiple_outputs or settings.global[const.name_setting_multiple_outputs].value
    if mode == "first-out"
        then return items end

    local main = recipe_proto.main_product
    local main_name = main ~= nil and main.type == "item" and main.name or nil
    if mode == "new-item" and focus.seen_items ~= nil then
        if main_name ~= nil and not focus.seen_items[main_name]
            then return {main_name} end
        for _, name in ipairs(items) do
            if not focus.seen_items[name]
                then return {name} end
        end
    end
    if main_name ~= nil
        then return {main_name} end
    return items
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemInCraftingMachine
tick_map["item-in-crafting-machine"] = function (focus, handle, pin)
    if handle.products_finished == pin.initial_products_finished
        and not skip_ahead.is_output_backed_up(handle)
        then return end

    if not pin.announced_change then
        utility.debug("watchdog changing: products_finished increased")
        pin.announced_change = true
    end

    local item_wl = focus.watching.item_wl
    if item_wl == nil then
        local recipe_set = utility.crafter_recipe_proto(handle)
        if recipe_set == nil
            then return end
        local recipe_proto = prototypes.recipe[recipe_set.name]
        item_wl = {
            items = pick_crafter_products(focus, recipe_proto)
        }
        -- Recipe products don't change while we wait, no need to look them up every tick
        focus.watching.item_wl = item_wl
    end

    local has_drop_target = handle.prototype.vector_to_place_result ~= nil
    local first_taken_by = transfer_to.taken_out_of_building(focus, handle, item_wl, has_drop_target)
    if first_taken_by ~= nil then
        -- Crafting machine put its (first) output here
        focus.watching = first_taken_by
        return
    end

    local skipped_to = skip_ahead.building_tick(focus, handle, item_wl)
    if skipped_to ~= nil then
        focus.watching = skipped_to
    end
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemHeldByRobot
tick_map["item-held-by-robot"] = function (focus, handle, pin)
    local drop_target = pin.drop_target

    local order = handle.robot_order_queue[1]
    if order ~= nil and (
        order.target == drop_target
        or order.secondary_target == drop_target
    ) and const.all_deliver_robot_order[order.type]
        then return end

    utility.debug("watchdog changing: first robot order no longer deliver or target changed")

    if drop_target == nil or not drop_target.valid then
        utility.debug("watchdog lost: invalid drop_target")
        focus.watching.valid = false
        return
    end

    focus.watching =  transfer_to.next(focus, drop_target, focus.watching.item_wl)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemComingFromMiningDrill
tick_map["item-coming-from-mining-drill"] = function (focus, handle, pin)
    local mining_target = handle.mining_target
    if mining_target == nil or not mining_target.valid then
        utility.debug("watchdog lost: no more mining_target")
        focus.watching.valid = false
        return
    end

    if game.tick < pin.tick_should_mine
        then return true end

    local first_output = transfer_to.drop_target(focus, handle, focus.watching.item_wl)
    if first_output ~= nil then
        focus.watching =  first_output
    end
end

--- @param focus FocusInstance
--- @param handle LuaEntity
tick_map["item-in-rocket-silo"] = function (focus, handle)
    if handle.rocket ~= nil and handle.rocket_silo_status >= defines.rocket_silo_status.launch_starting then
        utility.debug("watchdog changing: rocket_silo_status launch_started")
        focus.watching = watchdog.create.item_in_rocket(handle.rocket, focus.watching.item_wl.item)
    end

    return item_in_container(focus, handle)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
tick_map["item-in-rocket"] = function (focus, handle)
    if handle.cargo_pod ~= nil and handle.cargo_pod.cargo_pod_state == "ascending" then
        utility.debug("watchdog changing: cargo_pod_state ascending")
        focus.watching = watchdog.create.item_in_cargo_pod(handle.cargo_pod, focus.watching.item_wl.item)
    end
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemInCargoPod
tick_map["item-in-cargo-pod"] = function (focus, handle, pin)
    if
        handle.cargo_pod_state ~= "parking"
        or (pin.drop_target ~= nil and pin.drop_target.valid)
    then
        return
    end

    local destination = handle.cargo_pod_destination
    if destination.type ~= defines.cargo_destination.station then
        utility.debug("watchdog lost: cargo_pod_destination is not station")
        focus.watching.valid = false
        return
    end

    local target = destination.station
    if target == nil then
        -- TODO: It drops as a container
        utility.debug("watchdog lost: station is nil")
        focus.watching.valid = false
        return
    end

    if target.type == "cargo-bay" then
        pin.drop_target = target.cargo_bay_connection_owner
    else
        pin.drop_target = target
    end
    utility.debug("watchdog updated: drop_target selected")

    -- The actual watchdog switch happens when cargo pod entity is destroyed
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemInCargoPod
handle_invalid_map["item-in-cargo-pod"] = function (focus, handle, pin)
    utility.debug("watchdog changing: handle got destroyed")
    focus.watching =  transfer_to.next(focus, pin.drop_target, focus.watching.item_wl)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
tick_map["item-in-container-with-cargo-hatches"] = function (focus, handle)
    -- The actual watchdog switch happens on environment_changed
    return item_in_container(focus, handle)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin nil
--- @param cause_entity LuaEntity
environment_changed_map["item-in-container-with-cargo-hatches"] = function (focus, handle, pin, cause_entity)
    if
        cause_entity.type ~= "cargo-pod"
        or cause_entity.cargo_pod_state ~= "awaiting_launch"
        or cause_entity.surface ~= handle.surface
        or cause_entity.cargo_pod_origin ~= handle
    then
        return
    end

    local inventory = cause_entity.get_inventory(defines.inventory.cargo_unit)
    assert(inventory, "cause_entity has no targeted inventory")

    local first_item = utility.first_item_stack_filtered(inventory, focus.watching.item_wl)
    if first_item == nil
        then return end

    focus.watching =  watchdog.create.item_in_cargo_pod(cause_entity, utility.item_proto(first_item))
end

--- @param focus FocusInstance
--- @param handle LuaEntity
tick_map["item-coming-from-asteroid-collector"] = function (focus, handle)
    -- It's basically a container
    return item_in_container(focus, handle)
end

tick_map["seed-in-agricultural-tower"] = function ()
    -- Waiting for tower to plant seed
end

--- If cause entity is new plant, check if tower we're watching owns it
--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin nil
--- @param cause_entity LuaEntity
environment_changed_map["seed-in-agricultural-tower"] = function (focus, handle, pin, cause_entity)
    if cause_entity.type ~= "plant"
        then return end
    if utility.contains(handle.owned_plants, cause_entity) then
        focus.watching = watchdog.create.plant_growing(cause_entity)
    end
end

--- @param focus FocusInstance
--- @param pin PinPlantGrowing
tick_map["plant-growing"] = function (focus, _, pin)
    -- Crane destination can immediately change on the tick our plant gets destroyed
    -- so we're going to remember their last known position
    for idx, tower_entity in ipairs(pin.last_tick_towers_nearby) do
        if not tower_entity.valid then
            table.remove(pin.last_tick_towers_nearby, idx)
            table.remove(pin.last_tick_crane_destinations, idx)
        else
            pin.last_tick_crane_destinations[idx] = tower_entity.crane_destination
        end
    end
end

--- @param handle LuaEntity
--- @param pin PinPlantGrowing
--- @param cause_entity LuaEntity
environment_changed_map["plant-growing"] = function (_, handle, pin, cause_entity)
    if cause_entity.type ~= "agricultural-tower"
        then return end

    -- This new tower might include our plant. Recompute last tick
    pin.last_tick_towers_nearby = utility.search_agricultural_towers_owning_plant(handle)
    pin.last_tick_crane_destinations = utility.mapped(pin.last_tick_towers_nearby, function (entry)
        return entry.crane_destination
    end)
end

--- @param focus FocusInstance
--- @param pin PinPlantGrowing
handle_invalid_map["plant-growing"] = function (focus, _, pin)
    local best_guess, best_idx = utility.minimum_of(pin.last_tick_towers_nearby, function (_, idx)
        utility.debug_pos(focus.surface, pin.last_tick_crane_destinations[idx], const.__dc_min_pass)

        return utility.sq_distance(pin.last_tick_crane_destinations[idx], focus.position), idx
    end)

    if best_guess == nil
        then return end
    utility.debug_pos(focus.surface, pin.last_tick_crane_destinations[best_idx], const.__dc_min_pick)

    -- transfer_to.next assumes the agricultural tower received a seed.
    -- Replicate a simple inserter-took-same-tick check that entities considered container would have
    focus.watching =
        transfer_to.inserter_nearby(
            focus,
            focus.surface,
            nil, -- Plants lose force
            utility.aabb_expand(best_guess.selection_box, const.inserter_search_d),
            best_guess.position,
            focus.watching.item_wl,
            {source = best_guess, swinging_towards = true}
        ) or watchdog.create.item_coming_from_agricultural_tower(best_guess)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
tick_map["item-coming-from-agricultural-tower"] = function (focus, handle)
    -- It's basically a container
    return item_in_container(focus, handle)
end

tick_map["end-lab"] = function ()
    -- End of the line
end

--- @param handle LuaEntity
--- @param pin PinUnit
tick_map["unit"] = function (_, handle, pin)
    if pin.highest_commandable ~= nil and not pin.highest_commandable.valid then
        pin.highest_commandable = nil
    end
    if pin.highest_commandable == nil and handle.commandable ~= nil then
        pin.highest_commandable = handle.commandable
    end
    local new_highest_commandable = pin.highest_commandable
    while new_highest_commandable.parent_group ~= nil do
        utility.debug("watchdog updated: walked to new parent commandable")
        new_highest_commandable = new_highest_commandable.parent_group
    end
    pin.highest_commandable = new_highest_commandable
end

--- @param focus FocusInstance
--- @param pin PinUnit
handle_invalid_map["unit"] = function (focus, _, pin)
    focus.watching.valid = false
    if pin.highest_commandable == nil
        then return end

    if not pin.highest_commandable.is_unit_group
        then return end
    utility.debug("watchdog changing: handle died")

    local next_unit_to_watch = utility.first(pin.highest_commandable.members, function (entry)
        return entry.valid and entry or nil
    end)
    if next_unit_to_watch == nil
        then return end

    utility.debug("watchdog changing: found next unit within commandable")
    focus.watching.valid = true
    focus.watching = watchdog.create.unit(next_unit_to_watch)
end

--- @class SmoothingDefinition
--- @field speed? number
--- @field min_speed? number
--- @field mul? number
--- @field ticks integer

--- @type SmoothingDefinition
local smooth_type_linear = {speed = 0.25, ticks = 60}
--- @type SmoothingDefinition
local smooth_type_jump = {min_speed = 0.1, mul = 0.1, ticks = 120}

--- @type table<string, SmoothingDefinition>
local map_smooth_speed_in = {
    -- container -> inserter
    ["item-in-inserter-hand"] = smooth_type_linear,
    -- container -> loader, vector_to_place_result -> belt
    ["item-on-belt"] = smooth_type_linear,
    -- tower -> plant
    ["plant-growing"] = smooth_type_linear,

    -- cargo pod -> container
    ["item-in-container-with-cargo-hatches"] = smooth_type_jump,
    -- container -> cargo pod
    ["item-in-cargo-pod"] = smooth_type_jump
}
--- @type table<string, SmoothingDefinition>
local map_smooth_speed_out = {
    -- inserter -> container
    ["item-in-inserter-hand"] = smooth_type_linear,
    -- mining drill -> container
    ["item-coming-from-mining-drill"] = smooth_type_linear,
    -- loader -> container
    ["item-on-belt"] = smooth_type_linear,
    -- plant -> tower
    ["plant-growing"] = smooth_type_linear
}

--- @type FocusSmoothingState
local __no_smoothing = {
    final_tick = 0,
    speed = 0,
    min_speed = nil,
    mul = nil
}
--- @param a number
--- @param b number
--- @param nil_larger boolean
local function max_with_nil(a, b, nil_larger)
    if a == nil or b == nil then
        if nil_larger then return nil
        else return a or b end
    end
    return math.max(a, b)
end

--- @param focus FocusInstance
--- @param kind table<string, SmoothingDefinition>
--- @param type string
local function extend_smooth(focus, kind, type)
    local new_smoothing = kind[type]
    if new_smoothing == nil
        then return end

    local prev = focus.smoothing or __no_smoothing
    local next = {
        final_tick = game.tick + new_smoothing.ticks,
        speed = new_smoothing.speed,
        min_speed = new_smoothing.min_speed,
        mul = new_smoothing.mul
    }
    next.final_tick = math.max(next.final_tick, prev.final_tick)
    next.speed = max_with_nil(next.speed, prev.speed, true)
    next.min_speed = max_with_nil(next.min_speed, prev.min_speed, false)
    next.mul = max_with_nil(next.mul, prev.mul, false)

    if
        new_smoothing.speed ~= nil
        and next.min_speed ~= nil
        and new_smoothing.speed > next.min_speed
    then
        -- If previous had min_speed, but new_smoothing defines speed, that should become next's min_speed
        next.min_speed = new_smoothing.speed
    end

    local previous_final_tick = focus.smoothing and focus.smoothing.final_tick or game.tick
    local extended_by = next.final_tick - previous_final_tick
    focus.smoothing = next
    utility.debug("smoothing extended "..extended_by.." ticks: "..serpent.line(prev).." -> "..serpent.line(next))
end

--- Items the cam already followed, so "new-item" mode doesn't go round in circles
--- @param focus FocusInstance
local function remember_seen_items(focus)
    local item_wl = focus.watching.item_wl
    if item_wl == nil
        then return end
    focus.seen_items = focus.seen_items or {}
    if item_wl.item ~= nil then
        focus.seen_items[item_wl.item.name] = true
    end
    for _, name in ipairs(item_wl.items or {}) do
        focus.seen_items[name] = true
    end
end

--- @param map table<string, fun(focus: FocusInstance, handle: LuaEntity, pin?: any, cause_entity?: LuaEntity): boolean>
--- @param focus FocusInstance
--- @param cause_entity? LuaEntity
local function apply_fn(map, focus, cause_entity)
    local last_watching = focus.watching
    --- @cast last_watching -nil

    local fn = map[last_watching.type]
    if not fn
        then return false end

    fn(focus, last_watching.handle, last_watching.pin, cause_entity)

    if focus.watching == nil or not focus.watching.valid
        then return false end

    if focus.watching == last_watching
        then return true end

    utility.debug("focus watchdog changed from "..last_watching.type.." to "..focus.watching.type)
    follow_rules.apply_matching(focus)
    remember_seen_items(focus)

    utility.raise_event(const.events.on_focus_switch, {
        focus_id = focus.id,
        previous_target = last_watching.handle,
        new_target = focus.watching.handle,
        surface = focus.surface,
        position = focus.position,
        smooth_position = focus.smooth_position,
        cause_entity = cause_entity
    })

    extend_smooth(focus, map_smooth_speed_out, last_watching.type)
    extend_smooth(focus, map_smooth_speed_in, focus.watching.type)
    return true
end

local focus_update = {}

--- @param focus FocusInstance
function focus_update.tick(focus)
    if not focus.watching.handle.valid and not apply_fn(handle_invalid_map, focus)
        then return false end

    if not apply_fn(tick_map, focus)
        then return false end

    return true
end

--- @param focus FocusInstance
--- @param cause_entity LuaEntity
function focus_update.environment_changed(focus, cause_entity)
    return apply_fn(environment_changed_map, focus, cause_entity)
end

return focus_update
