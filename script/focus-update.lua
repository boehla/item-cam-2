local const = require("const")
local utility = require("utility")
local watchdog = require("focus-watchdog")
local transfer_to = require("focus-transfer")
local follow_rules = require("focus-follow-rules")
local skip_ahead = require("skip-ahead")
local fluid_flow = require("fluid-flow")

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

--- Which products of a recipe with multiple outputs to follow, see setting "multiple-outputs".
--- Fluids are followed when the recipe makes nothing else, or when they're the main product
--- @param focus FocusInstance
--- @param recipe_proto LuaRecipePrototype
--- @return FocusItemWhitelist?
local function pick_crafter_products(focus, recipe_proto)
    local items = utility.products_filtered(recipe_proto.products, {items = true})
    local fluids = utility.products_filtered(recipe_proto.products, {fluids = true})

    -- Scripted focuses can name the products they want to go for
    for _, name in ipairs(focus.prefer_products or {}) do
        if items ~= nil and utility.contains(items, name)
            then return {items = {name}} end
        if fluids ~= nil and utility.contains(fluids, name)
            then return {fluid = name} end
    end

    local mode = focus.multiple_outputs or settings.global[const.name_setting_multiple_outputs].value
    local main = recipe_proto.main_product
    if items == nil then
        if fluids == nil
            then return end
        return {fluid = main ~= nil and main.type == "fluid" and main.name or fluids[1]}
    end
    if #items == 1 and fluids == nil
        then return {items = items} end
    if mode ~= "first-out" and main ~= nil and main.type == "fluid"
        then return {fluid = main.name} end
    if #items == 1 or mode == "first-out"
        then return {items = items} end

    local main_name = main ~= nil and main.type == "item" and main.name or nil
    if mode == "new-item" and focus.seen_items ~= nil then
        if main_name ~= nil and not focus.seen_items[main_name]
            then return {items = {main_name}} end
        for _, name in ipairs(items) do
            if not focus.seen_items[name]
                then return {items = {name}} end
        end
    end
    if main_name ~= nil
        then return {items = {main_name}} end
    return {items = items}
end

--- Crafted fluid leaves the crafter: route it to wherever it goes next
--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param fluid string
--- @return FocusWatchdog?
local function fluid_out_of_crafter(focus, handle, fluid)
    local idx = fluid_flow.output_fluidbox(handle, fluid)
    if idx == nil
        then return end
    local route = fluid_flow.route(handle, idx, fluid, focus.fluid_prefer and focus.fluid_prefer[fluid])
    if route == nil
        then return end
    return watchdog.create.fluid_in_pipes(route, fluid, focus.fluid_speed)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemInCraftingMachine
tick_map["item-in-crafting-machine"] = function (focus, handle, pin)
    if handle.products_finished == pin.initial_products_finished then
        -- Remember the recipe ours is crafted with: circuit-driven crafters can switch or clear it
        -- the moment the craft finishes (pY slaughterhouses), and then its products would be wrong
        local recipe_set = utility.crafter_recipe_proto(handle)
        if recipe_set ~= nil
            then pin.recipe_name = recipe_set.name end
        if not skip_ahead.is_output_backed_up(handle)
            then return end
    end

    if not pin.announced_change then
        utility.debug("watchdog changing: products_finished increased")
        pin.announced_change = true
    end

    local item_wl = focus.watching.item_wl
    if item_wl == nil then
        local recipe_set = utility.crafter_recipe_proto(handle)
        local recipe_name = pin.recipe_name or (recipe_set and recipe_set.name)
        if recipe_name == nil
            then return end
        local recipe_proto = prototypes.recipe[recipe_name]
        item_wl = pick_crafter_products(focus, recipe_proto) or utility.__no_wl
        -- Recipe products don't change while we wait, no need to look them up every tick
        focus.watching.item_wl = item_wl
    end

    if item_wl.fluid ~= nil then
        -- Routing walks the whole fluid network, don't do it every tick when nothing leads anywhere
        if pin.fluid_retry_tick ~= nil and game.tick < pin.fluid_retry_tick
            then return end
        local next_watchdog = fluid_out_of_crafter(focus, handle, item_wl.fluid)
        if next_watchdog ~= nil then
            focus.watching = next_watchdog
        else
            pin.fluid_retry_tick = game.tick + const.fluid_route_retry_ticks
        end
        return
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

    local ghost = pin.ghost
    if ghost ~= nil and (drop_target == nil or not drop_target.valid) then
        -- Ghost got revived: the item is now that building
        local built = ghost.surface.find_entities_filtered({name = ghost.name, position = ghost.position, limit = 1})[1]
        if built ~= nil then
            utility.debug("watchdog changing: robot built its ghost")
            focus.watching = watchdog.create.end_built(built)
            return
        end
    end

    if drop_target == nil or not drop_target.valid then
        utility.debug("watchdog lost: invalid drop_target")
        focus.watching.valid = false
        return
    end

    focus.watching =  transfer_to.next(focus, drop_target, focus.watching.item_wl)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemInRoboport
