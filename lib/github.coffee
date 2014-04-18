request    = require 'request'
linkheader = require('parse-link-header')
parser     = require 'uri-template'
uuid       = require 'uuid'

Stopwatch = require './stopwatch'

errorObjectFromBody = (body)->
  if body?.error_description? || body?.error?
    err = new Error body.error_description || body.error
    err.identifier = body.error
    err.uri = body.error_uri
    err

class GitHubAPI

  constructor: (options)->
    throw Error("Invalid Github client ID") unless options.client_id?.length > 0
    throw Error("Invalid Github client secret") unless options.client_secret?.length > 0
    throw Error("You must provide a redis client") unless options.redis?

    @redis = options.redis
    @client_id = options.client_id
    @client_secret = options.client_secret
    @_github = options.baseURL || 'https://api.github.com'
    @_auth = {
      access_token: 'https://github.com/login/oauth/access_token'
    };
    @_useragent = options.useragent || 'thepatrick'
    @_apiURLsIsFetching = null

  oauthLoginURL: (redirect_uri, scope, state)->
    'https://github.com/login/oauth/authorize?' +
    'client_id=' + encodeURIComponent(@client_id) +
    '&redirect_uri=' + encodeURIComponent(redirect_uri) +
    '&scope=' + encodeURIComponent(scope) +
    '&state=' + (state or uuid.v4())

  request: (options, callback)->
    _options =
      headers:
        'User-Agent': @_useragent

    requestTimer = new Stopwatch 'Request ' + (options.method || 'GET') + ' ' + options.url

    for own key, value of options
      switch key
        when 'token'
          _options.headers.Authorization = 'token ' + options[key]
        when 'headers'
          for own headerKey, headerValue of value
            _options.headers[headerKey] = headerValue
        else
          _options[key] = value

    request _options, (err, res, body)->
      remaining = if res?.headers?['x-ratelimit-remaining']
        " (Rate limit remaining: #{res.headers['x-ratelimit-remaining']})"
      else
        ""
      if res?.headers?.link
        res.links = linkheader res.headers.link
      if err
        requestTimer.next "Error: " + err.message
        callback err
      else if res.statusCode > 300 && res.statusCode != 304
        _err = errorObjectFromBody(body) ||
          new Error 'Unable to request ' + _options.url + ': ' + res.statusCode        
        _err.statusCode = res.statusCode
        requestTimer.next "Error: " + _err.message + "/" + res.statusCode
        callback _err
      else
        requestTimer.next "OK " + res.statusCode
        callback null, res, body

  conditionalRequest: (key, options, process, callback)->
    
    requestTimer = new Stopwatch 'conditionalRequest ' + key
    redis = @redis

    requestTimer.next 'conditionalRequest starting for ' + key
    @redis.hgetall key, (err, cached)=>
      if err?
        requestTimer.next 'hgetall error'
        callback err
      else
        requestTimer.next 'hgetall ok'
        if cached?.etag?
          options.headers || = {}
          options.headers['If-None-Match'] = cached.etag
        @request options, (err, res, body)=>
          if err?
            requestTimer.next key + " returned error"
            callback err
          else if res.statusCode == 304
            requestTimer.next key + " using cache"
            callback null, JSON.parse cached.value
          else
            requestTimer.next key + " requested"
            process res, body, (error, value)=>
              if error
                requestTimer.next key + " processed, with error"
                callback error
              else
                requestTimer.next key + " processed"
                callback null, value
                @redis.hmset key,
                  etag: res.headers.etag,
                  value: JSON.stringify value
                  (error)->
                    if error
                      console.error "Unable to cache", key, error.message
                      requestTimer.next key + " error caching response"
                    else
                      requestTimer.next key + " cached"

  conditionalRequestSaveBody: (res, body, store)->
    store null, body

  _apiURLsIsFetching: false

  _githubURL: (path)->
    @_github + path

  apiURLs: (callback)->
    timer = new Stopwatch 'apiURLs'
    if @_apiURLs
      timer.next 'apiurls using cache'
      callback null, @_apiURLs
    else if Array.isArray @_apiURLsIsFetching
      timer.next 'apiurls add to callback cache'
      @_apiURLsIsFetching.push callback
    else
      timer.next 'fetching'
      @_apiURLsIsFetching = [callback]
      @conditionalRequest 'github-api-urls',
        url: @_githubURL '/'
        json: true
        @conditionalRequestSaveBody
        (error, apiURLs)=>
          if apiURLs
            @_apiURLs = {}
            for key, value of apiURLs
              try
                @_apiURLs[key] = parser.parse value 
              catch parseError
                console.error 'Unable to parse API URL', key, value, parseError.message

          callbacks = @_apiURLsIsFetching
          @_apiURLsIsFetching = null
          timer.next 'apiurls callback count ' + callbacks.length
          callbacks.forEach (callback)=>
            callback? error, @_apiURLs

  getCurrentUser: (token, callback)->
    unless token?.length > 0
      return callback Error 'Token is invalid'

    @apiURLs (error, apiURLs)=>
      return callback error if error?
 
      @conditionalRequest 'token-' + token,
        uri: apiURLs.current_user_url.expand {}
        token: token,
        json: true
        @conditionalRequestSaveBody
        callback

  getUsersOrgnizations: (token, user, callback)->
    @conditionalRequest 'user-' + user.login,
      url: user.organizations_url,
      token: token,
      json: true
      (res, body, store)->
        store null, body.map (org)->
          login: org.login,
          repos_url: org.repos_url,
          avatar_url: org.avatar_url
      callback

  getAccessToken: (code, callback)->
    @request
      url: @_auth.access_token
      method: 'POST'
      headers:
        Accept: 'application/json'
      form:
          client_id: @client_id
          client_secret: @client_secret
          code: code
      (error, response, body)->
        if err?
          callback err
        else
          try
            parsed = JSON.parse body
            error = errorObjectFromBody parsed
          catch e
            console.error "Error response from github to get access token",
              e.message, response.statusCode, body
            error = Error "Unexpected error parsing response from Github"
          
          callback error, parsed 
  

#   _getReposForThing: (token, thing, callback)->
# var getReposForThing = function(token, thing, callback) {
#   request({
#     url: thing.repos_url + "?per_page=100",
#     headers: {
#       'User-Agent': 'thepatrick',
#       Authorization: 'token ' + token
#     },
#     json: true
#   }, function(err, res, body) {
#     if(err) {
#       callback(err);
#     } else if(res.statusCode > 400) {
#       console.log('Error getting user: ', body, res.statusCode);
#       callback(new Error('Error getting user'));
#     } else {
#       callback(null, body);
#     }
#   });
# };

module.exports = (options)->
  new GitHubAPI options

# tpl.expand({ year: 2006, month: 6, day: 6 });
# // /2006/6/6
# 
# tpl.expand({ year: 2006, month: 6, day: 6, orderBy: 'size' });
# // /2006/6/6?orderBy=size

# tpl.expand({ year: 2006, month: 6, day: 6, orderBy: 'time', direction: 'asc' });
# // /2006/6/6?orderBy=time&direction=asc

# var queryTpl = parser.parse('/search{?q,*otherParams}');
# queryTpl.expand({ q: 'Bigger office', otherParams: { prefer: "Sterling's office", accept: "Crane's office" }});
# // /search?q=Bigger%20office&prefer=Sterling%27s%20office&accept=Crane%27s%20office
