local util = require("data/tf_util/tf_util")
local shared = require("shared")
local name = shared.entities.repair_turret

local turret = util.copy(data.raw.roboport.roboport)
util.recursive_hack_scale(turret, 0.5)

turret.name = name
turret.localised_name = {name}
turret.logistics_radius = 0
turret.construction_radius = 32
turret.robot_slots_count = 0
turret.material_slots_count = 1
turret.charging_offsets = {}
turret.charging_energy = "0W"
turret.energy_usage = "0W"
turret.energy_source =
{
  type = "void"
}
turret.collision_box = util.area({0,0}, 0.9)
turret.selection_box = util.area({0,0}, 1)
turret.working_sound = nil





--[[

    energy_source =
    {
      type = "electric",
      usage_priority = "secondary-input",
      input_flow_limit = "5MW",
      buffer_capacity = "100MJ"
    },
    recharge_minimum = "40MJ",
    energy_usage = "50kW",
    -- per one charge slot
    charging_energy = "1000kW",
    logistics_radius = 25,
    construction_radius = 55,
    charge_approach_distance = 5,
    robot_slots_count = 7,
    material_slots_count = 7,
    stationing_offset = {0, 0},
    charging_offsets =
    {
      {-1.5, -0.5}, {1.5, -0.5}, {1.5, 1.5}, {-1.5, 1.5}
    },
]]

local item = util.copy(data.raw.item.roboport)
item.name = name
item.localised_name = {name}
item.place_result = name

data:extend
{
  turret,
  item
}