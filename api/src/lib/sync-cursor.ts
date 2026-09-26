import { z } from "zod";

/**
 * Timestamps inside a sync cursor keep Postgres's full microsecond precision.
 * A JS Date only holds milliseconds, so round-tripping through one would make
 * `(updated_at, id) > cursor` re-match every row sharing the last row's
 * millisecond — and a page made entirely of such rows would loop forever.
 */
const cursorTimestampSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/);

/** Postgres `to_char` pattern producing the format cursorTimestampSchema accepts. */
export const CURSOR_TIMESTAMP_FORMAT = 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"';

export const ZERO_UUID = "00000000-0000-0000-0000-000000000000";

const syncCursorSchema = z.discriminatedUnion("phase", [
  // Walking the whole history newest first, so a fresh install fills its
  // timeline from the top. `since` is when this backfill began: anything
  // created or edited after it is picked up by the changes phase instead.
  z.object({
    phase: z.literal("backfill"),
    createdAt: cursorTimestampSchema,
    id: z.string().uuid(),
    since: cursorTimestampSchema,
  }),
  // Walking forward through edits and new checkins in updated_at order.
  z.object({
    phase: z.literal("changes"),
    updatedAt: cursorTimestampSchema,
    id: z.string().uuid(),
  }),
]);

export type SyncCursor = z.infer<typeof syncCursorSchema>;

/** Cursors are opaque to clients; the shape is ours to change. */
export function encodeSyncCursor(cursor: SyncCursor): string {
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

/** Returns null for anything that is not a cursor this server issued. */
export function decodeSyncCursor(encoded: string): SyncCursor | null {
  try {
    const decoded: unknown = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
    const parsed = syncCursorSchema.safeParse(decoded);
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}