tick_map["item-in-roboport"] = function (focus, handle, pin)
    local name = focus.watching.item_wl.item.name
    local count = handle.get_inventory(defines.inventory.roboport_robot).get_item_count(name)
    if count >= pin.count then
        -- More of them put in after ours: the next one out is still ours
        pin.count = count
        return
    end
    -- One left: the robot that appeared next to the roboport
    for _, robot in pairs(handle.surface.find_entities_filtered({name = name, position = handle.position,
        radius = const.roboport_launch_radius})) do
        if not pin.known[robot.unit_number] then
            utility.debug("watchdog changing: robot left the roboport")
            focus.watching = watchdog.create.robot_flying(robot)
            return
        end
    end
    -- Not out yet, or it left before we looked: count again next tick
    pin.count = count
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinRobotFlying
tick_map["robot-flying"] = function (focus, handle, pin)
    if pin.ghost == nil then
        for _, order in pairs(handle.robot_order_queue) do
            local target = order.target
            if target ~= nil and target.valid and target.type == "entity-ghost" then
                pin.ghost = {name = target.ghost_name, position = target.position, surface = target.surface}
                break
            end
        end
        return
    end
    local ghost = pin.ghost
    if ghost.surface.find_entities_filtered({type = "entity-ghost", ghost_name = ghost.name, position = ghost.position, limit = 1})[1] ~= nil
        then return end
    local built = ghost.surface.find_entities_filtered({name = ghost.name, position = ghost.position, limit = 1})[1]
    if built ~= nil then
        utility.debug("watchdog changing: our robot built its first ghost")
        focus.watching = watchdog.create.end_built(built)
    end
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemInDigSiteFood
tick_map["item-in-dig-site-food"] = function (focus, handle, pin)
    local site = pin.site
    if not site.valid then
        utility.debug("watchdog lost: dig site is gone")
        focus.watching.valid = false
        return
    end
    local count = handle.get_inventory(defines.inventory.chest).get_item_count(focus.watching.item_wl.item.name)
    if count < pin.count then
        -- Eaten: the script sends a digosaur off in the same tick
        for _, unit in pairs(site.surface.find_entities_filtered({type = "unit", position = site.position,
            radius = const.dig_site_spawn_radius})) do
            if not pin.known[unit.unit_number] then
                utility.debug("watchdog changing: food eaten, digosaur leaves")
                focus.watching = watchdog.create.digosaur(unit, site)
                return
            end
        end
    end
    -- More put in after ours, or taken out by someone else: the next one eaten is still ours
    pin.count = count
    pin.known = watchdog.units_at_dig_site(site)
end

--- @param handle LuaEntity
--- @param pin PinDigosaur
tick_map["digosaur-digging"] = function (_, handle, pin)
    -- Other digosaurs bring their ore back meanwhile
    if not pin.site.valid
        then return end
    pin.finished = pin.site.products_finished
    pin.output = watchdog.dig_site_output(pin.site)
end

