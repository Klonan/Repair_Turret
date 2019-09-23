local util = require("data/tf_util/tf_util")
local shared = require("shared")
local name = shared.entities.repair_turret
local repair_range = require("shared").repair_range

local turret = util.copy(data.raw.roboport.roboport)
util.recursive_hack_scale(turret, 0.5)

local path = util.path("data/entities/repair_turret/")

local picture = {layers = {
  {
    filename = path.."repair_turret.png",
    width = 330,
    height = 261,
    frame_count = 1,
    direction_count = 1,
    shift = {3/2, -1.8/2},
    scale = 0.5
  },
  {
    filename = path.."repair_turret_shadow.png",
    width = 330,
    height = 261,
    frame_count = 1,
    direction_count = 1,
    shift = {3/2, -1.8/2},
    scale = 0.5,
    draw_as_shadow = true
  },
  {
    filename = path.."repair_turret_mask.png",
    flags = { "mask" },
    line_length = 1,
    width = 122,
    height = 102,
    axially_symmetrical = false,
    direction_count = 1,
    frame_count = 1,
    shift = util.by_pixel(-4/2, -1/2),
    tint = {g = 1, r = 0, b = 0, a = 0.5},
    scale = 0.5
    --apply_runtime_tint = true
  },
}}

local animation =
{layers =
{
{
  filename = "__base__/graphics/entity/roboport/hr-roboport-base-animation.png",
  priority = "medium",
  width = 83,
  height = 59,
  frame_count = 8,
  animation_speed = 0.4,
  shift = {0, -2.5},
  scale = 0.66,
  run_mode = "backward"
},
{
  filename = path.."repair_turret_shadow_animation.png",
  width = 59,
  height = 60,
  animation_speed = 0.4,
  line_length = 1,
  frame_count = 8,
  shift = {3.5, 0.1},
  draw_as_shadow = true,
  scale = 0.66,
  run_mode = "backward"
  --apply_runtime_tint = true
}
}}

turret.name = name
turret.localised_name = {name}
turret.localised_description = {name.."-description"}
turret.icon = path.."repair_turret_icon.png"
turret.icon_size = 182
turret.logistics_radius = 0
turret.logistics_connection_distance = repair_range
turret.construction_radius = repair_range
turret.robot_slots_count = 0
turret.material_slots_count = 1
turret.charging_energy = "1MW"
turret.energy_usage = "2kW"
turret.energy_source =
{
  type = "electric",
  usage_priority = "secondary-input",
  input_flow_limit = "1MW",
  buffer_capacity = "10MJ"
}
turret.recharge_minimum = "1J"
turret.collision_box = util.area({0,0}, 0.7)
turret.selection_box = util.area({0,0}, 1)
--turret.hit_visualization_box = util.area({0, -2.5}, 0.1)
--turret.drawing_box = {{-1, -2.5},{1, 1}}
turret.working_sound = nil
turret.base = picture
turret.base_animation = animation
turret.base_patch = util.empty_sprite()
turret.charging_offsets = {{0, -2.5}}
turret.charge_approach_distance = 2
--turret.recharging_animation = util.empty_sprite()
turret.door_animation_down = util.empty_sprite()
turret.door_animation_up = util.empty_sprite()
turret.circuit_wire_max_distance = 0
turret.corpse = "small-remnants"
turret.minable = {result = name, mining_time = 0.5}

local item = util.copy(data.raw.item.roboport)
item.name = name
item.localised_name = {name}
item.icon = turret.icon
item.icon_size = turret.icon_size
item.place_result = name
item.subgroup = "defensive-structure"
item.order = "b[turret]-az[repair-turret]"
item.stack_size = 20

local laser_beam = util.copy(data.raw.beam["laser-beam"])

local beam = util.copy(data.raw.beam["electric-beam"])
beam.ground_light_animations = laser_beam.ground_light_animations
for k, v in pairs (beam.ground_light_animations) do
  v.repeat_count = 16
end
util.recursive_hack_tint(beam, {g = 1, r = 0.2, b = 0.2})
beam.damage_interval = 1
beam.name = "repair-beam"
beam.localised_name = "repair-beam"
beam.action_triggered_automatically = true
beam.action =
{
  type = "direct",
  action_delivery =
  {
    type = "instant",
    target_effects =
    {
      {
        type = "damage",
        damage = { amount = -1, type = util.damage_type("repair")}
      }
    }
  }
}

