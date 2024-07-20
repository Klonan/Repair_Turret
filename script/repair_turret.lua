local util = require("util")
local pathfinding = require("pathfinding")
local TURRET_UPDATE_INTERVAL = 31
local KIDNAP_TIMEOUT = TURRET_UPDATE_INTERVAL * 10
local moving_entity_check_interval = 301
local HOSTAGE_POSITION = {696969, 696969}
local energy_per_heal = 100000

local turret_names =
{
  [require("shared").entities.repair_turret] = true
}

local is_turret = function(name)
  return turret_names[name]
end

local script_data =
{
  turrets = {},
  turret_map = {},
  active_turrets = {},
  beam_multiple = {},
  beam_efficiency = {},
  can_construct = {},
  pathfinder_cache = {},
  robots_to_check  = {},
  proxy_inventory = nil
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
  ["logistic-robot"] = true,
  ["spider-vehicle"] = true
}

local ghost_names =
{
  ["entity-ghost"] = true,
  ["tile-ghost"] = true
}

local nice_types =
{
  [defines.robot_order_type.construct] = true,
  [defines.robot_order_type.deconstruct] = true,
  [defines.robot_order_type.repair] = true
}

local is_handled_job = function(work_queue)
  for k, job in pairs(work_queue) do
    if nice_types[job.type] then
      return k
    end
  end
end

local get_build_stack = function(queue, index)
  local source = queue[index - 1]
  if not source then return end

  local item = source.target_item
  if not item then return end

  local entity = source.target
  if not (entity and entity.valid) then return end

  return item, entity
end

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

local add_to_turret_map = function(turret, s, x, y)
  local map = script_data.turret_map

  local surface_map = map[s]
  if not surface_map then
    surface_map = {}
    map[s] = surface_map
  end

  local map_x = surface_map[x]
  if not map_x then
    map_x = {}
    surface_map[x] = map_x
  end

  local turrets = map_x[y]
  if not turrets then
    turrets = {}
    map_x[y] = turrets
  end

  turrets[turret.unit_number] = turret
end

local remove_from_turret_map = function(unit_number, s, x, y)
  game.print("unregistering turret" .. unit_number)
  local map = script_data.turret_map
  local surface_map = map[s]
  if not surface_map then return end
  local map_x = surface_map[x]
  if not map_x then return end
  local turrets = map_x[y]
  if not turrets then return end
  turrets[unit_number] = nil
end

local add_to_turret_update = function(turret)
  local unit_number = turret.unit_number
  local bucket_index = unit_number % TURRET_UPDATE_INTERVAL
  local bucket = script_data.active_turrets[bucket_index]
  if not bucket then
    bucket = {}
    script_data.active_turrets[bucket_index] = bucket
  end
  assert(not bucket[unit_number])
  bucket[unit_number] = turret
end

local remove_from_turret_update = function(unit_number)
  local bucket_index = unit_number % TURRET_UPDATE_INTERVAL
  local bucket = script_data.active_turrets[bucket_index]
  if not bucket then return end
  bucket[unit_number] = nil
  if not next(bucket) then
    script_data.active_turrets[bucket_index] = nil
  end
end

local RepairTurret = {}
RepairTurret.metatable =
{
  __index = RepairTurret
}
script.register_metatable("repair-turret", RepairTurret.metatable)

RepairTurret.new = function(entity)
  script.register_on_object_destroyed(entity)

  local self = setmetatable({}, RepairTurret.metatable)
  self.entity = entity
  self.range = entity.prototype.construction_radius
  self.unit_number = entity.unit_number
  self.surface_index = entity.surface.index
  self.position = entity.position
  self.force_index = entity.force.index
  self.targets = {}
  self.low_priority_queue = {}
  self.kidnapped_robots = {}
  self.inventory = self.entity.get_inventory(defines.inventory.roboport_material)

  self:post_setup()
end

RepairTurret.post_setup = function(self)
  script_data.turrets[self.unit_number] = self
  self:register_on_chunks()
end

RepairTurret.kill_all_hostages = function(self)
  for unit_number, hostage in pairs(self.kidnapped_robots) do
    hostage.robot.destroy()
  end
  self.kidnapped_robots = {}
end

RepairTurret.on_destroyed = function(self)
  self.entity = nil
  self:unregister_from_chunks()
  self:kill_all_hostages()
  if self.active then
    self:deactivate()
  end
  script_data.turrets[self.unit_number] = nil
