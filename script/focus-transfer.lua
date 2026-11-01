local const = require("const")
local utility = require("utility")
local watchdog = require("focus-watchdog")

local transfer_to = {}

--- @param focus FocusInstance
--- @param surface LuaSurface
--- @param search_position MapPosition
--- @param item_wl FocusItemWhitelist
--- @return FocusWatchdog?
function transfer_to.item_on_ground(focus, surface, search_position, item_wl)
    utility.debug_pos(surface, search_position, const.__dc_item_entity_seek)

    local candidates = surface.find_entities_filtered({
        position = search_position,
        type = {"item-entity"}
        -- Item on ground loses force
    })
    if #candidates == 0
        then return end
    for _, candidate in ipairs(candidates) do
        if utility.is_item_filtered(candidate.stack, item_wl) then
            return watchdog.create.item_on_ground(candidates[1])
        end
    end
end

--- @class WatchInserterCandidateRestrictions
--- @field source? LuaEntity
--- @field target? LuaEntity
--- @field swinging_towards? boolean

--- @param focus FocusInstance
--- @param surface LuaSurface
--- @param force? ForceID
--- @param search_area BoundingBox
--- @param ref_pos MapPosition
--- @param item_wl FocusItemWhitelist
--- @param restrictions WatchInserterCandidateRestrictions
function transfer_to.inserter_nearby(focus, surface, force, search_area, ref_pos, item_wl, restrictions)
    utility.debug_area(surface, search_area, const.__dc_inserter_seek)

    local best_guess = utility.minimum_of(surface.find_entities_filtered({
        area = search_area,
        type = "inserter",
        force = force,
    }), function (candidate)
        utility.debug_pos(surface, candidate.position, const.__dc_min_cand)

        local held_stack = candidate.held_stack
        if not held_stack.valid_for_read
            then return end
        if not utility.is_item_filtered(held_stack, item_wl)
            then return end
        if restrictions.source ~= nil and candidate.pickup_target ~= restrictions.source
            then return end
        if restrictions.target ~= nil and candidate.drop_target ~= restrictions.target
            then return end

        if restrictions.swinging_towards and (
            utility.sq_distance(candidate.held_stack_position, candidate.pickup_position)
            >
            const.inserter_search_d_picking_up_feather
        ) then return end

        utility.debug_pos(surface, candidate.position, const.__dc_min_pass)

        return utility.sq_distance(ref_pos, candidate.held_stack_position)
    end)

    if best_guess ~= nil then
        utility.debug_pos(surface, best_guess.position, const.__dc_min_pick)
        return watchdog.create.item_in_inserter_hand(best_guess)
    end
end

--- @param focus FocusInstance
--- @param target_belt_entity LuaEntity
--- @param item_wl FocusItemWhitelist
function transfer_to.newest_item_on_belt(focus, target_belt_entity, item_wl)
    local function newest_on(belt)
        return utility.minimum_on_belt(belt, function (candidate, line_idx)
            utility.debug_item_on_line(candidate, line_idx, belt, const.__dc_min_cand)
            if not utility.is_item_filtered(candidate.stack, item_wl)
                then return end

            utility.debug_item_on_line(candidate, line_idx, belt, const.__dc_min_pass)
            return -candidate.unique_id -- Pick newest
        end)
    end

    local best_guess, line_idx = newest_on(target_belt_entity)
    local on_belt = target_belt_entity
    if best_guess == nil then
        -- Dropped onto a short piece (underground exit) of a fast belt: by the time we look, the item already moved
        -- on to the next belt (pY moss chain: burner inserter -> underground exit -> sushi lane; focus got lost)
        for _, next_belt in ipairs(target_belt_entity.belt_neighbours.outputs) do
            best_guess, line_idx = newest_on(next_belt)
            if best_guess ~= nil then
                on_belt = next_belt
                break
            end
        end
    end

    if best_guess and line_idx then
        utility.debug_item_on_line(best_guess, line_idx, on_belt, const.__dc_min_pick)
        return watchdog.create.item_on_belt(best_guess, line_idx, on_belt)
    end
