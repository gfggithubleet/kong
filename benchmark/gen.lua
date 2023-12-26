--function replaceNamePattern(url)
--  local replacedUrl = url:gsub("{(.-)}", "(?<%1>\\S+)")
--
--  return replacedUrl
--end
--
--
--local file = io.open("github-api.txt", "rb")
--if not file then return nil end
--
--local lines = {}
--
--for line in io.lines("github-api.txt") do
--  print("~" ..  replaceNamePattern((line)))
--end
--
--file:close()
--return lines;

local service1 = {
  name = "example-service",
  host = "mockbin.org",
  port = 80,
  protocol = "http",
  routes = {},
  plugins = {
    {
      name = "pre-function",
      config = {
        access = {
          "kong.response.exit(200, { params = kong.request.get_uri_captures()})"
        }
      }
    }
  }
}
local config = {
  _format_version = "3.0",
  services = { service1 }
}

local function gen_simple_variable(n)
  local lyaml = require "lyaml"

  -- default
  service1.routes = {}
  for i = 1, n do
    local route = {
      name = "route" .. i,
      paths = { string.format("~/user%d/(?<name>\\S+)$", i) }
    }
    service1.routes[i] = route
  end
  local content = lyaml.dump({ config })
  local file = io.open("kong-default-variable-" .. n  .. ".yaml", "w")
  file:write(content)
  file:close()

  -- radix
  service1.routes = {}
  for i = 1, n do
    local route = {
      name = "route" .. i,
      paths = { string.format("/user%d/{name}", i) }
    }
    service1.routes[i] = route
  end
  local content = lyaml.dump({ config })
  local file = io.open("kong-radix-variable-" .. n .. ".yaml", "w")
  file:write(content)
  file:close()
end


gen_simple_variable(1000)
gen_simple_variable(10000)
gen_simple_variable(20000)
gen_simple_variable(30000)
gen_simple_variable(100000)
