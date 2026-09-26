import { afterEach, describe, expect, it } from "vitest";
import { loadFoursquareFixture } from "../../test/helpers/fixtures.js";
import { stubFetch, type StubbedFetch } from "../../test/helpers/stub-fetch.js";
import {
  authorizationUrl,
  fetchCategories,
  fetchCheckinsPage,
  fetchSelf,
  FoursquareError,
  photoUrl,
  retryDelayMilliseconds,
} from "./foursquare.js";

let fetchStub: StubbedFetch | undefined;

afterEach(() => {
  fetchStub?.restore();
  fetchStub = undefined;
});

describe("fetchCheckinsPage", () => {
  it("pages by timestamp with the pinned version and a bearer token", async () => {
    fetchStub = stubFetch([
      { match: "/users/self/checkins", json: loadFoursquareFixture("checkins-page.json") },
    ]);

    await fetchCheckinsPage("user-token", { beforeTimestamp: 1600000001, afterTimestamp: null });

    const url = new URL(fetchStub.calls[0]!.url);
    expect(url.searchParams.get("v")).toBe("20260223");
    expect(url.searchParams.get("limit")).toBe("250");
    expect(url.searchParams.get("sort")).toBe("newestfirst");
    expect(url.searchParams.get("beforeTimestamp")).toBe("1600000001");
    expect(url.searchParams.has("afterTimestamp")).toBe(false);
    expect(url.searchParams.has("offset")).toBe(false);
    expect(fetchStub.calls[0]!.headers.authorization).toBe("Bearer user-token");
  });

  it("skips a checkin that does not parse and keeps the raw payload of the rest", async () => {
    fetchStub = stubFetch([
      { match: "/users/self/checkins", json: loadFoursquareFixture("checkins-page.json") },
    ]);

    const page = await fetchCheckinsPage("user-token", {});

    expect(page.checkins.map((checkin) => checkin.id)).toEqual([
      "5f1a2b3c4d5e6f7a8b9c0d1e",
      "5f1a2b3c4d5e6f7a8b9c0d1f",
    ]);
    // Fields the importer does not model survive in the raw payload.
    expect(page.rawCheckinsById.get("5f1a2b3c4d5e6f7a8b9c0d1e")).toMatchObject({
      isMayor: true,
      with: [{ firstName: "Alex" }],
    });
  });

  it("does not retry a rejected token", async () => {
    fetchStub = stubFetch([
      {
        match: "/users/self/checkins",
        status: 401,
        json: { meta: { code: 401, errorType: "invalid_auth", errorDetail: "OAuth token invalid" } },
      },
    ]);

    await expect(fetchCheckinsPage("user-token", {})).rejects.toBeInstanceOf(FoursquareError);
    expect(fetchStub.calls).toHaveLength(1);
  });
});

describe("fetchCategories", () => {
  it("flattens the tree, keeping each category's parent", async () => {
    fetchStub = stubFetch([
      { match: "/venues/categories", json: loadFoursquareFixture("categories.json") },
    ]);

    const categories = await fetchCategories("user-token");

    const hotpot = categories.find((category) => category.name === "Hotpot Restaurant");
    expect(hotpot).toEqual({
      id: "52af0bd33cf9994f4e043bdd",
      name: "Hotpot Restaurant",
      pluralName: "Hotpot Restaurants",
      shortName: "Hotpot",
      categoryCode: 13196,
      parentId: "4bf58dd8d48988d142941735",
      iconPrefix: expect.any(String),
      iconSuffix: ".png",
    });
    const topLevel = categories.find((category) => category.name === "Dining and Drinking");
    expect(topLevel?.parentId).toBeNull();
  });
});

describe("retryDelayMilliseconds", () => {
  it("prefers Retry-After", () => {
    expect(retryDelayMilliseconds(new Headers({ "Retry-After": "3" }), 0)).toBe(3000);
  });

  it("waits until the rate limit resets", () => {
    const now = 1_700_000_000_000;
    const headers = new Headers({ "X-RateLimit-Reset": String(now / 1000 + 5) });
    expect(retryDelayMilliseconds(headers, 0, now)).toBe(5000);
  });

  it("backs off exponentially, capped at a minute", () => {
    expect(retryDelayMilliseconds(new Headers(), 0)).toBe(1000);
    expect(retryDelayMilliseconds(new Headers(), 3)).toBe(8000);
    expect(retryDelayMilliseconds(new Headers(), 20)).toBe(60_000);
  });
});

describe("urls", () => {
  it("builds a full-size photo url", () => {
    expect(
      photoUrl({ prefix: "https://fastly.4sqi.net/img/general/", suffix: "/1234_first.jpg" }),
    ).toBe("https://fastly.4sqi.net/img/general/original/1234_first.jpg");
  });

  it("builds an authorization url carrying the state", () => {
    const url = new URL(
      authorizationUrl({
        clientId: "client",
        redirectUrl: "https://api.test.invalid/imports/swarm/callback",
        state: "signed-state",
      }),
    );
    expect(url.origin + url.pathname).toBe("https://foursquare.com/oauth2/authenticate");
    expect(url.searchParams.get("response_type")).toBe("code");
    expect(url.searchParams.get("redirect_uri")).toBe(
      "https://api.test.invalid/imports/swarm/callback",
    );
    expect(url.searchParams.get("state")).toBe("signed-state");
  });
});

describe("fetchSelf", () => {
  it("returns the user's id and how many checkins they have", async () => {
    fetchStub = stubFetch([
      {
        match: "/users/self",
        json: { meta: { code: 200 }, response: { user: { id: "12345", checkins: { count: 3812 } } } },
      },
    ]);

    expect(await fetchSelf("token")).toEqual({ id: "12345", checkinCount: 3812 });
  });

  it("leaves the count null when Foursquare does not send one", async () => {
    fetchStub = stubFetch([
      { match: "/users/self", json: { meta: { code: 200 }, response: { user: { id: "12345" } } } },
    ]);

    expect(await fetchSelf("token")).toEqual({ id: "12345", checkinCount: null });
  });
});
