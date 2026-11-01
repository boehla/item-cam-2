local const = require("const")
local utility = require("utility")

--- Fluids don't have identity like items do. Cam treats a crafted fluid as a parcel that takes the
--- shortest pipe route to the next place that uses it, and glides along that route at belt speed.
local fluid_flow = {}

--- Entities fluid passes through on its way, never the place it ends up in
local is_passthrough = {
    ["pipe"] = true,
    ["pipe-to-ground"] = true,
    ["storage-tank"] = true,
    ["pump"] = true,
    ["valve"] = true,
    ["infinity-pipe"] = true
}

--- @param entity LuaEntity
--- @param idx integer
local function production_type(entity, idx)
    local proto = entity.get_fluid_box_prototype(idx)
    if proto == nil
        then return end
    if proto.object_name == nil and proto[1] ~= nil
        then proto = proto[1] end
    return proto.production_type
end

--- @param entity LuaEntity
--- @param fluid_name string
local function recipe_uses_fluid(entity, fluid_name)
    local recipe = utility.crafter_recipe_proto(entity)
    if recipe == nil
        then return false end
    for _, ingredient in ipairs(prototypes.recipe[recipe.name].ingredients) do
        if ingredient.type == "fluid" and ingredient.name == fluid_name
            then return true end
    end
    return false
end

--- @param entity LuaEntity
--- @return string?
local function crafter_recipe_name(entity)
    local recipe = utility.crafter_recipe_proto(entity)
    return recipe and recipe.name
end

--- @class FluidRouteTarget
--- @field kind "crafter"|"rail"|"consumer"
--- @field entity LuaEntity
--- @field d number Route length in tiles

--- Rank of an endpoint, lower wins. `prefer` names a target kind ("rail"), recipe or entity to go for first
--- @param target FluidRouteTarget
--- @param prefer? string[]
local function rank_of(target, prefer)
    local entity = target.entity
    local recipe = target.kind == "crafter" and crafter_recipe_name(entity) or nil
    for idx, wanted in ipairs(prefer or {}) do
        if wanted == target.kind or wanted == entity.name or (recipe ~= nil and wanted == recipe)
            then return idx end
    end
    -- Gas vents and other voids are where fluid goes to die, only pick them if there's nothing else
    if (recipe ~= nil and recipe:find("void", 1, true)) or entity.name:find("vent", 1, true)
        then return 1000 end
    return 100
end

--- Endpoint reached through `entity`'s fluidbox `idx`, if fluid can end up there
--- @param entity LuaEntity
--- @param idx integer
--- @param fluid_name string
--- @return ("crafter"|"consumer")?
local function endpoint_kind(entity, idx, fluid_name)
    if const.is_crafting_machine[entity.type] then
        local pt = production_type(entity, idx)
        if pt ~= "input" and pt ~= "input-output"
            then return end
        if not recipe_uses_fluid(entity, fluid_name)
            then return end
        return "crafter"
    end
    if entity.type == "fluid-wagon"
        then return end
    if entity.type == "mining-drill" then
        -- Mining fluid: only if what it mines right now needs this one
        local target = entity.mining_target
        local required = target and target.prototype.mineable_properties.required_fluid
        if required ~= fluid_name
            then return end
    end
    -- Generators, boilers, reactors, turrets: they burn or use the fluid up
    return "consumer"
end

--- Find the pump of a rail station a fluid route ends at: its output faces a rail
--- @param pump LuaEntity
local function is_loading_pump(pump)
    local targets = pump.pump_output_rail_targets
    return targets ~= nil and #targets > 0
end

--- Binary min-heap on `.d`
--- @param heap table[]
--- @param node table
local function heap_push(heap, node)
    table.insert(heap, node)
    local i = #heap
    while i > 1 do
        local parent = math.floor(i / 2)
        if heap[parent].d <= heap[i].d
            then break end
        heap[parent], heap[i] = heap[i], heap[parent]
        i = parent
    end
end

--- @param heap table[]
local function heap_pop(heap)
    local top = heap[1]
    local last = table.remove(heap)
    if #heap == 0
        then return top end
    heap[1] = last
    local i = 1
    while true do
        local l, r, smallest = i * 2, i * 2 + 1, i
        if l <= #heap and heap[l].d < heap[smallest].d then smallest = l end
        if r <= #heap and heap[r].d < heap[smallest].d then smallest = r end
        if smallest == i
            then break end
        heap[smallest], heap[i] = heap[i], heap[smallest]
        i = smallest
    end
    return top
end

--- Shortest route through the fluid network from `entity`'s fluidbox `idx` to wherever the fluid can go
--- Fluidbox (or its segment) currently holds a fluid other than `fluid_name`, or is filtered to one
--- @param entity LuaEntity
--- @param idx integer
--- @param fluid_name string
local function holds_other_fluid(entity, idx, fluid_name)
    local in_box = entity.get_fluid(idx)
    if in_box and in_box.name ~= fluid_name
        then return true end
    local in_segment = entity.has_fluid_segment(idx) and entity.get_fluid_segment_fluid(idx) or nil
    if in_segment and in_segment.name ~= fluid_name
        then return true end
    local ok, filter = pcall(function () return entity.get_fluid_filter(idx) end)
    return ok and filter ~= nil and filter.name ~= fluid_name
