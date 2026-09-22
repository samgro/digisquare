import { vi } from "vitest";

type QueryResult = unknown[];

export interface StubbedDatabase {
  /** Queue the rows the next awaited query should resolve to, in order. */
  queue: (...results: QueryResult[]) => void;
  /** Every top-level operation, in order: "select", "insert", "update", … */
  operations: string[];
  reset: () => void;
}

/**
 * A stand-in for the drizzle client.
 *
 * Drizzle builders are chainable and thenable — `database.update(t).set(…)
 * .where(…).returning()` is only executed when awaited — so every method on a
 * chain returns the same proxy, and awaiting one shifts the next queued result
 * off the front. That means a test scripts what the database returns without
 * modelling any SQL.
 *
 * This deliberately proves nothing about the queries themselves; it exists to
 * test the decision logic around them, which is where the subtle behaviour
 * lives. Whether the SQL is right is settled against real Postgres.
 */
export function createDatabaseStub(): {
  database: Record<string, unknown>;
  controls: StubbedDatabase;
} {
  const results: QueryResult[] = [];
  const operations: string[] = [];

  const makeChain = (): unknown => {
    const chain: Record<string | symbol, unknown> = {};
    const proxy: unknown = new Proxy(chain, {
      get(_target, property) {
        if (property === "then") {
          return (
            onFulfilled?: (value: QueryResult) => unknown,
            onRejected?: (reason: unknown) => unknown,
          ) => Promise.resolve(results.shift() ?? []).then(onFulfilled, onRejected);
        }
        return () => proxy;
      },
    });
    return proxy;
  };

  const operation = (name: string) =>
    vi.fn(() => {
      operations.push(name);
      return makeChain();
    });

  const database = {
    select: operation("select"),
    insert: operation("insert"),
    update: operation("update"),
    delete: operation("delete"),
    // batch resolves to one array per queued statement result.
    batch: vi.fn(async (statements: unknown[]) => {
      operations.push("batch");
      return statements.map(() => results.shift() ?? []);
    }),
  };

  return {
    database,
    controls: {
      queue: (...next: QueryResult[]) => results.push(...next),
      operations,
      reset: () => {
        results.length = 0;
        operations.length = 0;
      },
    },
  };
}
