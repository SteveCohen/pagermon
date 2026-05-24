# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

PagerMon is an API-driven client/server framework for parsing and displaying pager messages decoded by `multimon-ng` (POCSAG / FLEX / EAS). The repo has two independent Node apps with separate `package.json`/`node_modules`:

- `server/` — Express backend + AngularJS 1.x / Bootstrap frontend (server-rendered EJS shell hosting an Angular SPA).
- `client/` — standalone Node scripts that read piped `multimon-ng` output and POST messages to the server API.

There is **no root `package.json`** — always `cd` into `server/` or `client/` first.

## Commands (run from `server/`)

```bash
npm install            # install deps (Node 12.x; CI uses 12.16.x)
node app.js            # start the server (default port 3000, login admin/changeme)
npm test               # mocha + nyc, lcov coverage, 60s timeout
npm run test-text      # same tests, text coverage — this is what CI runs
npm run lint           # eslint (wesbos config + prettier)
npm run lint:fix       # eslint --fix

# Run a single test file:
npx mocha --exit -t 60000 test/routes.api.messages.test.js
# Filter by name:
npx mocha --exit -t 60000 --grep "should POST new message"
```

> The `npm start` script (`node ./bin/www`) is **dead** — `server/bin/` is gitignored and does not exist. The real entry point is `app.js`, run directly or via `pm2 start process.json` (copy `process-default.json` → `process.json` first). `app.js` both exports the Express app and calls `server.listen()`.

Tests force `NODE_ENV=test`, which redirects the DB to `./test/messages.db` and silences all logging. Each test does `migrate.rollback → migrate.latest → seed.run` (seed: `knex/seeds/test_data.js`), so tests are self-contained against a throwaway SQLite DB.

The client has no real tests; run it via the `reader.sh` pipeline (`rtl_fm | multimon-ng | node reader.js`).

## Configuration model

Configuration is the source of truth for almost all behavior and is read through **nconf** from `config/config.json` (auto-created from `config/default.json` on first run; gitignored). This covers DB type/credentials, auth users + API keys, enabled plugins, dedupe and display settings, theme, etc. Settings are edited live via the `/admin` UI (which writes back to `config.json`) — many routes call `nconf.load()` per-request to pick up changes without a restart.

## Database

- Access goes through **Knex** (`knex/knex.js` exports a configured instance built by `knexfile.js` from nconf). Supports `sqlite3` (default), `mysql`, and `oracledb` (optional dep). Queries must stay cross-compatible across all three — see the `dbtype == 'oracledb'` branches in `routes/api.js` for quoting/search-index special cases.
- Schema changes **must** be Knex migrations in `knex/migrations/`. The DB auto-migrates on startup via `db.js` `init()`. (Per `knexfile.js`, generating new migration files requires temporarily hardcoding the client to `sqlite3`.)
- Three tables: `capcodes` (alias definitions — `address` pattern, `alias`, `agency`, `icon`, `color`, `pluginconf` JSON, `ignore` flag), `messages` (`address`, `message`, `source`, `timestamp`, `alias_id` FK→capcodes), `users` (`username`, bcrypt `password`, `role` admin|user, `status`).

## Request flow & architecture

Routes are mounted in `app.js`: `/` → `routes/index.js`, `/admin` → `routes/admin.js`, `/auth` → `routes/auth.js`, and **both `/api` and `/post`** → `routes/api.js` (the large core file: messages CRUD/search, capcodes CRUD, alias refresh).

**Auth** (`auth/local.js`, Passport) has two strategies: `login-user` (LocalStrategy, bcrypt vs the `users` table) and `login-api` (API key matched against the `auth.keys` array in config). **All API keys are treated as admin.** `middleware/authhelper.js` gates routes with `isLoggedIn`, `isLoggedInMessages` (bypasses auth unless `messages:apiSecurity` is set), `isAdmin`, `isAdminGUI`.

**Message ingestion** (`POST /api/messages`, the heart of the system) runs this pipeline:
1. Dedupe — in-memory `msgBuffer` + a DB lookup, bounded by `duplicateLimit`/`duplicateTime` config.
2. `pluginHandler.handle('message', 'before', ...)` — `before` plugins run synchronously and can mutate the message, drop it (`data.pluginData.ignore = true`), or force an alias (`data.pluginData.aliasId`).
3. Alias matching — SQL `LIKE` against `capcodes.address` where `_` acts as a single-char wildcard (so `100000_` matches a capcode range); a matched alias with `ignore = 1` drops the message.
4. Insert into `messages`.
5. `pluginHandler.handle('message', 'after', ...)` — `after` plugins fire notifications (Discord, Pushover, Telegram, SMTP, etc.).
6. Emit over **socket.io** to two namespaces: `/` (normal users) and `/adminio` (admin). The `pdwMode` / `adminShow` / `HideCapcode` settings decide what payload reaches which namespace.

## Plugin system

Plugins live in `plugins/`; each is a matching pair `Name.js` + `Name.json` (same name, capitalized). See `Template.js`/`Template.json` and `plugins/README.md` for the authoritative contract.

- The `.json` declares `trigger` (only `"message"` currently), `scope` (`"before"` | `"after"`), a global `config` field array (rendered in the settings UI), and an `aliasConfig` array for per-capcode settings (stored as JSON in `capcodes.pluginconf`). `"disable": true` means it can never be enabled from the UI (use for risky plugins, e.g. `Shell`).
- The `.js` exports `run(trigger, scope, data, config, callback)` and **must always call `callback(data)`** (place it in every async branch). Returning a non-null first arg to the callback replaces the whole `data` object — only ever pass back `data` or `null`.
- `pluginHandler.js` iterates plugins enabled in nconf `plugins`, runs only those whose `trigger`+`scope` match the current event, serially. `data.pluginData` carries state between plugins and into the front-end; `data.pluginconf[PluginName]` holds that alias's settings (may be `undefined`/empty — guard for it).

## Client (`client/`)

`reader.js` reads stdin line-by-line, regex-parses POCSAG/FLEX/EAS output from `multimon-ng`, zero-pads the address to 7 digits, and POSTs `{address, message, datetime, source}` to `<hostname>/api/messages` with the `apikey` header (retries with exponential backoff). Config comes from `client/config/config.json` (copied from `default.json`). EAS decoding uses the `jsame` package.

## Logging

`log.js` configures four Winston loggers — `main`, `http`, `db`, `auth` — each writing to its own rotating file under `logs/` plus the console. Import via `require('./log')` and call e.g. `logger.main.info(...)`. Level comes from `global:loglevel` in config; all loggers are silenced under `NODE_ENV=test`.

## Contributing conventions

- Update `CHANGELOG.md` on every PR (new entries go under the `# TBA` heading).
- The first PR after a release bumps the version in **three** places that must stay in sync: `CHANGELOG.md`, `server/app.js` (the `var version` on line 1), and `server/package.json`.
- CI (`.github/workflows/server.js.yml`) runs `npm install` + `npm run test-text` in `server/` on pushes/PRs to `master` and `develop`.
