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

Places live in the `places` table: Overture Maps places imported with
`npm run overture:import` (see SETUP.md), venues users add from the app, and
rows backfilled from pre-Overture checkins. `primaryType` and `types` hold
Overture category codes (`coffee_shop`, `airport`, `stadium_arena`...); the
iOS footprint and icon tables are keyed on them, so use the Overture spelling
everywhere, never Google's.

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
