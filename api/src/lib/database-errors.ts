const POSTGRES_UNIQUE_VIOLATION = "23505";

/**
 * True when a write failed on a unique index.
 *
 * Drizzle wraps every failed query in a DrizzleQueryError whose `cause` is the
 * driver's error, so the Postgres code lives one level down. Checking only the
 * top-level error means a real conflict surfaces as a 500 instead of the 409
 * the route intends. The top level is still checked for anything that reaches
 * here unwrapped, such as a batch.
 */
export function isUniqueViolation(error: unknown): boolean {
  return (
    hasPostgresCode(error, POSTGRES_UNIQUE_VIOLATION) ||
    (typeof error === "object" &&
      error !== null &&
      "cause" in error &&
      hasPostgresCode((error as { cause?: unknown }).cause, POSTGRES_UNIQUE_VIOLATION))
  );
}

function hasPostgresCode(error: unknown, code: string): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === code
  );
}
