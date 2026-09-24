-- HAND-EDITED. drizzle-kit does not know about extensions, and it emitted
-- the generated point column as a bare geometry(point) without its SRID.
-- PostGIS is needed for the geometry columns, the GiST indexes and the
-- spatial searches in places-search.ts; Neon ships it (CREATE EXTENSION works
-- on any Neon database), and so does a local Postgres with postgis installed.
CREATE EXTENSION IF NOT EXISTS postgis;
--> statement-breakpoint
CREATE TABLE "coverage_cells" (
	"cell_x" integer NOT NULL,
	"cell_y" integer NOT NULL,
	"status" text NOT NULL,
	"job_id" uuid,
	"overture_release" text,
	"ready_at" timestamp with time zone,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "coverage_cells_cell_x_cell_y_pk" PRIMARY KEY("cell_x","cell_y")
);
--> statement-breakpoint
CREATE TABLE "coverage_jobs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"kind" text NOT NULL,
	"priority" integer NOT NULL,
	"west" double precision NOT NULL,
	"south" double precision NOT NULL,
	"east" double precision NOT NULL,
	"north" double precision NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"requested_by_user_id" uuid,
	"parent_job_id" uuid,
	"overture_release" text NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"last_error" text,
	"place_count" integer,
	"extent_count" integer,
	"requested_at" timestamp with time zone DEFAULT now() NOT NULL,
	"started_at" timestamp with time zone,
	"completed_at" timestamp with time zone,
	CONSTRAINT "coverage_jobs_bounds_check" CHECK ("coverage_jobs"."west" <= "coverage_jobs"."east" and "coverage_jobs"."south" <= "coverage_jobs"."north")
);
--> statement-breakpoint
DROP INDEX "places_latitude_longitude_idx";--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "location" geometry(Point, 4326) GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)) STORED;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "extent" geometry(MultiPolygon, 4326);--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "extent_overture_id" text;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "extent_area_square_meters" double precision;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "is_private" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "last_seen_release" text;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "retired_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "coverage_cells" ADD CONSTRAINT "coverage_cells_job_id_coverage_jobs_id_fk" FOREIGN KEY ("job_id") REFERENCES "public"."coverage_jobs"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "coverage_jobs" ADD CONSTRAINT "coverage_jobs_requested_by_user_id_users_id_fk" FOREIGN KEY ("requested_by_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "coverage_cells_status_idx" ON "coverage_cells" USING btree ("status");--> statement-breakpoint
CREATE INDEX "coverage_cells_job_id_idx" ON "coverage_cells" USING btree ("job_id");--> statement-breakpoint
CREATE INDEX "coverage_jobs_status_priority_idx" ON "coverage_jobs" USING btree ("status","priority","requested_at");--> statement-breakpoint
CREATE INDEX "places_location_gist_idx" ON "places" USING gist (("location"::geography));--> statement-breakpoint
CREATE INDEX "places_extent_gist_idx" ON "places" USING gist (("extent"::geography));