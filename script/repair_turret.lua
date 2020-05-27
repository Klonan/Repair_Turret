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
  can_construct = {},
  pathfinder_cache = {},
  moving_entity_buckets = {},
  non_repairable_entities = {},
  ghost_check_queue = {},
  deconstruct_check_queue = {}
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

local ghost_names =
{
  ["entity-ghost"] = true,
  ["tile-ghost"] = true
}

local can_move = function(entity)
  return moving_entities[entity.type]
end

local repair_items
local get_repair_items = function()
  if repair_items then return repair_items end
  repair_items = {}
  for name, item in pairs (game.item_prototypes) do
    if item.type == "repair-tool" and (item.speed and item.speed > 0) then
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
local find_nearby_turrets = function(entity, for_deconstruction)

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
      (turret.force == force or turret.force.get_friend(force) or (for_deconstruction and force.name == "neutral")) and
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

local add_nearby_ghost_entities_to_ghost_check_queue = function(entity)
  local position = entity.position
  local ghost_check_queue = script_data.ghost_check_queue
  local area = {{position.x - repair_range, position.y - repair_range}, {position.x + repair_range, position.y + repair_range}}
  for k, entity in pairs (entity.surface.find_entities_filtered{area = area, name = {"entity-ghost", "tile-ghost"}}) do
    ghost_check_queue[entity.unit_number] = entity
  end
end

local insert = table.insert
local add_nearby_entities_to_deconstruct_check_queue = function(entity)
  local position = entity.position
  local deconstruct_check_queue = script_data.deconstruct_check_queue
  local area = {{position.x - repair_range, position.y - repair_range}, {position.x + repair_range, position.y + repair_range}}
  for k, entity in pairs (entity.surface.find_entities_filtered{area = area, to_be_deconstructed = true}) do
    insert(deconstruct_check_queue, entity)
  end
end

local entity_ghost_built = function(entity)
  script_data.ghost_check_queue[entity.unit_number] = entity
  local decons = entity.surface.find_entities_filtered{area = entity.bounding_box, to_be_deconstructed = true}
  for k, decon in pairs (decons) do
    insert(script_data.deconstruct_check_queue, decon)
  end
end

local on_created_entity = function(event)
  local entity = event.created_entity or event.entity or event.destination
  if not (entity and entity.valid) then return end

  local name = entity.name

  if ghost_names[name] then
    entity_ghost_built(entity)
    return
  end

  if name == turret_name then
    add_to_turret_map(entity)
    add_nearby_damaged_entities_to_repair_check_queue(entity)
    add_nearby_ghost_entities_to_ghost_check_queue(entity)
    add_nearby_entities_to_deconstruct_check_queue(entity)
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
local max_duration = turret_update_interval * 8

local highlight_path = function(source, path, beam_name)

  --local profiler = game.create_profiler()

  local current_duration = turret_update_interval

  local surface = source.surface
  local create_entity = surface.create_entity
  local force = source.force
  local count = 0

  if source.type ~= "roboport" then
    local position = source.position
    create_entity
    {
      name = beam_name,
      target_position = position,
      source_position = {position.x, position.y - 2.5},
      force = force,
      duration = current_duration,
      position = position
    }
  end

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

local make_path = function(target_entity, source_cell, beam_name)
  if settings.global.hide_repair_paths.value then return end

  local path = pathfinding.get_cell_path(target_entity, source_cell)

  if path then
    highlight_path(target_entity, path, beam_name)
  end

end

local get_repair_target = function(entities, position)

  local lowest
  local lowest_health = math.huge

  for k, entity in pairs (entities) do
    local health = entity.health
    if health then
      health = health - entity.get_damage_to_be_taken()
      if (health < lowest_health) and not (health >= entity.prototype.max_health or (can_move(entity) and not is_in_range(position, entity.position))) then
        lowest = entity
        lowest_health = health
      end
    end
  end

  return lowest
end

local repair_entity = function(turret_data, turret, entity)

  local force = turret.force

  local pickup_entity, stack = turret_data.pickup_entity, turret_data.stack

  if not (pickup_entity and pickup_entity.valid and stack.valid and stack.valid_for_read and stack.is_repair_tool) then
    pickup_entity, stack = get_pickup_entity(turret)

    if not pickup_entity then
      return
    end

    turret_data.pickup_entity = pickup_entity
    turret_data.stack = stack

  end

  local position = turret.position
  local target_position = entity.position

  if pickup_entity ~= turret then
    make_path(pickup_entity, turret.logistic_cell, "repair-beam")
  end

  stack.drain_durability(turret_update_interval / stack.prototype.speed)

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
      target_position = source_position,
      source = rocket,
      position = position,
      force = force
    }
  end

  return true

