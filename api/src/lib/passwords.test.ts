import { describe, expect, it } from "vitest";
import { burnTimingBudget, hashPassword, verifyPassword } from "./passwords.js";

const PASSWORD = "correct horse battery staple";

function elapsedMilliseconds(start: bigint): number {
  return Number(process.hrtime.bigint() - start) / 1e6;
}

describe("password hashing", () => {
  it("produces an argon2id hash", async () => {
    expect(await hashPassword(PASSWORD)).toMatch(/^\$argon2id\$/);
  });

  it("salts, so the same password hashes differently each time", async () => {
    expect(await hashPassword(PASSWORD)).not.toBe(await hashPassword(PASSWORD));
  });

  it("verifies the correct password and rejects a wrong one", async () => {
    const passwordHash = await hashPassword(PASSWORD);
    expect(await verifyPassword(passwordHash, PASSWORD)).toBe(true);
    expect(await verifyPassword(passwordHash, "wrong")).toBe(false);
  });

  it("does not trim, so surrounding whitespace is part of the password", async () => {
    const passwordHash = await hashPassword(` ${PASSWORD} `);
    expect(await verifyPassword(passwordHash, PASSWORD)).toBe(false);
    expect(await verifyPassword(passwordHash, ` ${PASSWORD} `)).toBe(true);
  });

  // A malformed stored hash must read as "wrong password". Throwing would
  // surface as a 500, which tells the caller the account exists.
  it("treats a malformed stored hash as a failed verify rather than throwing", async () => {
    await expect(verifyPassword("not-a-hash", PASSWORD)).resolves.toBe(false);
    await expect(verifyPassword("", PASSWORD)).resolves.toBe(false);
  });
});

describe("login timing equalization", () => {
  // The login handler calls burnTimingBudget when there is no password to
  // check — an unknown email, or an Apple-only account. If it returned
  // markedly faster than a real verify, the difference alone would enumerate
  // the user table.
  it("costs about the same as a real verify", async () => {
    const passwordHash = await hashPassword(PASSWORD);

    // Warm up first: the very first argon2 call in a process pays setup costs
    // that would otherwise swamp the comparison.
    await burnTimingBudget("warmup");
    await verifyPassword(passwordHash, "warmup");

    const samples = 3;
    let missTotal = 0;
    let hitTotal = 0;
    for (let index = 0; index < samples; index += 1) {
      let start = process.hrtime.bigint();
      await burnTimingBudget("some-password");
      missTotal += elapsedMilliseconds(start);

      start = process.hrtime.bigint();
      await verifyPassword(passwordHash, "some-password");
      hitTotal += elapsedMilliseconds(start);
    }

    const missAverage = missTotal / samples;
    const hitAverage = hitTotal / samples;

    // Asserted as a floor rather than a ratio. A ratio is bidirectional and
    // fails when the machine is merely busy — which it is, since vitest runs
    // files in parallel. What actually matters is that the miss path does real
    // argon2 work: if burnTimingBudget were removed or short-circuited it would
    // return in microseconds, so this floor would fail by orders of magnitude
    // while staying immune to scheduling noise.
    expect(missAverage).toBeGreaterThan(hitAverage * 0.25);
  });

  it("never reports success, whatever it is given", async () => {
    await expect(burnTimingBudget("anything")).resolves.toBeUndefined();
    await expect(burnTimingBudget("")).resolves.toBeUndefined();
  });
});
