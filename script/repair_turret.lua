local util = require("util")
local pathfinding = require("pathfinding")
local turret_update_interval = 31
local moving_entity_check_interval = 301
local energy_per_heal = 100000
local turret_name = require("shared").entities.repair_turret
local repair_range = require("shared").repair_range

local script_data =
{
  turret_map = {},
  active_turrets = {},
  repair_check_queue = {},
  beam_multiple = {},
  beam_efficiency = {},
  pathfinder_cache = {},
  moving_entity_buckets = {},
  non_repairable_entities = {}
}

local moving_entities =
{
  ["car"] = true,
  ["unit"] = true,
  ["character"] = true,
  ["combat-robot"] = true,
  ["locomotive"] = true,
  ["cargo-wagon"] = true,
  ["fluid-wagon"] = true,
  ["artillery-wagon"] = true,
  ["construction-robot"] = true,
  ["logistic-robot"] = true
}

local can_move = function(entity)
  return moving_entities[entity.type]
end

local repair_items
local get_repair_items = function()
  if repair_items then return repair_items end
  --Deliberately not 'local'
  repair_items = {}
  for name, item in pairs (game.item_prototypes) do
    if item.type == "repair-tool" then
      repair_items[name] = true
    end
  end
  return repair_items
end

local on_player_created = function(event)
  local player = game.get_player(event.player_index)
  player.insert("repair-turret")
end

local clear_cache = function()
  --game.print("Clearing cache")
  script_data.pathfinder_cache = {}
  pathfinding.cache = script_data.pathfinder_cache
end

local add_to_moving_entity_check = function(entity)

  local unit_number = entity.unit_number
  if not unit_number then return end

  local bucket_index = unit_number % moving_entity_check_interval

  local bucket = script_data.moving_entity_buckets[bucket_index]
  if not bucket then
    bucket = {}
    script_data.moving_entity_buckets[bucket_index] = bucket
  end

  bucket[unit_number] = entity

end

local add_to_repair_check_queue = function(entity)

  if can_move(entity) then
    add_to_moving_entity_check(entity)
    return
  end

  local unit_number = entity.unit_number
  if not unit_number then return end

  script_data.repair_check_queue[unit_number] = entity

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
  local map_x = map[x]
  local turrets = map_x and map_x[y]
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

local has_repair_item = function(network)
  local get_item_count = network.get_item_count
  for name, item in pairs (get_repair_items()) do
    if get_item_count(name) > 0 then return true end
  end
end

local abs = math.abs
local find_nearby_turrets = function(entity)

  local turrets = {}
  local radius = 1
  local position = entity.position
  local force = entity.force
  local surface = entity.surface

  local is_in_range = function(turret_position)
    return abs(position.x - turret_position.x) <= repair_range and abs(position.y - turret_position.y) <= repair_range
  end

  local check_turret = function(unit_number, turret)
    if
      turret ~= entity and
      (turret.force == force or turret.force.get_friend(force)) and
      turret.surface == surface and
      is_in_range(turret.position)
    then
      turrets[unit_number] = turret
    end
  end

  local x, y = to_map_position(position)

  for X = x - radius, x + radius do
    for Y = y - radius, y + radius do
      local turrets = get_turrets_in_map(X, Y)
      if turrets then
        for unit_number, turret in pairs (turrets) do
          if not turret.valid then
            turrets[unit_number] = nil
          else
            check_turret(unit_number, turret)
          end
        end
      end
    end
  end

  return turrets
end

local add_nearby_damaged_entities_to_repair_check_queue = function(entity)
  local position = entity.position
  local area = {{position.x - repair_range, position.y - repair_range}, {position.x + repair_range, position.y + repair_range}}
  for k, entity in pairs (entity.surface.find_entities_filtered{area = area}) do
    if entity.unit_number and (entity.get_health_ratio() or 1) < 1 then
      add_to_repair_check_queue(entity)
    end
  end