local technology =
{
  name = name,
  localised_name = {name},
  type = "technology",
  icon = turret.icon,
  icon_size = turret.icon_size,
  effects =
  {
    {
      type = "unlock-recipe",
      recipe = name
    }
  },

  prerequisites = {"turrets"},
  unit =
  {
    count = 100,
    ingredients =
    {
      {"automation-science-pack", 1},
      {"logistic-science-pack", 1}
    },
    time = 30
  },
  order = name
}

local recipe =
{
  type = "recipe",
  name = name,
  enabled = false,
  ingredients =
  {
    {"iron-gear-wheel", 10},
    {"steel-plate", 5},
    {"repair-pack", 5},
  },
  energy_required = 10,
  result = name
}

local n1 = 0
local n = function()
  n1 = n1 + 1
  return n1
end

local power_technologies =
{
  {
    name = "repair-turret-power-"..n(),
    localised_name = {"repair-turret-power"},
    type = "technology",
    icon = turret.icon,
    icon_size = turret.icon_size,
    upgrade = true,
    effects =
    {
      {
        type = "nothing",
        effect_description = {"repair-turret-power-description"}
      }
    },

    prerequisites = {name},
    unit =
    {
      count = 200,
      ingredients =
      {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1}
      },
      time = 30
    },
    order = name
  },
  {
    name = "repair-turret-power-"..n(),
    localised_name = {"repair-turret-power"},
    type = "technology",
    icon = turret.icon,
    icon_size = turret.icon_size,
    upgrade = true,
    effects =
    {
      {
        type = "nothing",
        effect_description = {"repair-turret-power-description"}
      }
    },
    prerequisites = {"repair-turret-power-"..n1-1},
    unit =
    {
      count = 200,
      ingredients =
      {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"chemical-science-pack", 1},
      },
      time = 30
    },
    order = name
  },
  {
    name = "repair-turret-power-"..n(),
    localised_name = {"repair-turret-power"},
    type = "technology",
    icon = turret.icon,
    icon_size = turret.icon_size,
    upgrade = true,
    effects =
    {
      {
        type = "nothing",
        effect_description = {"repair-turret-power-description"}
      }
    },
    prerequisites = {"repair-turret-power-"..n1-1},
    unit =
    {
      count = 200,
      ingredients =
      {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"chemical-science-pack", 1},
        {"utility-science-pack", 1},
      },
      time = 30
    },
    order = name
  },
}
data:extend(power_technologies)

n1 = 0

local efficiency_technologies =
{
  {
    name = "repair-turret-efficiency-"..n(),
    localised_name = {"repair-turret-efficiency"},
    type = "technology",
    icon = turret.icon,
    icon_size = turret.icon_size,
    upgrade = true,
    effects =
    {
      {
        type = "nothing",
        effect_description = {"repair-turret-efficiency-description"}
      }
    },
    prerequisites = {name},
    unit =
    {
      count = 200,
      ingredients =
      {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1}
      },
      time = 30
    },
    order = name
  },
  {
    name = "repair-turret-efficiency-"..n(),
    localised_name = {"repair-turret-efficiency"},
    type = "technology",
    icon = turret.icon,
    icon_size = turret.icon_size,
    upgrade = true,
    effects =
    {
      {
        type = "nothing",
        effect_description = {"repair-turret-efficiency-description"}
      }
    },
    prerequisites = {"repair-turret-efficiency-"..n1-1},
    unit =
    {
      count = 200,
      ingredients =
      {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"chemical-science-pack", 1},
      },
      time = 30
    },
    order = name
  },
  {
    name = "repair-turret-efficiency-"..n(),
    localised_name = {"repair-turret-efficiency"},
    type = "technology",
    icon = turret.icon,
    icon_size = turret.icon_size,
    upgrade = true,
    effects =
    {
      {
        type = "nothing",
        effect_description = {"repair-turret-efficiency-description"}
      }
    },
    prerequisites = {"repair-turret-efficiency-"..n1-1},
    unit =
    {
      count = 200,
      ingredients =
      {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"chemical-science-pack", 1},
        {"utility-science-pack", 1},
      },
      time = 30
    },
    order = name
  },
}
data:extend(efficiency_technologies)


data:extend
{
  turret,
  item,
  beam,
  technology,
  recipe
}