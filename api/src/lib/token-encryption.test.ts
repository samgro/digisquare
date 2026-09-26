import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { decryptToken, encryptToken } from "./token-encryption.js";

const KEY = randomBytes(32).toString("base64");

describe("token encryption", () => {
  it("round-trips a token", () => {
    const sealed = encryptToken("foursquare-token", KEY);
    expect(sealed).not.toContain("foursquare-token");
    expect(decryptToken(sealed, KEY)).toBe("foursquare-token");
  });

  it("never produces the same ciphertext twice", () => {
    expect(encryptToken("foursquare-token", KEY)).not.toBe(
      encryptToken("foursquare-token", KEY),
    );
  });

  it("refuses a ciphertext sealed under another key", () => {
    const sealed = encryptToken("foursquare-token", KEY);
    expect(() =>
      decryptToken(sealed, randomBytes(32).toString("base64")),
    ).toThrow();
  });

  it("refuses a tampered ciphertext", () => {
    const [version, initializationVector, authenticationTag, ciphertext] =
      encryptToken("foursquare-token", KEY).split(".");
    const flipped = Buffer.from(ciphertext!, "base64url");
    flipped[0] = flipped[0]! ^ 1;
    const tampered = [
      version,
      initializationVector,
      authenticationTag,
      flipped.toString("base64url"),
    ].join(".");
    expect(() => decryptToken(tampered, KEY)).toThrow();
  });

  it("refuses a key of the wrong length", () => {
    expect(() =>
      encryptToken("foursquare-token", randomBytes(16).toString("base64")),
    ).toThrow();
  });
});