end

local on_created_entity = function(event)
  local entity = event.created_entity or event.entity or event.destination
  if not (entity and entity.valid) then return end

  if entity.name == turret_name then
    add_to_turret_map(entity)
    add_nearby_damaged_entities_to_repair_check_queue(entity)
  end

  if entity.logistic_cell then
    clear_cache()
  end

  if (entity.get_health_ratio() or 1) < 1 then
    add_to_repair_check_queue(entity)
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

    --source.energy = (source.energy - transmission_energy_per_hop) + 1

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
  elseif owner.type == "character" then
    stack = owner.get_main_inventory().find_item_stack(repair_item)
  else
    stack = owner.get_output_inventory().find_item_stack(repair_item)
  end

  if not (stack and stack.valid and stack.valid_for_read) then return end

  return owner, stack

end

local is_in_range = function(turret_position, position)
  return abs(position.x - turret_position.x) <= repair_range and abs(position.y - turret_position.y) <= repair_range
end

local get_target = function(entities, position)
  local lowest
  local lowest_health = math.huge

  for k, entity in pairs (entities) do
    if not entity.valid then
      entities[k] = nil
    else
      local health = entity.health - entity.get_damage_to_be_taken()
      if health >= entity.prototype.max_health or (can_move(entity) and not is_in_range(position, entity.position)) then
        entities[k] = nil
      elseif (health < lowest_health) then
        lowest = entity
        lowest_health = health
      end
    end
  end

  return lowest
end

local update_turret = function(turret_data)
  --local profiler = game.create_profiler()
  local turret = turret_data.turret
  if not (turret and turret.valid) then return true end

  --turret.surface.create_entity{name = "flying-text", position = turret.position, text = "!"}

  local entity = get_target(turret_data.targets, turret.position)

  if not entity then return true end

  local force = turret.force

  local turret_energy = turret.energy
  new_energy = turret_energy - get_needed_energy(force)
  if new_energy < 0 then
    return
  end

  local pickup_entity, stack = turret_data.pickup_entity, turret_data.stack

  if not (pickup_entity and pickup_entity.valid and stack.valid and stack.valid_for_read) then
    pickup_entity, stack = get_pickup_entity(turret)

    if not pickup_entity then
      return
    end

    turret_data.pickup_entity = pickup_entity
    turret_data.stack = stack

  end

  local position = turret.position
  local target_position = entity.position

  if abs(target_position.x - position.x) > repair_range or abs(target_position.y - position.y) > repair_range then
    turret_data.targets[entity.unit_number] = nil
    return
  end

  if not settings.global.hide_repair_paths.value then
    if pickup_entity ~= turret then
      local path = pathfinding.get_cell_path(pickup_entity, turret.logistic_cell)

      if path then
        highlight_path(pickup_entity, path)
      end

    end
  end

  stack.drain_durability(turret_update_interval / stack.prototype.speed)

  turret.energy = new_energy

  local speed = 1 / 2

  local source_position = {position.x, position.y - 2.5}
  local surface = turret.surface
  local create_entity = surface.create_entity

  for k = 1, get_beam_multiple(turret.force) do
    local rocket = create_entity
    {
      name = "repair-bullet",
      speed = speed,
      position = source_position,
      target = entity,
      force = force,
      max_range = repair_range * 2
    }
    speed = speed / 0.8
    create_entity
    {
      name = "repair-beam",
      --source_position = {turret.position.x, turret.position.y - 2.5},
      target_position = source_position,
      source = rocket,
      --source_offset = {0, 0},
      --target = turret,
      --target = entity,
      --duration = turret_update_interval - 1,
      position = position,
      force = force
    }
    --if health_needed <= 0 then return true end
  end


end

