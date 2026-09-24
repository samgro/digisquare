/**
 * Dummy values for everything src/config.ts requires.
 *
 * config.ts parses the environment once at module load and calls
 * process.exit(1) if anything is missing — deliberately, so a misconfigured
 * deploy dies at boot instead of at the first request. Under vitest that would
 * kill the run outright the moment a test imports anything that reaches
 * config, so the harness supplies a complete environment instead of the
 * production behaviour being softened.
 *
 * These are only shapes, not credentials. Nothing here reaches a real service:
 * tests stub fetch, and the few that need a database use an in-process one
 * from test-database.ts instead of this URL.
 *
 * GOOGLE_PLACES_API_KEY has to be here too, because config validates it even
 * though google-places.ts does not read it from config. That costs nothing:
 * google-places.ts reads process.env at call time, so places.test.ts keeps
 * full control via vi.stubEnv — including stubbing it to "" to exercise the
 * missing-key path, which still works because nothing consults the cached
 * config value.
 */
process.env.GOOGLE_PLACES_API_KEY ??= "test-config-placeholder-key";
process.env.DATABASE_URL ??= "postgres://user:password@localhost:5432/hackysack_test";
process.env.AUTH_JWT_SECRET ??= "test-secret-at-least-thirty-two-characters-long";
process.env.APPLE_BUNDLE_IDENTIFIER ??= "samgro.Hackysack";
process.env.R2_ACCOUNT_ID ??= "test-account";
process.env.R2_ACCESS_KEY_ID ??= "test-access-key";
process.env.R2_SECRET_ACCESS_KEY ??= "test-secret-key";
process.env.R2_BUCKET_NAME ??= "hackysack-avatars-test";
process.env.R2_PUBLIC_BASE_URL ??= "https://avatars.test.invalid";
