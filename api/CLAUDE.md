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
from the app, and rows backfilled from pre-Overture checkins. `primaryType`
and `types` hold Overture category codes (`coffee_shop`, `airport`,
`stadium_arena`...); the iOS footprint and icon tables are keyed on them, so
use the Overture spelling everywhere, never Google's. Venue grounds
(`extent`) come from Overture's base theme polygons, matched in
`src/lib/extent-matching.ts`.

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
The current files were converted from the old Google recordings, with the
Google types mapped to Overture categories, and are all in that state.

# Running locally

`npm run dev` takes the first free port from 3000 up (several checkouts run
at once), so read the port from its "Server running at" line rather than
assuming 3000; set `PORT` to pin one. The simulator app finds its own server
by probing ports 3000-3009 for the one on its branch, so it needs no
configuration. Bruno's Local environment is fixed to 3000; change `baseUrl`
there when the server landed elsewhere.
