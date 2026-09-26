# Testing

The api has vitest tests in `api/src/**/*.test.ts`. Run them with `npm test` in
`api`. Tests stub the database (`test/helpers/stub-database.ts`) and never hit
Postgres, so a change to the SQL itself (the place searches in
`src/lib/places-search.ts`, a migration) still needs checking against a real
Postgres: apply the migrations to a scratch database and run the Bruno
collection, or a throwaway script, against it.

Run the tests before finishing any change to the api. When fixing a bug, add a
test that fails on the old behavior first, then fix it.

# Place data

Places live in the `places` table (PostGIS): Overture Maps places fetched by
the coverage worker (`src/lib/coverage-worker.ts`, straight from the release
files with DuckDB) or seeded with `npm run coverage:seed`, venues users add
from the app, rows backfilled from pre-Overture checkins, and the venues of
imported Swarm checkins (`source = 'foursquare'`, one per Foursquare venue,
hidden from search until matched to Overture's copy). `primaryType` and
`types` hold Overture category codes (`coffee_shop`, `airport`,
`stadium_arena`...); the iOS footprint and icon tables are keyed on them, so
use the Overture spelling everywhere, never Google's or Foursquare's.
Foursquare categories are mapped in `src/lib/foursquare-category-mapping.ts`
against the code list in `src/lib/overture-categories.ts` (generated with
`npm run overture:categories`); the source's own label survives in
`categoryName`. Venue grounds (`extent`) come from Overture's base theme
polygons, matched in `src/lib/extent-matching.ts`.

Every Overture row carries a `prior`: the log-odds that anyone would check
in there, computed at import by `src/lib/place-quality.ts` from which
provider the record came from (`sourceDataset`), its confidence and
operating status, and its taxonomy path (`taxonomyHierarchy`, which also
gives the category tiers: food and drink up, offices and practitioners
down). `providerCount`, how many providers matched the venue in the
release's bridge files, is written separately by `npm run overture:bridge`
after a seed or refresh (a whole-release scan, minutes), which also records
each imported Foursquare venue's Overture id on `foursquare_venues`; the
search adds its bonus when a row is read. Nearby searches drop rows below
`HIDDEN_PRIOR_THRESHOLD`; name searches do not. `GET /places` returns the
prior and the app's ranker adds it to its score, so a change to the
weights in `place-quality.ts` needs `npm run coverage:refresh -- --all` to
reach existing rows.

The searches in `src/lib/places-search.ts` cast to geography and the GiST
indexes are on that cast; a plain geometry index would go unused. Anything
that touches SQL there, a migration, or the worker needs a real PostGIS to
check against (a local Postgres with `postgresql-16-postgis-3` works; the
Overture fetch can be pointed at local parquet files with
`test/helpers/overture-parquet.ts`).

# Ranking fixtures

`fixtures/ranking/*.json` at the repo root hold recorded `GET /places`
responses for real spots plus sample checkin histories. The API replays them
as golden tests for the result shape, and the iOS `PlaceRanker` tests read the
same files. Scenarios are defined in `scripts/ranking-scenarios.ts`; record or
refresh them from a running API whose database holds Overture data for each
scenario's area:

```
HACKYSACK_API_URL=http://localhost:3000 npm run fixtures:record            # every scenario
HACKYSACK_API_URL=http://localhost:3000 npm run fixtures:record -- sfo-terminal-2
```

A file whose `recordedAt` is null is stand-in data and should be re-recorded.

# Ranking evaluation

`npm run ranking:evaluate` measures the ranker against the imported Swarm
checkins whose venues `overture:bridge` matched to Overture places: it
stands a noisy fix near each venue's pin, fetches candidates the way `GET
/places` does, ranks them with the app's own `PlaceRanker` (compiled from
the iOS sources with swiftc into `build/`) and reports top-1, top-3 and MRR
by accuracy. Flags such as `--pin-error 12 --prior-weight 0` override
weights, so a tuning change is compared before and after on the same fixes.
Run it against a database holding the checkins' areas (the Neon branch or
production; `.env.branch` picks). Use it before changing `RankingWeights`,
`PlaceFootprint` or `place-quality.ts`. Its truths come through Foursquare's
bridge records, so they are nearly all corroborated venues: discount what
it says about the corroboration bonus.

# Running locally

Port 3000 is the user's own server: their `.env` sets `PORT=3000` and Bruno's
Local environment points there. A Claude Code session has
`HACKYSACK_AUTOMATIC_PORT=1` in its environment (from `.claude/settings.json`),
which makes `npm run dev` ignore `PORT` and take the first free port from 3001
up (several checkouts run at once), so read the port from its "Server running
at" line rather than assuming one. Never start a server with `PORT=3000`, never
send requests to 3000, and never assume 3000 is this checkout's server. The simulator app finds its own
server by probing ports 3000-3009 for the one on its branch, so it needs no
configuration. Never `pkill` or `killall`: the user's server and other
checkouts' servers share this machine, so kill the pid you started. A
PreToolUse hook (`.claude/hooks/guard-bash.sh`) refuses both mistakes.
