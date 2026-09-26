ALTER TABLE "checkins" ADD COLUMN "place_region" text;--> statement-breakpoint
ALTER TABLE "checkins" ADD COLUMN "place_country" text;--> statement-breakpoint
CREATE INDEX "checkins_user_id_created_at_id_idx" ON "checkins" USING btree ("user_id","created_at","id");--> statement-breakpoint
CREATE INDEX "checkins_user_id_updated_at_id_idx" ON "checkins" USING btree ("user_id","updated_at","id");--> statement-breakpoint
-- Places carried over from Google hold the region as it appeared in the
-- address line ("CA"). Put the US-style ones in Overture's ISO 3166-2 shape
-- ("US-CA") so a state groups the same way whichever source a place came
-- from. Anything that does not look like a subdivision code is left alone.
UPDATE "places" SET "address_region" = "address_country" || '-' || "address_region"
WHERE "source" = 'google'
	AND "address_country" ~ '^[A-Z]{2}$'
	AND "address_region" ~ '^[A-Z0-9]{1,3}$';--> statement-breakpoint
-- Existing checkins take their region and country from the place they point
-- at. A plain UPDATE leaves updated_at alone, which is fine: no client has
-- synced these columns yet.
UPDATE "checkins" SET "place_region" = "places"."address_region", "place_country" = "places"."address_country"
FROM "places"
WHERE "places"."id" = "checkins"."place_id";
