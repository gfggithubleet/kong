local counter = 1

request = function()
  local path = string.format("/repos/owner%d/repo%d/pages/health", counter, counter)
  counter = counter + 1
  return wrk.format(nil, path)
end
