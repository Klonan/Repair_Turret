local pathfinding = require("pathfinding")
local turret_update_interval = 23
local repair_update_interval = 53
local energy_per_heal = 10000

local script_data =
{
  turrets = {},
  turret_map = {},
  active_turrets = {},
  repair_queue = {},
  beam_multiple = {},
  beam_efficiency = {}
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
  --game.print("HI"..x..y)
  local map = script_data.turret_map
  local turrets = map[x] and map[x][y]
  --game.print(serpent.line(turrets))
  return turrets
end

local get_beam_multiple = function(force)
  return script_data.beam_multiple[force.index] or 1
end

local get_needed_energy = function(force)
  local base = energy_per_heal * turret_update_interval
  local modifier = script_data.beam_efficiency[force.index] or 1
  return base * modifier
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
      turret.energy >= get_needed_energy(force)
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

local connect_beams = function(entity)

  local x, y = to_map_position(entity.position)
  local radius = 1

  --[[for X = x - radius, x + radius do
    for Y = y - radius, y + radius do
      local turrets = get_turrets_in_map(X, Y)
      if turrets then
        for k, turret in pairs (turrets) do
          if turret.valid then
            turret.surface.create_entity
            {
              name = "repair-beam",
              source_position = {turret.position.x, turret.position.y - 2.5},
              --source = turret,
              target = entity,
              --target = {entity.position.x, entity.position.y - 2.5},
              --duration = turret_update_interval - 1,
              position = turret.position,
              force = turret.force
            }
            game.print("HI")
          end
        end
      end
    end
  end]]

  local turret = find_turret_for_repair(entity)

  if turret then
    turret.surface.create_entity
    {
      name = "repair-beam",
      source_position = {turret.position.x, turret.position.y - 2.5},
      --source = turret,
      target = entity,
      --target = {entity.position.x, entity.position.y - 2.5},
      --duration = turret_update_interval - 1,
      position = turret.position,
      force = turret.force
    }

    local turret_2 = find_turret_for_repair(turret)
    if turret_2 then
      turret_2.surface.create_entity
      {
        name = "repair-beam",
        source_position = {turret_2.position.x, turret_2.position.y - 2.5},
        --source = turret,
        target = turret,
        --target = {entity.position.x, entity.position.y - 2.5},
        --duration = turret_update_interval - 1,
        position = turret.position,
        force = turret.force
      }
    end
  end

end

local on_created_entity = function(event)
  local entity = event.created_entity or event.entity or event.destination
  if not (entity and entity.valid) then return end

  if entity.name ~= turret_name then return end

  --entity.energy = 0

  add_to_turret_map(entity)

  --connect_beams(entity)

  --script_data.turrets[entity.unit_number] = entity

end
local insert = table.insert
local highlight_path = function(source, path)
    --The pretty effect; time to pathfind

  local current_duration = 8
  local max_duration = turret_update_interval * 5

  local resolution = 4

  local surface = source.surface
  local force = source.force
  local huh = 100

  local make_beam = function(source, target, duration)
    local positions = {}
    local source_position = source.position
    local target_position = target.position

    --local dx = (source_position.x - target_position.x) / segments
    --local dy = (source_position.y - target_position.y) / segments
    local dx = (target_position.x - source_position.x)
    local dy = (target_position.y - source_position.y)
    local distance = ((dx * dx) + (dy * dy)) ^ 0.5
    local segments = 1 or math.ceil(distance / 10)
    local time = math.ceil(distance / 10)
    dx = dx / segments
    dy = dy / segments

    if source == target then return end
    for k = 0, segments do
      local position = {x = source_position.x + k * dx, y = source_position.y + k * dy, }
      insert(positions, position)
    end
    --insert(positions, target_position)
    for k = 1, #positions do
      local source_position = positions[k]
      local target_position = positions[k + 1]
      if target_position then
        current_duration = math.min(current_duration + time, max_duration)
        surface.create_entity
        {
          name = "repair-beam",
          --source = source,
          --source_offset = source.type == "roboport" and {x = 0, y = -2.5} or nil,
          --target = target,
          source_position = (source.type == "roboport" or k > 1) and {source_position.x, source_position.y - 2.5} or source_position,
          target_position = {target_position.x, target_position.y - 2.5},
          duration = current_duration,
          position = source_position,
          force = force
        }
      else
        return
      end
    end
  end

  local i = 1
  local last_target = source
  while true do
    local cell = path[i]
    if cell then
      local source = cell.owner
      if last_target then
        make_beam(last_target, source)
      end
      last_target = source
      i = i + 1
    else
      break
    end
  end
end

local update_turret = function(turret_data)
  local turret = turret_data.turret
  if not (turret and turret.valid) then return true end

  local entity = turret_data.entity
  if not (entity and entity.valid) then return true end

  if entity.get_health_ratio() == 1 then return true end

  local turret_energy = turret.energy
  new_energy = turret_energy - get_needed_energy(turret.force)
  if new_energy < 0 then
    return
  end

  local turret_cell = turret.logistic_cell
  local logistic_network = turret_cell.logistic_network
  if not logistic_network then return end
  local pickup_point = logistic_network.select_pickup_point{name = "repair-pack", position = turret.position, include_buffers = true}

  if not pickup_point then
    add_to_repair_queue(entity)
    return true
  end

  local stack
  local owner = pickup_point.owner
  if owner.type == "roboport" then
    stack = owner.get_inventory(defines.inventory.roboport_material).find_item_stack("repair-pack")
  else
    stack = owner.get_output_inventory().find_item_stack("repair-pack")
  end

  if not (stack and stack.valid and stack.valid_for_read) then
    add_to_repair_queue(entity)
    return true
  end

  local path = pathfinding.get_cell_path(owner, turret_cell, logistic_network)
  if not path then
    add_to_repair_queue(entity)
    return true
  end

  highlight_path(owner, path)



  stack.drain_durability(turret_update_interval)



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
  script_data.active_turrets[turret.unit_number] =
  {
    turret = turret,
    point = turret.get_logistic_point(),
    entity = entity
  }
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

  if name:find("repair%-turret%-power") then
    local number = name:sub(name:len())
    if not tonumber(number) then return end
    local index = research.force.index
    script_data.beam_multiple[index] = math.max(script_data.beam_multiple[index] or 1, (number + 1))
  end

  if name:find("repair%-turret%-efficiency") then
    local number = name:sub(name:len())
    if not tonumber(number) then return end
    local index = research.force.index
    local amount = 1 - (number / 4)
    script_data.beam_efficiency[index] = math.min(script_data.beam_efficiency[index] or 1, amount)
  end

end


local lib = {}

lib.events =
{
  --[defines.events.on_player_created] = on_player_created,
  [defines.events.on_built_entity] = on_created_entity,
  [defines.events.on_robot_built_entity] = on_created_entity,
  [defines.events.on_robot_built_entity] = on_created_entity,
  [defines.events.script_raised_built] = on_created_entity,
  [defines.events.script_raised_revive] = on_created_entity,
  [defines.events.on_entity_cloned] = on_created_entity,
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
