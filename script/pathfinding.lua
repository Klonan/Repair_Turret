local position_cache = {}
local get_position = function(cell, index)
  local position = position_cache[index]
  if position then
    return position
  end
  position = cell.owner.position
  position_cache[index] = position
  return position
end

local abs = math.abs
local dist = function(cell_a, cell_a_index, cell_b, cell_b_index)
  local position1 = get_position(cell_a, cell_a_index)
  local position2 = get_position(cell_b, cell_b_index)
  local dx, dy = position2.x - position1.x, position2.y - position1.y
  return (dx > 0 and dx or -dx) + (dy > 0 and dy or -dy)
end

local max = math.huge
local insert = table.insert

local lowest_f_score = function(set, f_score)
  local lowest = max
  local best_cell
  for unit_number, cell in pairs(set) do
    local score = f_score[unit_number]
    if score <= lowest then
      lowest = score
      best_cell = cell
    end
  end
  return best_cell
end

local unwind_path
unwind_path = function(flat_path, map, current_cell)
  local index = current_cell.owner.unit_number
  local node = map[index]
  if node then
    insert(flat_path, 1, node)
    return unwind_path(flat_path, map, node)
  else
    return flat_path
  end
end

local get_path = function(start, goal)
  --print("Starting path find")
  local closed_set = {}
  local open_set = {}
  local came_from = {}

  local g_score = {}
  local f_score = {}
  local start_index = start.owner.unit_number
  local goal_index = goal.owner.unit_number
  open_set[start_index] = start
  g_score[start_index] = 0
  f_score[start_index] = dist(start, start_index, goal, goal_index)

  local insert = table.insert
  local dist = dist
  local lowest_f_score = lowest_f_score
  while next(open_set) do

    local current = lowest_f_score(open_set, f_score)

    if current == goal then
      local path = unwind_path({}, came_from, goal)
      insert(path, goal)
      --print("A* path find complete")
      return path
    end

    local current_index = current.owner.unit_number
    open_set[current_index] = nil
    closed_set[current_index] = current

    for k, neighbour in pairs(current.neighbours) do
      local neighbour_index = neighbour.owner.unit_number

      if not closed_set[neighbour_index] then

        local tentative_g_score = g_score[current_index] + dist(current, current_index, neighbour, neighbour_index)
        local new_node = not open_set[neighbour_index]

        if new_node then
          open_set[neighbour_index] = neighbour
          f_score[neighbour_index] = max
        end

        if new_node or tentative_g_score < g_score[neighbour_index] then
          came_from[neighbour_index] = current
          g_score[neighbour_index] = tentative_g_score
          f_score[neighbour_index] = g_score[neighbour_index] + dist(neighbour, neighbour_index, goal, goal_index)
        end

      end

    end

  end
  return nil -- no valid path
end

local get_cell_path = function(source, destination_cell)

  local origin_cell = destination_cell.logistic_network.find_cell_closest_to(source.position)
  if not destination_cell and origin_cell then return end

  local path = get_path(origin_cell, destination_cell)

  return path

end

local lib = {}

lib.get_cell_path = get_cell_path

lib.clear_position_cache = function()
  position_cache = {}
end

return lib