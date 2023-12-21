
local cjson = require "cjson"
local errlog = require "ngx.errlog"
local kong_meta = require "kong.meta"
local http = require "resty.http"

local VectorHandler =  {
  PRIORITY = 6,
  VERSION = kong_meta.version,
}

local VECTOR_CONFIG_DIRECTORY = "/etc/vector"
local ERROR_FORWARDER_TIMER_NAME = "vector-error-log-forwarder"
local ERROR_FORWARDER_TIMER_INTERVAL = 1
local ERROR_LOG_URL

local function forward_error_log(url)
  local logs, err = errlog.get_logs()
  if not logs then
    kong.log.err("cannot get error log entries: ", err)
    kong.timer:cancel(ERROR_FORWARDER_TIMER_NAME)
    return
  end

  if #logs == 0 then
    return -- nothing logged
  end

  local httpc = http.new()
  local res, err = httpc:request_uri(ERROR_LOG_URL, {
    method = "POST",
    body = cjson.encode(logs),
  })
  if not res then
    kong.log.err("failed sending: " .. err)
    return nil, "failed request to " .. ERROR_LOG_URL .. ": " .. err
  end

  return true
end

function VectorHandler:configure(configs)
  if ngx.worker.id() ~= 0 or not configs or #configs == 0 then
    return
  end

  if #configs ~= 1 then
    kong.log.err("cannot have multiple vector plugins, not started")
  end
  local config = configs[1]

  -- write vector configuration file
  local file = assert(io.open(VECTOR_CONFIG_DIRECTORY .. "/vector.toml", "w"))
  file:write(config.vector_config)
  file:close()

  -- start log collector
  ERROR_LOG_URL = config.error_log_url
  kong.timer:cancel(ERROR_FORWARDER_TIMER_NAME) -- remove any previous instance
  local name, err = kong.timer:named_every(ERROR_FORWARDER_TIMER_NAME, ERROR_FORWARDER_TIMER_INTERVAL, forward_error_log)
  if not name then
    kong.log.err("could not start error log forwarding timer: ", err)
  end
end

return VectorHandler
