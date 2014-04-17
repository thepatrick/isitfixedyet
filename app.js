/*jshint camelcase:false*/

var express = require('express'),
    path = require('path'),
    redis = require('redis'),
    request = require('request'),
    uuid = require('uuid');

var config = {
  port: process.env.PORT,
  cookieSecret: process.env.COOKIE_SECRET,
  github: {
    clientID: process.env.GH_CLIENT_ID,
    secret: process.env.GH_CLIENT_SECRET
  },
  redis: {
    host: process.env.REDIS_HOST,
    port: process.env.REDIS_PORT != null && parseInt(process.env.REDIS_PORT, 10),
    database: process.env.REDIS_DB != null && parseInt(process.env.REDIS_DB, 10),
    password: process.env.REDIS_PASSWORD
  }
};

var app = express(),
    client = redis.createClient(config.redis.port, config.redis.host);

// all environments
app.set('port', config.port);
app.set('views', __dirname + '/views');
app.set('view engine', 'ejs');


app.use(express.cookieParser(config.cookieSecret));
app.use(express.cookieSession());
app.use(express.favicon());
app.use(express.bodyParser());
app.use(express.methodOverride());
app.use(express.static(path.join(__dirname, 'public')));
app.use(express.errorHandler());

var loginUrl = function() {
  return 'https://github.com/login/oauth/authorize?' +
        'client_id=' + encodeURIComponent(config.github.clientID) +
        '&redirect_uri=http://localhost:' + config.port + '/login' +
        '&scope=' + encodeURIComponent('repo,read:org') +
        '&state=' + uuid.v4();
};

var githubRequest = function(options, callback) {
  var _options = {
    headers: {
      'User-Agent': 'thepatrick'
    }
  };
  Object.keys(options).forEach(function(key) {
    if(key === 'token') {
      _options.headers.Authorization = 'token ' + options[key];
    } else if (key === 'headers') {
      Object.keys(options[key]).forEach(function(header) {
        _options.headers[header] = options[key][header];
      });
    } else {
      _options[key] = options[key];
    }
  });
  console.log('Requesting', _options.url || _options.uri);
  request(_options, function(err, res, body) {
    if(err) {
      callback(err);
    } else if(res.statusCode > 300 && res.statusCode !== 304) {
      var _err;
      if(body && (body.error_description || body.error)) {
        _err = new Error(body.error_description || body.error);
        _err.identifier = body.error;
        _err.uri = body.error_uri;
      } else {
        _err = new Error('Unable to request ' + _options.url + ': ' + res.statusCode);
      }
      callback(_err);
    } else {
      console.log('••••••••••••••••••••••••••••');
      console.log('HEADERS', res.headers);
      console.log('••••••••••••••••••••••••••••');
      callback(null, res, body);
    }
  });
};

var conditionalRequest = function(key, options, process, callback) {
  var condStop = new Stopwatch();
  client.hgetall(key, function (err, obj) {
    condStop.next(key + " hgetall");
    if(err) {
      callback(err);
    } else {
      if(obj && obj.etag) {
        if(!options.headers) {
          options.headers = {};
        }
        options.headers['If-None-Match'] = obj.etag;
      }
      githubRequest(options, function(err, res, body) {
        if(err) {
          callback(err);
        } else if(res.statusCode === 304) {
          condStop.next(key + " using cache");
          callback(null, JSON.parse(obj.value));
        } else {
          condStop.next(key + " requested");
          process(res, body, function(error, value) {
            condStop.next(key + " processed");
            if(error) {
              callback(error);
            } else {
              client.hmset(key, {
                etag: res.headers.etag,
                value: JSON.stringify(value)
              }, function(error) {
                condStop.next(key + " cached");
                if(error) {
                  callback(error);
                } else {
                  callback(null, value);
                }
              });
            }
          });
        }
      });
    }
  });
};

var getUser = function(token, callback) {
  conditionalRequest('token-' + token, {
    uri: 'https://api.github.com/user',
    token: token,
    json: true
  }, function(res, body, store) {
    store(null, body);
  }, callback);
};

var getOrganisationsForUser = function(token, user, callback) {
  conditionalRequest('user-' + user.login, {
    url: user.organizations_url,
    token: token,
    json: true
  }, function(res, body, store) {
    store(null, body.map(function(org) {
      return {
        login: org.login,
        repos_url: org.repos_url,
        avatar_url: org.avatar_url
      };
    }));
  }, callback);
};

var getReposForThing = function(token, thing, callback) {
  request({
    url: thing.repos_url + "?per_page=100",
    headers: {
      'User-Agent': 'thepatrick',
      Authorization: 'token ' + token
    },
    json: true
  }, function(err, res, body) {
    if(err) {
      callback(err);
    } else if(res.statusCode > 400) {
      console.log('Error getting user: ', body, res.statusCode);
      callback(new Error('Error getting user'));
    } else {
      callback(null, body);
    }
  });
};

