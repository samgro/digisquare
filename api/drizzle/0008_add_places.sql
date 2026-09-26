-- HAND-EDITED. drizzle-kit generated a bare
--   ALTER TABLE "checkins" ADD COLUMN "place_id" uuid NOT NULL;
-- which fails on any existing checkin. This version backfills a `places` row
-- for every Google place the old checkins referenced (from the snapshot each
-- checkin already carries), points the checkins at those rows, and only then
-- drops `google_place_id`. Nothing is deleted; every old checkin keeps its
-- place, and places that used to share a Google id share a row, so visit
-- counts and history ranking carry over.
--
-- Google's place types are renamed to the closest Overture category so the
-- app's footprint and icon tables keep matching them. Anything without a
-- counterpart is kept as-is: it just matches no table, like an unknown
-- Overture category would.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
--> statement-breakpoint
CREATE TABLE "places" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"source" text NOT NULL,
	"overture_id" text,
	"google_place_id" text,
	"name" text NOT NULL,
	"primary_type" text,
	"types" text[] DEFAULT '{}'::text[] NOT NULL,
	"address_street" text,
	"address_locality" text,
	"address_region" text,
	"address_postcode" text,
	"address_country" text,
	"latitude" double precision,
	"longitude" double precision,
	"confidence" double precision,
	"website" text,
	"phone" text,
	"created_by_user_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "places_source_check" CHECK ("places"."source" in ('overture', 'user', 'google')),
	CONSTRAINT "places_source_identifier_check" CHECK (("places"."source" = 'overture') = ("places"."overture_id" is not null) and ("places"."source" = 'google') = ("places"."google_place_id" is not null))
);
--> statement-breakpoint
ALTER TABLE "places" ADD CONSTRAINT "places_created_by_user_id_users_id_fk" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "places_overture_id_unique_idx" ON "places" USING btree ("overture_id");--> statement-breakpoint
CREATE UNIQUE INDEX "places_google_place_id_unique_idx" ON "places" USING btree ("google_place_id");--> statement-breakpoint
CREATE INDEX "places_latitude_longitude_idx" ON "places" USING btree ("latitude","longitude");--> statement-breakpoint
CREATE INDEX "places_name_trgm_idx" ON "places" USING gin (lower("name") gin_trgm_ops);--> statement-breakpoint
CREATE INDEX "places_created_by_user_id_idx" ON "places" USING btree ("created_by_user_id");--> statement-breakpoint
-- Backfill. The most recent checkin at each Google place supplies the
-- snapshot, and Google's "street, city, region postcode, country" formatted
-- address is split into the same parts an Overture address has.
CREATE TEMPORARY TABLE "google_type_mapping" ("google_type" text PRIMARY KEY, "overture_type" text NOT NULL);
--> statement-breakpoint
INSERT INTO "google_type_mapping" VALUES
	('international_airport', 'airport'),
	('stadium', 'stadium_arena'),
	('university', 'college_university'),
	('shopping_mall', 'shopping_center'),
	('transit_station', 'public_transportation'),
	('subway_station', 'light_rail_and_subway_stations'),
	('bus_stop', 'bus_station'),
	('city_hall', 'town_hall'),
	('local_government_office', 'local_and_state_government_offices'),
	('government_office', 'government_services'),
	('association_or_organization', 'public_and_government_association'),
	('consultant', 'professional_services'),
	('service', 'professional_services'),
	('finance', 'financial_service'),
	('atm', 'atms'),
	('public_bathroom', 'public_restrooms'),
	('electric_vehicle_charging_station', 'ev_charging_station'),
	('storage', 'self_storage_facility'),
	('movie_theater', 'cinema'),
	('performing_arts_theater', 'theatre'),
	('lodging', 'hotel'),
	('resort_hotel', 'resort'),
	('sports_complex', 'sports_and_recreation_venue'),
	('fitness_center', 'gym'),
	('night_club', 'dance_club'),
	('tea_house', 'tea_room'),
	('hiking_area', 'hiking_trail'),
	('warehouse_store', 'wholesale_store'),
	('store', 'shopping'),
	('tourist_attraction', 'attractions_and_activities'),
	('convention_center', 'convention_and_exhibition_center');
