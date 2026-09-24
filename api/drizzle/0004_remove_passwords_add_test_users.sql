-- HAND-EDITED. drizzle-kit generated everything below except the DELETE.
--
-- Email/password sign in is gone, so an account with no Apple ID has no way
-- to sign in and would violate the new credential check. The DELETE removes
-- those accounts, and cascades to their sessions, checkins and friendships.
-- It is intentional and irreversible. TAKE A NEON BRANCH BEFORE RUNNING THIS.
ALTER TABLE "users" DROP CONSTRAINT "users_has_credential_check";--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "is_test_user" boolean DEFAULT false NOT NULL;--> statement-breakpoint
DELETE FROM "users" WHERE "apple_user_id" IS NULL;--> statement-breakpoint
ALTER TABLE "users" DROP COLUMN "password_hash";--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_has_credential_check" CHECK ("users"."apple_user_id" is not null or "users"."is_test_user");
