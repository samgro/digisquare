ALTER TABLE "foursquare_venues" ADD COLUMN "overture_id" text;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "source_dataset" text;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "source_updated_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "basic_category" text;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "taxonomy_hierarchy" text[];--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "operating_status" text;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "provider_count" integer;--> statement-breakpoint
ALTER TABLE "places" ADD COLUMN "prior" double precision;