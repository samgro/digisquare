import { Hono } from "hono";
import { places } from "./routes/places.js";
import { checkins } from "./routes/checkins.js";

export const app = new Hono();

app.get("/", (context) => context.json({ status: "ok" }));
app.route("/places", places);
app.route("/checkins", checkins);
