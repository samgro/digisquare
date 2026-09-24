ALTER TABLE "checkins" ADD COLUMN "visibility" text DEFAULT 'friends' NOT NULL;--> statement-breakpoint
ALTER TABLE "checkins" ADD COLUMN "source" text DEFAULT 'manual' NOT NULL;