local util = require("util")
local pathfinding = require("pathfinding")
local turret_update_interval = 31
local repair_update_interval = 60
local energy_per_heal = 100000
local transmission_energy_per_hop = 5000

local script_data =
{
  turrets = {},
  turret_map = {},
  active_turrets = {},
  repair_queue = {},
  beam_multiple = {},
  beam_efficiency = {},
  free_pack_migration = true,
  pathfinder_cache = {}
}

local turret_name = require("shared").entities.repair_turret
local repair_range = require("shared").repair_range

local on_player_created = function(event)
  local player = game.get_player(event.player_index)
  player.insert("repair-turret")
end

local clear_cache = function()
  --game.print("Clearing cache")
  script_data.pathfinder_cache = {}
  pathfinding.cache = script_data.pathfinder_cache
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

local on_created_entity = function(event)
  local entity = event.created_entity or event.entity or event.destination
  if not (entity and entity.valid) then return end

  if entity.name == turret_name then
    add_to_turret_map(entity)
  end

  if entity.logistic_cell then
    clear_cache()
  end

end

local insert = table.insert
local max = math.max
local min = math.min
local abs = math.abs
local ceil = math.ceil

local juggle = function(number, amount)
  return number + ((math.random() + 0.5) * amount)
end
local beam_name = "repair-beam"
local max_duration = turret_update_interval * 8

local highlight_path = function(source, path)

  --local profiler = game.create_profiler()

  local current_duration = turret_update_interval

  local surface = source.surface
  local create_entity = surface.create_entity
  local force = source.force
  local count = 0

  local make_beam = function(source, target)
    --count = count + 1
    --local profiler = game.create_profiler()
    local source_position = source.position
    local target_position = target.position

    local x1, y1 = source_position.x, source_position.y - 2.5
    local x2, y2 = target_position.x, target_position.y - 2.5

    --game.print({"", count, " get positions ", profiler})
    --profiler.reset()

    source.energy = (source.energy - transmission_energy_per_hop) + 1

    --game.print({"", count, " set energy ", profiler})
    --profiler.reset()

    local position = {x1, y1}
    local beam = create_entity
    {
      name = beam_name,
      source_position = position,
      target_position = position,
      duration = current_duration,
      position = position,
      force = force,
    }
    beam.set_beam_target({x2, y2})

    --game.print({"", count, " create entity ", profiler})

    if current_duration < max_duration then
      current_duration = current_duration + 3
    end
  end

  local i = 1
  local last_target = source
  while true do
    local cell = path[i]
    if not cell then break end

    if not (cell.valid and cell.transmitting) then
      clear_cache()
      return
    end

    local source = cell.owner
    if last_target then
      make_beam(last_target, source)
    end
    last_target = source
    i = i + 1

  end

end

local repair_items
local get_repair_items = function()
  if repair_items then return repair_items end
  --Deliberately not 'local'
  repair_items = {}
  for name, item in pairs (game.item_prototypes) do
    if item.type == "repair-tool" then
      repair_items[name] = item
    end
  end
  return repair_items
end

local get_pickup_entity = function(turret)

  local inventory = turret.get_inventory(defines.inventory.roboport_material)
  if not inventory.is_empty() then
    return turret, inventory[1]
  end

  local position = turret.position
  local turret_cell = turret.logistic_cell
  local logistic_network = turret_cell.logistic_network
  if not logistic_network then return end

  local select_pickup_point = logistic_network.select_pickup_point
  local pickup_point
  local repair_item
  for name, item in pairs(get_repair_items()) do
    pickup_point = select_pickup_point{name = name, position = position, include_buffers = true}
    repair_item = name
    if pickup_point then break end
  end

  if not pickup_point then return end

  local stack
  local owner = pickup_point.owner
  if owner.type == "roboport" then
    stack = owner.get_inventory(defines.inventory.roboport_material).find_item_stack(repair_item)
  else
    stack = owner.get_output_inventory().find_item_stack(repair_item)
  end


  if not (stack and stack.valid and stack.valid_for_read) then return end

  return owner, stack

end

