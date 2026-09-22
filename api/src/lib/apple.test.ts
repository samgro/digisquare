import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from "jose";
import type { JWTVerifyGetKey } from "jose";

// jose v5 does not export CryptoKey, so take it from generateKeyPair.
type SigningKey = Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];
import { beforeAll, describe, expect, it } from "vitest";
import { verifyAppleIdentityToken } from "./apple.js";

const APPLE_KEY_ID = "test-apple-key";
const BUNDLE_IDENTIFIER = "samgro.Hackysack";

let applePrivateKey: SigningKey;
let attackerPrivateKey: SigningKey;
let localKeySet: JWTVerifyGetKey;

/**
 * Stands in for Apple's published key set so the real signature check runs.
 *
 * It is injected rather than served over a stubbed fetch because jose's Node
 * build retrieves a remote key set through node:https, which the suite's
 * fetch stub cannot intercept. Without the injection every token would be
 * rejected because the fetch failed rather than because the token was bad,
 * and these tests would pass while proving nothing.
 */
beforeAll(async () => {
  const appleKeyPair = await generateKeyPair("RS256", { extractable: true });
  const attackerKeyPair = await generateKeyPair("RS256", { extractable: true });
  applePrivateKey = appleKeyPair.privateKey;
  attackerPrivateKey = attackerKeyPair.privateKey;

  const publicJwk = await exportJWK(appleKeyPair.publicKey);
  localKeySet = createLocalJWKSet({
    keys: [{ ...publicJwk, kid: APPLE_KEY_ID, alg: "RS256", use: "sig" }],
  });
});

interface TokenOverrides {
  subject?: string;
  issuer?: string;
  audience?: string;
  issuedAt?: number;
  claims?: Record<string, unknown>;
  signWith?: SigningKey;
}

function mintToken(overrides: TokenOverrides = {}) {
  const jwt = new SignJWT({
    email: "user@example.com",
    email_verified: "true",
    is_private_email: "false",
    nonce: "abc123",
    ...overrides.claims,
  })
    .setProtectedHeader({ alg: "RS256", kid: APPLE_KEY_ID })
    .setSubject(overrides.subject ?? "001234.apple.subject")
    .setIssuer(overrides.issuer ?? "https://appleid.apple.com")
    .setAudience(overrides.audience ?? BUNDLE_IDENTIFIER)
    .setIssuedAt(overrides.issuedAt)
    .setExpirationTime("10m");

  return jwt.sign(overrides.signWith ?? applePrivateKey);
}

describe("verifyAppleIdentityToken", () => {
  it("accepts a well-formed token and returns the subject", async () => {
    const identity = await verifyAppleIdentityToken(await mintToken(), localKeySet);
    expect(identity?.subject).toBe("001234.apple.subject");
    expect(identity?.email).toBe("user@example.com");
    expect(identity?.nonceHash).toBe("abc123");
  });

  it("rejects anything that is not a JWT", async () => {
    expect(await verifyAppleIdentityToken("not.a.jwt", localKeySet)).toBeNull();
    expect(await verifyAppleIdentityToken("", localKeySet)).toBeNull();
  });

  // The whole point of checking against Apple's published keys: a token that
  // claims the right issuer and audience but is signed by someone else is a
  // forgery.
  it("rejects a token signed with a key Apple does not publish", async () => {
    expect(await verifyAppleIdentityToken(await mintToken({ signWith: attackerPrivateKey }), localKeySet)).toBeNull();
  });

  // Without the audience pin, an identity token minted for a different app
  // would sign its holder in here.
  it("rejects a token minted for another app", async () => {
    expect(await verifyAppleIdentityToken(await mintToken({ audience: "com.someone.else" }), localKeySet)).toBeNull();
  });

  it("rejects a wrong issuer", async () => {
    expect(await verifyAppleIdentityToken(await mintToken({ issuer: "https://evil.example.com" }), localKeySet)).toBeNull();
  });

  // maxTokenAge bounds how long a leaked token stays useful, independently of
  // the exp Apple sets.
  it("rejects a token older than the ten minute freshness window", async () => {
    const thirtyMinutesAgo = Math.floor(Date.now() / 1000) - 1800;
    expect(await verifyAppleIdentityToken(await mintToken({ issuedAt: thirtyMinutesAgo }), localKeySet)).toBeNull();
  });

  it("rejects a token with no subject", async () => {
    expect(await verifyAppleIdentityToken(await mintToken({ subject: "" }), localKeySet)).toBeNull();
  });

  // Apple sends these as real booleans in some responses and as the strings
  // "true"/"false" in others. A plain truthiness check would read the string
  // "false" as true and mark an unverified address verified.
  it.each([
    ["true", true],
    [true, true],
    ["false", false],
    [false, false],
    [undefined, false],
  ])("normalizes email_verified %s to %s", async (rawValue, expected) => {
    const identity = await verifyAppleIdentityToken(
      await mintToken({ claims: { email_verified: rawValue } }),
      localKeySet,
    );
    expect(identity?.emailVerified).toBe(expected);
  });

  it("normalizes is_private_email the same way", async () => {
    const relayed = await verifyAppleIdentityToken(
      await mintToken({ claims: { is_private_email: "true" } }),
      localKeySet,
    );
    expect(relayed?.isPrivateEmail).toBe(true);
  });

  it("reports a null email when Apple withholds it", async () => {
    const identity = await verifyAppleIdentityToken(
      await mintToken({ claims: { email: undefined } }),
      localKeySet,
    );
    expect(identity?.email).toBeNull();
  });

  it("lowercases the email so account matching is case-insensitive", async () => {
    const identity = await verifyAppleIdentityToken(
      await mintToken({ claims: { email: "User@Example.COM" } }),
      localKeySet,
    );
    expect(identity?.email).toBe("user@example.com");
  });
});
