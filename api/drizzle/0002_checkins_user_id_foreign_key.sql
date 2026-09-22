-- HAND-EDITED. drizzle-kit generated a bare
--   ALTER TABLE "checkins" ALTER COLUMN "user_id" SET DATA TYPE uuid;
-- which fails with "column user_id cannot be cast automatically to type uuid"
-- against the free-form strings this column used to hold (the Bruno fixtures
-- posted "sam"). Two changes were needed: drop those rows first, and give the
-- cast an explicit USING clause.
--
-- The DELETE is intentional and irreversible. Identity used to be whatever
-- string the client sent, so none of the existing rows can be attributed to a
-- real account. TAKE A NEON BRANCH BEFORE RUNNING THIS.
DELETE FROM "checkins";
--> statement-breakpoint
ALTER TABLE "checkins" ALTER COLUMN "user_id" SET DATA TYPE uuid USING "user_id"::uuid;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "checkins" ADD CONSTRAINT "checkins_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
