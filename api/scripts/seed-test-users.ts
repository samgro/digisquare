/**
 * Seeds the test users in src/lib/test-users.ts, each with a checkin at a real
 * branch of every seeded chain in their home city, and makes them all friends.
 * Some checkins are private and some came from accepted visit suggestions, so
 * the lock icon and the friends feed's privacy rule can be checked by signing
 * in as one user and then as a friend.
 *
 * The branches come from the `places` table. Any of the home cities not
 * loaded yet are fetched from Overture first, the same way `coverage:seed`
 * loads a region, so this needs OVERTURE_RELEASE too. A chain with no branch
 * there is skipped with a warning.
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
import { cellsAround } from "../src/lib/coverage-cells.js";
import { seedCellsNow } from "../src/lib/coverage-worker.js";
import { closeOvertureSource, s3Source } from "../src/lib/overture-remote.js";
import { formatAddress } from "../src/lib/place-result.js";
import { searchByName, type PlaceCandidate } from "../src/lib/places-search.js";
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
async function findBranch(chain: string, testUser: SeededTestUser): Promise<PlaceCandidate | null> {
  const results = await searchByName({
    query: chain,
    latitude: testUser.homeCity.latitude,
    longitude: testUser.homeCity.longitude,
    radius: SEARCH_RADIUS_METERS,
    viewerUserId: testUser.id,
  });
  return (
    results.find((place) =>
      place.name.toLowerCase().includes(chain.toLowerCase()),
    ) ?? null
  );
}

/** Spreads checkins over the past few weeks so the timeline looks lived in. */
function seededCheckinTime(userIndex: number, chainIndex: number): Date {
  const daysAgo = (chainIndex * 4 + userIndex) % SEEDED_HISTORY_DAYS;
  const hoursAgo = daysAgo * 24 + ((chainIndex * 5 + userIndex * 3) % 12);
  return new Date(Date.now() - hoursAgo * 3_600_000);
}

async function loadHomeCities() {
  const source = s3Source(config.OVERTURE_RELEASE);
  for (const testUser of SEEDED_TEST_USERS) {
    const { latitude, longitude, name } = testUser.homeCity;
    const fetched = await seedCellsNow(source, cellsAround(latitude, longitude, SEARCH_RADIUS_METERS));
    console.log(`${name}: ${fetched ? "fetched from Overture" : "already loaded"}`);
  }
  await closeOvertureSource(source);
}

async function seed() {
  await loadHomeCities();

  const testUserIds = SEEDED_TEST_USERS.map((testUser) => testUser.id);

  await database
    .insert(usersTable)
    .values(
      SEEDED_TEST_USERS.map((testUser) => ({
        id: testUser.id,
        name: testUser.name,
        // Required to get past profile setup, so a seeded user signs
        // straight in to the app.
        hometown: testUser.homeCity.name,
        isTestUser: true,
      })),
    )
    .onConflictDoUpdate({
      target: usersTable.id,
      set: { name: sql`excluded.name`, hometown: sql`excluded.hometown`, isTestUser: true },
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
        placeId: place.id,
        placeName: place.name,
        placeAddress: formatAddress(place),
        placeLocality: place.addressLocality,
        placeRegion: place.addressRegion,
        placeCountry: place.addressCountry,
        placePrimaryType: place.primaryType,
        placeTypes: place.types,
        latitude: place.latitude,
        longitude: place.longitude,
        message:
          checkinNumber % 2 === 0
            ? SEEDED_CHECKIN_MESSAGES[(checkinNumber / 2) % SEEDED_CHECKIN_MESSAGES.length]
            : null,
        visibility: checkinNumber % 3 === 1 ? "private" : "friends",
        source: checkinNumber % 4 === 2 ? "visit" : "manual",
        createdAt: seededCheckinTime(userIndex, chainIndex),
      });
      console.log(`  ${testUser.name}: ${place.name} — ${formatAddress(place)}`);
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
