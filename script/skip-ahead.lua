local const = require("const")
local utility = require("utility")
local watchdog = require("focus-watchdog")
local transfer_to = require("focus-transfer")

--- Optional behavior for when the followed item is stuck, so the cam doesn't wait forever:
--- - On a full belt, jump to the frontmost item of the same kind downstream
---   and follow the first one an inserter picks up anywhere on that belt stretch.
--- - In a building whose output is backed up, follow an inserter that already holds the same item from there.
local skip_ahead = {}

--- @class BeltStuckStretch
--- @field owners table<integer, true> unit_number of every belt entity in the stretch
--- @field area BoundingBox Inserter search area covering the whole stretch

--- @param entity LuaEntity
--- @return LuaEntity[]
local function next_belts(entity)
    if entity.type == "underground-belt" and entity.belt_to_ground_type == "input" then
        return {entity.underground_belt_neighbour}
    end
    if entity.type == "linked-belt" and entity.linked_belt_type == "input" then
        return {entity.linked_belt_neighbour}
    end
    return entity.belt_neighbours.outputs
end

--- Lines of an entity that belong to the same lane. Odd line indices are left lane, even ones right lane,
--- also on splitters and undergrounds. Sideloading switches lanes, that's ignored here.
--- @param entity LuaEntity
--- @param lane_parity integer line_idx % 2
--- @return integer[]
local function lane_line_idxs(entity, lane_parity)
    local idxs = {}
    for line_idx = 1, entity.get_max_transport_line_index() do
        if line_idx % 2 == lane_parity then
            table.insert(idxs, line_idx)
        end
    end
    return idxs
end

--- @param entity LuaEntity
--- @param lane_parity integer
local function is_lane_backed_up(entity, lane_parity)
    local count, length = 0, 0
    for _, line_idx in ipairs(lane_line_idxs(entity, lane_parity)) do
        local line = entity.get_transport_line(line_idx)
        count = count + line.get_item_count()
        length = length + line.line_length
    end
    -- Items sit 0.25 apart when compressed. Allow one missing so a gap closing right now still counts
    return count >= math.floor(length * 4 + 0.01) - 1
end

--- Belt entities in front of the given one, in order, as long as the lane is backed up.
--- The first one that isn't backed up anymore is still included, its items may be the front of the jam.
--- @param start_entity LuaEntity
--- @param lane_parity integer
--- @return LuaEntity[], boolean hit_limit Jam may go on past the last belt
local function belts_downstream(start_entity, lane_parity)
    local belts = {start_entity}
    local seen = {[start_entity.unit_number] = true}
    local idx = 1
    while idx <= #belts and #belts < const.belt_skip_ahead_max_belts do
        local current = belts[idx]
        -- A belt that isn't backed up ends its branch, other branches (splitter) keep going
        if idx == 1 or is_lane_backed_up(current, lane_parity) then
            for _, next_belt in ipairs(next_belts(current)) do
                if next_belt ~= nil and next_belt.unit_number ~= nil and not seen[next_belt.unit_number] then
                    seen[next_belt.unit_number] = true
                    table.insert(belts, next_belt)
                end
            end
        end
        idx = idx + 1
    end
    return belts, #belts >= const.belt_skip_ahead_max_belts
end

--- @param belts LuaEntity[]
--- @return BeltStuckStretch
local function stretch_of(belts)
    local owners = {}
    local left, top, right, bottom
    for _, belt in ipairs(belts) do
        owners[belt.unit_number] = true
        local box = belt.bounding_box
        left = math.min(left or box.left_top.x, box.left_top.x)
        top = math.min(top or box.left_top.y, box.left_top.y)
        right = math.max(right or box.right_bottom.x, box.right_bottom.x)
        bottom = math.max(bottom or box.right_bottom.y, box.right_bottom.y)
    end

    --- @type BeltStuckStretch
    return {
        owners = owners,
        area = utility.aabb_expand({
            left_top = {x = left, y = top},
            right_bottom = {x = right, y = bottom}
        }, const.belt_skip_ahead_inserter_search_d)
    }
end