--- @param focus FocusInstance
--- @param pin PinDigosaur
handle_invalid_map["digosaur-digging"] = function (focus, _, pin)
    local site = pin.site
    if not site.valid or site.products_finished == pin.finished then
        utility.debug("watchdog lost: digosaur gone without ore")
        focus.watching.valid = false
        return
    end
    local brought = nil
    for name, count in pairs(watchdog.dig_site_output(site)) do
        if count > (pin.output[name] or 0) then
            brought = name
            break
        end
    end
    if brought == nil then
        utility.debug("watchdog lost: digosaur back, no new ore in the output")
        focus.watching.valid = false
        return
    end
    utility.debug("watchdog changing: digosaur back with "..brought)
    local next_watching = watchdog.create.item_in_crafting_machine(site)
    next_watching.pin.initial_products_finished = pin.finished
    next_watching.item_wl = {items = {brought}}
    focus.watching = next_watching
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

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinFluidInPipes
tick_map["fluid-in-pipes"] = function (focus, handle, pin)
    local speed = pin.speed or settings.global[const.name_setting_fluid_speed].value
    pin.progress = pin.progress + speed
    pin.pos, pin.seg = fluid_flow.along(pin.path, pin.cum, pin.progress, pin.seg)
    if pin.progress < pin.cum[#pin.cum]
        then return end

    utility.debug("watchdog changing: fluid arrived at "..pin.kind)
    fluid_flow.unhighlight(pin.highlight)
    if pin.kind == "crafter" then
        focus.watching = watchdog.create.item_in_crafting_machine(handle)
    elseif pin.kind == "rail" then
        focus.watching = watchdog.create.fluid_at_rail_pump(handle, pin.fluid)
    else
        focus.watching = watchdog.create.end_consumed(handle, pin.fluid)
    end
end

--- @param focus FocusInstance
--- @param handle LuaEntity
tick_map["fluid-at-rail-pump"] = function (focus, handle)
    if handle.pumped_last_tick <= 0
        then return end
    local wagon = fluid_flow.wagon_at_pump(handle)
    if wagon == nil
        then return end
    utility.debug("watchdog changing: pump fills wagon")
    focus.watching = watchdog.create.fluid_in_wagon(wagon, focus.watching.item_wl.fluid)
end

--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinFluidInWagon
tick_map["fluid-in-wagon"] = function (focus, handle, pin)
    local train = handle.train
    if train == nil or train.state ~= defines.train_state.wait_station
        then return end
    if pin.loaded_at == nil and train.station ~= nil then
        -- Created while the train wasn't at a station yet
        pin.loaded_at = train.station
        return
    end
    if train.station == pin.loaded_at
        then return end

    local pump = fluid_flow.unloading_pump(handle)
    if pump == nil
        then return end
    if pin.retry_tick ~= nil and game.tick < pin.retry_tick
        then return end
    local fluid = focus.watching.item_wl.fluid
    local route = fluid_flow.route(pump, 1, fluid, focus.fluid_prefer and focus.fluid_prefer[fluid])
    if route == nil then
        pin.retry_tick = game.tick + const.fluid_route_retry_ticks
        return
    end
    utility.debug("watchdog changing: pump empties wagon")
    focus.watching = watchdog.create.fluid_in_pipes(route, fluid, focus.fluid_speed)
end

tick_map["end-consumed"] = function ()
    -- End of the line
end

tick_map["end-lab"] = function ()
    -- End of the line
end

tick_map["end-built"] = function ()
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
    -- crafter / wagon -> pipes
    ["fluid-in-pipes"] = smooth_type_linear,
    -- pump -> wagon
    ["fluid-in-wagon"] = smooth_type_linear,
    -- tower -> plant
    ["plant-growing"] = smooth_type_linear,
    -- dig site -> digosaur
    ["digosaur-digging"] = smooth_type_linear,

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
    ["plant-growing"] = smooth_type_linear,
    -- digosaur -> dig site
    ["digosaur-digging"] = smooth_type_linear
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
    -- Skip ahead to another piece (belt/inserter): with skip_glide_speed the camera rides there at that steady
    -- speed (tiles/tick) instead of 0.25 tiles/tick for 60 ticks and then snapping the rest of the way
    if focus.skip_glide_speed and (focus.watching.skipped == "belt" or focus.watching.skipped == "inserter") then
        focus.smoothing = {final_tick = game.tick + 60 * 60, speed = focus.skip_glide_speed}
    end
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
