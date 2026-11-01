import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fetchSnapshot, verifyDeployment, read } from "../src/chain";
import { addresses, RPC_URLS } from "../src/config";

const [snapshot, deployment] = await Promise.allSettled([
  fetchSnapshot(),
  verifyDeployment(),
]);
const rates = await Promise.allSettled(
  [6, 12, 24, 144].flatMap((n) =>
    [3000, 5000, 7000].map(async (t) => ({
      rounds: n,
      thresholdBps: t,
      rate: await read("PremiumModel", "rates", [n, t]),
    })),
  ),
);
const result = {
  checkedAt: new Date().toISOString(),
  network: "Sepolia",
  chainId: 11155111,
  addresses,
  rpcUrls: RPC_URLS,
  snapshot,
  deployment,
  rates,
  signedTransactions: 0,
};
const json = JSON.stringify(
  result,
  (_, value) =>
    typeof value === "bigint"
      ? value.toString()
      : value instanceof Error
        ? { name: value.name, message: value.message }
        : value,
  2,
);
if (process.argv[2]) {
  mkdirSync(dirname(resolve(process.argv[2])), { recursive: true });
  writeFileSync(process.argv[2], json + "\n");
}
console.log(json);
if (snapshot.status === "rejected" || deployment.status === "rejected")
  process.exitCode = 1;
