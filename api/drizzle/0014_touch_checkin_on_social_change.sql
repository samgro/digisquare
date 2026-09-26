-- HAND-EDITED. drizzle-kit does not know about triggers.
-- A like or comment added or removed bumps the checkin's updated_at, so the
-- changes phase of GET /checkins/sync, which walks updated_at, carries fresh
-- like and comment counts to the owner's local copy. A trigger rather than
-- code in the routes, so cascade deletes (an account going away with its
-- likes) count too, and no future route has to remember. A no-op, like the
-- second tap of a heart that hits ON CONFLICT DO NOTHING, touches no row and
-- so bumps nothing.
--
-- Photos too: an imported photo's url changes from Foursquare's to R2's when
-- the background copy fills in storage_key, and the local copy should follow.
CREATE FUNCTION "touch_checkin_updated_at"() RETURNS trigger AS $$
BEGIN
	UPDATE "checkins" SET "updated_at" = now()
	WHERE "id" = COALESCE(NEW."checkin_id", OLD."checkin_id");
	RETURN NULL;
END;
$$ LANGUAGE plpgsql;--> statement-breakpoint
CREATE TRIGGER "checkin_likes_touch_checkin"
AFTER INSERT OR DELETE ON "checkin_likes"
FOR EACH ROW EXECUTE FUNCTION "touch_checkin_updated_at"();--> statement-breakpoint
CREATE TRIGGER "checkin_comments_touch_checkin"
AFTER INSERT OR DELETE ON "checkin_comments"
FOR EACH ROW EXECUTE FUNCTION "touch_checkin_updated_at"();--> statement-breakpoint
CREATE TRIGGER "checkin_photos_touch_checkin"
AFTER INSERT OR DELETE OR UPDATE OF "storage_key" ON "checkin_photos"
FOR EACH ROW EXECUTE FUNCTION "touch_checkin_updated_at"();
