import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { keccak256, stringToHex } from "viem";

export const canonical = (value) =>
  Array.isArray(value)
    ? value.map(canonical)
    : value && typeof value === "object"
      ? Object.fromEntries(
          Object.keys(value)
            .sort()
            .map((key) => [key, canonical(value[key])]),
        )
      : value;
const deployment = JSON.parse(
  readFileSync(new URL("../deployment.json", import.meta.url)),
);
const source = readFileSync(new URL("../src/abis.ts", import.meta.url), "utf8");
const artifactDir = process.argv.includes("--artifacts")
  ? process.argv[process.argv.indexOf("--artifacts") + 1]
  : undefined;
for (const contract of deployment.contracts) {
  const raw = source.match(
    new RegExp(`export const ${contract.name}Abi = (.+) as const;`),
  )?.[1];
  if (!raw) throw new Error(`Missing ${contract.name} ABI`);
  const abi = JSON.parse(raw);
  const hash = keccak256(stringToHex(JSON.stringify(canonical(abi)))).slice(2);
  if (hash !== contract.abiHash)
    throw new Error(`${contract.name} ABI hash mismatch`);
  if (artifactDir) {
    const compiled = JSON.parse(
      readFileSync(
        resolve(artifactDir, `${contract.name}.sol/${contract.name}.json`),
      ),
    ).abi;
    if (JSON.stringify(canonical(compiled)) !== JSON.stringify(canonical(abi)))
      throw new Error(
        `${contract.name} differs from the compiled repository ABI`,
      );
  }
  console.log(`${contract.name}: canonical ABI hash matches ${hash}`);
}
