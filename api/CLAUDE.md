# Testing

The api has vitest tests in `api/src/**/*.test.ts`. Run them with `npm test` in
`api`. Tests stub global `fetch` and never hit Google. Most stub the database
with `test/helpers/stub-database.ts`. Tests where the SQL itself matters, like
`src/routes/checkin-privacy.test.ts`, run against an in-process Postgres from
`test/helpers/test-database.ts` instead.

Run the tests before finishing any change to the api. When fixing a bug, add a
test that fails on the old behavior first, then fix it.

# Ranking fixtures

`fixtures/ranking/*.json` at the repo root hold recorded Google Places
responses for real venues plus sample checkin histories. The API replays them
as golden tests for `GET /places`, and the iOS `PlaceRanker` tests read the
same files. Scenarios are defined in `scripts/ranking-scenarios.ts`; record or
refresh them against the live API with:

```
GOOGLE_PLACES_API_KEY=... npm run fixtures:record            # every scenario
GOOGLE_PLACES_API_KEY=... npm run fixtures:record -- sfo-terminal-2
```

Each scenario costs three billable requests. A file whose `recordedAt` is
null is hand-authored stand-in data and should be re-recorded.

# Privacy

You only ever see your own checkins and your friends'. All checkin queries
live in `src/lib/checkin-queries.ts`, which applies that rule. Routes call its
functions and never import the checkins table; `checkin-access.test.ts` fails
if anything else does. `toCheckinResult` only accepts the `VisibleCheckin`
rows those functions return.

A stranger's checkin is a 404 or an empty list, never a 403. Every new endpoint
that returns checkins needs a case in `src/routes/checkin-privacy.test.ts`
showing a stranger's checkins aren't returned.
