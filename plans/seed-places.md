# Plan: Seed Overture coverage for the entire US + world cities, via an admin dashboard

## Context

Hackysack's `places` table is seeded for two metro regions (Bay Area, New York) today via a CLI
script, `npm run coverage:seed`. Before launch, the goal is to pre-seed the entire United States
plus a curated set of the world's most popular cities, and to do it through an admin dashboard —
a map showing what's covered, click-to-seed for new areas, and a way to sample venue searches by
lat/long — rather than hand-running CLI commands and SQL queries.

The underlying pipeline (DuckDB reading Overture GeoParquet off S3, tiling a bounding box into 1°
chunks, resumable/idempotent upserts keyed on `overture_id`) already generalizes to arbitrary
bounding boxes — `bay-area`/`new-york` are just entries in `api/scripts/seed-regions.ts`. This plan
turns that same machinery into a small set of admin-only HTTP endpoints and a single dashboard page,
so seeding becomes point-and-click instead of terminal + SQL.

Confirmed against current code (as of this writing — a future implementer should re-verify line
numbers/exports before relying on them, code may have moved): `api/src/lib/coverage-cells.ts`,
`api/src/lib/coverage-worker.ts`, `api/src/lib/overture-remote.ts`, `api/src/lib/coverage.ts`,
`api/src/lib/overture-import.ts`, `api/src/lib/places-search.ts`, `api/src/db/schema.ts`,
`api/scripts/coverage-seed.ts`, `api/scripts/seed-regions.ts`, `api/src/app.ts`,
`api/src/middleware/require-auth.ts`, `api/src/middleware/optional-auth.ts`, `api/src/config.ts`,
`api/src/routes/places.ts`.

Key facts that shape this plan:
- **No admin/role concept exists** in the app. The `users` table (`api/src/db/schema.ts:29-67`) has
  no `role`/`isAdmin` column. Auth middleware (`api/src/middleware/require-auth.ts`) is binary:
  valid JWT or 401 — there's no notion of a privileged user to check against. The dashboard needs its
  own lightweight gate, not app-user auth.
- **No frontend of any kind exists** in this repo. `api/package.json` has no React/Vue/`hono/jsx`/
  Vite — every route in `api/src/app.ts` returns JSON. `ios/` is a native Swift/SwiftUI app, unrelated.
  This dashboard is built from scratch, but Hono natively supports server-rendered HTML responses and
  static file serving with no new deployable, no build step, and no new architecture — just new routes.
- **Single Railway service, no separate worker.** `api/src/index.ts` starts the `CoverageWorker`
  in-process alongside the HTTP server, with a comment explaining this is because Railway has no
  separate worker dyno here. There is no `railway.json`/`Procfile`/`nixpacks.toml` in the repo —
  deployment config lives directly in Railway's dashboard. The admin dashboard follows the same
  single-process pattern: new routes on the existing `app.ts`, nothing new to deploy.
- **`GET /places?lat&lng&q`** (`api/src/routes/places.ts`) already exists, is `optionalAuth`-gated,
  and does exactly what "sample venue search by lat/long" needs (calls
  `searchByName`/`searchNearbyCandidates` in `api/src/lib/places-search.ts`, plus
  `describeCoverage` from `api/src/lib/coverage.ts`) — reuse this logic directly.
- **No HTTP surface for coverage exists today.** `coverage_cells` status and triggering a seed are
  CLI-script/SQL-only (`api/scripts/coverage-seed.ts`, `coverage-refresh.ts`, `coverage-retry.ts`).
  This plan adds admin-only HTTP endpoints wrapping the same underlying functions those scripts call.
- The app is not broken outside pre-seeded areas — a live on-demand `fix`→`city` coverage-growth path
  already exists (`api/src/lib/coverage.ts::describeCoverage`, triggered when a signed-in user
  searches from an uncovered spot). Pre-seeding via the dashboard is a UX/cost optimization (avoid
  the first-search wait, avoid burning the small on-demand rate budget), not a functional
  requirement — safe to build and use incrementally, ship partial US coverage, keep going after
  launch.