--- Frontmost whitelisted item on the lane, searching from the last belt backwards
--- @param belts LuaEntity[]
--- @param lane_parity integer
--- @param item_wl FocusItemWhitelist
--- @return DetailedItemOnLine?, integer?, LuaEntity?
local function frontmost_item(belts, lane_parity, item_wl)
    for idx = #belts, 1, -1 do
        local belt = belts[idx]
        local best, best_line_idx
        for _, line_idx in ipairs(lane_line_idxs(belt, lane_parity)) do
            for _, item in ipairs(belt.get_transport_line(line_idx).get_detailed_contents()) do
                if utility.is_item_filtered(item.stack, item_wl)
                    and (best == nil or line_idx > best_line_idx or (line_idx == best_line_idx and item.position > best.position))
                then
                    best = item
                    best_line_idx = line_idx
                end
            end
        end
        if best ~= nil
            then return best, best_line_idx, belt end
    end
end

--- @param focus FocusInstance
--- @param surface LuaSurface
--- @param force ForceID
--- @param stretch BeltStuckStretch
--- @param item_wl FocusItemWhitelist
--- @return FocusWatchdog?
local function inserter_picking_from_stretch(focus, surface, force, stretch, item_wl)
    utility.debug_area(surface, stretch.area, const.__dc_inserter_seek)

    for _, candidate in ipairs(surface.find_entities_filtered({
        area = stretch.area,
        type = "inserter",
        force = force
    })) do
        local pickup_target = candidate.pickup_target
        local held_stack = candidate.held_stack
        if
            pickup_target ~= nil
            and pickup_target.unit_number ~= nil
            and stretch.owners[pickup_target.unit_number]
            and held_stack.valid_for_read
            and utility.is_item_filtered(held_stack, item_wl)
            and utility.sq_distance(candidate.held_stack_position, candidate.pickup_position)
                <= const.inserter_search_d_picking_up_feather
        then
            utility.debug("belt skip ahead: inserter picked same item from stuck stretch")
            utility.debug_pos(surface, candidate.position, const.__dc_min_pick)
            return watchdog.create.item_in_inserter_hand(candidate)
        end
    end
end

