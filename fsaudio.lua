os.setlocale('') -- set native locale

local Promise = require('jls.lang.Promise')
local logger = require('jls.lang.logger')
local event = require('jls.lang.event')
local File = require('jls.io.File')
local tables = require('jls.util.tables')
local json = require('jls.util.json')
local HttpClient = require('jls.net.http.HttpClient')
local FileHttpHandler = require('jls.net.http.handler.FileHttpHandler')
local RestHttpHandler = require('jls.net.http.handler.RestHttpHandler')
local ZipFileHttpHandler = require('jls.net.http.handler.ZipFileHttpHandler')
local TableHttpHandler = require('jls.net.http.handler.TableHttpHandler')
local Url = require('jls.net.Url')
local xml = require("jls.util.xml")

-- Extracts configuration from command line arguments
local options = tables.createArgumentTable(arg, {
  helpPath = 'help',
  configPath = 'config',
  emptyPath = 'config',
  schema = {
    title = 'FS Audio',
    type = 'object',
    additionalProperties = false,
    properties = {
      config = {
        title = 'The configuration file',
        type = 'string',
        default = 'fsaudio.json',
      },
      loglevel = {
        title = 'The log level',
        type = 'string',
        default = 'warn',
        enum = {'error', 'warn', 'info', 'config', 'fine', 'finer', 'finest', 'debug', 'all'},
      },
      url = {
        title = 'The FS device URL',
        type = 'string',
        pattern = '^https?://.+$',
      },
      pin = {
        title = 'The FS device PIN code',
        type = 'string',
        pattern = '^%d+$',
        default = '1234',
      },
      action = {
        title = 'The command line action',
        type = 'string',
        enum = {'get', 'set'},
      },
      node = {
        title = 'The API name to use',
        type = 'string',
        default = 'netRemote.sys.power',
      },
      value = {
        title = 'The value to set',
        type = 'string',
        default = '0',
      },
      webview = {
        type = 'object',
        additionalProperties = false,
        properties = {
          debug = {
            title = 'Enable WebView debug mode',
            type = 'boolean',
            default = false,
          },
          disable = {
            title = 'Disable WebView',
            type = 'boolean',
            default = false,
          },
          address = {
            title = 'The binding address',
            type = 'string',
            default = '::'
          },
          port = {
            title = 'WebView HTTP server port',
            type = 'integer',
            default = 0,
            minimum = 0,
            maximum = 65535,
          },
          width = {
            title = 'The WebView width',
            type = 'integer',
            default = 400,
            minimum = 320,
            maximum = 7680,
          },
          height = {
            title = 'The WebView height',
            type = 'integer',
            default = 400,
            minimum = 240,
            maximum = 4320,
          },
        }
      },
    },
  },
  aliases = {
    h = 'help',
    u = 'url',
    ll = 'loglevel',
    wd = 'webview.debug',
    r = 'webview.disable',
  },
});

-- Apply configured log level
logger:setLevel(options.loglevel)

local parserMap = {
  u8 = tonumber,
  u16 = tonumber,
  u32 = tonumber,
  s8 = tonumber,
  s16 = tonumber,
  s32 = tonumber,
  c8_array = tostring,
}

local function formatApiResponse(xr)
  if xr.name == 'fsapiResponse' then
    local r = {}
    for _, xe in ipairs(xr) do
      if xe.name == 'status' then
        r.status = xe[1]
        r.success = r.status == 'FS_OK'
      elseif xe.name == 'value' then
        local xv = xe[1]
        local v = xv[1]
        if v ~= nil then
          local p = parserMap[xv.name]
          if p then
            r.value = p(v)
          end
        end
      elseif xe.name == 'node' or xe.name == 'sessionId' then
        r[xe.name] = xe[1]
      end
    end
    return r
  elseif xr.name == 'fsapiGetMultipleResponse' then
    local l = {}
    for _, xe in ipairs(xr) do
      local r = formatApiResponse(xe)
      if r then
        table.insert(l, r)
      else
        return
      end
    end
    return l
  end
end

local function decodeApiResponse(body)
  local xr = xml.decode(body)
  return formatApiResponse(xr)
end

local function formatApiPath(path, query)
  if type(query) == 'table' then
    query = Url.mapToQuery(query)
  end
  return string.format('/fsapi/%s?%s', path, query)
end

local function getText(response)
  local status, reason = response:getStatusCode()
  return response:text():next(function(text)
    logger:fine('response is "%s"', response)
    if status ~= 200 then
      return Promise.reject(reason)
    end
    return text
  end)