---

## 1. Admin dashboard: auth

Add a lightweight gate mirroring the existing `ENABLE_TEST_USERS` pattern:
- `api/src/routes/test-users.ts` + the `ENABLE_TEST_USERS` boolean env var (checked in
  `api/src/config.ts`'s zod `environmentSchema`) is today's only precedent for "hide this route
  behind an env flag in production." Follow the same shape.
- New env vars: `ENABLE_ADMIN_DASHBOARD` (boolean, default `false`) and `ADMIN_DASHBOARD_PASSWORD`
  (string, required only when the flag is `true` — use zod's `.refine`/superRefine or a conditional
  schema the way other conditionally-required config is validated in `config.ts`, if such a pattern
  already exists there; otherwise a simple runtime check at startup is fine).
- New middleware `api/src/middleware/require-admin.ts` using Hono's built-in `hono/basic-auth`
  (ships with the `hono` package already installed — no new dependency). Fixed username (e.g.
  `"admin"`), password from `ADMIN_DASHBOARD_PASSWORD`.
- Mount the whole `admin` route group (see §2) only when `ENABLE_ADMIN_DASHBOARD` is true (mirrors
  how `/auth/test-users` is conditionally registered in `api/src/app.ts`), with `require-admin`
  applied to every route in the group.
- This is an internal tool, not user-facing — basic auth over HTTPS (Railway terminates TLS) is
  adequate; don't over-engineer this into a full auth system.

---

## 2. Admin HTTP endpoints (new)

New route file `api/src/routes/admin.ts`, mounted as `app.route("/admin", admin)` in
`api/src/app.ts`, every route behind `require-admin`:

- **`GET /admin`** — serves the dashboard HTML page (§3).
- **`GET /admin/coverage?west=&south=&east=&north=`** — returns `coverage_cells` rows (`cellX`,
  `cellY`, `status`, `overtureRelease`) intersecting the given bbox, queried from the `coverageCells`
  table (`api/src/db/schema.ts`, composite PK `(cell_x, cell_y)`). Used to paint the map grid.
  **Important scaling detail**: at low zoom (e.g. viewing the whole US or world), a naive per-0.1°-cell
  query/response could be huge. Bucket cells server-side into coarser blocks (e.g. round `cellX`/`cellY`
  down to whole-degree groups and return an aggregate status per block — "block is `ready` if all
  cells ready, `mixed` if some, etc) when the viewport bbox is above some area threshold; return real
  per-cell resolution only when the viewport is zoomed in enough that the cell count is small (e.g.
  under a few thousand). This mirrors the same 1°-tile granularity `coverage-cells.ts`'s
  `groupCellsIntoTiles` already uses elsewhere, so reuse that function/logic rather than inventing new
  bucketing math.
- **`POST /admin/seed-cell`** — body `{ lat: number, lng: number }`. Resolve the containing 1° tile
  using the same bounds math `coverage-cells.ts` already exposes (check for an existing "point to
  tile bounds" helper before writing a new one), then call `seedCellsNow` (already exported from
  `api/src/lib/coverage-worker.ts`, currently used by `api/scripts/coverage-seed.ts`) for that single
  tile. Return `{ jobId, status }` from the claimed job immediately; the dashboard polls
  `GET /admin/jobs` or re-fetches `GET /admin/coverage` to see it flip to `ready`. This is the
  "click a cell to seed just that area" feature.
- **`POST /admin/seed-region`** — body `{ west, south, east, north }`. Tile the bbox with
  `groupCellsIntoTiles`, then run all tiles as a background batch (see §6 for the in-process worker
  pool design — do **not** block the HTTP response on a potentially hours-long region). Return a
  batch/job-group identifier immediately so the dashboard can track progress via `GET /admin/jobs`.
  This is the "draw a box to seed a custom region" feature, and is also what the world-cities
  generator script (§7) calls per city.
- **`GET /admin/jobs`** — returns recent `coverage_jobs` rows (id, kind, bbox, status, attempts,
  last_error, timestamps), most recent first, for a status panel and for polling. Equivalent to the
  monitoring SQL:
  ```sql
  SELECT id, kind, west, south, east, north, status, attempts, last_error, started_at, completed_at
  FROM coverage_jobs ORDER BY requested_at DESC LIMIT 200;
  ```
- **`GET /admin/search?lat=&lng=&q=`** — thin pass-through to the same search logic
  `GET /places` uses (`searchByName`/`searchNearbyCandidates` in `api/src/lib/places-search.ts`).
  Kept as a separate admin-namespaced route (rather than just linking to `/places` from the dashboard)
  because the real `/places` route requires passing through `optionalAuth`, which expects an
  `Authorization` header shaped like a real user session — simplest for an internal tool to just call
  the search functions directly from an admin route already gated by basic auth, rather than minting
  a fake JWT.

No changes needed to `overture-remote.ts`, `overture-import.ts`, `coverage-worker.ts`,
`coverage-cells.ts`, or `coverage.ts` — every admin endpoint is a thin wrapper around functions that
already exist and are already exercised by the CLI scripts and the live on-demand path.

---

## 3. Admin dashboard page

Single server-rendered page at `GET /admin` — either inline in `api/src/routes/admin.ts` or a small
`api/src/admin-page.ts` exporting an HTML template string (or `hono/jsx`, if preferred for
readability; either works with zero new build tooling since Hono's JSX runtime needs only a
`tsconfig`/`jsx` pragma, no bundler).

- **No build step, no new frontend dependency beyond CDN `<script>`/`<link>` tags** — appropriate
  for a single internal page.
- **Map**: [Leaflet.js](https://leafletjs.com/) loaded from a CDN (e.g. unpkg or jsdelivr), tile
  layer from OpenStreetMap's free public tile server (no API key, no billing — matches the rest of
  this stack's avoidance of paid third-party map services for something that's Overture-data-driven
  anyway).
- **Coverage overlay**: on map `moveend`/`zoomend`, call `GET /admin/coverage` with the current
  viewport bounds and draw colored rectangles per cell/block: green = `ready`, yellow =
  `pending`/`importing`, red = `failed`, no rectangle = never seeded. Re-fetch on every viewport
  change (debounce to avoid hammering the endpoint while panning).
- **Click-to-seed (single cell)**: a map click handler reads the click's lat/lng, calls
  `POST /admin/seed-cell`, shows a small toast/status ("seeding cell..."), then polls
  `GET /admin/coverage` for that cell every few seconds until it flips to `ready`/`failed`.
- **Draw-to-seed (region)**: a toggle button enters "draw mode" using Leaflet's rectangle-drawing
  interaction (either hand-rolled with Leaflet's core mouse events, or the small `leaflet-draw`
  plugin, also CDN-loadable) — drag a rectangle, then show a confirmation dialog with an estimate
  ("this covers roughly N° × M°, could take hours — continue?") before calling
  `POST /admin/seed-region`. Don't try to give a precise place-count estimate here (that needs an
  actual DuckDB scan, see §5) — a rough size/tile-count warning is enough to prevent fat-fingering a
  huge region by accident.
