local turret_update_interval = 11
local repair_update_interval = 53
local energy_per_heal = 10000

local script_data =
{
  turrets = {},
  turret_map = {},
  active_turrets = {},
  repair_queue = {},
  beam_multiple = {}
}

local turret_name = require("shared").entities.repair_turret
local repair_range = require("shared").repair_range

local on_player_created = function(event)
  local player = game.get_player(event.player_index)
  player.insert("repair-turret")
end

local add_to_repair_queue = function(entity)

  if entity.has_flag("not-repairable") then return end

  local unit_number = entity.unit_number
  if not unit_number then return end

  if script_data.repair_queue[unit_number] then return end
  script_data.repair_queue[unit_number] = entity

end

local map_resolution = repair_range
local floor = math.floor

local to_map_position = function(position)
  local x = floor(position.x / map_resolution)
  local y = floor(position.y / map_resolution)
  return x, y
end

local add_to_turret_map = function(turret)
  local x, y = to_map_position(turret.position)
  local map = script_data.turret_map
  if not map[x] then
    map[x] = {}
  end

  if not map[x][y] then
    map[x][y] = {}
  end

  map[x][y][turret.unit_number] = turret

end

local get_turrets_in_map = function(x, y)
  local map = script_data.turret_map
  return map[x] and map[x][y]
end

local abs = math.abs

local find_turret_for_repair = function(entity, radius)
  local radius = radius or 1
  local position = entity.position
  local force = entity.force
  local surface = entity.surface

  --if not in any construction range, short-circuit...
  local networks = surface.find_logistic_networks_by_construction_area(position, force)
  if not next(networks) then return end

  local nearby = {}
  local active_turrets = script_data.active_turrets

  local check_turret = function(turret)
    local unit_number = turret.unit_number
    if
      turret ~= entity and
      (not active_turrets[unit_number]) and
      turret.force == force and
      turret.surface == surface and
      turret.is_connected_to_electric_network() and
      turret.energy >= (energy_per_heal * turret_update_interval)
    then
      nearby[unit_number] = turret
    end
  end

  local x, y = to_map_position(position)

  for X = x - radius, x + radius do
    for Y = y - radius, y + radius do
      local turrets = get_turrets_in_map(X, Y)
      if turrets then
        for k, turret in pairs (turrets) do
          if not turret.valid then
            turrets[k] = nil
          else
            check_turret(turret)
          end
        end
      end
    end
  end

  if not next(nearby) then return end
  local closest = surface.get_closest(position, nearby)
  local closest_position = closest.position
  if abs(closest_position.x - position.x) > repair_range then return end
  if abs(closest_position.y - position.y) > repair_range then return end

  return closest

end

local on_created_entity = function(event)
  local entity = event.created_entity or event.entity or event.destination
  if not (entity and entity.valid) then return end

  if entity.name ~= turret_name then return end

  --entity.energy = 0

  add_to_turret_map(entity)

  --script_data.turrets[entity.unit_number] = entity

end

local get_beam_multiple = function(force)
  return script_data.beam_multiple[force.index] or 1
end

local update_turret = function(turret_data)
  local turret = turret_data.turret
  if not (turret and turret.valid) then return true end

  local entity = turret_data.entity
  if not (entity and entity.valid) then return true end

  if entity.get_health_ratio() == 1 then return true end

  local turret_energy = turret.energy
  new_energy = turret_energy - (turret_update_interval * energy_per_heal)
  if new_energy < 0 then
    return
  end

  --entity.health = entity.health + max_repair
  turret.energy = new_energy

  for k = 1, get_beam_multiple(turret.force) do

    turret.surface.create_entity
    {
      name = "repair-beam",
      source_position = {turret.position.x, turret.position.y - 2.5},
      target = entity,
      duration = turret_update_interval - 1,
      position = turret.position,
      force = turret.force
    }

  end

  --turret.surface.create_entity{name = "flying-text", position = turret.position, text = "!"}

end

local activate_turret = function(turret, entity)
  if script_data.active_turrets[turret.unit_number] then
    error("Turret already active?")
  end
  assert(turret.name == turret_name)
  script_data.active_turrets[turret.unit_number] = {turret = turret, entity = entity}
end

local check_repair = function(entity)
  if not (entity and entity.valid) then return true end
  if entity.get_health_ratio() == 1 then return true end

  --entity.surface.create_entity{name = "flying-text", position = entity.position, text = "?"}

  local turret = find_turret_for_repair(entity, 1)
  if not turret then return end

  activate_turret(turret, entity)
  return true



end

local on_tick = function(event)

  local turret_update_mod = event.tick % turret_update_interval
  for k, turret_data in pairs (script_data.active_turrets) do
    if k % turret_update_interval == turret_update_mod then
      if update_turret(turret_data) then
        script_data.active_turrets[k] = nil
      end
    end
  end

  local repair_update_mod = event.tick % repair_update_interval
  for k, repair in pairs (script_data.repair_queue) do
    if k % repair_update_interval == repair_update_mod then
      if check_repair(repair) then
        script_data.repair_queue[k] = nil
      end
    end
  end

end

local on_entity_damaged = function(event)

  local entity = event.entity
  if not (entity and entity.valid) then
    return
  end

  add_to_repair_queue(entity)
end

local on_research_finished = function(event)
  local research = event.research
  if not (research and research.valid) then return end

  local name = research.name


  if not name:find("repair%-turret%-power") then return end

  local number = name:sub(name:len())
  if not tonumber(number) then return end

  local index = research.force.index

  script_data.beam_multiple[index] = math.max(script_data.beam_multiple[index] or 1, (number + 1))

end


local lib = {}

lib.events =
{
  [defines.events.on_player_created] = on_player_created,
  [defines.events.on_built_entity] = on_created_entity,
  [defines.events.on_robot_built_entity] = on_created_entity,
  [defines.events.on_robot_built_entity] = on_created_entity,
  [defines.events.script_raised_built] = on_created_entity,
  [defines.events.script_raised_revive] = on_created_entity,
  [defines.events.on_tick] = on_tick,
  [defines.events.on_entity_damaged] = on_entity_damaged,
  [defines.events.on_research_finished] = on_research_finished,

}

lib.on_load = function()
  script_data = global.repair_turret or script_data
end

lib.on_init = function()
  global.repair_turret = global.repair_turret or script_data
end

return lib