end

RepairTurret.get_turret = function(unit_number)
  return script_data.turrets[unit_number]
end

RepairTurret.register_on_chunks = function(self)
  for k, chunk_position in pairs (self:get_chunks_in_range()) do
    add_to_turret_map(self, self.surface_index, chunk_position[1], chunk_position[2])
  end
end

RepairTurret.unregister_from_chunks = function(self)
  for k, chunk_position in pairs (self:get_chunks_in_range()) do
    remove_from_turret_map(self.unit_number, self.surface_index, chunk_position[1], chunk_position[2])
  end
end

local CHUNK_SIZE = 32
RepairTurret.get_chunks_in_range = function(self)
  local position = self.position
  local range = self.range
  local chunks = {}
  local i = 1
  for x = math.floor((position.x - range) / CHUNK_SIZE), math.floor((position.x + range) / CHUNK_SIZE) do
    for y = math.floor((position.y - range) / CHUNK_SIZE), math.floor((position.y + range) / CHUNK_SIZE) do
      chunks[i] = {x, y}
      i = i + 1
    end
  end
  return chunks
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

local floor = math.floor

local to_chunk_position = function(position)
  local x = floor(position.x / CHUNK_SIZE)
  local y = floor(position.y / CHUNK_SIZE)
  return x, y
end

local get_turrets_in_map = function(s, x, y)
  --game.print("HI"..x..y)
  local map = script_data.turret_map
  local surface_map = map[s]
  if not surface_map then return end
  local map_x = surface_map[x]
  if not map_x then return end
  --local turrets = map_x[y]
  --if not turrets then return end
  return map_x[y]
end

local get_beam_multiple = function(force_index)
  return script_data.beam_multiple[force_index] or 1
end

local get_needed_energy = function(force_index)
  local base = energy_per_heal * TURRET_UPDATE_INTERVAL
  local modifier = script_data.beam_efficiency[force_index] or 1
  return base * modifier
end

local abs = math.abs
RepairTurret.is_in_range = function(self, position)
  return (abs(position.x - self.position.x) <= self.range) and (abs(position.y - self.position.y) <= self.range)
end

local NEUTRAL_FORCE_INDEX = 3
RepairTurret.can_do_stuff_to_force = function(self, force_index, for_deconstruction)
  if for_deconstruction and force_index == NEUTRAL_FORCE_INDEX then
    return true
  end
  return self.force_index == force_index
end

RepairTurret.is_valid_for_entity = function(self, entity_position, force_index, for_deconstruction)
  assert(self.entity.valid)

  if self.entity.to_be_deconstructed() then
    return false
  end
  if not self.entity.is_connected_to_electric_network() then
    return false
  end
  if not self:can_do_stuff_to_force(force_index, for_deconstruction) then
    return false
  end
  if not self:is_in_range(entity_position) then
    return false
  end
  return true
end

local get_unit_number = function(entity)
  local unit_number = entity.unit_number
  if not unit_number then
    unit_number = entity.position.x.."-"..entity.position.y
  end
  return unit_number
end

RepairTurret.add_target = function(self, entity)
  self.targets[get_unit_number(entity)] = entity
  self:activate()
end

RepairTurret.move_target_to_low_priority = function(self, entity)
  local unit_number = get_unit_number(entity)
  self.targets[unit_number] = nil
  self.low_priority_queue[unit_number] = entity
end

RepairTurret.activate = function(self)
  if self.active then return end
  self.active = true
  add_to_turret_update(self)
end

RepairTurret.deactivate = function(self)
  assert(self.active)
  self.active = false
  remove_from_turret_update(self.unit_number)
end

RepairTurret.get_energy_to_update = function(self)
  if not self.entity.is_connected_to_electric_network() then
    return 0
  end
  return self.entity.energy - get_needed_energy(self.force_index)
end

RepairTurret.has_enough_energy_to_work = function(self)
  return self:get_energy_to_update() > 0
end

RepairTurret.can_build = function(self)
  return script_data.can_construct[self.force_index]
end

RepairTurret.check_deactivate = function(self)
  if next(self.targets) then
    return
  end
  if next(self.low_priority_queue) then
    return
  end
  if next(self.kidnapped_robots) then
    return
  end
  self:deactivate()
end

RepairTurret.check_queue_swap = function(self)
  if not next(self.targets) and next(self.low_priority_queue) then
    self.targets, self.low_priority_queue = self.low_priority_queue, self.targets
  end