local check_repair = function(unit_number, entity)
  if not (entity and entity.valid) then return true end
  if entity.has_flag("not-repairable") then return true end
  if (entity.get_health_ratio() or 1) == 1 then return true end

  --entity.surface.create_entity{name = "flying-text", position = entity.position, text = "?"}

  local active_turrets = script_data.active_turrets
  local turrets = find_nearby_turrets(entity)

  for turret_unit_number, turret in pairs (turrets) do
    --turret.surface.create_entity{name = "flying-text", position = turret.position, text = "Added to list"}
    local turret_data = active_turrets[turret_unit_number]
    if turret_data then
      turret_data.targets[unit_number] = entity
    else
      turret_data =
      {
        turret = turret,
        targets = {[unit_number] = entity}
      }
      active_turrets[turret_unit_number] = turret_data
    end
  end

end

local repair_check_count = 5
local check_repair_check_queue = function()

  local repair_check_queue = script_data.repair_check_queue
  for k = 1, repair_check_count do

    local unit_number, entity = next(repair_check_queue)
    if not unit_number then return end

    repair_check_queue[unit_number] = nil

    check_repair(unit_number, entity)
  end

end

local check_moving_entity_repair = function(event)

  local moving_entity_check_index = event.tick % moving_entity_check_interval
  local moving_entity_bucket = script_data.moving_entity_buckets[moving_entity_check_index]

  if not moving_entity_bucket then return end

  for unit_number, entity in pairs(moving_entity_bucket) do
    if check_repair(unit_number, entity) then
      moving_entity_bucket[unit_number] = nil
    end
  end

  if not next(moving_entity_bucket) then
    script_data.moving_entity_buckets[moving_entity_check_index] = nil
  end

end

local check_turret_update = function(event)

  local active_turrets = script_data.active_turrets
  if not next(active_turrets) then return end

  local turret_update_mod = event.tick % turret_update_interval
  for k, turret_data in pairs (active_turrets) do
    if k % turret_update_interval == turret_update_mod then
      if update_turret(turret_data) then
        active_turrets[k] = nil
      end
    end
  end

end

local on_tick = function(event)

  check_repair_check_queue()

  check_moving_entity_repair(event)

  check_turret_update(event)

end

local on_entity_damaged = function(event)

  local entity = event.entity
  if not (entity and entity.valid) then
    return
  end

  add_to_repair_check_queue(entity)

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

local set_damaged_event_filter = function()

  if not script_data.non_repairable_entities then return end

  local filters = {}
  for name, bool in pairs (script_data.non_repairable_entities) do
    local filter =
    {
      filter = "name",
      name = name,
      invert = true,
      mode = "and"
    }
    table.insert(filters, filter)
  end

  if not next(filters) then return end

  script.set_event_filter(defines.events.on_entity_damaged, filters)
end

local update_non_repairable_entities = function()
  script_data.non_repairable_entities = {}
  for name, entity in pairs (game.entity_prototypes) do
    if entity.has_flag("not-repairable") then
      script_data.non_repairable_entities[name] = true
    end
  end
  set_damaged_event_filter()
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
  set_damaged_event_filter()
end

lib.on_configuration_changed = function()

  script_data.moving_entity_buckets = script_data.moving_entity_buckets or {}

  if not script_data.pathfinder_cache then
    script_data.pathfinder_cache = {}
    pathfinding.cache = script_data.pathfinder_cache
  end

  if not script_data.repair_check_queue then
    local profiler = game.create_profiler()

    script_data.repair_check_queue = {}
    script_data.active_turrets = {}

    for x, array in pairs (script_data.turret_map) do
      for y, turrets in pairs (array) do
        for k, turret in pairs (turrets) do
          if not turret.valid then
            turrets[k] = nil
          else
            add_nearby_damaged_entities_to_repair_check_queue(turret)
          end
        end
      end
    end

    game.print{"", "Repair turret - Rescanned map for repair targets. ", profiler}


  end

  update_non_repairable_entities()

end

lib.on_init = function()
  global.repair_turret = global.repair_turret or script_data
end

return lib