- **Job status panel**: a table (below or beside the map) polling `GET /admin/jobs` every few
  seconds — replaces manually re-running the monitoring SQL from a terminal.
- **Sample search panel**: a small form (lat, lng, optional free-text query) calling
  `GET /admin/search` and rendering the JSON results as a plain list — use this immediately after
  seeding an area to sanity-check real venues came back, without leaving the page.

---

## 4. Defining "the entire United States"

With the draw-to-seed tool, there's no need to hardcode US region bounding boxes in
`seed-regions.ts` — draw one box for CONUS, one for Alaska, one for Hawaii, one for Puerto Rico, and
let `POST /admin/seed-region` run each as a background batch. (`seed-regions.ts`'s existing
`bay-area`/`new-york` entries can stay as-is for CLI convenience/tests; nothing about this plan
requires removing them.)

Approximate boxes to draw (for reference — draw by eye on the map rather than typing exact
coordinates, since the dashboard's rectangle tool captures whatever's drawn):
- **CONUS**: roughly `west: -125.0, south: 24.5, east: -66.9, north: 49.5`
- **Alaska**: roughly `west: -179.5, south: 51.0, east: -129.5, north: 71.5` (accept a small gap on
  the westernmost Aleutian islands rather than handling the antimeridian for a few hundred places)