end

local items_to_place_cache = {}
local get_items_to_place = function(ghost)

  local name = ghost.ghost_name
  local items = items_to_place_cache[name]
  if items then return items end

  local prototype = ghost.ghost_prototype
  items = prototype.items_to_place_this
  items_to_place_cache[name] = items

  return items

end

local get_construction_target = function(entities, turret, turret_data)

  local network = turret.logistic_network
  --if not next(network.provider_points) then return end

  local contents = network.get_contents()
  if not next(contents) then return end

  --turret.surface.create_entity{name = "flying-text", position = turret.position, text = table_size(entities)}

  local get_item = function(ghost)
    for k, item in pairs (get_items_to_place(ghost)) do
      if (contents[item.name] or 0) >= item.count then
        return item
      end
    end
  end

  local surface = turret.surface
  local can_place = surface.can_place_entity
  local can_build = function(ghost)
    if ghost.name == "tile-ghost" then return true end
    return can_place
    {
      name = ghost.ghost_name,
      position = ghost.position,
      direction = ghost.direction,
      force = ghost.force,
      build_check_type = defines.build_check_type.ghost_revive
    }
  end

  local items = {}
  local ghosts = {}

  local low_priority_queue = turret_data.low_priority_queue
  if not low_priority_queue then
    low_priority_queue = {}
    turret_data.low_priority_queue = low_priority_queue
  end

  for k, entity in pairs (entities) do
    if entity.valid and ghost_names[entity.name] then
      local item = get_item(entity)
      if item and can_build(entity) then
        items[k] = item
        ghosts[k] = entity
      else
        low_priority_queue[k] = entity
        entities[k] = nil
      end
    end
  end

  local closest = surface.get_closest(turret.position, ghosts)
  if closest then
    --turret.surface.create_entity{name = "flying-text", position = turret.position, text = "Close"}
    return closest, items[closest.unit_number]
  end

  local checked_queue = turret_data.checked_queue
  if not checked_queue then
    checked_queue = {}
    turret_data.checked_queue = checked_queue
  end

  if not next(low_priority_queue) then
    turret_data.low_priority_queue = checked_queue
    low_priority_queue = checked_queue
    checked_queue = {}
    turret_data.checked_queue = checked_queue

    --turret.surface.create_entity{name = "flying-text", position = turret.position, text = "Queue swap"}
  end

  local index, entity = next(low_priority_queue)

  if entity then
    low_priority_queue[index] = nil
    if entity.valid then
      --entity.surface.create_entity{name = "flying-text", position = entity.position, text = "?"}
      local item = get_item(entity)
      if item and can_build(entity) then
        return entity, item
      else
        checked_queue[index] = entity
      end
    end
  end

end

local revive_param = {raise_revive = true}

local build_entity = function(turret, ghost, item)
  local network = turret.logistic_network
  local point = network.select_pickup_point
  {
    name = item.name,
    position = turret.position,
    include_buffers = true
  }
  if not point then return end

  local pickup_entity = point.owner

  local target_position = ghost.position
  local force = ghost.force

  local collided_items, entity, proxy = ghost.revive(revive_param)

  if collided_items then
    for name, count in pairs (collided_items) do
      network.insert{name = name, count = count}
    end
  end

  if pickup_entity ~= turret then
    make_path(pickup_entity, turret.logistic_cell, "construct-beam")
  end

  pickup_entity.remove_item(item)

  local position = turret.position
  local source_position = {position.x, position.y - 2.5}

  turret.surface.create_entity
  {
    name = "construct-beam",
    source_position = source_position,
    target = entity,
    target_position = target_position,
    position = position,
    force = force,
    duration = turret_update_interval
  }

  return true

end

local get_deconstruction_target = function(entities, turret)

  local available = {}
  if not next(turret.logistic_network.storage_points) then return end

  for k, entity in pairs (entities) do
    if entity.valid and entity.to_be_deconstructed() and entity.can_be_destroyed() then
      available[k] = entity
    end
  end

  return turret.surface.get_closest(turret.position, available)

end

