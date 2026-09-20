import { pgTable, uuid, text, doublePrecision, timestamp, index } from "drizzle-orm/pg-core";

export const checkins = pgTable(
  "checkins",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    userId: text("user_id").notNull(),

    googlePlaceId: text("google_place_id").notNull(),
    placeName: text("place_name").notNull(),
    placeAddress: text("place_address"),
    placePrimaryType: text("place_primary_type"),
    placeTypes: text("place_types").array(),
    latitude: doublePrecision("latitude"),
    longitude: doublePrecision("longitude"),

    message: text("message"),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    index("checkins_user_id_idx").on(table.userId),
    index("checkins_google_place_id_idx").on(table.googlePlaceId),
  ],
);
