import { lt, type Column, type SQL } from "drizzle-orm";
import { z } from "zod";

/**
 * How every newest-first list pages: `limit` rows created strictly before
 * the `before` timestamp, which the client takes from the last row it has.
 * A timestamp cursor keeps its place when new rows land above it, where a
 * numeric offset would repeat or skip one.
 */
export const paginationQuerySchema = z.object({
  limit: z.coerce.number().int().positive().max(100).default(20),
  before: z
    .string()
    .datetime({ offset: true })
    .transform((value) => new Date(value))
    .optional(),
});

/** The `where` fragment for `before`, or nothing when the first page was asked for. */
export function createdBefore(column: Column, before: Date | undefined): SQL | undefined {
  return before === undefined ? undefined : lt(column, before);
}