local products_cache = {}
local tile_products_cache = {}
local get_products = function(entity)

  local name = entity.name
  if name == "item-on-ground" then return {{name = entity.stack.name, amount = entity.stack.count}} end

  if name == "deconstructible-tile-proxy" then

    local tile = entity.surface.get_tile(entity.position)
    local tile_name = tile.name

    local tile_products = tile_products_cache[name]
    if tile_products then return tile_products end

    tile_products = tile.prototype.mineable_properties.products
    tile_products_cache[name] = tile_products
    return tile_products
  end

  local products = products_cache[name]
  if products then return products end

  products = entity.prototype.mineable_properties.products

  products_cache[name] = products

  return products

end

local remains_cache = {}
local get_remains = function(entity)

  local remains = remains_cache[entity.name]
  if remains then return remains end

  remains = entity.prototype.remains_when_mined

  remains_cache[entity.name] = remains

  return remains

end


local floor = math.floor
local random = math.random
local stack_from_product = function(product)
  local count = floor(product.amount or (random() * (product.amount_max - product.amount_min) + product.amount_min))
  if count < 1 then return end
  local stack =
  {
    name = product.name,
    count = count
  }
  --print(serpent.line(stack))
  return stack
end

local get_contents = function(entity)
  local contents = {}

  if not entity.has_items_inside() then
    return contents
  end

  local get = entity.get_inventory
  for k = 1, 10 do
    local inventory = get(k)
    if not inventory then break end
    for name, count in pairs (inventory.get_contents()) do
      contents[name] = (contents[name] or 0) + count
    end
  end
  return contents
end

local random = math.random
local destroy_params = {raise_destroy = true}
local deconstruct_entity = function(turret, entity)

  local remains = get_remains(entity)
  local products = get_products(entity)
  local contents = get_contents(entity)
  local position = entity.position
  local force = entity.force
  local name = entity.name
  local surface = entity.surface
  local tiles
  if entity.name == "deconstructible-tile-proxy" then
    local tile_name = surface.get_hidden_tile(position)
    if tile_name then
      tiles =
      {
        {name = tile_name, position = position}
      }
    end
  end

  local success = entity.destroy(destroy_params)
  if not success then return end


  if tiles then
    surface.set_tiles(tiles)
  end

  local source_position = {turret.position.x, turret.position.y - 2.5}

  local rocket = surface.create_entity
  {
    name = "deconstruct-bullet",
    speed = -0.1,
    position = position,
    target = source_position,
    force = force,
    max_range = repair_range * 2
  }
  surface.create_entity
  {
    name = "deconstruct-beam",
    target_position = source_position,
    source = rocket,
    position = position,
    force = force
  }

  for k, remains in pairs(remains) do
    surface.create_entity{name = remains.name, position = position, force = force}
  end

  local network = turret.logistic_network
  local cell = turret.logistic_cell

  local made_beam = false

  for k, product in pairs (products) do
    local stack = stack_from_product(product)
    if stack then
      local drop_point = network.select_drop_point{stack = stack}
      if drop_point then
        local owner = drop_point.owner
        owner.insert(stack)
        if not made_beam then
          make_path(owner, cell, "deconstruct-beam")
          made_beam = true
        end
      else
        surface.spill_item_stack(position, stack)
      end
    end
  end

  local insert = network.insert

  for name, count in pairs (contents) do
    local remaining = count - insert({name = name, count = count})
    if remaining > 0 then
      surface.spill_item_stack(position, {name = name, count = remaining})
    end
  end

  return true

end

local validate_targets = function(entities)
  for k, entity in pairs (entities) do
    if not (entity.valid and (entity.to_be_deconstructed() or ((entity.get_health_ratio() or 0) < 1) or ghost_names[entity.name])) then
      entities[k] = nil
    end
  end
  return entities
end

local can_construct = function(force)
  return script_data.can_construct[force.name]
end

