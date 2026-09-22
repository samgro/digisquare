import { describe, expect, it } from "vitest";
import { AVATAR_MAX_BYTES, createAvatarUploadUrl, isOwnedAvatarKey } from "./r2.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const OTHER_USER_ID = "11111111-1111-1111-1111-111111111111";
const UUID = "9f54a22a-2c65-4de5-b224-f1b5def25656";

describe("createAvatarUploadUrl", () => {
  it("scopes the key to the user and returns the limits", async () => {
    const upload = await createAvatarUploadUrl(USER_ID, 48_213);
    expect(upload.key).toMatch(new RegExp(`^avatars/${USER_ID}/[0-9a-f-]{36}\\.jpg$`));
    expect(upload.expiresInSeconds).toBe(300);
    expect(upload.maxBytes).toBe(AVATAR_MAX_BYTES);
  });

  it("never mints the same key twice", async () => {
    const first = await createAvatarUploadUrl(USER_ID, 1000);
    const second = await createAvatarUploadUrl(USER_ID, 1000);
    expect(first.key).not.toBe(second.key);
  });

  // Signing content-length is the only size cap a presigned PUT can carry.
  // Without it in SignedHeaders the url would accept an upload of any size.
  it("signs content-length and content-type", async () => {
    const upload = await createAvatarUploadUrl(USER_ID, 48_213);
    const signedHeaders = new URL(upload.uploadUrl).searchParams.get("X-Amz-SignedHeaders");
    expect(signedHeaders).toContain("content-length");
    expect(signedHeaders).toContain("content-type");
  });

  it("expires the url in five minutes", async () => {
    const upload = await createAvatarUploadUrl(USER_ID, 1000);
    expect(new URL(upload.uploadUrl).searchParams.get("X-Amz-Expires")).toBe("300");
  });
});

// The avatar key comes back from the client as a plain string, so PATCH
// /users/me re-derives ownership from it. Without this check any user could
// point their avatar at any object in the bucket, including someone else's.
describe("isOwnedAvatarKey", () => {
  it("accepts a key minted for this user", async () => {
    const upload = await createAvatarUploadUrl(USER_ID, 1000);
    expect(isOwnedAvatarKey(upload.key, USER_ID)).toBe(true);
  });

  it("rejects another user's key", async () => {
    const upload = await createAvatarUploadUrl(OTHER_USER_ID, 1000);
    expect(isOwnedAvatarKey(upload.key, USER_ID)).toBe(false);
  });

  it.each([
    [`avatars/${USER_ID}/../../etc/passwd`, "path traversal"],
    [`avatars/${USER_ID}/not-a-uuid.jpg`, "non-uuid filename"],
    [`avatars/${USER_ID}/${UUID}.png`, "wrong extension"],
    [`avatars/${USER_ID}/${UUID}`, "no extension"],
    [`x/avatars/${USER_ID}/${UUID}.jpg`, "extra leading segment"],
    [`avatars/${USER_ID}/${UUID}.jpg/extra`, "extra trailing segment"],
    [`avatars/${USER_ID}`, "too few segments"],
    ["", "empty"],
  ])("rejects %s (%s)", (key) => {
    expect(isOwnedAvatarKey(key, USER_ID)).toBe(false);
  });

  // The user id is compared as a path segment rather than interpolated into a
  // pattern, so regex metacharacters in it cannot match anything they should not.
  it("does not treat the user id as a pattern", () => {
    expect(isOwnedAvatarKey(`avatars/${USER_ID}/${UUID}.jpg`, ".*")).toBe(false);
  });
});
