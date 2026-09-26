import "./load-environment.js";
import { z } from "zod";

const environmentSchema = z.object({
  DATABASE_URL: z.string().min(1),
  PORT: z.coerce.number().int().positive().default(3000),
  // The Overture Maps release the database should hold, e.g. 2026-09-23.0.
  // Bumping it makes the coverage worker roll every ready cell forward.
  OVERTURE_RELEASE: z.string().regex(/^\d{4}-\d{2}-\d{2}\.\d+$/, "Expected a release like 2026-09-23.0"),

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

  // Swarm import. Optional so the API still boots without it; the
  // /imports/swarm routes answer 503 until all four are set (see
  // swarmImportConfig below).
  FOURSQUARE_CLIENT_ID: z.string().min(1).optional(),
  FOURSQUARE_CLIENT_SECRET: z.string().min(1).optional(),
  // This API's /imports/swarm/callback, exactly as registered with Foursquare.
  FOURSQUARE_REDIRECT_URL: z.string().url().optional(),
  // 32 random bytes, base64: openssl rand -base64 32
  FOURSQUARE_TOKEN_ENCRYPTION_KEY: z.string().min(1).optional(),
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

export interface SwarmImportConfig {
  clientId: string;
  clientSecret: string;
  redirectUrl: string;
  tokenEncryptionKey: string;
}

/** Everything the Swarm import needs, or null when it is not configured. */
export function swarmImportConfig(): SwarmImportConfig | null {
  const {
    FOURSQUARE_CLIENT_ID: clientId,
    FOURSQUARE_CLIENT_SECRET: clientSecret,
    FOURSQUARE_REDIRECT_URL: redirectUrl,
    FOURSQUARE_TOKEN_ENCRYPTION_KEY: tokenEncryptionKey,
  } = config;
  if (!clientId || !clientSecret || !redirectUrl || !tokenEncryptionKey) {
    return null;
  }
  return { clientId, clientSecret, redirectUrl, tokenEncryptionKey };
}
