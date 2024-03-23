os.setlocale('') -- set native locale

local Promise = require('jls.lang.Promise')
local logger = require('jls.lang.logger')
local system = require('jls.lang.system')
local event = require('jls.lang.event')
local tables = require('jls.util.tables')
local json = require('jls.util.json')
local HttpClient = require('jls.net.http.HttpClient')
local RestHttpHandler = require('jls.net.http.handler.RestHttpHandler')
local ResourceHttpHandler = require('jls.net.http.handler.ResourceHttpHandler')
local TableHttpHandler = require('jls.net.http.handler.TableHttpHandler')
local Url = require('jls.net.Url')
local xml = require("jls.util.xml")
local dns = require('jls.net.dns')
local UdpSocket = require('jls.net.UdpSocket')

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
      discovery = {
        title = 'Enable discovery',
        type = 'boolean',
        default = false,
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
        enum = {'get', 'set', 'list'},
      },
      node = {
        title = 'The API name to use',
        type = 'string',
        default = 'netRemote.sys.power',
      },
      maxItems = {
        title = 'The list maximum number of items',
        type = 'integer',
        default = 10,
        minimum = 0,
        maximum = 1000,
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

local function getValue(xe)
  local xv = xe[1]
  local v = xv[1]
  if v ~= nil then
    local p = parserMap[xv.name]
    if p then
      return p(v)
    end
  end
end

local function formatApiResponse(xr)
  if xr.name == 'fsapiResponse' then
    local r = {}
    for _, xe in ipairs(xr) do
      if xe.name == 'status' then
        r.status = xe[1]
        r.success = r.status == 'FS_OK'
      elseif xe.name == 'value' then
        r.value = getValue(xe)
      elseif xe.name == 'node' or xe.name == 'sessionId' then
        r[xe.name] = xe[1]
      elseif xe.name == 'item' then
        local item = {}
        for _, xf in ipairs(xe) do
          if xf.name == 'field' and xf.attr.name then
            item[xf.attr.name] = getValue(xf)
          end
        end
        if next(item) then
          item.key = xe.attr.key
          if not r.items then
            r.items = {}
          end
          table.insert(r.items, item)
        end
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
  logger:finer('Body response is "%s"', body)
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
  local status = response:getStatusCode()
  return response:text():next(function(text)
    logger:fine('response is "%s"', response)
    if status ~= 200 then
      return Promise.reject(response)
    end
    return text
  end)
end

local function asFailure(exchange, e)
  local status = 500
  local r = {
    status = 'Unknown',
    success = false,
  }
  if e and e.getStatusCode then
    local reponseStatus, responseReason = e:getStatusCode()
    status = 502
    r.status = 'Communication failure'
    r.reponseStatus = reponseStatus
    r.responseReason = responseReason
  end
  exchange:getResponse():setContentType('application/json')
  exchange:setResponseStatusCode(status, 'Failure', json.stringify(r))
  return false
end

local function askMDNS(qName, qType, callback, timeout)
  local mdnsAddress = '224.0.0.251'
  local mdnsPort = 5353
  local id = math.random(0xfff)
  local function onReceived(err, data, addr)
    if data then
      local _, message = pcall(dns.decodeMessage, data)
      if message.id == id then
        for _, rr in ipairs(message.answers) do
          if rr.value then
            logger:fine('received answer from %t value %t', addr, rr.value)
            callback(nil, {value = rr.value, ip = addr.ip})
          end
        end
      end
    elseif err then
      logger:warn('receive error %s', err)
    else
      logger:fine('receive no data')
    end
  end
  logger:fine('Sending mDNS question name "%s" type %s with id %d', qName, qType, id)
  local message = {
    id = id,
    questions = {{
      name = qName,
      type = qType,
      class = dns.CLASSES.IN,
      unicastResponse = true,
    }}
  }
  local data = dns.encodeMessage(message)
  logger:fine('sending data: (%l) %x', data, data)
  local addresses = dns.getInterfaceAddresses()
  logger:fine('Interface addresses: %t', addresses)
  local senders = {}
  local count = 0
  for _, address in ipairs(addresses) do
    local sender = UdpSocket:new()
    sender:bind(address, 0)
    logger:fine('sender bound to %s', address)
    sender:receiveStart(onReceived)
    sender:send(data, mdnsAddress, mdnsPort):next(function()
      table.insert(senders, sender)
    end, function(reason)
      logger:warn('error while sending %s', reason)
      sender:close()
    end):finally(function()
      count = count + 1
      if count == #addresses then
        if #senders > 0 then
          event:setTimeout(function()
            for _, s in ipairs(senders) do
              s:close()
            end
            callback()
          end, timeout or 3000)
        else
          callback('unable to send')
        end
      end
    end)
  end
end

local function lookupUrls(qName, callback, timeout)
  local maxtime = system.currentTimeMillis() + timeout - 500
  askMDNS(qName, dns.TYPES.PTR, function(err, ptr)
    local time = system.currentTimeMillis()
    if ptr and time < maxtime then
      askMDNS(ptr.value, dns.TYPES.SRV, function(_, srv)
        if srv and srv.value.port then
          local url = string.format('http://%s:%s', srv.ip, srv.value.port)
          callback(nil, url)
        end
      end, maxtime - time)
    else
      callback(err)
    end
  end, timeout)
end


-- Application local variables

local pin = options.pin
local sid
local client = HttpClient:new({
  url = options.url
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
  if client then
    client:close()
  end
end

local function changeUrl(url)
  terminate()
  client = HttpClient:new({
    url = url
  })
end

if options.action then
  local function printXml(text)
    print('body text', text)
    local status, xr = pcall(xml.decode, text)
    print('XML response', status, tables.stringify(xr, '  '))
  end
  if options.action == 'get' then
    client:fetch(formatApiPath('GET/'..options.node, {
      pin = pin
    })):next(getText):next(function(text)
      printXml(text)
      return text
    end):next(decodeApiResponse):next(function(value)
      print('response', json.stringify(value, '  '))
    end):next(terminate, print)
  elseif options.action == 'set' then
    client:fetch(formatApiPath('SET/'..options.node, {
      value = options.value,
      pin = pin
    })):next(getText):next(function(text)
      printXml(text)
      return text
    end):next(decodeApiResponse):next(function(value)
      print('response', json.stringify(value, '  '))
    end):next(terminate, print)
  elseif options.action == 'list' then
    client:fetch(formatApiPath('LIST_GET_NEXT/'..options.node, {
      maxItems = options.maxItems,
      pin = pin
    })):next(getText):next(function(text)
      printXml(text)
      return text
    end):next(decodeApiResponse):next(function(value)
      print('response', json.stringify(value, '  '))
    end):next(terminate, print)
  else
    print('unknown action', options.action)
  end
  event:loop()
  os.exit()
end

if options.discovery then
  local first = true
  lookupUrls('_undok._tcp.local', function(_, url)
    if url and first then
      first = false
      changeUrl(url)
    end
  end, 3000)
end

-- HTTP contexts used by the web application
local httpContexts = {
  -- HTTP resources
  ['/(.*)'] = ResourceHttpHandler:new('htdocs/', 'app.html'),
  -- Context to retrieve the configuration
  ['/config/(.*)'] = TableHttpHandler:new(options, nil, true),
  -- Assets HTTP resources directory or ZIP file
  ['/(assets/.*)'] = ResourceHttpHandler:new(),
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
        ['list(node)?method=GET'] = function(_, node)
          return client:fetch(formatApiPath('LIST_GET_NEXT/'..node..'/-1', {
            maxItems = 1000,
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
      ['get-multiple(requestJson)?method=POST'] = function(exchange, requestJson)
        local query = string.format('pin=%s&node=%s', pin, table.concat(requestJson, '&node='))
        logger:info('query is "%s"', query)
        return client:fetch(formatApiPath('GET_MULTIPLE', query)):next(getText):next(decodeApiResponse):catch(function(e) return asFailure(exchange, e) end)
      end,
    },
    ['discover-first?method=POST'] = function()
      return Promise:new(function(resolve, reject)
        lookupUrls('_undok._tcp.local', function(err, url)
          if err then
            reject(err)
          elseif url then
            resolve(url)
          else
            reject('timeout')
          end
        end, 3000)
      end)
    end,
    ['discover?method=POST'] = function()
      local urls = {}
      return Promise:new(function(resolve, reject)
        lookupUrls('_undok._tcp.local', function(err, url)
          if err then
            reject(err)
          elseif url then
            table.insert(urls, url)
          else
            resolve(urls)
          end
        end, 3000)
      end)
    end,
    ['url?method=GET'] = function()
      return client:getUrl()
    end,
    ['url?method=POST'] = function(exchange)
      local request = exchange:getRequest()
      changeUrl(request:getBody())
    end,
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
