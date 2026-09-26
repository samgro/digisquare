CREATE TABLE "checkin_photos" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"checkin_id" uuid NOT NULL,
	"position" integer DEFAULT 0 NOT NULL,
	"storage_key" text,
	"source_url" text,
	"external_id" text,
	"width" integer,
	"height" integer,
	"copy_failed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "checkin_photos_has_location_check" CHECK ("checkin_photos"."storage_key" is not null or "checkin_photos"."source_url" is not null)
);
--> statement-breakpoint
CREATE TABLE "foursquare_categories" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"plural_name" text,
	"short_name" text,
	"category_code" integer,
	"parent_id" text,
	"icon_prefix" text,
	"icon_suffix" text,
	"overture_category" text,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "foursquare_connections" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"foursquare_user_id" text NOT NULL,
	"access_token_ciphertext" text NOT NULL,
	"connected_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_imported_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "foursquare_venues" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"address" text,
	"cross_street" text,
	"city" text,
	"state" text,
	"postal_code" text,
	"country_code" text,
	"country" text,
	"formatted_address" text,
	"latitude" double precision,
	"longitude" double precision,
	"primary_category_id" text,
	"category_ids" text[],
	"raw" jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "imported_checkin_payloads" (
	"checkin_id" uuid PRIMARY KEY NOT NULL,
	"source" text NOT NULL,
	"payload" jsonb NOT NULL,
	"fetched_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "swarm_imports" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"status" text DEFAULT 'running' NOT NULL,
	"phase" text DEFAULT 'checkins' NOT NULL,
	"before_timestamp" integer,
	"after_timestamp" integer,
	"checkins_imported" integer DEFAULT 0 NOT NULL,
	"checkins_expected" integer,
	"photos_total" integer DEFAULT 0 NOT NULL,
	"photos_copied" integer DEFAULT 0 NOT NULL,
	"error" text,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"finished_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "places" DROP CONSTRAINT "places_source_check";--> statement-breakpoint
ALTER TABLE "places" DROP CONSTRAINT "places_source_identifier_check";--> statement-breakpoint
ALTER TABLE "checkins" ADD COLUMN "place_category_name" text;--> statement-breakpoint
ALTER TABLE "checkins" ADD COLUMN "external_id" text;--> statement-breakpoint
ALTER TABLE "checkins" ADD COLUMN "time_zone_offset_minutes" integer;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "foursquare_venue_id" text;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "category_name" text;--> statement-breakpoint
ALTER TABLE "checkin_photos" ADD CONSTRAINT "checkin_photos_checkin_id_checkins_id_fk" FOREIGN KEY ("checkin_id") REFERENCES "public"."checkins"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "foursquare_connections" ADD CONSTRAINT "foursquare_connections_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "imported_checkin_payloads" ADD CONSTRAINT "imported_checkin_payloads_checkin_id_checkins_id_fk" FOREIGN KEY ("checkin_id") REFERENCES "public"."checkins"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "swarm_imports" ADD CONSTRAINT "swarm_imports_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "checkin_photos_checkin_id_idx" ON "checkin_photos" USING btree ("checkin_id");--> statement-breakpoint
CREATE UNIQUE INDEX "checkin_photos_checkin_external_id_unique_idx" ON "checkin_photos" USING btree ("checkin_id","external_id");--> statement-breakpoint
CREATE INDEX "swarm_imports_user_id_started_at_idx" ON "swarm_imports" USING btree ("user_id","started_at" DESC NULLS LAST);--> statement-breakpoint
CREATE UNIQUE INDEX "swarm_imports_one_running_per_user_idx" ON "swarm_imports" USING btree ("user_id") WHERE "swarm_imports"."status" = 'running';--> statement-breakpoint
ALTER TABLE "places" ADD CONSTRAINT "places_foursquare_venue_id_foursquare_venues_id_fk" FOREIGN KEY ("foursquare_venue_id") REFERENCES "public"."foursquare_venues"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "checkins_user_source_external_id_unique_idx" ON "checkins" USING btree ("user_id","source","external_id") WHERE "checkins"."external_id" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "places_foursquare_venue_id_unique_idx" ON "places" USING btree ("foursquare_venue_id");--> statement-breakpoint
ALTER TABLE "places" ADD CONSTRAINT "places_source_check" CHECK ("places"."source" in ('overture', 'user', 'google', 'foursquare'));--> statement-breakpoint
ALTER TABLE "places" ADD CONSTRAINT "places_source_identifier_check" CHECK (("places"."source" = 'overture') = ("places"."overture_id" is not null) and ("places"."source" = 'google') = ("places"."google_place_id" is not null) and ("places"."source" = 'foursquare') = ("places"."foursquare_venue_id" is not null));