end

-- Application local variables

local scriptFile = File:new(arg[0]):getAbsoluteFile()
local scriptDir = scriptFile:getParentFile()
local assetsDir = File:new(scriptDir, 'assets')
local assetsZip = File:new(scriptDir, 'assets.zip')

local deviceUrl = options.url
if not deviceUrl then
  -- discover or indicate missing URL
end

local pin = options.pin
local sid

local client = HttpClient:new({
  url = deviceUrl
})

local function createSession()
  return client:fetch(formatApiPath('CREATE_SESSION', {
    pin = pin
  })):next(getText):next(decodeApiResponse):next(function(r)
    sid = r.sessionId
    logger:info('sid is "%s"', sid)
    return sid
  end, function(reason)
    logger:warn('unable to create session due to "%s"', reason)
  end)
end

local function terminate()
  client:close()
end

if options.action then
  if options.action == 'get' then
    client:fetch(formatApiPath('GET/'..options.node, {
      pin = pin
    })):next(getText):next(function(text)
      print('body text', text)
      return text
    end):next(decodeApiResponse):next(function(value)
      print('response', json.stringify(value, '  '))
    end):next(terminate, print)
  end
  event:loop()
  os.exit()
end

if deviceUrl then
  --createSession()
end

-- HTTP contexts used by the web application
local httpContexts = {
  -- HTTP resources
  ['/(.*)'] = FileHttpHandler:new(File:new(scriptDir, 'htdocs'), nil, 'app.html'),
  -- Context to retrieve the configuration
  ['/config/(.*)'] = TableHttpHandler:new(options, nil, true),
  -- Assets HTTP resources directory or ZIP file
  ['/assets/(.*)'] = assetsZip:isFile() and not assetsDir:isDirectory() and ZipFileHttpHandler:new(assetsZip) or FileHttpHandler:new(assetsDir),
  -- Context for the application REST API
  ['/rest/(.*)'] = RestHttpHandler:new({
    fsapi = {
      ['{node}'] = {
        ['get(node)?method=GET'] = function(_, node)
          logger:info('path is "%s"', node)
          return client:fetch(formatApiPath('GET/'..node, {
            pin = pin
          })):next(getText):next(decodeApiResponse)
        end,
        ['set(node, requestJson)?method=POST'] = function(_, node, requestJson)
          return client:fetch(formatApiPath('SET/'..node, {
            pin = pin,
            value = requestJson
          })):next(getText):next(decodeApiResponse)
        end,
      },
      ['get-multiple(requestJson)?method=POST'] = function(_, requestJson)
        local query = string.format('pin=%s&node=%s', pin, table.concat(requestJson, '&node='))
        logger:info('query is "%s"', query)
        return client:fetch(formatApiPath('GET_MULTIPLE', query)):next(getText):next(decodeApiResponse)
      end,
    },
  }),
}

-- Start the application as an HTTP server or a WebView
if options.webview.disable then
  local httpServer = require('jls.net.http.HttpServer'):new()
  httpServer:bind(options.webview.address, options.webview.port):next(function()
    httpServer:addContexts(httpContexts)
    if options.webview.port == 0 then
      print('FSAudio HTTP Server available at http://localhost:'..tostring(select(2, httpServer:getAddress())))
    end
    httpServer:createContext('/admin/(.*)', RestHttpHandler:new({
      ['stop?method=POST'] = function(exchange)
        logger:info('Closing HTTP server')
        httpServer:close()
        terminate()
        --HttpExchange.ok(exchange, 'Closing')
      end,
    }))
  end, function(err)
    logger:warn('Cannot bind HTTP server due to '..tostring(err))
    os.exit(1)
  end)
else
  local url = 'http://localhost:'..tostring(options.webview.port)..'/'
  if options.extension then
    url = url..'extensions/'..options.extension..'/'
  end
  require('jls.util.WebView').open(url, {
    title = 'FS Audio',
    resizable = true,
    bind = true,
    width = options.webview.width,
    height = options.webview.height,
    debug = options.webview.debug,
    contexts = httpContexts,
  }):next(function(webview)
    local httpServer = webview:getHttpServer()
    logger:info('FSAudio HTTP Server available at http://localhost:%s/', (select(2, httpServer:getAddress())))
    return webview:getThread():ended()
  end):next(function()
    logger:info('WebView closed')
  end, function(reason)
    logger:warn('Cannot open webview due to '..tostring(reason))
  end):finally(function()
    terminate()
  end)
end

-- Process events until the end
event:loop()
