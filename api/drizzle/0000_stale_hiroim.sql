CREATE TABLE IF NOT EXISTS "checkins" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"google_place_id" text NOT NULL,
	"place_name" text NOT NULL,
	"place_address" text,
	"place_primary_type" text,
	"place_types" text[],
	"latitude" double precision,
	"longitude" double precision,
	"message" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "checkins_user_id_idx" ON "checkins" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "checkins_google_place_id_idx" ON "checkins" USING btree ("google_place_id");