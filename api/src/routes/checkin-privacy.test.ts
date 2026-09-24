import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createTestDatabase } from "../../test/helpers/test-database.js";
import { checkins, friendships, users } from "../db/schema.js";
import { createAccessToken } from "../lib/tokens.js";

// Runs against real Postgres rather than the stub, because what this proves
// is that the SQL hides strangers' checkins.
const testDatabase = await createTestDatabase();

vi.mock("../db/index.js", () => ({ database: testDatabase.database }));

const { app } = await import("../app.js");

const SESSION_ID = "22222222-2222-2222-2222-222222222222";
const PLACE_ID = "shared-place";

// You, and someone in every relationship you can have with another user.
const PEOPLE = {
  you: "10000000-0000-4000-8000-000000000000",
  friendWhoAskedYou: "20000000-0000-4000-8000-000000000000",
  friendYouAsked: "30000000-0000-4000-8000-000000000000",
  pendingRequestToYou: "40000000-0000-4000-8000-000000000000",
  pendingRequestFromYou: "50000000-0000-4000-8000-000000000000",
  declinedByYou: "60000000-0000-4000-8000-000000000000",
  stranger: "70000000-0000-4000-8000-000000000000",
} as const;

type Person = keyof typeof PEOPLE;

const VISIBLE: Person[] = ["you", "friendWhoAskedYou", "friendYouAsked"];
const HIDDEN: Person[] = [
  "pendingRequestToYou",
  "pendingRequestFromYou",
  "declinedByYou",
  "stranger",
];

// Each person's one checkin, all at the same place, keyed by who made it.
const checkinIds = {} as Record<Person, string>;

const accessToken = await createAccessToken(PEOPLE.you, SESSION_ID);

function get(path: string) {
  return app.request(path, { headers: { Authorization: `Bearer ${accessToken}` } });
}

async function resultOwners(path: string): Promise<Person[]> {
  const response = await get(path);
  expect(response.status).toBe(200);
  const body = (await response.json()) as { results: { userId: string }[] };
  const people = Object.entries(PEOPLE) as [Person, string][];
  return body.results
    .map((result) => people.find(([, userId]) => userId === result.userId)![0])
    .sort();
}

beforeAll(async () => {
  const { database } = testDatabase;

  await database.insert(users).values(
    Object.entries(PEOPLE).map(([person, userId]) => ({
      id: userId,
      email: `${person}@example.com`,
      passwordHash: "hash",
      name: person,
    })),
  );

  await database.insert(friendships).values([
    { requesterId: PEOPLE.friendWhoAskedYou, addresseeId: PEOPLE.you, status: "accepted" },
    { requesterId: PEOPLE.you, addresseeId: PEOPLE.friendYouAsked, status: "accepted" },
    { requesterId: PEOPLE.pendingRequestToYou, addresseeId: PEOPLE.you, status: "pending" },
    { requesterId: PEOPLE.you, addresseeId: PEOPLE.pendingRequestFromYou, status: "pending" },
    { requesterId: PEOPLE.declinedByYou, addresseeId: PEOPLE.you, status: "declined" },
    // The stranger's friends are not your friends.
    { requesterId: PEOPLE.stranger, addresseeId: PEOPLE.friendYouAsked, status: "accepted" },
  ]);

  const created = await database
    .insert(checkins)
    .values(
      Object.entries(PEOPLE).map(([person, userId]) => ({
        userId,
        googlePlaceId: PLACE_ID,
        placeName: "Blue Bottle",
        message: `${person} was here`,
      })),
    )
    .returning();
  for (const [person, userId] of Object.entries(PEOPLE) as [Person, string][]) {
    checkinIds[person] = created.find((checkin) => checkin.userId === userId)!.id;
  }
});

afterAll(async () => {
  await testDatabase.close();
});

describe("checkin privacy", () => {
  it("shows only your own and your friends' checkins in the feed", async () => {
    expect(await resultOwners("/friends/checkins?limit=100")).toEqual([...VISIBLE].sort());
  });

  it("shows only your own and your friends' checkins in the list", async () => {
    expect(await resultOwners("/checkins?limit=100")).toEqual([...VISIBLE].sort());
  });

  it("hides strangers from a place's checkins", async () => {
    expect(await resultOwners(`/checkins?googlePlaceId=${PLACE_ID}&limit=100`)).toEqual(
      [...VISIBLE].sort(),
    );
  });

  it.each(HIDDEN)("lists no checkins for %s", async (person) => {
    expect(await resultOwners(`/checkins?userId=${PEOPLE[person]}`)).toEqual([]);
  });

  it.each(VISIBLE)("lists the checkins of %s", async (person) => {
    expect(await resultOwners(`/checkins?userId=${PEOPLE[person]}`)).toEqual([person]);
  });

  it.each(HIDDEN)("answers 404 for a checkin by %s", async (person) => {
    const response = await get(`/checkins/${checkinIds[person]}`);
    expect(response.status).toBe(404);
  });

  it.each(VISIBLE)("returns a checkin by %s", async (person) => {
    const response = await get(`/checkins/${checkinIds[person]}`);
    expect(response.status).toBe(200);
  });

  it("will not edit a friend's checkin", async () => {
    const response = await app.request(`/checkins/${checkinIds.friendYouAsked}`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ message: "edited" }),
    });
    expect(response.status).toBe(404);

    const unchanged = await get(`/checkins/${checkinIds.friendYouAsked}`);
    const body = (await unchanged.json()) as { message: string };
    expect(body.message).toBe("friendYouAsked was here");
  });
});
