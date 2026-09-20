import { neon } from "@neondatabase/serverless";
import { drizzle } from "drizzle-orm/neon-http";
import * as schema from "./schema.js";

const neonClient = neon(process.env.DATABASE_URL!);

export const database = drizzle(neonClient, { schema });
