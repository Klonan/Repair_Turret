local turret_update_interval = 13
local repair_update_interval = 29

local script_data =
{
  turrets = {},
  active_turrets = {},
  repair_queue = {}
}

local turret_name = require("shared").entities.repair_turret

local on_player_created = function(event)
  local player = game.get_player(event.player_index)
  player.insert("repair-turret")
end

local add_to_repair_queue = function(entity)

  local unit_number = entity.unit_number
  if not unit_number then return end

  if script_data.repair_queue[unit_number] then return end
  script_data.repair_queue[unit_number] = entity

end

local on_created_entity = function(event)
  local entity = event.created_entity
  if not (entity and entity.valid) then return end

  if entity.name ~= turret_name then return end

  script_data.turrets[entity.unit_number] = entity

end

local update_turret = function(turret_data)
  local turret = turret_data.turret
  if not (turret and turret.valid) then return true end

  local entity = turret_data.entity
  if not (entity and entity.valid) then return true end

  if entity.get_health_ratio() == 1 then return true end

  local stack = turret.get_inventory(defines.inventory.roboport_material)[1]
  if not (stack and stack.valid and stack.valid_for_read) then
    add_to_repair_queue(entity)
    return true
  end

  local needed_repair = entity.prototype.max_health - entity.health

  local repair_prototype = stack.prototype
  local repair_speed = repair_prototype.speed

  local max_repair = math.min(repair_speed * turret_update_interval, needed_repair)

  entity.health = entity.health + max_repair
  stack.drain_durability(max_repair / repair_speed)
  turret.surface.create_entity
  {
    name = "laser-beam",
    source_position = turret.position,
    target_position = entity.position,
    duration = turret_update_interval,
    position = turret.position,
    force = turret.force
  }




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

  entity.surface.create_entity{name = "flying-text", position = entity.position, text = "?"}

  local position = entity.position

  local active_turrets = script_data.active_turrets
  local nearby_turrets = {}
  local networks = entity.surface.find_logistic_networks_by_construction_area(position, entity.force)
  for k, network in pairs (networks) do
    local turret = network.find_cell_closest_to(position).owner
    local unit_number = turret.unit_number
    if turret.name == turret_name and
      turret ~= entity and
      (not active_turrets[turret.unit_number]) and
      turret.has_items_inside() then
      nearby_turrets[turret.unit_number] = turret
    end
  end

  if not next(nearby_turrets) then return end

  local closest_turret = entity.surface.get_closest(position, nearby_turrets)

  activate_turret(closest_turret, entity)
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


local lib = {}

lib.events =
{
  [defines.events.on_player_created] = on_player_created,
  [defines.events.on_built_entity] = on_created_entity,
  [defines.events.on_tick] = on_tick,
  [defines.events.on_entity_damaged] = on_entity_damaged
}

lib.on_load = function()
  script_data = global.repair_turret or script_data
end

lib.on_init = function()
  global.repair_turret = global.repair_turret or script_data
end

return lib
