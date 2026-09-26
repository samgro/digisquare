import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

/**
 * AES-256-GCM for third-party tokens we have to be able to read back, such as
 * a Foursquare token that never expires and unlocks someone's whole location
 * history. A leaked database dump should not hand those over.
 *
 * The output is versioned (`v1.`) so the scheme or key can be rotated later
 * without guessing which rows used which.
 */
const VERSION = "v1";
const INITIALIZATION_VECTOR_BYTES = 12;

export function encryptToken(plaintext: string, base64Key: string): string {
  const key = parseKey(base64Key);
  const initializationVector = randomBytes(INITIALIZATION_VECTOR_BYTES);
  const cipher = createCipheriv("aes-256-gcm", key, initializationVector);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const authenticationTag = cipher.getAuthTag();

  return [VERSION, initializationVector, authenticationTag, ciphertext]
    .map((part) => (typeof part === "string" ? part : part.toString("base64url")))
    .join(".");
}

/** Throws if the ciphertext was tampered with or sealed under another key. */
export function decryptToken(sealed: string, base64Key: string): string {
  const [version, initializationVector, authenticationTag, ciphertext, ...rest] =
    sealed.split(".");
  if (
    version !== VERSION ||
    !initializationVector ||
    !authenticationTag ||
    ciphertext === undefined ||
    rest.length > 0
  ) {
    throw new Error("Unrecognised encrypted token format");
  }

  const decipher = createDecipheriv(
    "aes-256-gcm",
    parseKey(base64Key),
    Buffer.from(initializationVector, "base64url"),
  );
  decipher.setAuthTag(Buffer.from(authenticationTag, "base64url"));
  return Buffer.concat([
    decipher.update(Buffer.from(ciphertext, "base64url")),
    decipher.final(),
  ]).toString("utf8");
}

function parseKey(base64Key: string): Buffer {
  const key = Buffer.from(base64Key, "base64");
  if (key.length !== 32) {
    throw new Error("Token encryption key must be 32 bytes, base64 encoded");
  }
  return key;
}
