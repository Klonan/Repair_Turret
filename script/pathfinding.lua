local dist = function(cell_a, cell_b)
  local position1 = cell_a.owner.position
  local position2 = cell_b.owner.position
  return ((position2.x - position1.x) * (position2.x - position1.x)) + ((position2.y - position1.y) * (position2.y - position1.y))
end

local max = math.huge
local insert = table.insert

local lowest_f_score = function(set, f_score)
  local lowest = max
  local bestcell
  for k, cell in pairs(set) do
    local score = f_score[cell.owner.unit_number]
    if score <= lowest then
      lowest = score
      bestcell = cell
    end
  end
  return bestcell
end

local unwind_path
unwind_path = function(flat_path, map, current_cell)
  local index = current_cell.owner.unit_number
  if map[index] then
    insert(flat_path, 1, map[index])
    return unwind_path(flat_path, map, map[index])
  else
    return flat_path
  end
end

local get_path = function(start, goal, cells)
  print("Starting path find")
  local closed_set = {}
  local open_set = {}
  local came_from = {}

  local g_score = {}
  local f_score = {}
  local start_index = start.owner.unit_number
  open_set[start_index] = start
  g_score[start_index] = 0
  f_score[start_index] = dist(start, goal)

  local insert = table.insert
  while table_size(open_set) > 0 do

    local current = lowest_f_score(open_set, f_score)

    if current == goal then
      local path = unwind_path({}, came_from, goal)
      insert(path, goal)
      print("A* path find complete")
      return path
    end

    local current_index = current.owner.unit_number
    open_set[current_index] = nil
    closed_set[current_index] = current

    for k, neighbour in pairs(current.neighbours) do
      local neighbour_index = neighbour.owner.unit_number
      if not closed_set[neighbour_index] then
        local tentative_g_score = g_score[current_index] + dist(current, neighbour)
        local new_node = not open_set[neighbour_index]
        if new_node then
          open_set[neighbour.owner.unit_number] = neighbour
          f_score[neighbour.owner.unit_number] = max
        end
        if new_node or tentative_g_score < g_score[neighbour_index] then
          came_from[neighbour_index] = current
          g_score[neighbour_index] = tentative_g_score
          f_score[neighbour_index] = g_score[neighbour_index] + dist(neighbour, goal)
        end
      end
    end

  end
  return nil -- no valid path
end

local get_cell_path = function(source, destination_cell, logistic_network)

  local origin_cell = logistic_network.find_cell_closest_to(source.position)
  if not destination_cell and origin_cell then return end

  return get_path(origin_cell, destination_cell, logistic_network.cells)

end

local lib = {}

lib.get_cell_path = get_cell_path

return lib