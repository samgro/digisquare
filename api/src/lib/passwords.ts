import { Algorithm, hash, verify } from "@node-rs/argon2";

// OWASP Password Storage Cheat Sheet baseline for argon2id.
const ARGON2_OPTIONS = {
  algorithm: Algorithm.Argon2id,
  memoryCost: 19456, // 19 MiB
  timeCost: 2,
  parallelism: 1,
} as const;

// Hashed once at module load so burnTimingBudget() below costs the same as a
// real verify without paying for a hash on every miss.
const dummyHashPromise = hash("00000000-0000-0000-0000-000000000000", ARGON2_OPTIONS);

export async function hashPassword(password: string): Promise<string> {
  return hash(password, ARGON2_OPTIONS);
}

export async function verifyPassword(
  passwordHash: string,
  password: string,
): Promise<boolean> {
  try {
    return await verify(passwordHash, password, ARGON2_OPTIONS);
  } catch {
    // A malformed stored hash must read as "wrong password", never as a 500
    // that tells the caller this account exists.
    return false;
  }
}

/**
 * Equalizes login timing when there is no password to check — either the
 * email does not exist, or the account is Apple-only.
 *
 * Without this, a miss returns in a few milliseconds while a hit spends ~50ms
 * in argon2, and that difference alone enumerates the user table.
 */
export async function burnTimingBudget(password: string): Promise<void> {
  try {
    await verify(await dummyHashPromise, password, ARGON2_OPTIONS);
  } catch {
    // Expected: the password will not match the dummy hash. We only want the
    // elapsed time.
  }
}