- **Hawaii**: roughly `west: -160.5, south: 18.5, east: -154.5, north: 22.5`
- **Puerto Rico**: roughly `west: -67.5, south: 17.8, east: -64.5, north: 18.6` (bundles the US
  Virgin Islands)

---

## 5. Volume & runtime: measure before committing to a full US run

Don't draw the full CONUS box blind. Recommended sequence:
1. Draw a box over one representative large state (e.g. Texas: roughly `-106.6, 25.8` to
   `-93.5, 36.5`) and seed it through the dashboard, watching the new job panel for real timing and
   place counts (`coverage_jobs.place_count` per completed job, summable).
2. Extrapolate from that real number (rather than the smaller/denser Bay Area ~0.5M / New York ~1.2M
   metro numbers from `api/SETUP.md`) to estimate full CONUS place count and runtime. Order-of-magnitude
   expectation going in: tens of millions of places nationwide, potentially many hours of wall-clock
   time even with the in-process worker pool from §6 — treat any number here as a rough guess to be
   replaced by the pilot's real measurement, not a spec to hit.
3. Decide from that measurement whether the default worker-pool concurrency (§6) is enough, or
   whether it's worth increasing before drawing the full CONUS box.

---

## 6. Background execution model for large regions (parallelism)

`POST /admin/seed-region` must not block its HTTP response for a multi-hour region, and running
hundreds of tiles one at a time would be needlessly slow. Recommended implementation:

