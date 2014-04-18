express = require 'express'
path    = require 'path'
redis   = require 'redis'
request = require 'request'
uuid    = require 'uuid'

github    = require './lib/github'
routes    = require './routes'
Stopwatch = require './lib/Stopwatch'

config =
  port: process.env.PORT
  url: process.env.URL || ('http://localhost:' + process.env.PORT)
  cookieSecret: process.env.COOKIE_SECRET
  github:
    client_id: process.env.GH_CLIENT_ID
    client_secret: process.env.GH_CLIENT_SECRET
  redis:
    host: process.env.REDIS_HOST
    port: process.env.REDIS_PORT != null && parseInt(process.env.REDIS_PORT, 10)
    database: process.env.REDIS_DB != null && parseInt(process.env.REDIS_DB, 10)
    password: process.env.REDIS_PASSWORD

app = express()

redisClient = redis.createClient config.redis.port, config.redis.host

githubClient = github
  client_id: config.github.client_id
  client_secret: config.github.client_secret
  redis: redisClient

#all environments
app.set 'port', config.port
app.set 'views', __dirname + '/views'
app.set 'view engine', 'ejs'

app.use express.cookieParser(config.cookieSecret)
app.use express.cookieSession()
app.use express.favicon()
app.use express.bodyParser()
app.use express.methodOverride()
app.use express.static(path.join(__dirname, 'public'))
app.use express.errorHandler()

app.request.github = githubClient
app.request.redis = redisClient
app.request.customConfig = config

app.use routes.loadSecureSession

app.get '/',           routes.index
app.get '/repos/:org', routes.organisationRepos

app.get '/g/logout',   routes.logout
app.get '/g/login',    routes.startLogin
app.get '/g/tokenize', routes.completeLogin

startup = new Stopwatch 'Startup'

redisClient.select config.redis.database, ->
  if config.redis.password
    redisClient.auth config.redis.password, (err)->
      if err
        console.error 'Authentication to redis failed: ' + err.message
        process.exit()

redisClient.on 'ready', ->
  startup.next 'Redis is ready'
  app.listen config.port, ->
    startup.next 'isitfixedyet server is listening on http://0.0.0.0:' + config.port + '/'

redisClient.on 'error', (error)->
  console.error 'Redis error: ' + error.message
  process.exit()