local update_turret = function(turret_data)
  local profiler = game.create_profiler()
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

  local pickup_entity, stack = get_pickup_entity(turret)

  if not pickup_entity then
    add_to_repair_queue(entity)
    return true
  end

  --game.print({"", game.tick, " 1 ", turret.unit_number, profiler})
  --profiler.reset()

  local distance = util.distance({turret.position.x, turret.position.y - 2.5}, entity.position)

  --how many ticks the projectile should take to hit.



  local duration = turret_update_interval - 1

  if pickup_entity ~= turret then

    local path = pathfinding.get_cell_path(pickup_entity, turret.logistic_cell)

    --game.print({"", " 2 ",  game.tick, turret.unit_number, profiler})
    --profiler.reset()

    if not path then
      add_to_repair_queue(entity)
      return true
    end
    local path_duration = highlight_path(pickup_entity, path)

    --game.print({"", " 3 ",  game.tick, turret.unit_number, profiler})
    --profiler.reset()

  end

  stack.drain_durability(turret_update_interval / stack.prototype.speed)

  turret.energy = new_energy
  --duration = duration + juggle(turret_update_interval, 0.2)

  local speed = (distance / duration)

  local health_needed = entity.prototype.max_health - entity.health

  for k = 1, get_beam_multiple(turret.force) do
    health_needed = health_needed - 30
    local rocket = turret.surface.create_entity
    {
      name = "repair-bullet",
      speed = speed,
      position = {turret.position.x, turret.position.y - 2.5},
      target = entity,
      force = turret.force
    }
    speed = speed / 0.8
    turret.surface.create_entity
    {
      name = "repair-beam",
      --source_position = {turret.position.x, turret.position.y - 2.5},
      target_position = {turret.position.x, turret.position.y - 2.5},
      source = rocket,
      source_offset = {0, 0},
      --target = turret,
      --target = entity,
      --duration = turret_update_interval - 1,
      position = turret.position,
      force = turret.force
    }

  end

  if health_needed <= 0 then
    return true
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

  --local profiler = game.create_profiler()

  local count = 0

  local turret_update_mod = event.tick % turret_update_interval
  for k, turret_data in pairs (script_data.active_turrets) do
    if k % turret_update_interval == turret_update_mod then
      count = count + 1
      if update_turret(turret_data) then
        script_data.active_turrets[k] = nil
      end
    end
  end


  --game.print({"", event.tick, "turret update ", count, "  ", profiler})
  --profiler.reset()

  local repair_update_mod = event.tick % repair_update_interval
  for k, repair in pairs (script_data.repair_queue) do
    if k % repair_update_interval == repair_update_mod then
      if check_repair(repair) then
        script_data.repair_queue[k] = nil
      end
    end
  end


  --game.print({"", event.tick, "repair update ", profiler})

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

local on_entity_removed = function(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end

  if entity.logistic_cell then
    clear_cache()
  end

end


local lib = {}

lib.events =
{
  --[defines.events.on_player_created] = on_player_created,
  [defines.events.on_built_entity] = on_created_entity,
  [defines.events.on_robot_built_entity] = on_created_entity,
  [defines.events.script_raised_built] = on_created_entity,
  [defines.events.script_raised_revive] = on_created_entity,
  [defines.events.on_entity_cloned] = on_created_entity,

  [defines.events.on_tick] = on_tick,
  [defines.events.on_entity_damaged] = on_entity_damaged,
  [defines.events.on_research_finished] = on_research_finished,

  [defines.events.on_entity_died] = on_entity_removed,
  [defines.events.script_raised_destroy] = on_entity_removed,
  [defines.events.on_player_mined_entity] = on_entity_removed,
  [defines.events.on_robot_mined_entity] = on_entity_removed,

  [defines.events.on_surface_cleared] = clear_cache,
  [defines.events.on_surface_deleted] = clear_cache,

}

lib.on_init = function()
  global.repair_turret = global.repair_turret or script_data
  pathfinding.cache = script_data.pathfinder_cache
end

lib.on_load = function()
  script_data = global.repair_turret or script_data
  pathfinding.cache = script_data.pathfinder_cache
end

lib.on_configuration_changed = function()

  if not script_data.free_pack_migration then
    script_data.free_pack_migration = true
    if game.item_prototypes["repair-pack"] then
      game.print("Klonan: Hello, Repair turrets now require repair packs in the logistic network to repair. As a 'sorry', I have given all repair turrets 5 repair packs for free.")
      for x, y in pairs (script_data.turret_map) do
        for y, turrets in pairs (y) do
          for unit_number, turret in pairs (turrets) do
            if turret.valid then
              turret.insert{name = "repair-pack", count = 5}
            else
              turrets[unit_number] = nil
            end
          end
        end
      end
    end
  end

  if not script_data.pathfinder_cache then
    script_data.pathfinder_cache = {}
    pathfinding.cache = script_data.pathfinder_cache
  end

end

lib.on_init = function()
  global.repair_turret = global.repair_turret or script_data
end

return lib
