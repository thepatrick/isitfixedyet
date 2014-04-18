Stopwatch = require '../lib/stopwatch'
uuid       = require 'uuid'

exports.loadSecureSession = (req, res, next)->
  if req.session.user
    req.redis.hgetall 'session-' + req.session.user, (err, session)->
      req.secureSession = session
      next()  
  else
    next()

exports.index = (req, res, next)->
  timer = new Stopwatch 'GET /'
  if req.secureSession?.token?
    timer.next "got token"
    req.github.getCurrentUser req.secureSession.token, (err, user)->
      timer.next 'got user'
      return next err if err?
      req.github.getUsersOrgnizations req.secureSession.token, user, (err, orgs)->
        timer.next 'gotOrganisationsForUser'
        return next err if err?
        res.render 'index', user: user, orgs: orgs
  else
    res.render 'login'

exports.logout = (req, res)->
  if req.session.user?
    req.redis.del 'session-' + req.session.user, (err)->
      if err?
        console.error 'Unable to delete session', req.session.user, err.message || err
      req.session.user = null
      res.redirect '/'
  else
    res.redirect '/'

exports.startLogin = (req, res, next)->
  loginURL = req.github.oauthLoginURL req.customConfig.url + '/g/tokenize', 'repo,read:org'
  res.redirect loginURL

exports.completeLogin = (req, res, next)->
  code = req.query.code
  if code?.length > 0
    req.github.getAccessToken code, (err, token)->
      if err?
        res.render 'login', error: err
      else
        user = uuid.v4()
        req.redis.hset 'session-' + user, 'token', token.access_token, (err)->
          if err
            res.render 'login', error: new Error "Unable to create session, please try again"
          else
            req.session.user = user
            res.redirect '/'
  else
    next new Error 'Missing callback parameters'

exports.organisationRepos = (req, res, next)->
  orgId = req.params.org
  timer = new Stopwatch 'GET /repos/' + orgId
  if req.secureSession?.token?
    timer.next "got token"
    req.github.getCurrentUser req.secureSession.token, (err, user)->
      timer.next 'got user'
      return next err if err?
      req.github.getUsersOrgnizations req.secureSession.token, user, (err, orgs)->
        timer.next 'gotOrganisationsForUser'
        return next err if err?
        res.render 'index', user: user, orgs: orgs
  else
    res.redirect '/'