end

--- @class WatchLoaderCandidateRestrictions
--- @field source? LuaEntity
--- @field target? LuaEntity

--- @param focus FocusInstance
--- @param surface LuaSurface
--- @param force? ForceID
--- @param search_area BoundingBox
--- @param item_wl FocusItemWhitelist
--- @param restrictions WatchLoaderCandidateRestrictions
function transfer_to.loader_nearby(focus, surface, force, search_area, item_wl, restrictions)
    utility.debug_area(surface, search_area, const.__dc_loader_seek)

    return utility.first(surface.find_entities_filtered({
        area = search_area,
        type = {"loader", "loader-1x1"},
        force = force
    }), function (candidate)
        if restrictions.source ~= nil and (
            candidate.loader_type == "input"
            or candidate.loader_container ~= restrictions.source
        ) then return end

        if restrictions.target ~= nil and (
            candidate.loader_type == "output"
            or candidate.loader_container ~= restrictions.target
        ) then return end

        return transfer_to.newest_item_on_belt(focus, candidate, item_wl)
    end)
end

--- @param focus FocusInstance
--- @param surface LuaSurface
--- @param force? ForceID
--- @param search_area BoundingBox
--- @param ref_pos MapPosition
--- @param item_wl FocusItemWhitelist
function transfer_to.robot_nearby(focus, surface, force, search_area, ref_pos, item_wl)
    utility.debug_area(surface, search_area, const.__dc_robot_seek)

    local best_guess, its_item_stack = utility.minimum_of(surface.find_entities_filtered({
        area = search_area,
        type = const.all_bot,
        force = force
    }), function (candidate)
        utility.debug_pos(surface, candidate.position, const.__dc_min_cand)

        -- It would have been nicer to check for a pickup order.
        -- But because they actually update only every 20 ticks, we'd need a giant surface area scanned every tick
        -- just so that we catch the bot before it updates when order target (ref_pos) is reached.
        -- And here we do these checks *after* they update, so the pickup order is gone
        local inventory = candidate.get_inventory(defines.inventory.robot_cargo)
        assert(inventory, "candidate robot doesn't have targeted inventory")

        local first_stack = utility.first_item_stack_filtered(inventory, item_wl)
        if first_stack == nil
            then return end
        if not utility.is_item_filtered(first_stack, item_wl)
            then return end

        return utility.sq_distance(ref_pos, candidate.position), first_stack
    end)

    if best_guess ~= nil then
        assert(its_item_stack)
        utility.debug_pos(surface, best_guess.position, const.__dc_min_pick)

        return watchdog.create.item_held_by_robot(
            best_guess,
            utility.item_proto(its_item_stack)
        )
    end
end

--- @param focus FocusInstance
--- @param entity LuaEntity
--- @param item_wl FocusItemWhitelist
function transfer_to.next(focus, entity, item_wl)
    local entity_type = entity.type
    if const.is_belt[entity_type] then
        return transfer_to.newest_item_on_belt(focus, entity, item_wl)
    end
    if entity_type == "inserter" then
        return watchdog.create.item_in_inserter_hand(entity)
    end
    if const.is_crafting_machine[entity_type] then
        return watchdog.create.item_in_crafting_machine(entity)
    end
    if const.container_inventory_idx[entity_type] then
        assert(item_wl.item or item_wl.items, "expected whitelist on item")

        local inventory = entity.get_inventory(const.container_inventory_idx[entity_type])
        assert(inventory, "expected entity to have its specific inventory")

        local first_applicable_stack = utility.first_item_stack_filtered(inventory, item_wl)
        if first_applicable_stack ~= nil then
            return watchdog.create.item_in_container(entity, utility.item_proto(first_applicable_stack))
        end

        utility.debug("transfer_to.next: item from container was already taken by inserter")
        return transfer_to.inserter_nearby(
            focus,
            entity.surface,
            entity.force,
            utility.aabb_expand(entity.bounding_box, const.inserter_search_d),
            entity.position,
            item_wl,
            {source = entity, swinging_towards = true}
        )
    end
    if entity_type == "agricultural-tower" then
        -- Happens only when it's inputted into. Output is triggered independently
        assert(item_wl.item, "expected whitelist on item")
        return watchdog.create.seed_in_agricultural_tower(entity, item_wl.item)
    end
    if entity_type == "lab" then
        return watchdog.create.end_lab(entity)
    end
    if entity_type == "roboport" then
        assert(item_wl.item, "expected whitelist on item")
        return watchdog.create.item_in_roboport(entity, item_wl.item)
    end
    if entity_type == "item-entity" then
        return watchdog.create.item_on_ground(entity)
    end
