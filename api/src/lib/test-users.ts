export interface SeededTestUser {
  id: string;
  name: string;
  homeCity: { name: string; latitude: number; longitude: number };
}

/**
 * The test users scripts/seed-test-users.ts creates. The ids are fixed so the
 * seed can run any number of times and so Bruno can sign in as Alice by id.
 */
export const SEEDED_TEST_USERS: readonly SeededTestUser[] = [
  {
    id: "7e570000-0000-4000-8000-000000000001",
    name: "Alice Testberg",
    homeCity: { name: "San Francisco, CA", latitude: 37.7749, longitude: -122.4194 },
  },
  {
    id: "7e570000-0000-4000-8000-000000000002",
    name: "Bob Testman",
    homeCity: { name: "Austin, TX", latitude: 30.2672, longitude: -97.7431 },
  },
  {
    id: "7e570000-0000-4000-8000-000000000003",
    name: "Catherine Testeroo",
    homeCity: { name: "Chicago, IL", latitude: 41.8781, longitude: -87.6298 },
  },
  {
    id: "7e570000-0000-4000-8000-000000000004",
    name: "David Testtest",
    homeCity: { name: "New York, NY", latitude: 40.7128, longitude: -74.006 },
  },
];

/** Each test user gets one checkin at a real branch of each of these. */
export const SEEDED_CHAINS = ["Starbucks", "Target", "Chipotle", "Taco Bell", "Burger King"];

/** Used on roughly every other seeded checkin; the rest have no message. */
export const SEEDED_CHECKIN_MESSAGES = [
  "Quick stop on the way to work",
  "Treat yourself",
  "Here with the crew",
  "Late night run",
];