function Stopwatch() {
  var last = Date.now();
  this.next = function(label) {
    var next = Date.now();
    console.log(label, (next - last) + 'ms');
    last = next;
  };
}

app.get('/', function(req, res, next) {
  var timer = new Stopwatch();
  var token = req.session.githubToken;
  if(token) {
    getUser(token, function(err, user) {
      timer.next('got user');
      if(err) {
        next(err);
      } else {
        getOrganisationsForUser(token, user, function(err, orgs) {
          timer.next('gotOrganisationsForUser');
          if(err) {
            next(err);
          } else {
            res.render('index', {
              user: user,
              orgs: orgs
            });

            // var org = orgs.filter(function(org) {
            //   return org.login === 'opentok';
            // })[0];

            // if(!org) {
            //   req.session.githubToken = null;
            //   res.redirect('/');
            //   return;
            // }
            // getReposForThing(token, org, function(err, repos) {
            //   timer.next('gotReposForThing');
            //   if(err) {
            //     next(err);
            //   } else {
            //     console.log('repos', repos);
            //     res.render('index', {
            //       user: user,
            //       repos: repos
            //     });
            //   }
            // });
          }
        });
      }
    });
  } else {
    res.render('login', {
      loginUrl: loginUrl()
    });
  }
});

app.get('/login', function(req, res, next) {
  var code = req.query.code,
      state = req.query.state;

  var form = {
    'client_id': config.github.clientID,
    'client_secret': config.github.secret,
    code: code
  };

  console.log('form', form);

  if(code && code.length > 0 && state && state.length > 0) {
    request({
      url: 'https://github.com/login/oauth/access_token',
      method: 'POST',
      headers: {
        'User-Agent': 'thepatrick',
        Accept: 'application/json'
      },
      form: form
    }, function(err, response, body) {
      if(err) {
        return next(err);
      }
      var parsed;
      try {
        parsed = JSON.parse(body);
      } catch(err) {
        next(err);
        return;
      }
      if(parsed.error) {
        res.render('login', {
          loginUrl: loginUrl(),
          error: parsed
        });
      } else {
        req.session.githubToken = parsed.access_token;
        req.session.githubScope = parsed.scope;
        res.redirect('/');
      }
    });
  } else {
    console.log(code);
    console.log(state);
    next(new Error('Missing callback parameters'));
  }
});

var startup = new Stopwatch();

client.select(config.redis.database, function() {
  if(config.redis.password) {
    client.auth(config.redis.password, function(err) {
      if(err) {
        console.error('Authentication to redis failed: ' + err.message);
        process.exit();
      }
    });
  }
});

client.on('ready', function() {
  startup.next('Redis is ready');
  app.listen(config.port, function(){
    startup.next('Listening...');
    console.log('isitfixedyet server is listening on http://%s:%d/', '0.0.0.0', config.port);
  });
});

client.on('error', function(error) {
  console.error('Redis error: ' + error.message);
  process.exit();
});


// https://api.github.com/ get github urls here!

// var parser = require('uri-template');

// var tpl = parser.parse('/{year}/{month}/{day}{?orderBy,direction}');

// tpl.expand({ year: 2006, month: 6, day: 6 });
// // /2006/6/6
// 
// tpl.expand({ year: 2006, month: 6, day: 6, orderBy: 'size' });
// // /2006/6/6?orderBy=size

// tpl.expand({ year: 2006, month: 6, day: 6, orderBy: 'time', direction: 'asc' });
// // /2006/6/6?orderBy=time&direction=asc

// var queryTpl = parser.parse('/search{?q,*otherParams}');
// queryTpl.expand({ q: 'Bigger office', otherParams: { prefer: "Sterling's office", accept: "Crane's office" }});
// // /search?q=Bigger%20office&prefer=Sterling%27s%20office&accept=Crane%27s%20office

// var parse = require('parse-link-header');

// var linkHeader = 
//   '<https://api.github.com/user/9287/repos?page=3&per_page=100>; rel="next", ' + 
//   '<https://api.github.com/user/9287/repos?page=1&per_page=100>; rel="prev"; pet="cat", ' + 
//   '<https://api.github.com/user/9287/repos?page=5&per_page=100>; rel="last"'

// var parsed = parse(linkHeader);

// { next:
//    { page: '3',
//      per_page: '100',
//      rel: 'next',
//      url: 'https://api.github.com/user/9287/repos?page=3&per_page=100' },
//   prev:
//    { page: '1',
//      per_page: '100',
//      rel: 'prev',
//      pet: 'cat',
//      url: ' https://api.github.com/user/9287/repos?page=1&per_page=100' },
//   last:
//    { page: '5',
//      per_page: '100',
//      rel: 'last',
//      url: ' https://api.github.com/user/9287/repos?page=5&per_page=100' } }
