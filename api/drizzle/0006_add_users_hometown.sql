-- HAND-EDITED. drizzle-kit generated only the ADD COLUMN; the UPDATE is
-- added by hand.
--
-- Every profile has a hometown, but accounts created before this column
-- existed have none, and the app would hold all of them on the profile setup
-- screen until they picked one. Backfill them with "Truckee, CA" instead.
--
-- The column stays nullable: a new account's row is written at signup, before
-- the setup screen collects its hometown. The API refuses to clear it.
ALTER TABLE "users" ADD COLUMN "hometown" text;--> statement-breakpoint
UPDATE "users" SET "hometown" = 'Truckee, CA' WHERE "hometown" IS NULL;
