import { Hono } from "hono";
import type { AppEnv } from "./types.js";
import { auth } from "./routes/auth.js";
import { places } from "./routes/places.js";
import { users } from "./routes/users.js";
import { checkins } from "./routes/checkins.js";
import { friends } from "./routes/friends.js";
import { testUsers } from "./routes/test-users.js";

export const app = new Hono<AppEnv>();

app.get("/", (context) => context.json({ status: "ok" }));
// Open. Everything under /users, /checkins and /friends applies requireAuth
// inside its own router.
app.route("/auth", auth);
// Answers 404 unless ENABLE_TEST_USERS is set.
app.route("/auth/test-users", testUsers);
app.route("/places", places);
app.route("/users", users);
app.route("/checkins", checkins);
app.route("/friends", friends);
