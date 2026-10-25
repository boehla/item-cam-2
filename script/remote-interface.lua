local state = require("state")
local focus_behavior = require("focus-behavior")
local focus_select = require("focus-select")

--- @param focus_id integer
--- @param assert_running_state? boolean
local function get_focus_assertive(focus_id, assert_running_state)
    assert(type(focus_id) == "number", "focus_id is not number")

    local focus = state.focuses[focus_id]

    assert(focus ~= nil, "focus instance with this id does not exist")
    assert(focus.valid, "focus instance is invalid")

    if assert_running_state ~= nil then
        local msg = "cannot be done when focus instance is "..(assert_running_state and "" or "not").." running"
        assert(focus.running == assert_running_state, msg)
    end

    return focus
end

--- @param v MapPosition
--- @param arg_name string
local function sanitize_position_assertive(v, arg_name)
    assert(v ~= nil, arg_name.." is nil")
    assert(type(v) == "table", arg_name.." is not a table")
    if v.x == nil then
        v.x = v[1]
        v.y = v[2]
        v[1] = nil
        v[2] = nil
    end
    assert(v.x ~= nil, arg_name..".x is nil")
    assert(v.y ~= nil, arg_name..".y is nil")
end

remote.add_interface("item-cam-2", {
    --- @param follow_rules? FollowRule[]
    focus_create = function (follow_rules)
        --- @type FocusInstanceRemote
        return {
            id = focus_behavior.create(follow_rules).id
        }
    end,

    --- @param focus_id integer
    focus_is_valid = function (focus_id)
        assert(type(focus_id) == "number", "focus_id is not number")

        local focus = state.focuses[focus_id]
        return focus ~= nil and focus.valid
    end,

    --- @param focus_id integer
    focus_is_running = function (focus_id)
        assert(type(focus_id) == "number", "focus_id is not number")

        local focus = state.focuses[focus_id]
        return focus ~= nil and focus.valid and focus.running
    end,

    --- @param focus_id integer
    focus_get_tags = function (focus_id)
        local focus = get_focus_assertive(focus_id)
        return focus.tags
    end,

    --- @param focus_id integer
    focus_set_tags = function (focus_id, value)
        local focus = get_focus_assertive(focus_id)

        assert(type(value) == "table", "value is not table")

        focus.tags = value
    end,

    --- @param focus_id integer
    --- @param controlling LuaPlayer
    focus_add_controllable_player = function (focus_id, controlling)
        focus_behavior.add_controllable_player(get_focus_assertive(focus_id, false), controlling)
    end,

    --- @param focus_id integer
    --- @param controlling LuaPlayer
    focus_add_controllable_player_remote = function (focus_id, controlling)
        focus_behavior.add_controllable_player_remote(get_focus_assertive(focus_id, false), controlling)
    end,

    --- @param focus_id integer
    --- @param controlling LuaGuiElement
    focus_add_controllable_camera = function (focus_id, controlling)
        focus_behavior.add_controllable_camera(get_focus_assertive(focus_id, false), controlling)
    end,

    --- @param focus_id integer
    --- @param surface SurfaceIdentification
    --- @param position MapPosition
    focus_start_from_point = function (focus_id, surface, position)
        local focus = get_focus_assertive(focus_id, false)

        local surface_resolved = surface
        if type(surface) ~= "userdata" then
            --- @cast surface -LuaSurface
            surface_resolved = game.get_surface(surface)
        end
        --- @cast surface LuaSurface

        assert(surface_resolved ~= nil, "surface resolved to nil")
        sanitize_position_assertive(position, "position")

        local watchdog_resolved = focus_select.at_position(surface_resolved, position)
        if watchdog_resolved == nil
            then return false end

        focus_behavior.assign_target_initial(focus, watchdog_resolved)
        focus_behavior.start_following(focus)
        return true
    end,

    --- @param focus_id integer
    --- @param entity LuaEntity
    focus_start_from_entity = function (focus_id, entity)
        local focus = get_focus_assertive(focus_id, false)

        assert(entity ~= nil, "entity resolved to nil")
        assert(entity.valid, "entity is invalid")

        local watchdog_resolved = focus_select.entity(entity)
        if watchdog_resolved == nil
            then return false end

        focus_behavior.assign_target_initial(focus, watchdog_resolved)
        focus_behavior.start_following(focus)
        return true
    end,

    --- @param focus_id integer
    --- @param candidates LuaEntity[]
    focus_start_from_closest = function (focus_id, candidates, center)
        local focus = get_focus_assertive(focus_id, false)

        assert(candidates ~= nil, "candidates resolved to nil")
        assert(type(candidates) ~= "table", "candidates is not table")
        sanitize_position_assertive(center, "center")

        local watchdog_resolved = focus_select.closest(candidates, center)
        if watchdog_resolved == nil
            then return false end

        focus_behavior.assign_target_initial(focus, watchdog_resolved)
        focus_behavior.start_following(focus)
        return true
    end,

    --- @param focus_id integer
    focus_destroy = function (focus_id)
        get_focus_assertive(focus_id) -- Make sure it exists

        -- Avoid event handler mutations. Wait for bulldozer
        state.focuses_to_destroy[focus_id] = true
    end
})
