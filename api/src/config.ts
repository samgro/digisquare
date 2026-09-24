import "dotenv/config";
import { z } from "zod";

const environmentSchema = z.object({
  DATABASE_URL: z.string().min(1),
  // Validated here so a missing key fails at boot rather than on the first
  // Google call, but google-places.ts deliberately reads process.env
  // directly at call time instead of going through this — its tests stub
  // the variable per-case, including to "" to exercise the error path.
  GOOGLE_PLACES_API_KEY: z.string().min(1),
  PORT: z.coerce.number().int().positive().default(3000),

  AUTH_JWT_SECRET: z.string().min(32),
  ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(60),
  REFRESH_TOKEN_ABSOLUTE_TTL_DAYS: z.coerce.number().int().positive().default(180),
  APPLE_BUNDLE_IDENTIFIER: z.string().min(1).default("samgro.Hackysack"),

  // Turns on /auth/test-users, which signs anyone in as a test user with no
  // credential at all. Leave it off anywhere real people have accounts.
  ENABLE_TEST_USERS: z
    .enum(["true", "false"])
    .default("false")
    .transform((value) => value === "true"),

  R2_ACCOUNT_ID: z.string().min(1),
  R2_ACCESS_KEY_ID: z.string().min(1),
  R2_SECRET_ACCESS_KEY: z.string().min(1),
  R2_BUCKET_NAME: z.string().min(1),
  R2_PUBLIC_BASE_URL: z.string().url(),
});

const parsedEnvironment = environmentSchema.safeParse(process.env);

if (!parsedEnvironment.success) {
  console.error(
    "Invalid environment configuration:",
    parsedEnvironment.error.flatten().fieldErrors,
  );
  process.exit(1);
}

export const config = parsedEnvironment.data;
