local const = require("const")
local utility = {}

function utility.debug(...)
    if not settings.global[const.name_setting_debug_tracker].value
        then return end
    print(game.tick, ...)
end

--- @param surface LuaSurface
--- @param position MapPosition
--- @param color Color.0
function utility.debug_pos(surface, position, color)
    if not settings.global[const.name_setting_debug_tracker].value
        then return end
    rendering.draw_circle({
        surface = surface,
        color = color,
        width = 1,
        target = position,
        radius = 0.25,
        time_to_live = const.__d_ttl
    })
end
--- @param item_on_line DetailedItemOnLine
--- @param line_idx integer
--- @param entity LuaEntity
--- @param color Color.0
function utility.debug_item_on_line(item_on_line, line_idx, entity, color)
    if not settings.global[const.name_setting_debug_tracker].value
        then return end
    rendering.draw_circle({
        surface = entity.surface,
        color = color,
        width = 1,
        target = entity.get_line_item_position(line_idx, item_on_line.position),
        radius = 0.25,
        time_to_live = 1
    })
end
--- @param surface LuaSurface
--- @param area BoundingBox
--- @param color Color.0
function utility.debug_area(surface, area, color)
    if not settings.global[const.name_setting_debug_tracker].value
        then return end
    rendering.draw_rectangle({
        surface = surface,
        color = color,
        width = 1,
        left_top = area.left_top,
        right_bottom = area.right_bottom,
        time_to_live = const.__d_ttl
    })
end

--- @param a Vector
--- @param b Vector
function utility.sq_distance(a, b)
    return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
end

--- @param src MapPosition
--- @param dst MapPosition
function utility.vec_angle(src, dst)
    local angle = math.atan2(dst.x - src.x, dst.y - src.y)
    --- @type Vector
    return {
        x = math.sin(angle),
        y = math.cos(angle)
    }
end

--- @param p MapPosition
--- @param c MapPosition
--- @param rad number
function utility.vec_rotate_around_cw(p, c, rad)
    local dx = p.x - c.x
    local dy = p.y - c.y
    --- @type MapPosition
    return {
        x = c.x + dx * math.cos(rad) - dy * math.sin(rad),
        y = c.y + dx * math.sin(rad) + dy * math.cos(rad)
    }
end

--- @param aabb BoundingBox
function utility.aabb_center(aabb)
    --- @type Vector
    return {
        x = (aabb.right_bottom.x + aabb.left_top.x) / 2,
        y = (aabb.right_bottom.y + aabb.left_top.y) / 2
    }
end

--- @param position MapPosition
--- @param w number
--- @param h? number
function utility.aabb_around(position, w, h)
    h = h or w
    --- @type BoundingBox
    return {
        left_top = {x = position.x - w, y = position.y - h},
        right_bottom = {x = position.x + w, y = position.y + h}
    }
end

--- @param aabb BoundingBox
--- @param w number
--- @param h? number
function utility.aabb_expand(aabb, w, h)
    h = h or w
    --- @type BoundingBox
    return {
        left_top = {x = aabb.left_top.x - w, y = aabb.left_top.y - h},
        right_bottom = {x = aabb.right_bottom.x + w, y = aabb.right_bottom.y + h}
    }
end

local has_non_rotated_selection_box = {
    ["car"] = true,
    ["cargo-wagon"] = true,
    ["fluid-wagon"] = true
}
--- @param entity LuaEntity
function utility.rotated_selection_box(entity)
    if not has_non_rotated_selection_box[entity.type] then
        return entity.selection_box
    end

    local selection_box = entity.selection_box
    local center = utility.aabb_center(selection_box)
    local hw = selection_box.left_top.x - center.x
    local hh = selection_box.left_top.y - center.y
    local angle_rad = (selection_box.orientation or 0) * 2 * math.pi

    local tl_rot = utility.vec_rotate_around_cw({x = center.x - hw, y = center.y - hh}, center, angle_rad)
    local tr_rot = utility.vec_rotate_around_cw({x = center.x + hw, y = center.y - hh}, center, angle_rad)
    local bl_rot = utility.vec_rotate_around_cw({x = center.x - hw, y = center.y + hh}, center, angle_rad)
    local br_rot = utility.vec_rotate_around_cw({x = center.x + hw, y = center.y + hh}, center, angle_rad)

    local tl_x = math.min(tl_rot.x, tr_rot.x, bl_rot.x, br_rot.x)
    local tl_y = math.min(tl_rot.y, tr_rot.y, bl_rot.y, br_rot.y)
    local br_x = math.max(tl_rot.x, tr_rot.x, bl_rot.x, br_rot.x)
    local br_y = math.max(tl_rot.y, tr_rot.y, bl_rot.y, br_rot.y)

    --- @type BoundingBox
    return {
        left_top = {x = tl_x, y = tl_y},
        right_bottom = {x = br_x, y = br_y}
    }
end

