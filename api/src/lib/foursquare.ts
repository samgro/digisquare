import { z } from "zod";

/**
 * A client for Foursquare's v2 API, which is what Swarm history lives behind.
 * Every call is made with a user's OAuth token; the newer Places API cannot
 * read anyone's checkins.
 */

const API_BASE_URL = "https://api.foursquare.com/v2";
const OAUTH_BASE_URL = "https://foursquare.com/oauth2";

// v2 responses are shaped by this date rather than by the path. Foursquare
// asks for a fixed date, never today's, so the shape cannot shift under us.
export const FOURSQUARE_API_VERSION = "20260223";

// The documented maximum page size for /users/self/checkins.
export const CHECKINS_PAGE_SIZE = 250;

const MAX_ATTEMPTS = 6;
const MAX_RETRY_DELAY_MILLISECONDS = 60_000;

export class FoursquareError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly errorType?: string,
  ) {
    super(message);
    this.name = "FoursquareError";
  }
}

const iconSchema = z.object({ prefix: z.string(), suffix: z.string() });

const venueCategorySchema = z.object({
  id: z.string(),
  name: z.string(),
  pluralName: z.string().optional(),
  shortName: z.string().optional(),
  icon: iconSchema.optional(),
  primary: z.boolean().optional(),
});

const venueSchema = z
  .object({
    id: z.string(),
    name: z.string(),
    location: z
      .object({
        address: z.string(),
        crossStreet: z.string(),
        city: z.string(),
        state: z.string(),
        postalCode: z.string(),
        cc: z.string(),
        country: z.string(),
        formattedAddress: z.array(z.string()),
        lat: z.number(),
        lng: z.number(),
      })
      .partial()
      .optional(),
    categories: z.array(venueCategorySchema).default([]),
  })
  .passthrough();

const photoSchema = z.object({
  id: z.string(),
  prefix: z.string(),
  suffix: z.string(),
  width: z.number().int().optional(),
  height: z.number().int().optional(),
});

/**
 * Only the fields the importer reads are declared. Everything else passes
 * through untouched and is stored whole in imported_checkin_payloads.
 */
const checkinSchema = z
  .object({
    id: z.string(),
    createdAt: z.number().int(),
    timeZoneOffset: z.number().int().optional(),
    shout: z.string().optional(),
    private: z.boolean().optional(),
    visibility: z.string().optional(),
    venue: venueSchema.optional(),
    photos: z.object({ items: z.array(photoSchema).default([]) }).optional(),
  })
  .passthrough();

export type FoursquareVenue = z.infer<typeof venueSchema>;
export type FoursquareCheckin = z.infer<typeof checkinSchema>;
export type FoursquarePhoto = z.infer<typeof photoSchema>;

interface CategoryTreeNode {
  id: string;
  name: string;
  pluralName?: string;
  shortName?: string;
  categoryCode?: number;
  icon?: z.infer<typeof iconSchema>;
  categories?: CategoryTreeNode[];
}

const categoryTreeNodeSchema: z.ZodType<CategoryTreeNode> = z.lazy(() =>
  z.object({
    id: z.string(),
    name: z.string(),
    pluralName: z.string().optional(),
    shortName: z.string().optional(),
    categoryCode: z.number().int().optional(),
    icon: iconSchema.optional(),
    categories: z.array(categoryTreeNodeSchema).optional(),
  }),
);

/** One node of the category tree, with its parent in place of its children. */
export interface FoursquareCategory {
  id: string;
  name: string;
  pluralName: string | null;
  shortName: string | null;
  categoryCode: number | null;
  parentId: string | null;
  iconPrefix: string | null;
  iconSuffix: string | null;
}

/** A full-size photo URL. Foursquare builds sizes as prefix + size + suffix. */
export function photoUrl(photo: Pick<FoursquarePhoto, "prefix" | "suffix">): string {
  return `${photo.prefix}original${photo.suffix}`;
}

export function authorizationUrl(options: {
  clientId: string;
  redirectUrl: string;
  state: string;
}): string {
  const url = new URL(`${OAUTH_BASE_URL}/authenticate`);
  url.searchParams.set("client_id", options.clientId);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("redirect_uri", options.redirectUrl);
  url.searchParams.set("state", options.state);
  return url.toString();
}

/** Trades the code from the OAuth redirect for a long-lived user token. */
export async function exchangeCode(options: {
  clientId: string;
  clientSecret: string;
  redirectUrl: string;
  code: string;
}): Promise<string> {
  const url = new URL(`${OAUTH_BASE_URL}/access_token`);
  url.searchParams.set("client_id", options.clientId);
  url.searchParams.set("client_secret", options.clientSecret);
  url.searchParams.set("grant_type", "authorization_code");
  url.searchParams.set("redirect_uri", options.redirectUrl);
  url.searchParams.set("code", options.code);

  const response = await fetch(url);
  const body = (await response.json().catch(() => null)) as { access_token?: unknown } | null;
  if (!response.ok || typeof body?.access_token !== "string") {
    throw new FoursquareError("Foursquare did not return an access token", response.status);
  }
  return body.access_token;
}

export interface FoursquareSelf {
  /** The Foursquare user id the token belongs to. */
  id: string;
  /** How many checkins they have in all, when Foursquare says. */
  checkinCount: number | null;
}

const selfSchema = z.object({
  user: z.object({
    id: z.string(),
    checkins: z.object({ count: z.number().int().nonnegative() }).optional(),
  }),
});

