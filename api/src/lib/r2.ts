import { randomUUID } from "node:crypto";
import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { config } from "../config.js";

export const IMAGE_MAX_BYTES = 2_000_000;

const UPLOAD_URL_TTL_SECONDS = 300;

const r2Client = new S3Client({
  region: "auto",
  endpoint: `https://${config.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  forcePathStyle: true,
  credentials: {
    accessKeyId: config.R2_ACCESS_KEY_ID,
    secretAccessKey: config.R2_SECRET_ACCESS_KEY,
  },
});

/** Where a stored object is served from. Clients never see raw keys. */
export function publicUrlFor(key: string): string {
  return `${config.R2_PUBLIC_BASE_URL.replace(/\/+$/, "")}/${key}`;
}

/** The folders client uploads may land in, one per kind of image. */
export type ImageKeyPrefix = "avatars" | "checkin-photos";

export interface ImageUpload {
  key: string;
  uploadUrl: string;
  expiresInSeconds: number;
  maxBytes: number;
}

/**
 * Mints a short-lived URL the client can PUT a JPEG to directly, so image
 * bytes never pass through this server.
 *
 * The key embeds the user id, which is what lets the route that later claims
 * the key prove the caller owns it (isOwnedImageKey) — without that check any
 * user could attach anyone else's image.
 */
export async function createImageUploadUrl(
  prefix: ImageKeyPrefix,
  userId: string,
  contentLength: number,
): Promise<ImageUpload> {
  const key = `${prefix}/${userId}/${randomUUID()}.jpg`;

  const uploadUrl = await getSignedUrl(
    r2Client,
    new PutObjectCommand({
      Bucket: config.R2_BUCKET_NAME,
      Key: key,
      ContentType: "image/jpeg",
      ContentLength: contentLength,
    }),
    {
      expiresIn: UPLOAD_URL_TTL_SECONDS,
      // Signing content-length is the only size cap a presigned PUT can carry:
      // without it the URL would accept an upload of any size. The client must
      // then send exactly the length it declared, or R2 answers 403.
      signableHeaders: new Set(["content-type", "content-length"]),
    },
  );

  return {
    key,
    uploadUrl,
    expiresInSeconds: UPLOAD_URL_TTL_SECONDS,
    maxBytes: IMAGE_MAX_BYTES,
  };
}

export function createAvatarUploadUrl(userId: string, contentLength: number) {
  return createImageUploadUrl("avatars", userId, contentLength);
}

/** Uploads a JPEG the server produced itself, such as a copied Swarm photo. */
export async function putJpegObject(key: string, body: Buffer): Promise<void> {
  await r2Client.send(
    new PutObjectCommand({
      Bucket: config.R2_BUCKET_NAME,
      Key: key,
      Body: body,
      ContentType: "image/jpeg",
      ContentLength: body.length,
    }),
  );
}

const UUID_FILENAME_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/;

/**
 * True only for keys createImageUploadUrl minted for this exact user and
 * prefix.
 *
 * Compares the three path segments directly rather than interpolating the
 * user id into a pattern, so nothing in the id can ever be read as regex
 * syntax. The segment count is checked first, which is what stops a crafted
 * key from smuggling extra path in front of or behind the expected shape.
 */
export function isOwnedImageKey(prefix: ImageKeyPrefix, key: string, userId: string): boolean {
  const segments = key.split("/");
  if (segments.length !== 3) {
    return false;
  }

  const [keyPrefix, ownerId, fileName] = segments;
  return keyPrefix === prefix && ownerId === userId && UUID_FILENAME_PATTERN.test(fileName!);
}

export function isOwnedAvatarKey(avatarKey: string, userId: string): boolean {
  return isOwnedImageKey("avatars", avatarKey, userId);
}
