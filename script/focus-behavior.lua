local const = require("const")
local utility = require("utility")
local focus_update = require("focus-update")
local focus_watchdog = require("focus-watchdog")
local focus_follow_rules = require("focus-follow-rules")
local state = require("state")

local focus_behavior = {}

--- @class FocusSmoothingState
--- @field speed? number
--- @field min_speed? number
--- @field mul? number
--- @field final_tick integer

--- @alias FocusControllable FocusControllablePlayerRemote|FocusControllablePlayer|FocusControllableGuiCamera

local controllables = {
    ["gui-camera"] = require("controllable.gui-camera"),
    ["player-remote"] = require("controllable.player-remote"),
    ["player"] = require("controllable.player")
}

--- @class FocusInstance
--- @field id integer
--- @field valid boolean
--- @field running boolean
--- @field tags? table<string, AnyBasic>
--- @field controlling FocusControllable[]
--- @field smoothing? FocusSmoothingState If set, smooth_position chases position at some rate instead of directly copying it
--- @field watching? FocusWatchdog
--- @field follow_rules? FollowRule[]
--- @field follow_rules_cnt? number
--- @field follow_rules_start_idx? number
--- @field position MapPosition
--- @field smooth_position MapPosition
--- @field surface LuaSurface
--- @field seen_items? table<string, true> Items already followed, for multiple-outputs "new-item"
--- @field multiple_outputs? string Overrides setting multiple-outputs for this focus
--- @field prefer_products? string[] Scripted: products to follow out of a recipe before any other
--- @field fluid_prefer? table<string, string[]> Scripted: per fluid, route targets (kind "rail", recipe or entity name) to go for first
--- @field fluid_speed? number Scripted: overrides setting fluid-speed for this focus
--- @field skip_glide_speed? number Scripted: camera glides to a skip-ahead target at this speed (tiles/tick)

--- @param follow_rules? FollowRule[]
function focus_behavior.create(follow_rules)
    local id = state.get_next_focus_id()

    --- @type FocusInstance
    local ret = {
        id = id,
        valid = true,
        running = false,
        controlling = {},
        position = {x = 0, y = 0},
        smooth_position = {x = 0, y = 0},
        surface = game.surfaces["nauvis"]
    }
    if follow_rules ~= nil then
        ret.follow_rules = follow_rules
        ret.follow_rules_cnt = #follow_rules
        ret.follow_rules_start_idx = 1
    end

    state.focuses[id] = ret
    return ret
end

--- @param focus FocusInstance
--- @param controlling LuaPlayer
function focus_behavior.add_controllable_player_remote(focus, controlling)
    table.insert(focus.controlling, controllables["player-remote"].create(controlling))
end

--- @param focus FocusInstance
--- @param controlling LuaPlayer
function focus_behavior.add_controllable_player(focus, controlling)
    table.insert(focus.controlling, controllables["player"].create(controlling))
end

--- @param focus FocusInstance
--- @param controlling LuaGuiElement
function focus_behavior.add_controllable_camera(focus, controlling)
    table.insert(focus.controlling, controllables["gui-camera"].create(controlling))
end

--- @param focus FocusInstance
--- @param watching FocusWatchdog
function focus_behavior.assign_target_initial(focus, watching)
    focus.watching = watching
    focus.position = focus_watchdog.get_position[watching.type](watching)
    focus.smooth_position = {x = focus.position.x, y = focus.position.y}
    focus.surface = focus_watchdog.get_surface[watching.type](watching)

    focus_follow_rules.apply_matching(focus)
end

--- @param focus FocusInstance
function focus_behavior.start_following(focus)
    assert(focus.watching ~= nil, "focus instance has no initial watchdog set")

    focus.running = true

    for _, controllable in ipairs(focus.controlling) do
        controllables[controllable.type].start(controllable, focus)
    end
end

--- @param focus FocusInstance
function focus_behavior.destroy(focus)
    if focus.running then
        for _, controllable in ipairs(focus.controlling) do
            controllables[controllable.type].stop(controllable)
        end
    end

    focus.valid = false
    focus.running = false
    state.focuses[focus.id] = nil

    utility.raise_event(const.events.on_focus_destroyed, {
        focus_id = focus.id,
        was_running = focus.running,
        previous_target = focus.running and focus.watching.handle or nil,
        surface = focus.running and focus.surface or nil,
        position = focus.running and focus.position or nil,
        smooth_position = focus.running and focus.smooth_position or nil
    })
end

--- @param focus FocusInstance
local function update_smooth_position(focus)
    local smoothing = focus.smoothing
    local real_d = math.sqrt(utility.sq_distance(focus.smooth_position, focus.position))
    if
        not smoothing
        or game.tick >= smoothing.final_tick
        or real_d < const.smooth_end_feather
    then
        focus.smoothing = nil
        focus.smooth_position.x = focus.position.x
        focus.smooth_position.y = focus.position.y
        return
    end

    local angle = utility.vec_angle(focus.smooth_position, focus.position)
    local d = real_d * (smoothing.mul or 1)
    d = math.min(focus.smoothing.speed or d, d)
    d = math.max(focus.smoothing.min_speed or 0, d)
    d = math.min(d, real_d)

    focus.smooth_position.x = focus.smooth_position.x + angle.x * d
    focus.smooth_position.y = focus.smooth_position.y + angle.y * d
end

--- @param focus FocusInstance
function focus_behavior.update(focus)
    utility.filtered_in_place(focus.controlling, function (controllable)
        return controllables[controllable.type].valid(controllable)
    end)

    if #focus.controlling == 0 then
        focus.valid = false
        return
    end

    if not focus_update.tick(focus) then
        focus.valid = false
        return
    end

    -- Update location
    local watching = focus.watching
    --- @cast watching -nil

    local new_surface = focus_watchdog.get_surface[watching.type](watching)
    if new_surface ~= focus.surface and focus.smoothing ~= nil then
        utility.debug("smoothing axed because surface changed")
        focus.smoothing = nil
    end
    focus.surface = new_surface
    focus.position = focus_watchdog.get_position[watching.type](watching)
    update_smooth_position(focus)

    -- Control the controlling
    for _, controllable in ipairs(focus.controlling) do
        controllables[controllable.type].update(controllable, focus)
    end
end

return focus_behavior
