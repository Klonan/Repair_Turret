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
    filename = path.."repair_turret_mask.png",
    flags = { "mask" },
    line_length = 1,
    width = 122,
    height = 102,
    axially_symmetrical = false,
    direction_count = 1,
    frame_count = 1,
    shift = util.by_pixel(-4/2, -1/2),
    tint = {g = 1, r = 1, b = 0, a = 0.5},
    scale = 0.5
    --apply_runtime_tint = true
  }
}}

local animation =
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
}

turret.name = name
turret.localised_name = {name}
turret.icon = path.."repair_turret_icon.png"
turret.icon_size = 90
turret.logistics_radius = 0
turret.construction_radius = repair_range
turret.robot_slots_count = 0
turret.material_slots_count = 0
turret.charging_offsets = {}
turret.charging_energy = "0W"
turret.energy_usage = "1kW"
turret.energy_source =
{
  type = "electric",
  usage_priority = "secondary-input",
  input_flow_limit = "0.1MW",
  buffer_capacity = "1MJ"
}
turret.recharge_minimum = "0W"
turret.collision_box = util.area({0,0}, 0.7)
turret.selection_box = util.area({0,0}, 1)
turret.working_sound = nil
turret.base = picture
turret.base_animation = animation
turret.base_patch = util.empty_sprite()
turret.recharging_animation = util.empty_sprite()
turret.door_animation_down = util.empty_sprite()
turret.door_animation_up = util.empty_sprite()
turret.circuit_wire_max_distance = 0
turret.corpse = "small-remnants"
turret.minable = {result = name, mining_time = 1}

local item = util.copy(data.raw.item.roboport)
item.name = name
item.localised_name = {name}
item.icon = turret.icon
item.icon_size = turret.icon_size
item.place_result = name
item.subgroup = "defensive-structure"
item.order = "b[turret]-az[repair-turret]"

local beam = util.copy(data.raw.beam["laser-beam"])
util.recursive_hack_tint(beam, {g = 1, r = 0.2, b = 0.2})
beam.damage_interval = 10000
beam.name = "repair-beam"
beam.localised_name = "repair-beam"
beam.action = nil

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
    {"electronic-circuit", 4},
    {"steel-plate", 5},
    {"iron-gear-wheel", 5}
  },
  energy_required = 10,
  result = name
}


data:extend
{
  turret,
  item,
  beam,
  technology,
  recipe
}