end

local entity_needs_repair = function(entity)
  local health = entity.health
  if not health then return end
  return health - entity.get_damage_to_be_taken() < entity.prototype.max_health
end

local result_enum =
{
  success = 1,
  fail = 2,
  low_priority = 3
}

RepairTurret.check_target = function(self, entity)

  if not entity.valid then
    return result_enum.fail
  end

  if (entity_needs_repair(entity)) then
    if self:repair_entity(entity) then
      return result_enum.success
    end
    return result_enum.low_priority
  end

  return result_enum.fail
end

RepairTurret.check_repair_targets = function (self)
  for unit_number, target in pairs(self.targets) do
    local result = self:check_target(target)
    if result == result_enum.success then
      return true
    elseif result == result_enum.low_priority then
      self:move_target_to_low_priority(target)
    else -- fail
      self.targets[unit_number] = nil
    end
  end
end

RepairTurret.check_hostages = function(self)
  local now = game.tick
  for unit_number, robot in pairs(self.kidnapped_robots) do
    local result = self:check_kidnapped_robot(robot, now)
    if result ~= result_enum.low_priority then
      self.kidnapped_robots[unit_number] = nil
      if result == result_enum.success then
        return true
      end
    end
  end
end

RepairTurret.check_kidnapped_robot = function(self, hostage, now)
  local robot = hostage.robot
  if not robot.valid then
    return result_enum.fail
  end
  --game.print("Checking robot" .. robot.unit_number)

  local queue = robot.robot_order_queue
  local handled_job_index = is_handled_job(queue)
  if not handled_job_index then
    robot.destroy()
    return result_enum.fail
  end

  local job = queue[handled_job_index]
  if not (job.target and job.target.valid) then
    robot.destroy()
    return result_enum.fail
  end

  if job.type == defines.robot_order_type.deconstruct then
    if self:deconstruct_entity(job.target) then
      robot.destroy()
      return result_enum.success
    end
  end

  if job.type == defines.robot_order_type.construct then
    local build_item, entity = get_build_stack(queue, handled_job_index)
    if self:try_build_ghost(job.target, entity, build_item) then
      hostage.robot.destroy()
      return result_enum.success
    end
  end

  if now - hostage.tick > KIDNAP_TIMEOUT then
    game.print("Kidnapped robot" .. robot.unit_number .. " timed out")
    robot.destroy()
    return result_enum.fail
  end

  return result_enum.low_priority
end

RepairTurret.check_hostage_timeout = function(self)
  if not next(self.kidnapped_robots) then return end
  local now = game.tick
  for k, hostage in pairs(self.kidnapped_robots) do
    if now - hostage.tick > KIDNAP_TIMEOUT then
      -- We were trying to do his task, but we failed, finish him.
      -- todo mark target as failed?
      game.print("Kidnapped robot" .. hostage.robot.unit_number .. " timed out")
      hostage.robot.destroy()
      self.kidnapped_robots[k] = nil
    end
  end
end

RepairTurret.update = function(self)
  --local profiler = game.create_profiler()

  local new_energy = self:get_energy_to_update()
  if new_energy > 0 then
    if self:check_repair_targets() or self:check_hostages() then
      self.entity.energy = new_energy
    end
    self:check_queue_swap()
  else
    self:check_hostage_timeout()
  end

  self:check_deactivate()

end

local find_nearby_turrets = function(entity, for_deconstruction)

  local result_turrets = {}
  local position = entity.position
  local force_index = entity.force.index
  local surface_index = entity.surface.index

  local x, y = to_chunk_position(position)

  local turrets = get_turrets_in_map(surface_index, x, y)
  if turrets then
    for unit_number, turret in pairs (turrets) do
      if turret:is_valid_for_entity(position, force_index, for_deconstruction) then
        result_turrets[unit_number] = turret
      end
    end
  end

  return result_turrets
end

RepairTurret.get_range_area = function(self)
  local position = self.position
  return {{position.x - self.range, position.y - self.range}, {position.x + self.range, position.y + self.range}}
end

local on_created_entity = function(event)
  local entity = event.created_entity or event.entity or event.destination
  if not (entity and entity.valid) then return end

  local name = entity.name

  if is_turret(name) then
    RepairTurret.new(entity)
  end

  if entity.logistic_cell then
    clear_cache()
  end