--- @generic T
--- @param arr T[]
--- @param f_fn fun(entry: T): boolean?
--- @return T[]
function utility.filtered(arr, f_fn)
    local ret = {}
    for _, entry in ipairs(arr) do
        if f_fn(entry) then
            table.insert(ret, entry)
        end
    end
    return ret
end

--- @generic T
--- @param arr T[]
--- @param f_fn fun(entry: T): boolean?
function utility.filtered_in_place(arr, f_fn)
    local idx = 1
    local len = #arr
    while idx <= len do
        if not f_fn(arr[idx]) then
            table.remove(arr, idx)
            len = len - 1
        else
            idx = idx + 1
        end
    end
    return arr
end

--- @generic T
--- @param arr table<string, any>|LuaCustomTable<string, any>
--- @param m_fn fun(entry: string, entry_value: any): T?
--- @return T[]
function utility.keys_mapped(arr, m_fn)
    local ret = {}
    for entry, entry_value in pairs(arr) do
        local ret_entry = m_fn(entry, entry_value)
        if ret_entry ~= nil then
            table.insert(ret, ret_entry)
        end
    end
    return ret
end

--- @generic T
--- @param arr table<string, any>|LuaCustomTable<string, any>
--- @param m_fn fun(entry: string, entry_value: any): T[]?
--- @return T[]
function utility.keys_mapped_flattened(arr, m_fn)
    local ret = {}
    for entry, entry_value in pairs(arr) do
        local ret_entry = m_fn(entry, entry_value)
        if ret_entry ~= nil then
            for _, x in ipairs(ret_entry) do
                table.insert(ret, x)
            end
        end
    end
    return ret
end

--- @generic T, U
--- @param arr T[]
--- @param m_fn fun(entry: T, idx: integer): U?
--- @return U[]
function utility.mapped(arr, m_fn)
    local ret = {}
    for idx, entry in ipairs(arr) do
        local ret_entry = m_fn(entry, idx)
        if ret_entry ~= nil then
            table.insert(ret, ret_entry)
        end
    end
    return ret
end

--- @generic T, U
--- @param arr T[]
--- @param m_fn fun(entry: T): U[]?
--- @return U[]
function utility.mapped_flattened(arr, m_fn)
    local ret = {}
    for _, entry in ipairs(arr) do
        local ret_entry = m_fn(entry)
        if ret_entry ~= nil then
            for _, x in ipairs(ret_entry) do
                table.insert(ret, x)
            end
        end
    end
    return ret
end

--- @generic T, U
--- @param arr T[]
--- @param f_fn fun(entry: T, idx: integer): U?
--- @return U?
function utility.first(arr, f_fn)
    for idx, entry in ipairs(arr) do
        local r_fn = f_fn(entry, idx)
        if r_fn
            then return r_fn end
    end
end

--- @generic T
--- @param arr T[]
--- @param target T
--- @return boolean, integer?
function utility.contains(arr, target)
    for idx, entry in ipairs(arr) do
        if entry == target then
            return true, idx
        end
    end
    return false
end

