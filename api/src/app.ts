import { Hono } from "hono";
import type { AppEnv } from "./types.js";
import { currentBuildIdentity } from "./lib/build-identity.js";
import { buildGate } from "./middleware/build-gate.js";
import { auth } from "./routes/auth.js";
import { places } from "./routes/places.js";
import { users } from "./routes/users.js";
import { checkins } from "./routes/checkins.js";
import { friends } from "./routes/friends.js";
import { notifications } from "./routes/notifications.js";
import { testUsers } from "./routes/test-users.js";
import { swarmImports } from "./routes/swarm-imports.js";

export const app = new Hono<AppEnv>();

// First, so a Debug simulator build from another checkout is refused before
// any route can touch the database.
app.use("*", buildGate);

app.get("/", async (context) => {
  const build = await currentBuildIdentity();
  return context.json({ status: "ok", build: build ? { branch: build.branch, commit: build.commit } : null });
});
// Open. Everything under /users, /checkins, /friends, /notifications and
// /imports/swarm applies requireAuth inside its own router (the Swarm OAuth
// callback aside, which Foursquare's redirect reaches with no token).
app.route("/auth", auth);
// Answers 404 unless ENABLE_TEST_USERS is set.
app.route("/auth/test-users", testUsers);
app.route("/places", places);
app.route("/users", users);
app.route("/checkins", checkins);
app.route("/friends", friends);
app.route("/notifications", notifications);
app.route("/imports/swarm", swarmImports);
