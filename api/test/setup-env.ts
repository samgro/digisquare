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
 * tests stub fetch and never touch the database.
 * */
process.env.OVERTURE_RELEASE ??= "2026-09-23.0";
process.env.DATABASE_URL ??= "postgres://user:password@localhost:5432/hackysack_test";
process.env.AUTH_JWT_SECRET ??= "test-secret-at-least-thirty-two-characters-long";
process.env.APPLE_BUNDLE_IDENTIFIER ??= "samgro.Hackysack";
process.env.R2_ACCOUNT_ID ??= "test-account";
process.env.R2_ACCESS_KEY_ID ??= "test-access-key";
process.env.R2_SECRET_ACCESS_KEY ??= "test-secret-key";
process.env.R2_BUCKET_NAME ??= "hackysack-avatars-test";
process.env.R2_PUBLIC_BASE_URL ??= "https://avatars.test.invalid";