end

--- @param focus FocusInstance
--- @param entity LuaEntity
--- @param item_wl FocusItemWhitelist
function transfer_to.drop_target(focus, entity, item_wl)
    if entity.prototype.vector_to_place_result == nil
        then return end

    local drop_target = entity.drop_target
    if drop_target == nil then
        return transfer_to.item_on_ground(focus, entity.surface, entity.drop_position, item_wl)
    end

    if drop_target.type ~= "transport-belt" then
        return transfer_to.next(focus, drop_target, item_wl)
    end

    -- Drop target is belt. Search only the proper lane
    local drop_line_idx = const.drop_belt_line_idx[entity.direction][drop_target.direction]

    local best_guess, line_idx = utility.minimum_on_belt(drop_target, function (candidate, line_idx)
        if line_idx ~= drop_line_idx
            then return end

        utility.debug_item_on_line(candidate, line_idx, drop_target, const.__dc_min_cand)
        if not utility.is_item_filtered(candidate.stack, item_wl)
            then return end

        utility.debug_item_on_line(candidate, line_idx, drop_target, const.__dc_min_pass)
        return utility.sq_distance(
            entity.drop_position,
            drop_target.get_line_item_position(line_idx, candidate.position)
        )
    end)

    if best_guess and line_idx then
        utility.debug_item_on_line(best_guess, line_idx, drop_target, const.__dc_min_pick)
        return watchdog.create.item_on_belt(best_guess, line_idx, drop_target)
    end
end

--- @param focus FocusInstance
--- @param entity LuaEntity
--- @param item_wl FocusItemWhitelist
--- @param also_drop_target? boolean
function transfer_to.taken_out_of_building(focus, entity, item_wl, also_drop_target)
    utility.debug_area(entity.surface, entity.selection_box, const.__dc_bounding)
    local entity_box = utility.rotated_selection_box(entity)
    utility.debug_area(entity.surface, entity_box, const.__dc_bounding_real)

    -- Robots only bring things to a requester chest. One arriving with more of our item isn't taking ours
    local robots_take = entity.type ~= "logistic-container" or entity.prototype.logistic_mode ~= "requester"

    return
        (also_drop_target and transfer_to.drop_target(focus, entity, item_wl))
        or transfer_to.inserter_nearby(
            focus,
            entity.surface,
            entity.force,
            utility.aabb_expand(entity_box, const.inserter_search_d),
            entity.position,
            item_wl,
            {source = entity, swinging_towards = true}
        ) or transfer_to.loader_nearby(
            focus,
            entity.surface,
            entity.force,
            utility.aabb_expand(entity_box, const.loader_search_d),
            item_wl,
            {source = entity}
        ) or (robots_take or nil) and transfer_to.robot_nearby(
            focus,
            entity.surface,
            entity.force,
            utility.aabb_expand(entity_box, const.robot_search_d),
            entity.position,
            item_wl
        )
end

return transfer_to
