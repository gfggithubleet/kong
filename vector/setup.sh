
curl -X POST http://localhost:8001/plugins \
    -H 'Content-Type: application/json' \
    -d '{
      "name": "opentelemetry",
      "config": {
        "endpoint": "http://localhost:4318/v1/traces",
        "resource_attributes": {
          "service.name": "kong-dev"
        }
      }
    }'
http -f put :8001/services/test url=https://www.google.com/
http -f put :8001/services/test/routes/test paths=/