--- @generic T, U
--- @param arr T[]
--- @param d_fn fun(entry: T, idx: integer): number?, U?
--- @return T?, U?
function utility.minimum_of(arr, d_fn)
    if arr == nil
        then return end
    local local_minimum
    local local_d
    local tag

    local cnt = 0
    for idx, entry in ipairs(arr) do
        local d, new_tag = d_fn(entry, idx)
        if d ~= nil then cnt = cnt + 1 end
        if d ~= nil and (local_d == nil or d < local_d) then
            local_minimum = entry
            local_d = d
            tag = new_tag
        end
    end
    -- utility.debug("minimum_of candidates "..cnt.."/"..#arr)

    return local_minimum, tag
end

--- @param belt_entity LuaEntity
--- @param d_fn fun(item: DetailedItemOnLine, line_idx: integer): number?
--- @return DetailedItemOnLine?, integer?
function utility.minimum_on_belt(belt_entity, d_fn)
    local local_minimum
    local local_line_idx
    local local_d

    local line_count = belt_entity.get_max_transport_line_index()
    local cnt = 0
    local total = 0
    for line_idx = 1, line_count do
        local line = belt_entity.get_transport_line(line_idx)
        for _, item in ipairs(line.get_detailed_contents()) do
            total = total + 1
            local d = d_fn(item, line_idx)
            if d ~= nil then cnt = cnt + 1 end
            if d ~= nil and (local_d == nil or d < local_d) then
                local_minimum = item
                local_line_idx = line_idx
                local_d = d
            end
        end
    end
    -- utility.debug("minimum_on_belt candidates "..cnt.."/"..total)

    return local_minimum, local_line_idx
end

--- @param line LuaTransportLine
--- @param fn fun(item: DetailedItemOnLine): boolean?
--- @return DetailedItemOnLine?
function utility.first_on_line(line, fn)
    for _, item in ipairs(line.get_detailed_contents()) do
        if fn(item) then return item end
    end
end

--- @param belt_entity LuaEntity
--- @param fn fun(item: DetailedItemOnLine): boolean?
--- @return DetailedItemOnLine?, integer?
function utility.first_on_belt(belt_entity, fn)
    local line_count = belt_entity.get_max_transport_line_index()
    for line_idx = 1, line_count do
        local item = utility.first_on_line(belt_entity.get_transport_line(line_idx), fn)
        if item then
            return item, line_idx
        end
    end
end

--- @param arr LuaEntity[]
--- @param fn fun(item: DetailedItemOnLine): boolean?
--- @return DetailedItemOnLine?, integer?, LuaEntity?
function utility.first_on_belts(arr, fn)
    for _, belt_entity in ipairs(arr) do
        local item, line_idx = utility.first_on_belt(belt_entity, fn)
        if item then
            return item, line_idx, belt_entity
        end
    end
end

--- @class FocusItemWhitelist
--- @field item? PrototypeWithQuality
--- @field items? string[]
--- @field qualities? string[]
--- @field fluid? string Followed fluid, items don't match

utility.__no_wl = {}

--- @param item LuaItemStack
--- @param wl FocusItemWhitelist
function utility.is_item_filtered(item, wl)
    if wl.fluid ~= nil
        then return false end
    if wl.item ~= nil and (
        item.name ~= wl.item.name
        or item.quality.name ~= wl.item.quality
    ) then return false end

    if wl.items ~= nil and not utility.contains(wl.items, item.name)
        then return false end
    if wl.qualities ~= nil and not utility.contains(wl.qualities, item.quality)
        then return false end

    return true
end

--- @param inventory LuaInventory
--- @param item_wl FocusItemWhitelist
--- @return LuaItemStack?
function utility.first_item_stack_filtered(inventory, item_wl)
    if inventory == nil
        then return end
    for idx = 1, #inventory do
        local stack = inventory[idx]
        if
            stack.valid_for_read
            and stack.count > 0
            and utility.is_item_filtered(stack, item_wl)
        then
            return inventory[idx]
        end
    end
end

--- @param entity LuaEntity
function utility.entity_proto(entity)
    --- @type PrototypeWithQuality
    return {
        name = entity.name,
        quality = entity.quality.name
    }
end


--- @param item LuaItemStack
function utility.item_proto(item)
    --- @type PrototypeWithQuality
    return {
        name = item.name,
        quality = item.quality.name
    }
end

--- Search the surface for agricultural towers that may have the reach to mine plant at specified position
--- @param plant_entity LuaEntity
function utility.search_agricultural_towers_owning_plant(plant_entity)
    local max_proto_distance = 0
    for _, proto in pairs(prototypes.entity) do
        if proto.type == "agricultural-tower" then
            max_proto_distance = math.max(
                max_proto_distance,
                proto.agricultural_tower_radius * proto.growth_grid_tile_size
            )
        end
    end
    max_proto_distance = max_proto_distance + 1 -- Give buffer because plant's position will change as it grows

    local search_area = utility.aabb_around(plant_entity.position, max_proto_distance)
    utility.debug_area(plant_entity.surface, search_area, const.__dc_agricultural_tower_seek)

    return utility.filtered(plant_entity.surface.find_entities_filtered({
        area = search_area,
        type = {"agricultural-tower"}
    }), function (entry)
        utility.debug_area(plant_entity.surface, entry.selection_box, const.__dc_min_pass)
        if not utility.contains(entry.owned_plants, plant_entity)
            then return end
        utility.debug_area(plant_entity.surface, entry.selection_box, const.__dc_min_pick)
        return true
    end)
end

--- @class UtilityProductsOptions
--- @field items? boolean
--- @field fluids? boolean

--- @param products (ItemProduct|FluidProduct|ResearchProgressProduct)[]
--- @param wl UtilityProductsOptions
--- @return string[]?
function utility.products_filtered(products, wl)
    local results = {}
    for _, entry in ipairs(products) do
        if
            (wl.items and entry.type == "item")
            or (wl.fluids and entry.type == "fluid")
        then
            table.insert(results, entry.name)
        end
    end
    if #results == 0
        then return end
    return results
end

--- @param entity LuaEntity
--- @return PrototypeWithQuality?
function utility.crafter_recipe_proto(entity)
    local recipe, quality = entity.get_recipe()
    if recipe ~= nil then
        --- @cast quality -nil
        --- @type PrototypeWithQuality
        return {
            name = recipe.name,
            quality = quality.name
        }
    end
    if entity.type == "furnace" and entity.previous_recipe ~= nil then
        return {
            name = entity.previous_recipe.name.name,
            quality = entity.previous_recipe.quality.name
        }
    end
end

--- @overload fun(event_name: ic2_events.on_focus_switch, data: EventDataStub.on_focus_switch)
--- @overload fun(event_name: ic2_events.on_focus_destroyed, data: EventDataStub.on_focus_destroyed)
utility.raise_event = function (event_name, data)
    --- @diagnostic disable-next-line: param-type-mismatch
    script.raise_event(event_name, data)
end

return utility