end

local max_duration = TURRET_UPDATE_INTERVAL * 8

local highlight_path = function(source, path, beam_name)

  --local profiler = game.create_profiler()

  local current_duration = TURRET_UPDATE_INTERVAL

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

RepairTurret.get_repair_pickup_point = function(self)
  local select_pickup_point = self.entity.logistic_network.select_pickup_point
  for name, item in pairs(get_repair_items()) do
    local pickup_point = select_pickup_point {name = name, position = self.position, include_buffers = true}
    if pickup_point then
      return pickup_point.owner, name
    end
  end
end

local get_owner_inventory = function(entity)
  local entity_type = entity.type
  if entity_type == "roboport" then
    return entity.get_inventory(defines.inventory.roboport_material)
  end
  if entity_type == "character" then
    return entity.get_main_inventory()
  end
  return entity.get_output_inventory()
end

RepairTurret.get_repair_stack_and_entity = function(self)

  local inventory = self.inventory
  if not inventory.is_empty() then
    return self.entity, inventory[1]
  end

  local owner, repair_item = self:get_repair_pickup_point()
  if not owner then return end

  local owner_inventory = get_owner_inventory(owner)

  local stack = owner_inventory and owner_inventory.find_item_stack(repair_item)

  if not (stack and stack.valid and stack.valid_for_read) then return end

  return owner, stack

end

local make_path = function(target_entity, source_cell, beam_name)
  if settings.global.hide_repair_paths.value then return end

  local path = pathfinding.get_cell_path(target_entity, source_cell)

  if path then
    highlight_path(target_entity, path, beam_name)
  end

end

