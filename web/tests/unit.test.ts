import { test } from "node:test";
import assert from "node:assert/strict";
import {
  amount,
  integer,
  requiredZeros,
  minimumOutput,
  validateStart,
  automaticStart,
  DURATIONS,
  THRESHOLDS,
  fullAmount,
  withDeadline,
  explainError,
  DeadlineError,
} from "../src/domain";

test("token amounts are exact and reject excess precision, exponents, negatives and overflow", () => {
  assert.equal(
    amount("123456789.000000000000000001"),
    123456789000000000000000001n,
  );
  assert.equal(
    fullAmount(amount("0.000000000000000001")),
    "0.000000000000000001",
  );
  for (const value of [
    "0",
    "-1",
    "1e4",
    "NaN",
    "0.0000000000000000001",
    "1.",
    "1,000",
    "01",
    "",
    "9".repeat(80),
  ])
    assert.throws(() => amount(value));
});
test("threshold ceil matches cross multiplication for all twelve products", () => {
  for (const n of DURATIONS)
    for (const t of THRESHOLDS) {
      const required = requiredZeros(n, t);
      assert.ok(required * 10000 >= n * t);
      assert.ok((required - 1) * 10000 < n * t);
    }
  assert.equal(requiredZeros(6, 3000), 2);
  assert.equal(requiredZeros(144, 7000), 101);
});
test("start respects both frontier and clock, exact lead cap, uint64 end", () => {
  assert.equal(automaticStart(1973n, 2789n), 2791n);
  assert.equal(automaticStart(3000n, 2789n), 3002n);
  assert.doesNotThrow(() => validateStart(3797n, 1973n, 2789n, 144));
  assert.throws(() => validateStart(3798n, 1973n, 2789n, 144));
  assert.throws(() => validateStart(2789n, 1973n, 2789n, 6));
  assert.throws(() => validateStart((1n << 64n) - 1n, 1n, (1n << 64n) - 2n, 6));
});
test("raw shares and IDs stay integer, nonzero and within uint256", () => {
  assert.equal(
    integer("1000000000000000000000000"),
    1000000000000000000000000n,
  );
  for (const v of ["0", "-1", "1.1", "1e9", "  ", "9".repeat(79)])
    assert.throws(() => integer(v));
  assert.equal(integer(" 123 "), 123n);
});
test("LP minimum is nonzero and protects output with 0.5% tolerance", () => {
  assert.equal(
    minimumOutput(1000000000000000000000000n),
    995000000000000000000000n,
  );
  assert.equal(minimumOutput(1000n), 995n);
  assert.throws(() => minimumOutput(1n));
});

test("withDeadline caps a hung read and passes through fast results", async () => {
  const started = Date.now();
  await assert.rejects(
    withDeadline(new Promise(() => {}), 50, "Reading the quote"),
    (e: unknown) =>
      e instanceof DeadlineError &&
      /Reading the quote took longer than 0 seconds/.test(explainError(e)),
  );
  assert.ok(Date.now() - started < 1000);
  assert.equal(await withDeadline(Promise.resolve(7), 50, "x"), 7);
  await assert.rejects(
    withDeadline(Promise.reject(new Error("boom")), 50, "x"),
    /boom/,
  );
});
