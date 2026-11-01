data:extend({{
    type = "bool-setting",
    name = "debug-tracker",
    setting_type = "runtime-global", -- Placeholder. This really should be per player
    default_value = false,
    order = "a"
}})

data:extend({{
    type = "bool-setting",
    name = "camera-stopping-opens-remote",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "a"
}})

data:extend({{
    type = "bool-setting",
    name = "skip-ahead",
    setting_type = "runtime-global",
    default_value = true,
    order = "b"
}, {
    type = "bool-setting",
    name = "skip-ahead-belts",
    setting_type = "runtime-global",
    default_value = true,
    order = "ba"
}, {
    type = "int-setting",
    name = "skip-ahead-ticks",
    setting_type = "runtime-global",
    default_value = 60,
    minimum_value = 1,
    maximum_value = 3600,
    order = "c"
}})

data:extend({{
    type = "string-setting",
    name = "multiple-outputs",
    setting_type = "runtime-global",
    default_value = "main-product",
    allowed_values = {"first-out", "main-product", "new-item"},
    order = "d"
}})

data:extend({{
    type = "double-setting",
    name = "fluid-speed",
    setting_type = "runtime-global",
    default_value = 0.09375, -- express belt, tiles per tick
    minimum_value = 0.01,
    maximum_value = 4,
    order = "e"
}})

data:extend({{
    type = "bool-setting",
    name = "fluid-highlight",
    setting_type = "runtime-global",
    default_value = true,
    order = "f"
}})