/** The user the token belongs to. */
export async function fetchSelf(accessToken: string): Promise<FoursquareSelf> {
  const response = await callApi(accessToken, "/users/self", {});
  const parsed = selfSchema.parse(response);
  return { id: parsed.user.id, checkinCount: parsed.user.checkins?.count ?? null };
}

/** The whole category tree, flattened. */
export async function fetchCategories(accessToken: string): Promise<FoursquareCategory[]> {
  const response = await callApi(accessToken, "/venues/categories", { locale: "en" });
  const parsed = z.object({ categories: z.array(categoryTreeNodeSchema) }).parse(response);
  return flattenCategoryTree(parsed.categories, null);
}

export function flattenCategoryTree(
  nodes: CategoryTreeNode[],
  parentId: string | null,
): FoursquareCategory[] {
  return nodes.flatMap((node) => [
    {
      id: node.id,
      name: node.name,
      pluralName: node.pluralName ?? null,
      shortName: node.shortName ?? null,
      categoryCode: node.categoryCode ?? null,
      parentId,
      iconPrefix: node.icon?.prefix ?? null,
      iconSuffix: node.icon?.suffix ?? null,
    },
    ...flattenCategoryTree(node.categories ?? [], node.id),
  ]);
}

export interface CheckinsPage {
  checkins: FoursquareCheckin[];
  /** Each checkin exactly as Foursquare sent it, keyed by id, for storage. */
  rawCheckinsById: Map<string, unknown>;
  /** How many items the page held, parsed or not. Zero means the history is done. */
  itemCount: number;
}

/**
 * One page of the user's checkins, newest first, strictly older than
 * `beforeTimestamp` (unix seconds) when given.
 *
 * Paged by timestamp rather than offset: Foursquare stops honouring offset
 * after a few hundred results and silently repeats the first page. A checkin
 * that fails to parse is skipped rather than failing the whole import.
 */
export async function fetchCheckinsPage(
  accessToken: string,
  options: { beforeTimestamp?: number | null; afterTimestamp?: number | null },
): Promise<CheckinsPage> {
  const parameters: Record<string, string> = {
    limit: String(CHECKINS_PAGE_SIZE),
    sort: "newestfirst",
  };
  if (options.beforeTimestamp) {
    parameters.beforeTimestamp = String(options.beforeTimestamp);
  }
  if (options.afterTimestamp) {
    parameters.afterTimestamp = String(options.afterTimestamp);
  }

  const response = await callApi(accessToken, "/users/self/checkins", parameters);
  const items = z
    .object({ checkins: z.object({ items: z.array(z.unknown()) }) })
    .parse(response).checkins.items;

  const checkins: FoursquareCheckin[] = [];
  const rawCheckinsById = new Map<string, unknown>();
  for (const item of items) {
    const parsed = checkinSchema.safeParse(item);
    if (!parsed.success) {
      console.warn("Skipping a Swarm checkin that did not parse", parsed.error.flatten());
      continue;
    }
    checkins.push(parsed.data);
    rawCheckinsById.set(parsed.data.id, item);
  }
  return { checkins, rawCheckinsById, itemCount: items.length };
}

/**
 * How long to wait before retrying a throttled or failed call: Retry-After if
 * Foursquare sent one, else until X-RateLimit-Reset, else exponential backoff.
 */
export function retryDelayMilliseconds(
  headers: Headers,
  attempt: number,
  now: number = Date.now(),
): number {
  const retryAfterSeconds = Number(headers.get("Retry-After"));
  if (headers.has("Retry-After") && Number.isFinite(retryAfterSeconds)) {
    return Math.min(retryAfterSeconds * 1000, MAX_RETRY_DELAY_MILLISECONDS);
  }

  const resetSeconds = Number(headers.get("X-RateLimit-Reset"));
  if (headers.has("X-RateLimit-Reset") && Number.isFinite(resetSeconds)) {
    return Math.min(Math.max(resetSeconds * 1000 - now, 0), MAX_RETRY_DELAY_MILLISECONDS);
  }

  return Math.min(1000 * 2 ** attempt, MAX_RETRY_DELAY_MILLISECONDS);
}

const envelopeSchema = z.object({
  meta: z.object({
    code: z.number(),
    errorType: z.string().optional(),
    errorDetail: z.string().optional(),
  }),
  response: z.unknown(),
});

async function callApi(
  accessToken: string,
  path: string,
  parameters: Record<string, string>,
): Promise<unknown> {
  const url = new URL(`${API_BASE_URL}${path}`);
  url.searchParams.set("v", FOURSQUARE_API_VERSION);
  for (const [name, value] of Object.entries(parameters)) {
    url.searchParams.set(name, value);
  }

  for (let attempt = 0; ; attempt += 1) {
    const response = await fetch(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    const body = envelopeSchema.safeParse(await response.json().catch(() => null));
    const errorType = body.success ? body.data.meta.errorType : undefined;

    if (response.ok && body.success) {
      return body.data.response;
    }

    const isRetryable =
      response.status === 429 || response.status >= 500 || errorType === "rate_limit_exceeded";
    if (!isRetryable || attempt + 1 >= MAX_ATTEMPTS) {
      const detail = body.success ? body.data.meta.errorDetail : undefined;
      throw new FoursquareError(
        detail ?? `Foursquare ${path} failed with ${response.status}`,
        response.status,
        errorType,
      );
    }

    await sleep(retryDelayMilliseconds(response.headers, attempt));
  }
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
