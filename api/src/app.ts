import { Hono } from "hono";
import type { AppEnv } from "./types.js";
import { auth } from "./routes/auth.js";
import { places } from "./routes/places.js";
import { users } from "./routes/users.js";
import { checkins } from "./routes/checkins.js";

export const app = new Hono<AppEnv>();

app.get("/", (context) => context.json({ status: "ok" }));
// Open. Everything under /users and /checkins applies requireAuth inside
// its own router.
app.route("/auth", auth);
app.route("/places", places);
app.route("/users", users);
app.route("/checkins", checkins);
