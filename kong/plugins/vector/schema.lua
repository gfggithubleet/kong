local typedefs = require "kong.db.schema.typedefs"

return {
  name   = "vector",
  fields = { {
               config = {
                 type   = "record",
                 fields = {
                   { vector_config = { description = "The configuration for vector to apply, must be in TOML format",
                                       type        = "string",
                                       required    = true, } },
                   { error_log_url = typedefs.url({ description = "URL to use to send error logs to vector",
                                                    required    = true, }), },
                 }
               }
             } }
}
