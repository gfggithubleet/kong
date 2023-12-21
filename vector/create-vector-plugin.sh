http :8001/plugins \
     name=vector \
     'config[vector_config]=@vector/vector.toml' \
     'config[error_log_url]=http://localhost:3992/'
