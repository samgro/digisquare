# Testing

The api has vitest tests in `api/src/**/*.test.ts`. Run them with `npm test` in
`api`. Tests stub global `fetch` and never hit Google or the database.

Run the tests before finishing any change to the api. When fixing a bug, add a
test that fails on the old behavior first, then fix it.
