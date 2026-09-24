/**
 * Seeds the test users in src/lib/test-users.ts, each with a checkin at a real
 * branch of every seeded chain in their home city, and makes them all friends.
 *
 * Safe to run repeatedly: the users are upserted by fixed id, and their
 * checkins and friendships with each other are replaced each run.
 *
 *   ENABLE_TEST_USERS=true npm run db:seed-test-users
 */
import { and, inArray, sql } from "drizzle-orm";
import { config } from "../src/config.js";
import { database } from "../src/db/index.js";
import {
  checkins as checkinsTable,
  friendships as friendshipsTable,
  users as usersTable,
} from "../src/db/schema.js";
import { searchText, type GooglePlace } from "../src/lib/google-places.js";
import {
  SEEDED_CHAINS,
  SEEDED_CHECKIN_MESSAGES,
  SEEDED_TEST_USERS,
  type SeededTestUser,
} from "../src/lib/test-users.js";

const SEARCH_RADIUS_METERS = 10_000;
const SEEDED_HISTORY_DAYS = 21;

if (!config.ENABLE_TEST_USERS) {
  console.error(
    "Refusing to seed: ENABLE_TEST_USERS is not set, so this database is not meant to have test users.",
  );
  process.exit(1);
}

/** The nearest search result that is actually a branch of the chain. */
async function findBranch(chain: string, testUser: SeededTestUser): Promise<GooglePlace | null> {
  const results = await searchText({
    query: chain,
    latitude: testUser.homeCity.latitude,
    longitude: testUser.homeCity.longitude,
    radius: SEARCH_RADIUS_METERS,
  });
  return (
    results.find((place) =>
      place.displayName?.text.toLowerCase().includes(chain.toLowerCase()),
    ) ?? null
  );
}

/** Spreads checkins over the past few weeks so the timeline looks lived in. */
function seededCheckinTime(userIndex: number, chainIndex: number): Date {
  const daysAgo = (chainIndex * 4 + userIndex) % SEEDED_HISTORY_DAYS;
  const hoursAgo = daysAgo * 24 + ((chainIndex * 5 + userIndex * 3) % 12);
  return new Date(Date.now() - hoursAgo * 3_600_000);
}

async function seed() {
  const testUserIds = SEEDED_TEST_USERS.map((testUser) => testUser.id);

  await database
    .insert(usersTable)
    .values(
      SEEDED_TEST_USERS.map((testUser) => ({
        id: testUser.id,
        name: testUser.name,
        isTestUser: true,
      })),
    )
    .onConflictDoUpdate({
      target: usersTable.id,
      set: { name: sql`excluded.name`, isTestUser: true },
    });
  console.log(`Upserted ${SEEDED_TEST_USERS.length} test users`);

  const checkinValues: (typeof checkinsTable.$inferInsert)[] = [];
  for (const [userIndex, testUser] of SEEDED_TEST_USERS.entries()) {
    for (const [chainIndex, chain] of SEEDED_CHAINS.entries()) {
      const place = await findBranch(chain, testUser);
      if (!place) {
        console.warn(`No ${chain} found near ${testUser.homeCity.name}; skipping`);
        continue;
      }

      const checkinNumber = userIndex * SEEDED_CHAINS.length + chainIndex;
      checkinValues.push({
        userId: testUser.id,
        googlePlaceId: place.id,
        placeName: place.displayName?.text ?? chain,
        placeAddress: place.formattedAddress ?? null,
        placePrimaryType: place.primaryType ?? null,
        placeTypes: place.types ?? null,
        latitude: place.location?.latitude ?? null,
        longitude: place.location?.longitude ?? null,
        message:
          checkinNumber % 2 === 0
            ? SEEDED_CHECKIN_MESSAGES[(checkinNumber / 2) % SEEDED_CHECKIN_MESSAGES.length]
            : null,
        createdAt: seededCheckinTime(userIndex, chainIndex),
      });
      console.log(`  ${testUser.name}: ${place.displayName?.text} — ${place.formattedAddress}`);
    }
  }

  const friendshipValues: (typeof friendshipsTable.$inferInsert)[] = [];
  for (const [index, requesterId] of testUserIds.entries()) {
    for (const addresseeId of testUserIds.slice(index + 1)) {
      friendshipValues.push({ requesterId, addresseeId, status: "accepted" });
    }
  }

  // Replace rather than merge, so a rerun leaves exactly one checkin per
  // chain and friendships that are accepted even if someone changed them.
  await database.batch([
    database.delete(checkinsTable).where(inArray(checkinsTable.userId, testUserIds)),
    database
      .delete(friendshipsTable)
      .where(
        and(
          inArray(friendshipsTable.requesterId, testUserIds),
          inArray(friendshipsTable.addresseeId, testUserIds),
        ),
      ),
    database.insert(checkinsTable).values(checkinValues),
    database.insert(friendshipsTable).values(friendshipValues),
  ]);
  console.log(
    `Seeded ${checkinValues.length} checkins and ${friendshipValues.length} friendships`,
  );
}

await seed();
