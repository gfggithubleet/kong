#!/bin/sh

set -e

id=$(http :8001/plugins | jq -r '.data[] | select(.name == "vector") |  .id')
http patch :8001/plugins/$id 'config[vector_config]=@vector/vector.toml'