--- Collects the backed up stretch in front of a belt lane and jumps to its frontmost whitelisted item.
--- The jumped to item keeps watching the whole stretch, so it follows the first same item an inserter takes off.
--- @param belt LuaEntity
--- @param line_idx integer
--- @param item_wl FocusItemWhitelist
--- @param current_id? integer unique_id of the item already followed, no jump if it's the frontmost
--- @param stuck_ticks integer
--- @return BeltStuckStretch, FocusWatchdog?
local function enter_stuck_stretch(belt, line_idx, item_wl, current_id, stuck_ticks)
    local lane_parity = line_idx % 2
    local belts, hit_limit = belts_downstream(belt, lane_parity)
    local stretch = stretch_of(belts)

    local front_it, front_line_idx, front_belt = frontmost_item(belts, lane_parity, item_wl)
    if front_it == nil or front_it.unique_id == current_id
        then return stretch end

    utility.debug("skip ahead: jumping to frontmost item of stretch, "..#belts.." belts")
    local jumped = watchdog.create.item_on_belt(front_it, front_line_idx, front_belt)
    jumped.pin.last_position = front_it.position
    if hit_limit then
        -- Jam goes on. Let the jumped item get stuck again and hop the next stretch from there
        jumped.pin.stuck_ticks = 0
    else
        jumped.pin.stuck_ticks = stuck_ticks
        jumped.pin.stretch = stretch
    end
    return stretch, jumped
end

--- Called every tick the followed item is still found on its line.
--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param pin PinItemOnBelt
--- @return FocusWatchdog? Watchdog to switch to, if any
function skip_ahead.belt_tick(focus, handle, pin)
    if not settings.global[const.name_setting_skip_ahead].value then
        pin.stuck_ticks = nil
        pin.stretch = nil
        return
    end

    -- A full belt rarely stands completely still, it creeps forward whenever something is taken off.
    -- Count standing ticks up and moving ticks down, so creeping counts as stuck but flowing doesn't.
    local threshold = settings.global[const.name_setting_skip_ahead_ticks].value
    if pin.last_position ~= pin.it.position then
        pin.last_position = pin.it.position
        pin.stuck_ticks = math.max(0, (pin.stuck_ticks or 0) - 1)
        if pin.stuck_ticks == 0 then
            pin.stretch = nil
        end
    else
        pin.stuck_ticks = math.min(threshold, (pin.stuck_ticks or 0) + 1)
    end

    if pin.stretch == nil and pin.stuck_ticks < threshold
        then return end

    local item_wl = focus.watching.item_wl

    if pin.stretch == nil then
        utility.debug("belt skip ahead: item stuck for "..pin.stuck_ticks.." ticks")
        local stretch, jumped = enter_stuck_stretch(handle, pin.line_idx, item_wl, pin.id, pin.stuck_ticks)
        pin.stretch = stretch
        if jumped ~= nil
            then return jumped end
    end

    return inserter_picking_from_stretch(focus, handle.surface, handle.force, pin.stretch, item_wl)
end

--- Called every tick an inserter still holds the followed item.
--- @param focus FocusInstance
--- @param handle LuaEntity
--- @return FocusWatchdog? Watchdog to switch to, if any
function skip_ahead.inserter_tick(focus, handle)
    local watching = focus.watching
    if not settings.global[const.name_setting_skip_ahead].value then
        watching.stuck_ticks = nil
        return
    end

    local threshold = settings.global[const.name_setting_skip_ahead_ticks].value
    -- Retry now and then, the belt may not carry the same item yet
    watching.stuck_ticks = (watching.stuck_ticks or 0) + 1
    if watching.stuck_ticks < threshold or (watching.stuck_ticks - threshold) % const.skip_ahead_retry_ticks ~= 0
        then return end

    -- Only a full belt is worth skipping into. A full chest or machine doesn't move the item anywhere
    local drop_target = handle.drop_target
    if drop_target == nil or not const.is_belt[drop_target.type]
        then return end

    -- Inserters drop onto the lane closest to their drop position
    local drop_line_idx, closest_d
    for line_idx = 1, math.min(2, drop_target.get_max_transport_line_index()) do
        local d = utility.sq_distance(handle.drop_position, drop_target.get_line_item_position(line_idx, 0.5))
        if closest_d == nil or d < closest_d then
            drop_line_idx = line_idx
            closest_d = d
        end
    end
    if drop_line_idx == nil
        then return end

    utility.debug("inserter skip ahead: can't drop for "..threshold.." ticks")
    local _, jumped = enter_stuck_stretch(drop_target, drop_line_idx, watching.item_wl, nil, threshold)
    return jumped
end

--- A crafter with full output never finishes the craft we're waiting for. Its output inventory is what comes next
--- @param handle LuaEntity
function skip_ahead.is_output_backed_up(handle)
    return settings.global[const.name_setting_skip_ahead].value
        and handle.status == defines.entity_status.full_output
end

--- Called every tick the followed item waits in a building (container, crafter output) and wasn't taken out.
--- @param focus FocusInstance
--- @param handle LuaEntity
--- @param item_wl FocusItemWhitelist
--- @return FocusWatchdog? Watchdog to switch to, if any
function skip_ahead.building_tick(focus, handle, item_wl)
    local watching = focus.watching
    if not settings.global[const.name_setting_skip_ahead].value then
        watching.stuck_ticks = nil
        return
    end

    -- Holding inserters don't go anywhere, no need to search for them every tick
    local threshold = settings.global[const.name_setting_skip_ahead_ticks].value
    watching.stuck_ticks = (watching.stuck_ticks or 0) + 1
    if watching.stuck_ticks < threshold or (watching.stuck_ticks - threshold) % const.skip_ahead_retry_ticks ~= 0
        then return end

    -- Output is backed up, nothing gets picked up fresh. An inserter already holding the same item
    -- from here, waiting to drop it, is the next one out
    return transfer_to.inserter_nearby(
        focus,
        handle.surface,
        handle.force,
        utility.aabb_expand(utility.rotated_selection_box(handle), const.inserter_search_d),
        handle.position,
        item_wl,
        {source = handle}
    )
end

return skip_ahead
