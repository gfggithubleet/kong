local helpers   = require "spec.helpers"
local http_mock = require "spec.helpers.http_mock"
local cjson     = require "cjson"


local stop_kong = helpers.stop_kong


for _, strategy in helpers.each_strategy() do
  describe("Upstream header(s) [#" .. strategy .. "]", function()

    local proxy_client
    local bp, db

    local function insert_routes(arr)
      if type(arr) ~= "table" then
        return error("expected arg #1 to be a table", 2)
      end

      for i = 1, #arr do
        local service = assert(bp.services:insert())
        local route   = arr[i]
        route.service = service
        bp.routes:insert(route)
      end
    end

    local function request_headers(headers, path)
      local res = assert(proxy_client:send {
        method  = "GET",
        path    = path or "/",
        headers = headers,
      })

      local json = assert.res_status(200, res)

      return cjson.decode(json).headers
    end

    local function start_kong(config)
      return function()
        assert(db:truncate("routes"))
        assert(db:truncate("services"))

        insert_routes {
          {
            protocols     = { "http" },
            hosts         = { "headers-inspect.test" },
          },
          {
            protocols     = { "http" },
            hosts         = { "preserved.test" },
            preserve_host = true,
          },
          {
            protocols     = { "http" },
            paths         = { "/foo" },
            strip_path    = true,
          },
          {
            protocols     = { "http" },
            paths         = { "/status/200" },
            strip_path    = false,
          },
          {
            protocols     = { "http" },
            paths         = { "/" },
            strip_path    = true,
          },
        }

        local service = assert(bp.services:insert())
        local route   = bp.routes:insert({
          service     = service,
          protocols   = { "http" },
          paths       = { "/proxy-authorization" },
          strip_path  = true,
        })

        bp.plugins:insert({
          route = route,
          name = "request-transformer",
          config = {
            add = {
              headers = {
                "Proxy-Authorization:Basic ZGVtbzp0ZXN0",
              },
            },
            replace = {
              headers = {
                "Proxy-Authorization:Basic ZGVtbzp0ZXN0",
              },
            },
          },
        })

        assert(helpers.start_kong(config))
      end
    end

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
      })
    end)

    before_each(function()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then
        proxy_client:close()
      end
    end)

    describe("hop-by-hop headers", function()
      lazy_setup(start_kong {
        database         = strategy,
        nginx_conf       = "spec/fixtures/custom_nginx.template",
        lua_package_path = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
      })

      lazy_teardown(stop_kong)

      it("are removed from request", function()
        local headers = request_headers({
          ["Connection"]          = "X-Foo, X-Bar",
          ["Host"]                = "headers-inspect.test",
          ["Keep-Alive"]          = "timeout=5, max=1000",
          ["Proxy"]               = "Remove-Me", -- See: https://httpoxy.org/
          ["Proxy-Connection"]    = "close",
          -- This is a response header, so we don't remove it, should we?
          ["Proxy-Authenticate"]  = "Basic",
          ["Proxy-Authorization"] = "Basic YWxhZGRpbjpvcGVuc2VzYW1l",
          ["TE"]                  = "trailers, deflate;q=0.5",
          --["Transfer-Encoding"]   = "identity", -- Removed with OpenResty 1.19.3.1 as Nginx errors with:
                                                  -- client sent unknown "Transfer-Encoding": "identity"

          -- This is a response header, so we don't remove it, should we?
          --["Trailer"]             = "Expires",
          ["Upgrade"]             = "example/1, foo/2",
          ["X-Foo"]               = "Remove-Me",
          ["X-Bar"]               = "Remove-Me",
          ["X-Foo-Bar"]           = "Keep-Me",
          ["Close"]               = "Keep-Me",
        })

        assert.is_nil(headers["keep-alive"])
        assert.is_nil(headers["proxy"])
        assert.is_nil(headers["proxy-connection"])
        assert.is_nil(headers["upgrade"])
        assert.is_nil(headers["x-boo"])
        assert.is_nil(headers["x-bar"])
        assert.equal("Basic", headers["proxy-authenticate"])
        assert.equal("Basic YWxhZGRpbjpvcGVuc2VzYW1l", headers["proxy-authorization"])
        assert.equal("trailers", headers["te"]) -- trailers are kept
        assert.equal("Keep-Me", headers["x-foo-bar"])
        assert.equal("Keep-Me", headers["close"])
      end)

      it("are removed from response", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          headers = {
            ["Host"] = "headers-inspect.test",
          },
          path = "/hop-by-hop",
        })

        assert.res_status(200, res)

        local headers = res.headers

        assert.is_nil(headers["keep-alive"])
        -- This needs to be cleared only on requests (https://httpoxy.org/)
        --assert.is_nil(headers["proxy"])
        -- This is a request header, so we don't remove it, should we?
        --assert.is_nil(headers["proxy-connection"])
        --assert.is_nil(headers["proxy-authenticate"])
        -- This is a request header, so we don't remove it, should we?
        --assert.is_nil(headers["proxy-authorization"])
        -- This is a request header, so we don't remove it, should we?
        --assert.is_nil(headers["te"])
        assert.is_nil(headers["trailer"])
        assert.is_nil(headers["upgrade"])

        assert.equal("chunked", headers["transfer-encoding"])
      end)

      it("keeps trailer when requested", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          headers = {
            ["Host"] = "headers-inspect.test",
            ["TE"]   = "trailers"
          },
          path = "/hop-by-hop",
        })

        assert.res_status(200, res)

        local headers = res.headers

        assert.equal("Expires", headers["Trailer"])
      end)

      it("keeps upgrade when upgrading", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          headers = {
            ["Host"] = "headers-inspect.test",
            ["Connection"] = "keep-alive, Upgrade",
            ["Upgrade"] = "websocket"
          },
          path = "/get",
        })

        local json = cjson.decode(assert.res_status(200, res))
        assert.equal("keep-alive, Upgrade", json.headers.connection)
        assert.equal("websocket", json.headers.upgrade)
      end)

      it("keeps proxy-authorization header when a plugin specifies it", function()
        local headers = request_headers({
          ["Proxy-Authorization"] = "Basic YWxhZGRpbjpvcGVuc2VzYW1l",
        }, "/proxy-authorization")

        assert.equal("Basic ZGVtbzp0ZXN0", headers["proxy-authorization"])

        local headers = request_headers({}, "/proxy-authorization")

        assert.equal("Basic ZGVtbzp0ZXN0", headers["proxy-authorization"])
      end)

      it("keeps proxy-authorization header if plugin specifies same value as in requests", function()
        local headers = request_headers({
          ["Proxy-Authorization"] = "Basic ZGVtbzp0ZXN0",
        }, "/proxy-authorization")

        assert.equal("Basic ZGVtbzp0ZXN0", headers["proxy-authorization"])
      end)
    end)

    describe("(response from upstream)", function()
      local mock
      lazy_setup(function()
        assert(db:truncate("routes"))
        assert(db:truncate("services"))
        local port = helpers.get_available_port()
        mock = http_mock.new("localhost:" .. port, {
          ["/nocharset"] = {
            content = [[
              ngx.header.content_type = "text/plain"
              ngx.say("Hello World!")
            ]]
          },
          ["/charset"] = {
            content = [[
              ngx.header.content_type = "text/plain; charset=utf-8"
              ngx.say("Hello World!")
            ]]
          }
        }, {
          record_opts = {
            req = false,
          }
        })

        assert(mock:start())

        local service = assert(bp.services:insert {
          protocol = "http",
          host = "127.0.0.1",
          port = port,
        })

        assert(bp.routes:insert {
          hosts = { "headers-charset.test" },
          paths = { "/" },
          service = service,
        })

        assert(helpers.start_kong({
          database           = strategy,
          nginx_http_charset = "off",
        }))
      end)

      lazy_teardown(function()
        stop_kong()
        mock:stop()
      end)

      describe("Content-Type", function()
        it("does not add charset if the response from upstream contains no charset when charset is turned off", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/nocharset",
            headers = {
              ["Host"] = "headers-charset.test",
            }
          })

          assert.res_status(200, res)
          assert.equal("text/plain", res.headers["Content-Type"])
        end)

        it("charset remain unchanged if the response from upstream contains charset when charset is turned off", function()
          local res = assert(proxy_client:send {
            method  = "GET",
            path    = "/charset",
            headers = {
              ["Host"] = "headers-charset.test",
            }
          })

          assert.res_status(200, res)
          assert.equal("text/plain; charset=utf-8", res.headers["Content-Type"])
        end)
      end)
    end)

    describe("(using the default configuration values)", function()
      lazy_setup(start_kong {
        database         = strategy,
        nginx_conf       = "spec/fixtures/custom_nginx.template",
        lua_package_path = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
      })

      lazy_teardown(stop_kong)

      describe("X-Real-IP", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]      = "headers-inspect.test",
            ["X-Real-IP"] = "10.0.0.1",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
        end)
      end)

      describe("X-Forwarded-For", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("127.0.0.1", headers["x-forwarded-for"])
        end)

        it("should be appended if present in request", function()
          local headers = request_headers {
            ["Host"]            = "headers-inspect.test",
            ["X-Forwarded-For"] = "10.0.0.1",
          }

          assert.equal("10.0.0.1, 127.0.0.1", headers["x-forwarded-for"])
        end)
      end)

      describe("X-Forwarded-Proto", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("http", headers["x-forwarded-proto"])
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]              = "headers-inspect.test",
            ["X-Forwarded-Proto"] = "https",
          }

          assert.equal("http", headers["x-forwarded-proto"])
        end)
      end)

      describe("X-Forwarded-Host", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("headers-inspect.test", headers["x-forwarded-host"])
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Host"] = "example.test",
          }

          assert.equal("headers-inspect.test", headers["x-forwarded-host"])
        end)
      end)

      describe("X-Forwarded-Port", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Port"] = "80",
          }

          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
        end)
      end)

      describe("X-Forwarded-Path", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("/", headers["x-forwarded-path"])
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Path"] = "/replaced",
          }

          assert.equal("/", headers["x-forwarded-path"])
        end)
      end)

      describe("X-Forwarded-Prefix", function()
        it("should be added if path was stripped", function()
          local headers = request_headers({}, "/foo/status/200")

          assert.equal("/foo", headers["x-forwarded-prefix"])
        end)

        it("should be replaced if present in request and path was stripped", function()
          local headers = request_headers({
            ["X-Forwarded-Prefix"] = "/replaced",
          }, "/foo")

          assert.equal("/foo", headers["x-forwarded-prefix"])
        end)

        it("should not be added if path was not stripped", function()
          local headers = request_headers({}, "/status/200")

          assert.is_nil(headers["x-forwarded-prefix"])
        end)

        it("should not be added if / was stripped", function()
          local headers = request_headers({}, "/")

          assert.is_nil(headers["x-forwarded-prefix"])
        end)
      end)

      describe("with the downstream host preserved", function()
        it("should be added if not present in request while preserving the downstream host", function()
          local headers = request_headers {
            ["Host"] = "preserved.test",
          }

          assert.equal("preserved.test", headers["host"])
          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1", headers["x-forwarded-for"])
          assert.equal("http", headers["x-forwarded-proto"])
          assert.equal("preserved.test", headers["x-forwarded-host"])
          assert.equal("/", headers["x-forwarded-path"])
          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
        end)

        it("should be added if present in request while preserving the downstream host", function()
          local headers = request_headers {
            ["Host"]              = "preserved.test",
            ["X-Real-IP"]         = "10.0.0.1",
            ["X-Forwarded-For"]   = "10.0.0.1",
            ["X-Forwarded-Proto"] = "https",
            ["X-Forwarded-Host"]  = "example.test",
            ["X-Forwarded-Port"]  = "80",
          }

          assert.equal("preserved.test", headers["host"])
          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("10.0.0.1, 127.0.0.1", headers["x-forwarded-for"])
          assert.equal("http", headers["x-forwarded-proto"])
          assert.equal("preserved.test", headers["x-forwarded-host"])
          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
          assert.equal("/", headers["x-forwarded-path"])
        end)
      end)

      describe("with the downstream host discarded", function()
        it("should be added if not present in request while discarding the downstream host", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal(helpers.mock_upstream_host .. ":" ..
                       helpers.mock_upstream_port,
                       headers["host"])
          assert.equal(helpers.mock_upstream_host, headers["x-real-ip"])
          assert.equal(helpers.mock_upstream_host, headers["x-forwarded-for"])
          assert.equal("http", headers["x-forwarded-proto"])
          assert.equal("headers-inspect.test", headers["x-forwarded-host"])
          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
          assert.equal("/", headers["x-forwarded-path"])
        end)

        it("if present in request while discarding the downstream host", function()
          local headers = request_headers {
            ["Host"]              = "headers-inspect.test",
            ["X-Real-IP"]         = "10.0.0.1",
            ["X-Forwarded-For"]   = "10.0.0.1",
            ["X-Forwarded-Proto"] = "https",
            ["X-Forwarded-Host"]  = "example.test",
            ["X-Forwarded-Port"]  = "80",
          }

          assert.equal(helpers.mock_upstream_host .. ":" ..
                       helpers.mock_upstream_port,
                       headers["host"])
          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("10.0.0.1, 127.0.0.1", headers["x-forwarded-for"])
          assert.equal("http", headers["x-forwarded-proto"])
          assert.equal("headers-inspect.test", headers["x-forwarded-host"])
          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
          assert.equal("/", headers["x-forwarded-path"])
        end)
      end)

    end)

    describe("(using the trusted configuration values)", function()
      lazy_setup(start_kong {
        database         = strategy,
        trusted_ips      = "127.0.0.1",
        nginx_conf       = "spec/fixtures/custom_nginx.template",
        lua_package_path = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
      })

      lazy_teardown(stop_kong)

      describe("X-Real-IP", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
        end)

        it("should be forwarded if present in request", function()
          local headers = request_headers {
            ["Host"]      = "headers-inspect.test",
            ["X-Real-IP"] = "10.0.0.1",
          }

          assert.equal("10.0.0.1", headers["x-real-ip"])
        end)
      end)

      describe("X-Forwarded-For", function()

        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("127.0.0.1", headers["x-forwarded-for"])
        end)

        it("should be appended if present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
            ["X-Forwarded-For"] = "10.0.0.1",
          }

          assert.equal("10.0.0.1, 127.0.0.1", headers["x-forwarded-for"])
        end)

      end)

      describe("X-Forwarded-Proto", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("http", headers["x-forwarded-proto"])
        end)

        it("should be forwarded if present in request", function()
          local headers = request_headers {
            ["Host"]              = "headers-inspect.test",
            ["X-Forwarded-Proto"] = "https",
          }

          assert.equal("https", headers["x-forwarded-proto"])
        end)
      end)

      describe("X-Forwarded-Host", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("headers-inspect.test", headers["x-forwarded-host"])
        end)

        it("should be forwarded if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Host"] = "example.test",
          }

          assert.equal("example.test", headers["x-forwarded-host"])
        end)
      end)

      describe("X-Forwarded-Port", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
        end)

        it("should be forwarded if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Port"] = "80",
          }

          assert.equal("80", headers["x-forwarded-port"])
        end)
      end)

      describe("X-Forwarded-Path", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("/", headers["x-forwarded-path"])
        end)

        it("should be forwarded if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Path"] = "/original-path",
          }

          assert.equal("/original-path", headers["x-forwarded-path"])
        end)
      end)

      describe("X-Forwarded-Prefix", function()
        it("should be preserved even if path was stripped", function()
          local headers = request_headers({
            ["x-forwarded-prefix"] = "/preserved",
          }, "/foo/status/200")

          assert.equal("/preserved", headers["x-forwarded-prefix"])
        end)

        it("should be preserved even if path was stripped", function()
          local headers = request_headers({
            ["x-forwarded-prefix"] = "/preserved",
          }, "/status/200")

          assert.equal("/preserved", headers["x-forwarded-prefix"])
        end)
      end)
    end)

    describe("(using the non-trusted configuration values)", function()
      lazy_setup(start_kong {
        database         = strategy,
        trusted_ips      = "10.0.0.1",
        nginx_conf       = "spec/fixtures/custom_nginx.template",
        lua_package_path = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
      })

      lazy_teardown(stop_kong)

      describe("X-Real-IP", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]      = "headers-inspect.test",
            ["X-Real-IP"] = "10.0.0.1",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
        end)
      end)

      describe("X-Forwarded-For", function()

        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("127.0.0.1", headers["x-forwarded-for"])
        end)

        it("should be appended if present in request", function()
          local headers = request_headers {
            ["Host"]            = "headers-inspect.test",
            ["X-Forwarded-For"] = "10.0.0.1",
          }

          assert.equal("10.0.0.1, 127.0.0.1", headers["x-forwarded-for"])
        end)

      end)

      describe("X-Forwarded-Proto", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("http", headers["x-forwarded-proto"])
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]              = "headers-inspect.test",
            ["X-Forwarded-Proto"] = "https",
          }

          assert.equal("http", headers["x-forwarded-proto"])
        end)
      end)

      describe("X-Forwarded-Host", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("headers-inspect.test", headers["x-forwarded-host"])
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Host"] = "example.test",
          }

          assert.equal("headers-inspect.test", headers["x-forwarded-host"])
        end)
      end)

      describe("X-Forwarded-Port", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Port"] = "80",
          }

          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
        end)
      end)

      describe("X-Forwarded-Path", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("/", headers["x-forwarded-path"])
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Path"] = "/untrusted",
          }

          assert.equal("/", headers["x-forwarded-path"])
        end)
      end)

      describe("X-Forwarded-Prefix", function()
        it("should be added if path was stripped", function()
          local headers = request_headers({}, "/foo/status/200")

          assert.equal("/foo", headers["x-forwarded-prefix"])
        end)

        it("should be replaced if present in request and path was stripped", function()
          local headers = request_headers({
            ["X-Forwarded-Prefix"] = "/replaced",
          }, "/foo")

          assert.equal("/foo", headers["x-forwarded-prefix"])
        end)

        it("should not be added if path was not stripped", function()
          local headers = request_headers({}, "/status/200")

          assert.is_nil(headers["x-forwarded-prefix"])
        end)

        it("should not be added if / was stripped", function()
          local headers = request_headers({}, "/")

          assert.is_nil(headers["x-forwarded-prefix"])
        end)
      end)
    end)

    describe("(using the recursive trusted configuration values)", function()
      lazy_setup(start_kong {
        database          = strategy,
        real_ip_header    = "X-Forwarded-For",
        real_ip_recursive = "on",
        trusted_ips       = "127.0.0.1,172.16.0.1,192.168.0.1",
        nginx_conf        = "spec/fixtures/custom_nginx.template",
        lua_package_path  = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
      })

      lazy_teardown(stop_kong)

      describe("X-Real-IP and X-Forwarded-For", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1", headers["x-forwarded-for"])
        end)

        it("should be changed according to rules if present in request", function()
          local headers = request_headers {
            ["Host"]            = "headers-inspect.test",
            ["X-Forwarded-For"] = "127.0.0.1, 10.0.0.1, 192.168.0.1, 127.0.0.1, 172.16.0.1",
            ["X-Real-IP"]       = "10.0.0.2",
          }

          assert.equal("10.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1, 10.0.0.1, 192.168.0.1, 127.0.0.1, 172.16.0.1, 127.0.0.1", headers["x-forwarded-for"])
        end)
      end)

      describe("X-Forwarded-Port", function()
        it("should be forwarded even if X-Forwarded-For header has a port in it", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-For"]  = "127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18",
            ["X-Real-IP"]        = "10.0.0.2",
            ["X-Forwarded-Port"] = "14",
          }

          assert.equal("10.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18, 127.0.0.1", headers["x-forwarded-for"])
          assert.equal(14, tonumber(headers["x-forwarded-port"]))
        end)

        pending("should take a port from X-Forwarded-For header if it has a port in it", function()
  --        local headers = request_headers {
  --          ["Host"]             = "headers-inspect.test",
  --          ["X-Forwarded-For"]  = "127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18",
  --          ["X-Real-IP"]        = "10.0.0.2",
  --        }
  --
  --        assert.equal("10.0.0.1", headers["x-real-ip"])
  --        assert.equal("127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18, 127.0.0.1", headers["x-forwarded-for"])
  --        assert.equal(16, tonumber(headers["x-forwarded-port"]))
        end)
      end)
    end)

    describe("(using the recursive non-trusted configuration values)", function()
      lazy_setup(start_kong {
        database          = strategy,
        real_ip_header    = "X-Forwarded-For",
        real_ip_recursive = "on",
        trusted_ips       = "10.0.0.1,172.16.0.1,192.168.0.1",
        nginx_conf        = "spec/fixtures/custom_nginx.template",
        lua_package_path  = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
      })

      lazy_teardown(stop_kong)

      describe("X-Real-IP and X-Forwarded-For", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1", headers["x-forwarded-for"])
        end)

        it("should be changed according to rules if present in request", function()
          local headers = request_headers {
            ["Host"]            = "headers-inspect.test",
            ["X-Forwarded-For"] = "10.0.0.1, 127.0.0.2, 10.0.0.1, 192.168.0.1, 172.16.0.1",
            ["X-Real-IP"]       = "10.0.0.2",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("10.0.0.1, 127.0.0.2, 10.0.0.1, 192.168.0.1, 172.16.0.1, 127.0.0.1", headers["x-forwarded-for"])
        end)
      end)

      describe("X-Forwarded-Port", function()
        it("should be replaced even if X-Forwarded-Port and X-Forwarded-For headers have a port in it", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-For"]  = "127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18",
            ["X-Real-IP"]        = "10.0.0.2",
            ["X-Forwarded-Port"] = "14",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18, 127.0.0.1", headers["x-forwarded-for"])
          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
        end)

        it("should not take a port from X-Forwarded-For header if it has a port in it", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-For"]  = "127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18",
            ["X-Real-IP"]        = "10.0.0.2",
          }

          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18, 127.0.0.1", headers["x-forwarded-for"])
          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
        end)
      end)

    end)

    describe("(using trusted proxy protocol configuration values)", function()
      local proxy_ip = helpers.get_proxy_ip(false)
      local proxy_port = helpers.get_proxy_port(false)

      lazy_setup(start_kong {
        database          = strategy,
        proxy_listen      = proxy_ip .. ":" .. proxy_port .. " proxy_protocol",
        real_ip_header    = "proxy_protocol",
        real_ip_recursive = "on",
        trusted_ips       = "127.0.0.1,172.16.0.1,192.168.0.1",
        nginx_conf        = "spec/fixtures/custom_nginx.template",
        lua_package_path  = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
      })

      lazy_teardown(stop_kong)

      describe("X-Real-IP, X-Forwarded-For and X-Forwarded-Port", function()
        it("should be added if not present in request", function()
          local sock = ngx.socket.tcp()
          local request = "PROXY TCP4 192.168.0.1 " .. helpers.get_proxy_ip(false) .. " 56324 " .. helpers.get_proxy_port(false) .. "\r\n" ..
                          "GET / HTTP/1.1\r\n" ..
                          "Host: headers-inspect.test\r\n" ..
                          "Connection: close\r\n" ..
                          "\r\n"

          assert(sock:connect(helpers.get_proxy_ip(false), helpers.get_proxy_port(false)))
          assert(sock:send(request))

          local response, err = sock:receive "*a"

          assert(response, err)

          local json = string.match(response, "%b{}")

          assert.is_not_nil(json)

          local headers = cjson.decode(json).headers

          assert.equal("192.168.0.1", headers["x-real-ip"])
          assert.equal("192.168.0.1", headers["x-forwarded-for"])
          assert.equal(helpers.get_proxy_port(false), tonumber(headers["x-forwarded-port"]))
          assert(sock:close())
        end)

        it("should be changed according to rules if present in request", function()
          local sock = ngx.socket.tcp()
          local request = "PROXY TCP4 192.168.0.1 " .. helpers.get_proxy_ip(false) .. " 56324 " .. helpers.get_proxy_port(false) .. "\r\n" ..
                          "GET / HTTP/1.1\r\n" ..
                          "Host: headers-inspect.test\r\n" ..
                          "Connection: close\r\n" ..
                          "X-Real-IP: 10.0.0.2\r\n" ..
                          "X-Forwarded-For: 10.0.0.1, 127.0.0.2, 10.0.0.1, 192.168.0.1, 172.16.0.1\r\n" ..
                          "\r\n"

          assert(sock:connect(helpers.get_proxy_ip(false), helpers.get_proxy_port(false)))
          assert(sock:send(request))

          local response, err = sock:receive "*a"

          assert(response, err)

          local json = string.match(response, "%b{}")

          assert.is_not_nil(json)

          local headers = cjson.decode(json).headers

          assert.equal("192.168.0.1", headers["x-real-ip"])
          assert.equal("10.0.0.1, 127.0.0.2, 10.0.0.1, 192.168.0.1, 172.16.0.1, 127.0.0.1", headers["x-forwarded-for"])
          assert(sock:close())
        end)
      end)

      describe("X-Forwarded-Port", function()
        it("should be forwarded even if proxy protocol and X-Forwarded-For header has a port in it", function()
          local sock = ngx.socket.tcp()
          local request = "PROXY TCP4 192.168.0.1 " .. helpers.get_proxy_ip(false) .. " 56324 " .. helpers.get_proxy_port(false) .. "\r\n" ..
                          "GET / HTTP/1.1\r\n" ..
                          "Host: headers-inspect.test\r\n" ..
                          "Connection: close\r\n" ..
                          "X-Real-IP: 10.0.0.2\r\n" ..
                          "X-Forwarded-For: 127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18\r\n" ..
                          "X-Forwarded-Port: 14\r\n" ..
                          "\r\n"

          assert(sock:connect(helpers.get_proxy_ip(false), helpers.get_proxy_port(false)))
          assert(sock:send(request))

          local response, err = sock:receive "*a"

          assert(response, err)

          local json = string.match(response, "%b{}")

          assert.is_not_nil(json)

          local headers = cjson.decode(json).headers

          assert.equal("192.168.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18, 127.0.0.1", headers["x-forwarded-for"])
          assert.equal(14, tonumber(headers["x-forwarded-port"]))
          assert(sock:close())
        end)
      end)
    end)

    describe("(using non-trusted proxy protocol configuration values)", function()
      local proxy_ip = helpers.get_proxy_ip(false)
      local proxy_port = helpers.get_proxy_port(false)

      lazy_setup(start_kong {
        database          = strategy,
        proxy_listen      = "0.0.0.0:" .. proxy_port .. " proxy_protocol",
        real_ip_header    = "proxy_protocol",
        real_ip_recursive = "on",
        trusted_ips       = "10.0.0.1,172.16.0.1,192.168.0.1",
        nginx_conf        = "spec/fixtures/custom_nginx.template",
        lua_package_path  = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
      })

      lazy_teardown(stop_kong)

      describe("X-Real-IP, X-Forwarded-For and X-Forwarded-Port", function()
        it("should be added if not present in request", function()
          local sock = ngx.socket.tcp()
          local request = "PROXY TCP4 192.168.0.1 " .. proxy_ip .. " 56324 " .. proxy_port .. "\r\n" ..
                          "GET / HTTP/1.1\r\n" ..
                          "Host: headers-inspect.test\r\n" ..
                          "Connection: close\r\n" ..
                          "\r\n"

          assert(sock:connect(proxy_ip, tonumber(proxy_port)))
          assert(sock:send(request))

          local response, err = sock:receive "*a"

          assert(response, err)

          local json = string.match(response, "%b{}")

          assert.is_not_nil(json)

          local headers = cjson.decode(json).headers

          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1", headers["x-forwarded-for"])
          assert.equal(proxy_port, tonumber(headers["x-forwarded-port"]))
          assert(sock:close())
        end)

        it("should be changed according to rules if present in request", function()
          local sock = ngx.socket.tcp()
          local request = "PROXY TCP4 192.168.0.1 " .. proxy_ip .. " 56324 " .. proxy_port .. "\r\n" ..
                          "GET / HTTP/1.1\r\n" ..
                          "Host: headers-inspect.test\r\n" ..
                          "Connection: close\r\n" ..
                          "X-Real-IP: 10.0.0.2\r\n" ..
                          "X-Forwarded-For: 10.0.0.1, 127.0.0.2, 10.0.0.1, 192.168.0.1, 172.16.0.1\r\n" ..
                          "\r\n"

          assert(sock:connect(proxy_ip, proxy_port))
          assert(sock:send(request))

          local response, err = sock:receive "*a"

          assert(response, err)

          local json = string.match(response, "%b{}")

          assert.is_not_nil(json)

          local headers = cjson.decode(json).headers

          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("10.0.0.1, 127.0.0.2, 10.0.0.1, 192.168.0.1, 172.16.0.1, 127.0.0.1", headers["x-forwarded-for"])
          assert(sock:close())
        end)
      end)

      describe("X-Forwarded-Port", function()
        it("should be replaced even if proxy protocol, X-Forwarded-Port and X-Forwarded-For headers have a port in it", function()
          local sock = ngx.socket.tcp()
          local request = "PROXY TCP4 192.168.0.1 " .. proxy_ip .. " 56324 " .. proxy_port .. "\r\n" ..
                          "GET / HTTP/1.1\r\n" ..
                          "Host: headers-inspect.test\r\n" ..
                          "Connection: close\r\n" ..
                          "X-Real-IP: 10.0.0.2\r\n" ..
                          "X-Forwarded-For: 127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18\r\n" ..
                          "X-Forwarded-Port: 14\r\n" ..
                          "\r\n"

          assert(sock:connect(proxy_ip, tonumber(proxy_port)))
          assert(sock:send(request))

          local response, err = sock:receive "*a"

          assert(response, err)

          local json = string.match(response, "%b{}")

          assert.is_not_nil(json)

          local headers = cjson.decode(json).headers

          assert.equal("127.0.0.1", headers["x-real-ip"])
          assert.equal("127.0.0.1:14, 10.0.0.1:15, 192.168.0.1:16, 127.0.0.1:17, 172.16.0.1:18, 127.0.0.1", headers["x-forwarded-for"])
          assert.equal(proxy_port, tonumber(headers["x-forwarded-port"]))
          assert(sock:close())
        end)
      end)
    end)

    describe("(using port maps configuration)", function()
      local proxy_port = helpers.get_proxy_port(false)

      lazy_setup(start_kong {
        database         = strategy,
        nginx_conf       = "spec/fixtures/custom_nginx.template",
        lua_package_path = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua",
        port_maps        =  "80:" .. proxy_port,
      })

      lazy_teardown(stop_kong)

      describe("X-Forwarded-Port", function()
        it("should be added if not present in request", function()
          local headers = request_headers {
            ["Host"] = "headers-inspect.test",
          }

          assert.equal(80, tonumber(headers["x-forwarded-port"]))
        end)

        it("should be replaced if present in request", function()
          local headers = request_headers {
            ["Host"]             = "headers-inspect.test",
            ["X-Forwarded-Port"] = "81",
          }

          assert.equal(80, tonumber(headers["x-forwarded-port"]))
        end)
      end)
    end)
  end)
end