- On receiving a region, tile the bbox (`groupCellsIntoTiles`) and immediately insert **all** tiles'
  jobs pre-claimed (`enqueueJob({ ..., claimed: true })` — the same mechanism `seedCellsNow` already
  uses, added specifically so a script's own inline run is never double-claimed by a live worker) so
  progress is visible in `GET /admin/jobs`/`GET /admin/coverage` right away, even before processing
  starts.
- Process the pre-claimed jobs with a small in-process worker pool — e.g. a simple concurrency-limited
  loop (a tiny custom queue, or a small library like `p-limit`) running N `runJob` calls at a time
  (`runJob` already exists in `api/src/lib/coverage-worker.ts`), default N = 4-8, ideally configurable
  via an env var (`ADMIN_SEED_CONCURRENCY`) so it can be tuned without a code change.
- This reuses the existing `FOR UPDATE SKIP LOCKED`-safe claim path (already safe for concurrent
  claimers, since that's exactly what lets the live `CoverageWorker` and CLI scripts coexist safely
  today) — no new locking logic needed, just calling `runJob` N-at-a-time instead of one-at-a-time.
- **Concurrency guard**: since this now runs inside the always-on API process (which also serves real
  user traffic and runs the live `CoverageWorker`), avoid oversubscribing the single Railway instance
  — only allow one `seed-region` batch to run at a time (a simple in-memory flag is fine, since it's a
  single process; a DB-backed lock only matters if Railway ever runs multiple instances of this
  service, which it doesn't per §current setup). Reject/queue a second `seed-region` request while one
  is in flight, and surface that in the dashboard's confirmation dialog.
- **Crash resilience**: because this runs inside the long-lived API process rather than a one-off CLI
  script, the existing `recoverStaleJobs()` housekeeping (already called from `CoverageWorker`'s boot
  in `api/src/lib/coverage-worker.ts`) already covers recovery if the whole API process restarts
  mid-seed — no separate stale-job-cleanup code path is needed for the dashboard flow.

---

## 7. Worldwide "most popular places" set

Don't hand-curate a list from memory — source real data, then feed it through the same
`seed-region` endpoint the dashboard's draw tool uses:

1. **Source**: the open [GeoNames `cities15000` dataset](https://download.geonames.org/export/dump/)
   (public domain; population, lat/lng, country, admin codes for every populated place >15,000
   people worldwide) combined with a published tourism ranking (e.g. a "Global Destination Cities
   Index" — pick whichever specific one is actually accessible at implementation time) as a secondary
   filter, to catch high-tourism/lower-population places pure population rank would miss (Venice,
   etc). Cross-reference — don't invent numbers.
2. **Rank/filter** to roughly the top 150-200 cities across the combined population + tourism
   signal. Expect to manually prune duplicates/oddities in raw population data (the same metro often
   appears multiple times under different administrative subdivisions).
3. **Derive a bbox per city** using the existing `boundsOfCircle` helper
   (`api/src/lib/coverage-cells.ts`) with a population-tiered radius — e.g. >10M metro population →
   60km, >3M → 40km, >1M → 25km (tune against how `bay-area`/`new-york`'s existing boxes compare to
   their metro population, for consistency).
4. **Implementation**: a one-off script, `api/scripts/generate-world-regions.ts`, that reads a
   downloaded GeoNames extract (+ the tourism list), does the filtering/bbox derivation above, and
   either (a) calls `POST /admin/seed-region` directly for each city against a running API instance
   (simplest, one seeding code path), or (b) prints the boxes so an operator can review/draw them on
   the dashboard manually first before triggering. Prefer (a) once the list has been reviewed once;
   use (b) for the first pass to eyeball a handful of generated boxes on the map before trusting the
   generator.
5. This is the one part of the feature set that genuinely needs external data pulled in at
   implementation time — do not skip the download-and-review step in favor of a plausible-sounding
   hardcoded list.

---

## 8. Database/infra considerations at this scale

These apply to the underlying seeding volume regardless of CLI vs. dashboard:
- **Storage**: full US + ~150-200 world cities plausibly totals in the tens of millions of `places`
  rows. Check the current Neon plan/branch storage cap before starting a big run — a billing/config
  check, not a schema change.
- **Indexes**: existing indexes on `places` (`places_location_gist_idx`, `places_extent_gist_idx`,
  `places_name_trgm_idx`, `places_created_by_user_id_idx`) scale fine to tens of millions of rows for
  point/polygon/trigram search respectively — no index redesign needed.
- **Insert path**: `upsertOverturePlaces`'s existing 500-row batch upsert
  (`UPSERT_BATCH_SIZE` in `api/src/lib/overture-import.ts`) is already the right shape for bulk
  loading; only revisit if the pilot run (§5) shows the insert path (not the S3 scan) is the
  bottleneck.
- **Autovacuum**: heavy upsert + soft-delete (`retirePlacesMissingFrom`) churn during a big region
  seed generates meaningful dead-tuple bloat. Watch `pg_stat_user_tables.n_dead_tup` for `places`
  during a big run; consider a manual `VACUUM ANALYZE places;` afterward, or a temporary
  `ALTER TABLE places SET (autovacuum_vacuum_scale_factor = 0.05)` for the duration of a big seed.
- **Partitioning**: not recommended at this row count (tens of millions) — added complexity for no
  clear benefit below roughly 100M+ rows.
- **Neon compute**: the in-process worker pool (§6) means more concurrent DB writers from the single
  Railway service than exist today — consider temporarily bumping Neon compute (CU count) during a
  big seed window, then scaling back down afterward.
- **Resource contention with live traffic**: the worker pool shares the same process as the live API
  server and its `CoverageWorker` — keep `ADMIN_SEED_CONCURRENCY` conservative (default 4-8) and rely
  on the single-batch-at-a-time guard (§6) rather than letting an admin accidentally run multiple huge
  regions simultaneously while real users are on the app.

---

## Summary of code changes

**New files:**
- `api/src/middleware/require-admin.ts` — basic-auth gate, active only when `ENABLE_ADMIN_DASHBOARD`
  is true.
- `api/src/routes/admin.ts` — `GET /admin` (dashboard page), `GET /admin/coverage`,
  `POST /admin/seed-cell`, `POST /admin/seed-region`, `GET /admin/jobs`, `GET /admin/search`.
- Dashboard page template (HTML + Leaflet via CDN + vanilla JS; no build step) — inline in
  `admin.ts` or split into `api/src/admin-page.ts` for readability.
- `api/scripts/generate-world-regions.ts` — GeoNames + tourism-index-driven world-city list
  generator, calling `POST /admin/seed-region` per city (or emitting boxes for manual review).

**Modified files:**
- `api/src/config.ts` — add `ENABLE_ADMIN_DASHBOARD` (boolean) and `ADMIN_DASHBOARD_PASSWORD`
  (conditionally-required string) to the env schema.
- `api/src/app.ts` — conditionally mount the new `admin` route group when `ENABLE_ADMIN_DASHBOARD`
  is true, matching the existing `ENABLE_TEST_USERS` conditional-mount pattern for `/auth/test-users`.

**No changes needed** to `overture-remote.ts`, `overture-import.ts`, `coverage-worker.ts`,
`coverage-cells.ts`, `coverage.ts`, or `places-search.ts` — the dashboard is purely a new HTTP/UI
layer over existing, already-battle-tested seeding and search logic. `seed-regions.ts` and the CLI
scripts (`coverage-seed.ts`, `coverage-refresh.ts`, `coverage-retry.ts`) can remain untouched and
continue to work as they do today; the dashboard is an additional, more convenient way to trigger the
same underlying jobs, not a replacement.

## Verification

1. `npm test` in `api/` after adding the admin routes/middleware. Add unit tests (per
   `api/CLAUDE.md`'s testing conventions — tests stub the database, per
   `api/test/helpers/stub-database.ts`) for:
   - `require-admin` middleware: rejects with no/wrong credentials, passes with correct ones, and is
     absent entirely (404) when `ENABLE_ADMIN_DASHBOARD` is false.
   - Each new route handler's request/response shape against the stubbed database.
2. **Real-Postgres manual verification is required** for anything touching the coverage
   worker/SQL, per `api/CLAUDE.md` ("a change to the SQL itself... still needs checking against a
   real Postgres"): run the API locally against a real PostGIS database with
   `ENABLE_ADMIN_DASHBOARD=true`, then:
   - Open `/admin`, confirm the map renders and the coverage overlay reflects real
     `coverage_cells` rows for an already-seeded area (Bay Area or New York).
   - Click an unseeded cell, confirm it transitions unseeded → pending/importing → ready, and that a
     corresponding `coverage_jobs` row appears with sane `place_count`.
   - Draw a small test box (a few tiles), confirm `POST /admin/seed-region` processes them via the
     worker pool and the job panel reflects progress in real time.
   - Run a sample search via the dashboard's search panel against a just-seeded area and confirm real
     venues come back (cross-check against `GET /places` directly for the same coordinates).
3. Before attempting a full CONUS run, pilot one large state (Texas) through the dashboard end-to-end
   and confirm the worker pool holds up without visibly starving the live API (check response times
   on other endpoints while the pilot seed runs).
4. For the world-regions generator: spot-check a handful of generated bounding boxes on the dashboard
   map (do they look right for e.g. Tokyo, Paris, Cairo?) before triggering their seeds for real.