end

--- @param entity LuaEntity
--- @param idx integer
--- @param fluid_name string
--- @param prefer? string[]
--- @return {path: MapPosition[], target: FluidRouteTarget}?
function fluid_flow.route(entity, idx, fluid_name, prefer)
    -- Dijkstra over (entity, fluidbox) pairs, once per hand-over
    local start_key = entity.unit_number..":"..idx
    local nodes = {[start_key] = {entity = entity, idx = idx, d = 0}}
    local open = {}
    heap_push(open, nodes[start_key])
    local done = {}
    --- @type {target: FluidRouteTarget, node: table}[]
    local found = {}
    local found_at = {}
    local visited = 0
    -- Every pipe connection seen, for highlighting the network the fluid flows through
    local edges = {}
    local edge_seen = {}

    while #open > 0 and visited < const.fluid_route_max_nodes do
        local cur = heap_pop(open)
        local cur_key = cur.entity.unit_number..":"..cur.idx

        if not done[cur_key] then
            done[cur_key] = true
            visited = visited + 1

            for _, connection in ipairs(cur.entity.get_fluid_box_pipe_connections(cur.idx) or {}) do
                local target = connection.target
                -- Fluid only leaves through connections that let it out
                if target ~= nil and connection.flow_direction ~= "input" then
                    local target_idx = connection.target_fluidbox_index
                    local back = (target.get_fluid_box_pipe_connections(target_idx) or {})[connection.target_pipe_connection_index]
                    -- ... and only enters through connections that let it in (pumps, crafter outputs)
                    -- ... and never into a segment holding another fluid: a switching block (pY slaughterhouses) shares
                    -- one output pipe, circuit-driven pumps sort each fluid to its own tanks and station
                    if not (back ~= nil and back.flow_direction == "output") and not holds_other_fluid(target, target_idx, fluid_name) then
                        local key = target.unit_number..":"..target_idx
                        local d = cur.d + math.sqrt(utility.sq_distance(cur.entity.position, target.position))
                        -- Each connection once, a second copy the other way round would fill the dash gaps
                        local a_id, b_id = cur.entity.unit_number, target.unit_number
                        local edge_key = a_id < b_id and (a_id..":"..b_id) or (b_id..":"..a_id)
                        if not edge_seen[edge_key] and #edges < const.fluid_highlight_max_edges then
                            edge_seen[edge_key] = true
                            table.insert(edges, {cur.entity.position, target.position})
                        end
                        if not done[key] and (nodes[key] == nil or d < nodes[key].d) then
                            local node = {entity = target, idx = target_idx, d = d, parent = cur}
                            if is_passthrough[target.type] then
                                nodes[key] = node
                                heap_push(open, node)
                                if target.type == "pump" and is_loading_pump(target) then
                                    table.insert(found, {target = {kind = "rail", entity = target, d = d}, node = node})
                                end
                            else
                                local kind = endpoint_kind(target, target_idx, fluid_name)
                                if kind ~= nil then
                                    -- Fluid ends here, keep the shortest way in
                                    nodes[key] = node
                                    local entry = found_at[key]
                                    if entry == nil then
                                        entry = {target = {kind = kind, entity = target, d = d}, node = node}
                                        found_at[key] = entry
                                        table.insert(found, entry)
                                    else
                                        entry.target.d = d
                                        entry.node = node
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local best = utility.minimum_of(found, function (entry)
        return rank_of(entry.target, prefer) * 1000000 + entry.target.d
    end)
    if best == nil
        then return end

    local reversed = {}
    local node = best.node
    while node ~= nil do
        table.insert(reversed, {x = node.entity.position.x, y = node.entity.position.y})
        node = node.parent
    end
    local path = {}
    for i = #reversed, 1, -1 do
        table.insert(path, reversed[i])
    end
    utility.debug("fluid route to "..best.target.kind.." "..best.target.entity.name.." over "..math.floor(best.target.d).." tiles, "..visited.." nodes")
    return {path = path, target = best.target, edges = edges}
end

