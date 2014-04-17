isitfixedyet
============

Info to come. The instructions below work. Mostly. Don't blame me when it sets fire to your kitchen and drinks all your expensive alcohol.

Prerequisites
-------------

* node (tested with v0.10.26)
* redis (tested with v2.6.14)
* a github oauth client id and secret

Running it
----------

To start it use a command like this:

```bash
$ npm install
$ PORT=9987 COOKIE_SECRET=... GH_CLIENT_ID=... GH_CLIENT_SECRET=... node app
```

If your redis server isn't on the local machine set REDIS_HOST, if you need a custom port REDIS_PORT and for a database other than 0 set REDIS_DB.

Or deploy to heroku with those things. You'll need redis though.
