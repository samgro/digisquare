import { vi } from "vitest";

export interface StubbedFetchCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

export interface StubbedFetchRoute {
  /** Matched as a substring against the request URL. First match wins. */
  match: string;
  status?: number;
  json?: unknown;
  text?: string;
  delayMilliseconds?: number;
}

export interface StubbedFetch {
  calls: StubbedFetchCall[];
  restore: () => void;
}

/**
 * Replaces the global `fetch` with a fake that matches request URLs against
 * `routes` and records every call. An unmatched URL throws loudly instead of
 * silently returning something usable — that's the difference between a test
 * that proves we called the right endpoint and one that just proves *some*
 * fetch happened.
 */
export function stubFetch(routes: StubbedFetchRoute[]): StubbedFetch {
  const originalFetch = globalThis.fetch;
  const calls: StubbedFetchCall[] = [];

  globalThis.fetch = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = init?.method ?? "GET";
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, key) => {
      headers[key.toLowerCase()] = value;
    });
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;

    calls.push({ url, method, headers, body });

    const route = routes.find((candidate) => url.includes(candidate.match));
    if (!route) {
      throw new Error(`stubFetch: no route matched ${url}`);
    }

    if (route.delayMilliseconds) {
      await new Promise((resolve) => setTimeout(resolve, route.delayMilliseconds));
    }

    const status = route.status ?? 200;
    const responseBody = route.text ?? JSON.stringify(route.json ?? {});
    return new Response(responseBody, {
      status,
      headers: { "Content-Type": "application/json" },
    });
  }) as typeof fetch;

  return {
    calls,
    restore: () => {
      globalThis.fetch = originalFetch;
    },
  };
}
