import { createConfig, http, fallback } from "wagmi";
import { injected, coinbaseWallet } from "wagmi/connectors";
import { createPublicClient, defineChain, type Address } from "viem";
import {
  CoverPoolAbi,
  CoreReaderAbi,
  MockSQKAbi,
  PolicyBookAbi,
  PremiumModelAbi,
  SqueekCoreAbi,
} from "./abis";

// Deployment source: e4e6668ad2dd701ce96e96160c2e316bb68d38f3.
export const addresses = {
  PolicyBook: "0xff8f5214c0895a8805ebc0dd5105ab7956dd67db",
  CoverPool: "0x95524725736cf4ec96e29a6ed73c33335c61c2a9",
  PremiumModel: "0x66d9003653ee9b898fc1e6abb83620dd8e39deda",
  CoreReader: "0x5fbe17ecdae6cab9d657313ba5704ea3e19ab72d",
  MockSQK: "0x5e6729156ed49a0de73ddacb6529c363f2bd38bb",
  SqueekCore: "0x74665dAecA35A2303e767E76a2FF1FB6F93e119f",
} as const satisfies Record<string, Address>;
export const abis = {
  PolicyBook: PolicyBookAbi,
  CoverPool: CoverPoolAbi,
  PremiumModel: PremiumModelAbi,
  CoreReader: CoreReaderAbi,
  MockSQK: MockSQKAbi,
  SqueekCore: SqueekCoreAbi,
};
export type ContractName = keyof typeof addresses;
export const RPC_URLS = [
  "https://ethereum-sepolia-rpc.publicnode.com",
  "https://rpc.sepolia.ethpandaops.io",
  "https://sepolia.rpc.sentio.xyz",
] as const;
export const EXPLORER = "https://sepolia.etherscan.io";
export const REPO = "https://github.com/identity-md-launches/launch-2814-sqi";
export const JOB =
  "https://explorer.imd.fun/jobs/f31056b6-bfd7-4e25-afd1-461d53d2a210";
export const chain = defineChain({
  id: 11155111,
  name: "Sepolia",
  testnet: true,
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: RPC_URLS } },
  blockExplorers: { default: { name: "Etherscan", url: EXPLORER } },
});
const transport = () =>
  fallback(
    RPC_URLS.map((url) =>
      http(url, { timeout: 8_000, retryCount: 0, batch: { wait: 20 } }),
    ),
    { retryCount: 0 },
  );
export const publicClient = createPublicClient({
  chain,
  transport: transport(),
  batch: { multicall: false },
});
export const walletConfig = createConfig({
  chains: [chain],
  multiInjectedProviderDiscovery: true,
  connectors: [
    injected(),
    coinbaseWallet({
      appName: "SqueekFi COVER",
      appLogoUrl:
        typeof document === "undefined"
          ? undefined
          : new URL("favicon.svg", document.baseURI).href,
      preference: { options: "smartWalletOnly" },
    }),
  ],
  transports: { [chain.id]: transport() },
});
export const explorerAddress = (address: string) =>
  `${EXPLORER}/address/${address}`;
export const explorerTx = (hash: string) => `${EXPLORER}/tx/${hash}`;
