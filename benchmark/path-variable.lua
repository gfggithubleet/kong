local counter = 1
math.randomseed(os.time())
local random_i = math.random(600, 700)
request = function()
  -- random URL ensure not hitting the cache!
  local path = string.format("/user%d/%d", random_i, counter)
  counter = counter + 1
  return wrk.format(nil, path)
end
