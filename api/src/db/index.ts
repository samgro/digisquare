import { neon } from "@neondatabase/serverless";
import { config } from "../config.js";
import { drizzle } from "drizzle-orm/neon-http";
import * as schema from "./schema.js";

const neonClient = neon(config.DATABASE_URL);

export const database = drizzle(neonClient, { schema });
