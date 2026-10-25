local const = {}

if prototypes then
    --- @module "library.event-ids"
    const.events = require("__item-cam-2__.library.event-ids")
end

const.__d_ttl = 30
const.__dc_bounding = {255, 0, 0}
const.__dc_bounding_real = {0, 0, 255}
const.__dc_inserter_seek = {255, 255, 0}
const.__dc_loader_seek = {0, 255, 0}
const.__dc_robot_seek = {0, 255, 255}
const.__dc_agricultural_tower_seek = {255, 0, 255}
const.__dc_item_entity_seek = {0, 255, 255}

const.__dc_robot_pos = {255, 0, 0}
const.__dc_min_cand = {255, 0, 0}
const.__dc_min_pass = {255, 255, 0}
const.__dc_min_pick = {0, 255, 0}

const.zoom_initial = 2
const.zoom_minimum = 0.3

const.name_setting_debug_tracker = "debug-tracker"
const.name_setting_camera_stopping_opens_remote = "camera-stopping-opens-remote"
const.name_setting_skip_ahead = "skip-ahead"
const.name_setting_skip_ahead_ticks = "skip-ahead-ticks"

const.name_options_shortcut = "item-cam-options"
const.name_shortcut = "item-cam"
const.name_selection_item = "item-cam"
const.name_keybind = "item-cam"
const.name_stop_console_command = "stop-item-cam"
const.name_trigger_check_cargo_pod_follow = "check-cargo-pod-follow"
const.name_trigger_check_plant_follow = "check-plant-follow"

const.inserter_search_d = 2.2
const.inserter_search_d_picking_up_feather = 0.08
const.loader_search_d = 1.5
const.robot_search_d = 0
const.belt_skip_ahead_max_belts = 64
const.belt_skip_ahead_inserter_search_d = 6
const.skip_ahead_retry_ticks = 10
const.smooth_end_feather = 0.05

-- Building direction -> belt piece direction -> target line_idx
const.drop_belt_line_idx = {
    [defines.direction.east] = {
        [defines.direction.north] = 1,
        [defines.direction.south] = 2,
        [defines.direction.west] = 2,
        [defines.direction.east] = 2
    },
    [defines.direction.west] = {
        [defines.direction.north] = 2,
        [defines.direction.south] = 1,
        [defines.direction.west] = 2,
        [defines.direction.east] = 2
    },
    [defines.direction.north] = {
        [defines.direction.east] = 2,
        [defines.direction.west] = 1,
        [defines.direction.north] = 2,
        [defines.direction.south] = 2
    },
    [defines.direction.south] = {
        [defines.direction.east] = 1,
        [defines.direction.west] = 2,
        [defines.direction.north] = 2,
        [defines.direction.south] = 2
    },
}

const.is_belt = {
    ["transport-belt"] = true,
    ["splitter"] = true,
    ["lane-splitter"] = true,
    ["underground-belt"] = true,
    ["linked-belt"] = true,
    ["loader"] = true,
    ["loader-1x1"] = true,
}
const.all_belt = {
    "transport-belt", "underground-belt", "linked-belt",
    "splitter", "lane-splitter",
    "loader", "loader-1x1"
}

const.missing_inventory_defines = {
    agricultural_tower_input = 2,
    agricultural_tower_output = 3
}

const.container_inventory_idx = {
    ["container"] = defines.inventory.chest,
    ["logistic-container"] = defines.inventory.chest,
    ["infinity-container"] = defines.inventory.chest,
    ["temporary-container"] = defines.inventory.chest,
    ["cargo-wagon"] = defines.inventory.cargo_wagon,
    ["cargo-landing-pad"] = defines.inventory.cargo_landing_pad_main,
    ["space-platform-hub"] = defines.inventory.hub_main,
    ["rocket-silo"] = defines.inventory.rocket_silo_rocket
}

const.is_robot = {
    ["construction-robot"] = true,
    ["logistic-robot"] = true
}
const.all_bot = {"construction-robot", "logistic-robot"}

const.is_crafting_machine = {
    ["furnace"] = true,
    ["assembling-machine"] = true
}

const.all_suitable_robot_order = {
    [defines.robot_order_type.deliver] = true,
    [defines.robot_order_type.deliver_items] = true,
    [defines.robot_order_type.pickup] = true,
    [defines.robot_order_type.pickup_items] = true
}
const.all_pickup_robot_order = {
    [defines.robot_order_type.pickup] = true,
    [defines.robot_order_type.pickup_items] = true
}
const.all_deliver_robot_order = {
    [defines.robot_order_type.deliver] = true,
    [defines.robot_order_type.deliver_items] = true
}

return const