RepairTurret.repair_entity = function(self, entity, pickup_entity, stack)

  if not pickup_entity then
    pickup_entity, stack = self:get_repair_stack_and_entity()
    if not (pickup_entity and pickup_entity.valid) then
      return
    end
  end

  if not (stack and stack.valid and stack.valid_for_read and stack.is_repair_tool) then
    return
  end

  if pickup_entity ~= self.entity then
    make_path(pickup_entity, self.entity.logistic_cell, "repair-beam")
  end

  stack.drain_durability(TURRET_UPDATE_INTERVAL / stack.prototype.speed)

  local speed = 1 / 2

  local source_position = {self.position.x, self.position.y - 2.5}
  local surface = entity.surface
  local create_entity = surface.create_entity

  for k = 1, get_beam_multiple(self.force_index) do
    local rocket = create_entity
    {
      name = "repair-bullet",
      speed = speed,
      position = source_position,
      target = entity,
      force = force,
      max_range = self.range * 2
    }
    speed = speed / 0.8
    create_entity
    {
      name = "repair-beam",
      target_position = source_position,
      source = rocket,
      position = self.position,
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

local mineable_products_cache = {}
local get_mineable_products = function(entity)

  local name = entity.name
  local products = mineable_products_cache[name]
  if products then return products end

  local prototype = entity.prototype
  products = prototype.mineable_properties.products or {}
  mineable_products_cache[name] = products
  for k, product in pairs (products) do
    product.count = product.amount_max or product.amount or 1
  end

  return products

end

local can_revive = function(ghost)
  if ghost.name == "tile-ghost" then return true end
  return ghost.surface.can_place_entity
        {
          name = ghost.ghost_name,
          position = ghost.position,
          direction = ghost.direction,
          force = ghost.force,
          build_check_type = defines.build_check_type.ghost_revive
        }
end

local get_item_to_place_in_network = function(ghost, get_item_count)
  for k, item in pairs (get_items_to_place(ghost)) do
    if (get_item_count(item)) >= item.count then
      return item
    end
  end
end

RepairTurret.can_build_ghost = function(self, ghost)

  local get_item_count = self.entity.logistic_network.get_item_count
  if can_revive(ghost) then
    local item = get_item_to_place_in_network(ghost, get_item_count)
    if item then
      return item
    end
  end

end

local revive_param = {raise_revive = true}

RepairTurret.try_build_ghost = function(self, ghost, pickup_entity, build_item)

  if not pickup_entity then return end
  --  if not self:can_build() then return end
  --
  --  local build_item = self:can_build_ghost(ghost)
  --  if not build_item then return end
  --
  --  local network = self.entity.logistic_network
  --  local point = network.select_pickup_point
  --  {
  --    name = build_item.name,
  --    position = self.position,
  --    include_buffers = true
  --  }
  --  if not point then return end
  --
  --local pickup_entity = point.owner

  if not can_revive(ghost) then return end

  local target_position = ghost.position
  local force = ghost.force

  local collided_items, entity, proxy = ghost.revive(revive_param)

  if collided_items then
    for name, count in pairs (collided_items) do
      network.insert{name = name, count = count}
    end
  end

  if pickup_entity ~= self.entity then
    make_path(pickup_entity, self.entity.logistic_cell, "construct-beam")
  end

  pickup_entity.remove_item(build_item)

  local position = self.position
  local source_position = {position.x, position.y - 2.5}

  self.entity.surface.create_entity
  {
    name = "construct-beam",
    source_position = source_position,
    target = entity,
    target_position = target_position,
    position = position,
    force = force,
    duration = TURRET_UPDATE_INTERVAL
  }

  return true

end

RepairTurret.deconstruct_entity = function(self, entity)
  if not self:can_build() then return end
  if not entity.can_be_destroyed() then return end
  local network = self.entity.logistic_network
  local position = entity.position
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
    -- todo check we can like the check below
  else
    for k, product in pairs (get_mineable_products(entity)) do
      if not network.select_drop_point{stack = product, "storage"} then
        return
      end
    end
  end

  local inventory = script_data.proxy_inventory
  local success = entity.mine
  {
    inventory = inventory
  }
  if not success then return end

  local cell = self.entity.logistic_cell
  local force = self.entity.force

  if tiles then
    surface.set_tiles(tiles)
  end

  local source_position = {self.position.x, self.position.y - 2.5}

  local rocket = surface.create_entity
  {
    name = "deconstruct-bullet",
    speed = -0.1,
    position = position,
    target = source_position,
    force = force,
    max_range = self.range * 2
  }
  surface.create_entity
  {
    name = "deconstruct-beam",
    target_position = source_position,
    source = rocket,
    position = position,
    force = force
  }

  local made_beam = false

  for stack_index = 1, #inventory do
    local stack = inventory[stack_index]
    if not stack.valid_for_read then break end
    local count = stack.count
    if not made_beam then
      local drop_point = network.select_drop_point{stack = stack}
      if drop_point then
        local owner = drop_point.owner
        count = count - owner.insert(stack)
        make_path(owner, cell, "deconstruct-beam")
        made_beam = true
      end
    end
    if count > 0 then
      count = count - network.insert(stack)
    end
    if count > 0 then
      stack.count = count
      surface.spill_item_stack(position, stack, false, nil, false)
    end
    stack.clear()
  end

  return true

end


RepairTurret.kidnap_robot = function(self, robot)
  local kidnap_tick = game.tick
  self.kidnapped_robots[robot.unit_number] = {robot = robot, tick = kidnap_tick}
  --game.print("Kidnapping robot" .. robot.unit_number)
  robot.teleport(HOSTAGE_POSITION)
  robot.active = false
  self:activate()
end

RepairTurret.distance = function(self, position)
  return util.distance(self.position, position)
end

local check_turret_update = function(event)
  local active_turrets = script_data.active_turrets
  local bucket_index = event.tick % TURRET_UPDATE_INTERVAL
  local bucket = active_turrets[bucket_index]
  if not bucket then return end
  for unit_number, turret in pairs(bucket) do
    turret:update()
  end
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
    script_data.can_construct[research.force.index] = true
  end

end

local on_entity_removed = function(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end

  if entity.logistic_cell then
    clear_cache()
  end

end

local entity_type = defines.target_type.entity
local on_object_destroyed = function(event)
  --game.print("Object destroyed")
  if event.type ~= entity_type then return end
  local turret = RepairTurret.get_turret(event.useful_id)
  if not turret then return end
  turret:on_destroyed()
end

local entity_marked_as_damaged = function(entity)
  if not entity.valid then return end
  for k, turret in pairs(find_nearby_turrets(entity)) do
    turret:add_target(entity)
  end
end

local find_turret_to_kidnap_robot = function(robot, target, for_deconstruction)
  local turrets = find_nearby_turrets(target, for_deconstruction)

  local best_turret = nil
  local lowest_kidnaps = math.huge
  local lowest_distance = math.huge

  local target_position = target.position

  for k, turret in pairs (turrets) do
    local kidnaps = table_size(turret.kidnapped_robots)
    if kidnaps < lowest_kidnaps then
      best_turret = turret
      lowest_kidnaps = kidnaps
      lowest_distance = turret:distance(target_position)
    else if kidnaps == lowest_kidnaps then
        local distance = turret:distance(target_position)
        if distance < lowest_distance then
          best_turret = turret
          lowest_distance = distance
        end
      end
    end
  end

  return best_turret
end

local refund_robot = function(robot)
  local roboport = robot.surface.find_entities_filtered {position = robot.position, type = "roboport"}[1]
  if not roboport then
    game.print("refund failed?")
    return
  end
  local inserted = roboport.get_inventory(defines.inventory.roboport_robot).insert(
    {
      name = robot.name,
      quality = robot.quality
    })
  if inserted == 0 then
    -- drop a stack or something
    game.print("refund failed!?")
  end

end

local try_to_steal_job = function(robot, queue, index)
  local job_to_steal = queue[index]
  if not job_to_steal then return end

  local target = job_to_steal.target
  if not (target and target.valid) then return end

  if job_to_steal.type == defines.robot_order_type.repair then
    entity_marked_as_damaged(target)
    return
  end

  local best_turret = find_turret_to_kidnap_robot(robot, target, job_to_steal.type == defines.robot_order_type.deconstruct)
  if not best_turret then return end

  refund_robot(robot)
  best_turret:kidnap_robot(robot)

end

local check_spawned_robot = function(robot)
  local queue = robot.robot_order_queue
  --game.print(robot.unit_number .. " - " .. serpent.block(queue))
  local handled_job_index = is_handled_job(queue)
  if not handled_job_index then return end
  try_to_steal_job(robot, queue, handled_job_index)
  --game.print(source_entity.name .. " spawned".. event.tick)
end

local check_robots = function()
  local robots = script_data.robots_to_check or {}
  for unit_number, robot in pairs(robots) do
    check_spawned_robot(robot)
    robots[unit_number] = nil
  end
end

local construction_robot_spawned = function(event)
  --game.print("hello")
  local source_entity = event.source_entity
  if not (source_entity and source_entity.valid) then
    return
  end
  script_data.robots_to_check = script_data.robots_to_check or {}
  script_data.robots_to_check[source_entity.unit_number] = source_entity
end

local on_script_trigger_effect = function(event)
  if event.effect_id == "construction-robot-spawned" then
    construction_robot_spawned(event)
  end
end

local on_tick = function(event)
  check_robots()
  check_turret_update(event)
end

local lib = {}

lib.events =
{
  [defines.events.on_player_created] = on_player_created,
  [defines.events.on_built_entity] = on_created_entity,
  [defines.events.on_robot_built_entity] = on_created_entity,
  [defines.events.script_raised_built] = on_created_entity,
  [defines.events.script_raised_revive] = on_created_entity,
  [defines.events.on_entity_cloned] = on_created_entity,

  [defines.events.on_tick] = on_tick,
  --[defines.events.on_entity_damaged] = on_entity_damaged,
  [defines.events.on_research_finished] = on_research_finished,

  [defines.events.on_entity_died] = on_entity_removed,
  [defines.events.script_raised_destroy] = on_entity_removed,
  [defines.events.on_player_mined_entity] = on_entity_removed,
  [defines.events.on_robot_mined_entity] = on_entity_removed,

  [defines.events.on_object_destroyed] = on_object_destroyed,

  [defines.events.on_post_entity_died] = on_post_entity_died,

  [defines.events.on_surface_cleared] = clear_cache,
  [defines.events.on_surface_deleted] = clear_cache,

  --[defines.events.on_marked_for_deconstruction] = on_marked_for_deconstruction,
  [defines.events.on_script_trigger_effect] = on_script_trigger_effect,
}

lib.on_init = function()
  global.repair_turret = global.repair_turret or script_data
  pathfinding.cache = script_data.pathfinder_cache
  script_data.proxy_inventory = game.create_inventory(200)
end

lib.on_load = function()
  script_data = global.repair_turret or script_data
  pathfinding.cache = script_data.pathfinder_cache
end

lib.on_configuration_changed = function()

  if not script_data.pathfinder_cache then
    script_data.pathfinder_cache = {}
    pathfinding.cache = script_data.pathfinder_cache
  end

  script_data.can_construct = script_data.can_construct or {}
  script_data.proxy_inventory = script_data.proxy_inventory or game.create_inventory(200)

end

return lib