--- One dashed line with round caps (like the game's pipeline visualization), from a to b.
--- `phase` is how far into a dash+gap period the line starts; returns the phase where it ends,
--- so consecutive segments continue the pattern
--- @param objects LuaRenderObject[]
local function dashed(objects, surface, a, b, color, width, ticks, phase)
    local dx, dy = b.x - a.x, b.y - a.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0
        then return phase end
    local period = const.fluid_highlight_dash + const.fluid_highlight_gap
    local radius = width / 64 -- line width is in pixels, 32 per tile
    local t = -phase
    while t < len do
        -- The round caps stick out by the radius: inset them, so a dash is `fluid_highlight_dash` long overall
        local from_t, to_t = math.max(0, t) + radius, math.min(len, t + const.fluid_highlight_dash) - radius
        if to_t >= from_t then
            local from = {x = a.x + dx * from_t / len, y = a.y + dy * from_t / len}
            local to = {x = a.x + dx * to_t / len, y = a.y + dy * to_t / len}
            table.insert(objects, rendering.draw_line({surface = surface, from = from, to = to,
                color = color, width = width, time_to_live = ticks}))
            for _, cap in ipairs({from, to}) do
                table.insert(objects, rendering.draw_circle({surface = surface, target = cap, radius = radius,
                    filled = true, color = color, time_to_live = ticks}))
            end
        end
        t = t + period
    end
    return (phase + len) % period
end

--- Highlight the fluid network and the route through it, like the game's pipeline visualization does
--- (that one can't be switched on by script): dashed, round-capped lines in the fluid's own visualization color
--- @param surface LuaSurface
--- @param route {path: MapPosition[], edges: MapPosition[][]}
--- @param fluid_name string
--- @param ticks integer How long the highlight stays at most
--- @return LuaRenderObject[]
function fluid_flow.highlight(surface, route, fluid_name, ticks)
    local objects = {}
    if not settings.global[const.name_setting_fluid_highlight].value
        then return objects end
    local c = prototypes.fluid[fluid_name].visualization_color
    -- Opaque: round caps on translucent dashes would overlap into darker dots. The network is a darker shade instead
    local net_color = {r = c.r * 0.55, g = c.g * 0.55, b = c.b * 0.55, a = 1}
    local route_color = {r = c.r, g = c.g, b = c.b, a = 1}
    for _, edge in ipairs(route.edges or {}) do
        dashed(objects, surface, edge[1], edge[2], net_color, 4, ticks, 0)
    end
    local phase = 0
    for i = 2, #route.path do
        phase = dashed(objects, surface, route.path[i - 1], route.path[i], route_color, 6, ticks, phase)
    end
    return objects
end

--- @param objects LuaRenderObject[]?
function fluid_flow.unhighlight(objects)
    for _, object in ipairs(objects or {}) do
        if object.valid then object.destroy() end
    end
end

--- Output fluidbox of a crafter holding (or filtered to) `fluid_name`
--- @param entity LuaEntity
--- @param fluid_name string
--- @return integer?
function fluid_flow.output_fluidbox(entity, fluid_name)
    local fallback = nil
    for idx = 1, entity.fluids_count do
        if production_type(entity, idx) == "output" then
            local in_box = entity.get_fluid(idx)
            local in_segment = entity.has_fluid_segment(idx) and entity.get_fluid_segment_fluid(idx) or nil
            if (in_box and in_box.name == fluid_name) or (in_segment and in_segment.name == fluid_name)
                then return idx end
            local proto = entity.get_fluid_box_prototype(idx)
            if proto and proto.object_name == nil and proto[1] ~= nil
                then proto = proto[1] end
            if proto and proto.filter and proto.filter.name == fluid_name
                then return idx end
            -- Empty, unfiltered output box: the only candidate if nothing else matches
            if in_box == nil and in_segment == nil
                then fallback = fallback or idx end
        end
    end
    return fallback
end

--- Fluid wagon sitting at a rail pump, if any
--- @param pump LuaEntity
--- @return LuaEntity?
function fluid_flow.wagon_at_pump(pump)
    local wagons = pump.surface.find_entities_filtered({
        area = utility.aabb_expand(pump.bounding_box, const.fluid_wagon_search_d),
        type = "fluid-wagon"
    })
    return utility.minimum_of(wagons, function (wagon)
        local train = wagon.train
        if train == nil or train.state ~= defines.train_state.wait_station
            then return end
        return utility.sq_distance(wagon.position, pump.position)
    end)
end

--- Pump that is emptying the wagon right now, if any
--- @param wagon LuaEntity
--- @return LuaEntity?
function fluid_flow.unloading_pump(wagon)
    local pumps = wagon.surface.find_entities_filtered({
        area = utility.aabb_expand(wagon.bounding_box, const.fluid_wagon_search_d),
        type = "pump"
    })
    return utility.minimum_of(pumps, function (pump)
        local targets = pump.pump_input_rail_targets
        if targets == nil or #targets == 0 or pump.pumped_last_tick <= 0
            then return end
        return utility.sq_distance(wagon.position, pump.position)
    end)
end

--- Position `progress` tiles along the path, `seg` is a hint where the last lookup ended
--- @param path MapPosition[]
--- @param cum number[]
--- @param progress number
--- @param seg integer
--- @return MapPosition, integer
function fluid_flow.along(path, cum, progress, seg)
    if #path == 1
        then return path[1], 1 end
    while seg < #path - 1 and cum[seg + 1] < progress do
        seg = seg + 1
    end
    local a, b = path[seg], path[seg + 1]
    local len = cum[seg + 1] - cum[seg]
    local t = len > 0 and math.min(1, math.max(0, (progress - cum[seg]) / len)) or 1
    return {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t}, seg
end

return fluid_flow