--> statement-breakpoint
INSERT INTO "places" (
	"source", "google_place_id", "name", "primary_type", "types",
	"address_street", "address_locality", "address_region", "address_postcode", "address_country",
	"latitude", "longitude", "created_at", "updated_at"
)
SELECT
	'google',
	"latest"."google_place_id",
	"latest"."place_name",
	COALESCE((SELECT "overture_type" FROM "google_type_mapping" WHERE "google_type" = "latest"."place_primary_type"), "latest"."place_primary_type"),
	COALESCE(
		(
			-- Mapped in order, without duplicates: international_airport and
			-- airport both map to airport.
			SELECT array_agg("mapped"."overture_type" ORDER BY "mapped"."first_ordinality")
			FROM (
				SELECT COALESCE("mapping"."overture_type", "original"."google_type") AS "overture_type", MIN("original"."ordinality") AS "first_ordinality"
				FROM unnest("latest"."place_types") WITH ORDINALITY AS "original" ("google_type", "ordinality")
				LEFT JOIN "google_type_mapping" AS "mapping" ON "mapping"."google_type" = "original"."google_type"
				GROUP BY 1
			) AS "mapped"
		),
		'{}'::text[]
	),
	NULLIF(BTRIM("parts"."street"), ''),
	NULLIF(BTRIM("parts"."locality"), ''),
	NULLIF(SPLIT_PART(BTRIM("parts"."region_postcode"), ' ', 1), ''),
	NULLIF(SUBSTRING(BTRIM("parts"."region_postcode") FROM '\s(\S+)$'), ''),
	CASE BTRIM("parts"."country") WHEN 'USA' THEN 'US' WHEN 'UK' THEN 'GB' ELSE NULLIF(BTRIM("parts"."country"), '') END,
	"latest"."latitude",
	"latest"."longitude",
	"latest"."created_at",
	"latest"."created_at"
FROM (
	SELECT DISTINCT ON ("google_place_id") *
	FROM "checkins"
	ORDER BY "google_place_id", "created_at" DESC
) AS "latest"
CROSS JOIN LATERAL (
	SELECT
		string_to_array("latest"."place_address", ',') AS "components",
		array_length(string_to_array("latest"."place_address", ','), 1) AS "count"
) AS "split"
CROSS JOIN LATERAL (
	-- Google's formatted address drops the parts it does not have:
	-- "450 10th St, San Francisco, CA 94103, USA" for a storefront but
	-- "San Francisco, CA 94128, USA" for an airport and "Pier 39" on its own.
	-- It also adds them: "Fox Plaza, 1390 Market St, San Francisco, CA 94102,
	-- USA" names the building first. So the last three parts are always the
	-- locality, region and postcode, and country, and everything before them
	-- is the street.
	SELECT
		CASE WHEN "split"."count" >= 4 THEN array_to_string("split"."components"[1:"split"."count" - 3], ',') WHEN "split"."count" = 1 THEN "split"."components"[1] END AS "street",
		CASE WHEN "split"."count" >= 4 THEN "split"."components"["split"."count" - 2] WHEN "split"."count" IN (2, 3) THEN "split"."components"[1] END AS "locality",
		CASE WHEN "split"."count" >= 3 THEN "split"."components"["split"."count" - 1] END AS "region_postcode",
		CASE WHEN "split"."count" >= 2 THEN "split"."components"["split"."count"] END AS "country"
) AS "parts";
--> statement-breakpoint
DROP TABLE "google_type_mapping";
--> statement-breakpoint
DROP INDEX "checkins_google_place_id_idx";--> statement-breakpoint
ALTER TABLE "checkins" ADD COLUMN "place_id" uuid;--> statement-breakpoint
UPDATE "checkins" SET "place_id" = "places"."id" FROM "places" WHERE "places"."google_place_id" = "checkins"."google_place_id";--> statement-breakpoint
ALTER TABLE "checkins" ALTER COLUMN "place_id" SET NOT NULL;--> statement-breakpoint
ALTER TABLE "checkins" ADD COLUMN "place_locality" text;--> statement-breakpoint
UPDATE "checkins" SET "place_locality" = "places"."address_locality" FROM "places" WHERE "places"."id" = "checkins"."place_id";--> statement-breakpoint
ALTER TABLE "checkins" ADD CONSTRAINT "checkins_place_id_places_id_fk" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "checkins_place_id_idx" ON "checkins" USING btree ("place_id");--> statement-breakpoint
ALTER TABLE "checkins" DROP COLUMN "google_place_id";
