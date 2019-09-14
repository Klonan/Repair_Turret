local util = require("data/tf_util/tf_util")
local shared = require("shared")
local name = shared.entities.repair_turret

local turret = util.copy(data.raw.roboport.roboport)
turret.name = name
turret.localised_name = {name}
util.recursive_hack_scale(turret, 0.5)

local item = util.copy(data.raw.item.roboport)
item.name = name
item.localised_name = {name}
item.place_result = name

data:extend
{
  turret,
  item
}