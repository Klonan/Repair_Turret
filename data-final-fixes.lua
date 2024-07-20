local trigger =
{
  type = "direct",
  action_delivery =
  {
    type = "instant",
    target_effects =
    {
      {
        type = "script",
        effect_id = "construction-robot-spawned"
      }
    }
  }
}

local add_trigger_to_robot = function(robot)
  if not robot.created_effect then
    robot.created_effect = trigger
    return
  end
  if robot.created_effect.type then
    robot.created_effect = {robot.created_effect, trigger}
    return
  end
  table.insert(robot.created_effect.target_effects, trigger)
end


for k, robot in pairs (data.raw["construction-robot"]) do
  add_trigger_to_robot(robot)
end