local update_turret = function(turret_data)
  --local profiler = game.create_profiler()
  local turret = turret_data.turret
  if not (turret and turret.valid) then return true end

  new_energy = turret.energy - get_needed_energy(turret.force)
  if new_energy < 0 then
    return
  end

  local targets = validate_targets(turret_data.targets)

  local force = turret.force

  local entity = get_repair_target(targets, turret.position)
  if entity then
    if repair_entity(turret_data, turret, entity) then
      turret.energy = new_energy
      return
    end
  end

  if can_construct(force) then

    local ghost, item = get_construction_target(targets, turret, turret_data)
    if ghost then
      if build_entity(turret, ghost, item) then
        turret.energy = new_energy
        return
      end
    end

    local entity = get_deconstruction_target(targets, turret)
    if entity then
      if deconstruct_entity(turret, entity) then
        turret.energy = new_energy
        return
      end
    end

  end

  if not (next(turret_data.targets) or next(turret_data.low_priority_queue) or next(turret_data.checked_queue)) then
    return true
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
    if (k * 8) % turret_update_interval == turret_update_mod then
      if update_turret(turret_data) then
        active_turrets[k] = nil
      end
    end
  end

end

local check_ghost = function(unit_number, entity)
  if not (entity and entity.valid) then return true end

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

local ghost_check_count = 5
local check_ghost_check_queue = function()

  local ghost_check_queue = script_data.ghost_check_queue
  for k = 1, ghost_check_count do

    local unit_number, entity = next(ghost_check_queue)
    if not unit_number then return end

    ghost_check_queue[unit_number] = nil

    check_ghost(unit_number, entity)
  end

end

local check_deconstruction = function(index, entity)
  if not (entity and entity.valid) then return true end
  if not entity.to_be_deconstructed() then return end

  --entity.surface.create_entity{name = "flying-text", position = entity.position, text = "?"}

  local active_turrets = script_data.active_turrets
  local turrets = find_nearby_turrets(entity, true)

  for turret_unit_number, turret in pairs (turrets) do
    --turret.surface.create_entity{name = "flying-text", position = turret.position, text = "Added to list"}
    local turret_data = active_turrets[turret_unit_number]
    if turret_data then
      turret_data.targets[index] = entity
    else
      turret_data =
      {
        turret = turret,
        targets = {[index] = entity}
      }
      active_turrets[turret_unit_number] = turret_data
    end
  end

end

local deconstruct_check_count = 5
local check_deconstruction_check_queue = function()

  local deconstruct_check_queue = script_data.deconstruct_check_queue
  for k = 1, deconstruct_check_count do

    local index, entity = next(deconstruct_check_queue)
    if not index then return end

    deconstruct_check_queue[index] = nil

    if entity.valid and entity.type ~= "cliff" then
      check_deconstruction(entity.unit_number or (entity.position.x.."-"..entity.position.y), entity)
    end
  end

end

local on_tick = function(event)

  check_repair_check_queue()

  check_ghost_check_queue()

  check_deconstruction_check_queue()

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

  if name == "repair-turret-construction" then
    script_data.can_construct[research.force.name] = true
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

local on_post_entity_died = function(event)
  local ghost = event.ghost
  if ghost and ghost.valid then
    script_data.ghost_check_queue[ghost.unit_number] = ghost
  end
end

local insert = table.insert
local on_marked_for_deconstruction = function(event)
  local entity = event.entity
  if entity and entity.valid then
    insert(script_data.deconstruct_check_queue, entity)
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

  [defines.events.on_post_entity_died] = on_post_entity_died,

  [defines.events.on_surface_cleared] = clear_cache,
  [defines.events.on_surface_deleted] = clear_cache,

  [defines.events.on_marked_for_deconstruction] = on_marked_for_deconstruction,
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

  if not script_data.ghost_check_queue then
    local profiler = game.create_profiler()

    script_data.ghost_check_queue = {}

    for x, array in pairs (script_data.turret_map) do
      for y, turrets in pairs (array) do
        for k, turret in pairs (turrets) do
          if not turret.valid then
            turrets[k] = nil
          else
            add_nearby_ghost_entities_to_ghost_check_queue(turret)
          end
        end
      end
    end

    game.print{"", "Repair turret - Rescanned map for ghost targets. ", profiler}

  end

  if not script_data.deconstruct_check_queue then
    local profiler = game.create_profiler()

    script_data.deconstruct_check_queue = {}

    for x, array in pairs (script_data.turret_map) do
      for y, turrets in pairs (array) do
        for k, turret in pairs (turrets) do
          if not turret.valid then
            turrets[k] = nil
          else
            add_nearby_entities_to_deconstruct_check_queue(turret)
          end
        end
      end
    end

    game.print{"", "Repair turret - Rescanned map for deconstruct targets. ", profiler}

  end

  script_data.can_construct = script_data.can_construct or {}

end

return lib
