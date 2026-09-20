import "dotenv/config";
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { places } from "./routes/places.js";
import { checkins } from "./routes/checkins.js";

const app = new Hono();

app.get("/", (context) => context.json({ status: "ok" }));
app.route("/places", places);
app.route("/checkins", checkins);

const port = Number(process.env.PORT) || 3000;

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`Server running at http://localhost:${info.port}`);
});
