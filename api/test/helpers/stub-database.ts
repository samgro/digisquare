import { vi } from "vitest";

/** Rows for a builder query, or `{ rows }` for `database.execute`. */
type QueryResult = unknown;

/** A queued entry that makes the query reject instead of resolving. */
class QueuedFailure {
  constructor(readonly error: unknown) {}
}

export interface StubbedDatabase {
  /** Queue the rows the next awaited query should resolve to, in order. */
  queue: (...results: QueryResult[]) => void;
  /** Make the next awaited query reject with `error`, as a failed write would. */
  queueFailure: (error: unknown) => void;
  /** Every top-level operation, in order: "select", "insert", "update", … */
  operations: string[];
  /**
   * Every chained call and its arguments, in order, e.g. `values` with the
   * inserted row or `where` with the condition. Lets a test check what was
   * written without modelling the query.
   */
  chainedCalls: { method: string; arguments: unknown[] }[];
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
  const results: (QueryResult | QueuedFailure)[] = [];
  const operations: string[] = [];
  const chainedCalls: { method: string; arguments: unknown[] }[] = [];

  const makeChain = (): unknown => {
    const chain: Record<string | symbol, unknown> = {};
    const proxy: unknown = new Proxy(chain, {
      get(_target, property) {
        if (property === "then") {
          return (
            onFulfilled?: (value: QueryResult) => unknown,
            onRejected?: (reason: unknown) => unknown,
          ) => {
            const next = results.shift() ?? [];
            const settled =
              next instanceof QueuedFailure ? Promise.reject(next.error) : Promise.resolve(next);
            return settled.then(onFulfilled, onRejected);
          };
        }
        return (...callArguments: unknown[]) => {
          chainedCalls.push({ method: String(property), arguments: callArguments });
          return proxy;
        };
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
    execute: operation("execute"),
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
      queueFailure: (error: unknown) => results.push(new QueuedFailure(error)),
      operations,
      chainedCalls,
      reset: () => {
        results.length = 0;
        operations.length = 0;
        chainedCalls.length = 0;
      },
    },
  };
}
