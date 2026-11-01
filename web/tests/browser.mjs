import { chromium, webkit } from "playwright";
import AxeBuilder from "@axe-core/playwright";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { resolve, extname, join } from "node:path";
import {
  decodeFunctionData,
  encodeFunctionResult,
  encodeErrorResult,
  keccak256,
  stringToHex,
  encodeEventTopics,
  encodeAbiParameters,
} from "viem";

// Entirely simulated RPC/wallet interactions. No signing keys and no real writes.
const root = resolve(process.argv[2] ?? "../dist");
const output = resolve(
  process.argv[3] ?? "../artifacts/browser-validation.json",
);
const abiSource = readFileSync(
  new URL("../src/abis.ts", import.meta.url),
  "utf8",
);
const abis = Object.fromEntries(
  [...abiSource.matchAll(/export const (\w+)Abi = (.+) as const;/g)].map(
    (m) => [m[1], JSON.parse(m[2])],
  ),
);
const deployment = JSON.parse(
  readFileSync(new URL("../deployment.json", import.meta.url)),
);
const fixture = JSON.parse(
  readFileSync(new URL("./fixtures/sepolia-code.json", import.meta.url)),
);
const addresses = Object.fromEntries(
  deployment.contracts.map((c) => [c.name, c.address]),
);
addresses.SqueekCore = "0x74665dAecA35A2303e767E76a2FF1FB6F93e119f";
const byAddress = Object.fromEntries(
  Object.entries(addresses).map(([n, a]) => [a.toLowerCase(), n]),
);
const ACCOUNT = addresses.SqueekCore; // Fixture-only impersonation; never a signer or a deployment input.
const UNIT = 10n ** 18n;
const contentTypes = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
};
const server = createServer((req, res) => {
  const path = decodeURIComponent(
    new URL(req.url, "http://local").pathname,
  ).replace(/^\/preview\//, "");
  const file = join(root, path || "index.html");
  if (!file.startsWith(root + "/")) {
    res.writeHead(403).end();
    return;
  }
  try {
    const body = readFileSync(
      statSync(file).isDirectory() ? join(file, "index.html") : file,
    );
    res
      .writeHead(200, {
        "Content-Type":
          contentTypes[extname(file)] ?? "application/octet-stream",
      })
      .end(body);
  } catch {
    res.writeHead(404).end("Not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}/preview/`;
const results = [];
const browsers = [];
function state() {
  return {
    offline: false,
    configured: true,
    rate: true,
    paused: false,
    corePaused: false,
    wrongCode: false,
    frontier: 103n,
    current: 105n,
    pending: false,
    allowances: {},
    shares: 1000000000000000000000000n,
    assets: 10000n * UNIT,
    reserved: 100n * UNIT,
    next: 2n,
    policies: new Map([
      [
        1n,
        {
          holder: ACCOUNT,
          startRound: 90n,
          endRound: 95n,
          decideRound: 92n,
          rounds: 6,
          thresholdBps: 5000,
          zeroRounds: 0,
          status: 1,
          cover: 100n * UNIT,
          premium: 5n * UNIT,
        },
      ],
    ]),
    calls: [],
    sent: [],
    receipts: new Map(),
    reject: false,
    receiptStatus: "0x1",
    delayQuote: 0,
  };
}
function rpc(s, method, params = []) {
  if (method === "eth_chainId") return "0xaa36a7";
  if (method === "eth_blockNumber") return fixture.block.number;
  if (method === "eth_getBlockByNumber")
    return {
      ...fixture.block,
      timestamp: "0x" + Math.floor(Date.now() / 1000).toString(16),
    };
  if (method === "eth_getCode")
    return s.wrongCode
      ? "0x1234"
      : fixture.codes[byAddress[params[0].toLowerCase()]];
  if (method === "eth_getTransactionReceipt")
    return s.receipts.get(params[0]) ?? null;
  if (method === "eth_getBalance") return "0x56bc75e2d63100000";
  if (method === "eth_getTransactionCount") return "0x0";
  if (method === "eth_gasPrice") return "0x3b9aca00";
  if (method === "eth_estimateGas") return "0x493e0";
  if (method === "eth_call") {
    const target = byAddress[params[0].to.toLowerCase()];
    const abi = abis[target];
    const { functionName: fn, args = [] } = decodeFunctionData({
      abi,
      data: params[0].data,
    });
    s.calls.push({ target, fn, args });
    const contractError = (name) => {
      throw {
        code: 3,
        message: "execution reverted",
        data: encodeErrorResult({
          abi: Object.values(abis).flat(),
          errorName: name,
        }),
      };
    };
    let value;
    switch (fn) {
      case "token":
        value = addresses.MockSQK;
        break;
      case "pool":
        value = addresses.CoverPool;
        break;
      case "reader":
        value = addresses.CoreReader;
        break;
      case "premiumModel":
        value = addresses.PremiumModel;
        break;
      case "core":
        value = addresses.SqueekCore;
        break;
      case "decimals":
        value = 18;
        break;
      case "policyBook":
        value = s.configured ? addresses.PolicyBook : addresses.CoverPool;
        break;
      case "snapshot":
        value = [s.frontier, s.current, s.corePaused];
        break;
      case "totalAssets":
        value = s.assets;
        break;
      case "reserved":
        value = s.reserved;
        break;
      case "freeAssets":
        value = s.assets - s.reserved;
        break;
      case "openPolicyCount":
        value = BigInt(
          [...s.policies.values()].filter((p) => p.status === 1).length,
        );
        break;
      case "nextPolicyId":
        value = s.next;
        break;
      case "paused":
        value = s.paused;
        break;
      case "settlementPending":
        value = s.pending;
        break;
      case "earliestDecideRound":
        value = 92n;
        break;
      case "openPolicyIdsDecidingAt":
        value = [1n];
        break;
      case "allowance":
        value = s.allowances[args[1].toLowerCase()] ?? 0n;
        break;
      case "balanceOf":
        value = 1000n * UNIT;
        break;
      case "sharesOf":
        value = s.shares;
        break;
      case "shareEpoch":
        value = 0n;
        break;
      case "previewDeposit":
        value = args[0] * 1000000n;
        break;
      case "previewRedeem":
        value = args[0] / 1000000n;
        break;
      case "quote":
        if (!s.configured) contractError("NotConfigured");
        if (s.paused) contractError("OpeningPaused");
        if (s.corePaused) contractError("CorePaused");
        if (!s.rate) contractError("RateNotConfigured");
        if (args[3] > s.assets - s.reserved)
          contractError("InsufficientLiquidity");
        value = [args[3] / 20n, args[0] + BigInt(args[1]) - 1n];
        break;
      case "getPolicy":
        value = s.policies.get(args[0]) ?? {
          holder: ACCOUNT,
          startRound: 0n,
          endRound: 0n,
          decideRound: 0n,
          rounds: 0,
          thresholdBps: 0,
          zeroRounds: 0,
          status: 0,
          cover: 0n,
          premium: 0n,
        };
        break;
      case "certifiedZeroRounds":
        value =
          s.frontier >= args[0] + BigInt(args[1]) - 1n ? [4, args[1]] : [0, 0];
        break;
      case "approve":
        value = true;
        break;
      case "openPolicy":
        value = s.next;
        break;
      case "deposit":
        value = args[0] * 1000000n;
        break;
      case "redeem":
        value = args[0] / 1000000n;
        break;
      case "settle":
        value = s.policies.get(args[0]).cover;
        break;
      case "review":
        value = [true, 92n];
        break;
      default:
        throw Error("Unhandled fixture call " + target + "." + fn);
    }
    return encodeFunctionResult({ abi, functionName: fn, result: value });
  }
  throw Error("Unhandled fixture RPC " + method);
}
async function fixturePage(
  browser,
  s,
  { mobile = false, wallet = false, chain = "0xaa36a7" } = {},
) {
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    ...(mobile
      ? {
          userAgent:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1",
          isMobile: true,
          hasTouch: true,
        }
      : {}),
    permissions: ["clipboard-read", "clipboard-write"],
  });
  await context.route("**/*", async (route) => {
    const req = route.request();
    if (req.url().startsWith(url.slice(0, url.indexOf("/preview/"))))
      return route.continue();
    if (
      !/ethereum-sepolia-rpc.publicnode.com|rpc.sepolia.ethpandaops.io|sepolia.rpc.sentio.xyz/.test(
        req.url(),
      )
    )
      return route.abort();
    if (s.offline) return route.abort();
    const payload = req.postDataJSON();
    if (s.hang) {
      // Simulates every public RPC accepting the request and never answering.
      await new Promise((r) => setTimeout(r, s.hang));
      return route.abort().catch(() => {});
    }
    const resolveCall = async (call) => {
      try {
        if (
          s.delayQuote &&
          call.method === "eth_call" &&
          call.params?.[0]?.data?.startsWith("0x")
        ) {
          try {
            const decoded = decodeFunctionData({
              abi: abis.PolicyBook,
              data: call.params[0].data,
            });
            if (decoded.functionName === "quote")
              await new Promise((r) => setTimeout(r, s.delayQuote));
          } catch {}
        }
        return {
          jsonrpc: "2.0",
          id: call.id,
          result: rpc(s, call.method, call.params),
        };
      } catch (e) {
        return {
          jsonrpc: "2.0",
          id: call.id,
          error: {
            code: e.code ?? -32000,
            message: e.message ?? "fixture revert",
            ...(e.data ? { data: e.data } : {}),
          },
        };
      }
    };
    const body = Array.isArray(payload)
      ? await Promise.all(payload.map(resolveCall))
      : await resolveCall(payload);
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(body),
    });
  });
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", (e) => pageErrors.push(e.message));
  if (wallet) {
    await page.exposeFunction("__fixtureSend", async (request) => {
      if (s.reject) throw Error("User rejected the request.");
      const target = byAddress[request.to.toLowerCase()];
      const decoded = decodeFunctionData({
        abi: abis[target],
        data: request.data,
      });
      s.sent.push({ target, ...decoded, request });
      const hash = keccak256(
        stringToHex("offline transaction " + s.sent.length),
      );
      const fn = decoded.functionName,
        args = decoded.args;
      const logs = [];
      if (s.receiptStatus === "0x1") {
        if (fn === "approve") s.allowances[args[0].toLowerCase()] = args[1];
        if (fn === "deposit") {
          s.assets += args[0];
          s.shares += args[0] * 1000000n;
        }
        if (fn === "redeem") {
          s.assets -= args[0] / 1000000n;
          s.shares -= args[0];
        }
        if (fn === "openPolicy") {
          const id = s.next++;
          s.policies.set(id, {
            holder: ACCOUNT,
            startRound: args[0],
            endRound: args[0] + BigInt(args[1]) - 1n,
            decideRound: args[0] + 2n,
            rounds: args[1],
            thresholdBps: args[2],
            zeroRounds: 0,
            status: 1,
            cover: args[3],
            premium: args[4],
          });
          const topics = encodeEventTopics({
            abi: abis.PolicyBook,
            eventName: "PolicyOpened",
            args: { policyId: id, holder: ACCOUNT },
          });
          const data = encodeAbiParameters(
            [
              { type: "uint64" },
              { type: "uint64" },
              { type: "uint16" },
              { type: "uint16" },
              { type: "uint256" },
              { type: "uint256" },
            ],
            [
              args[0],
              args[0] + BigInt(args[1]) - 1n,
              args[1],
              args[2],
              args[3],
              args[4],
            ],
          );
          logs.push({
            address: addresses.PolicyBook,
            topics,
            data,
            blockNumber: fixture.block.number,
            blockHash: fixture.block.hash,
            transactionHash: hash,
            transactionIndex: "0x0",
            logIndex: "0x0",
            removed: false,
          });
        }
        if (fn === "settle" || fn === "review") {
          s.policies.get(args[0]).status = 2;
          s.pending = false;
        }
      }
      s.receipts.set(hash, {
        transactionHash: hash,
        transactionIndex: "0x0",
        blockHash: fixture.block.hash,
        blockNumber: fixture.block.number,
        from: ACCOUNT,
        to: request.to,
        cumulativeGasUsed: "0x493e0",
        gasUsed: "0x493e0",
        contractAddress: null,
        logs,
        logsBloom: fixture.block.logsBloom,
        status: s.receiptStatus,
        effectiveGasPrice: "0x3b9aca00",
        type: "0x2",
      });
      return hash;
    });
    await page.addInitScript(
      ({ account, initialChain }) => {
        const listeners = {};
        let chainId = initialChain;
        let authorized = false;
        window.__fixtureWallet = {
          requests: [],
          rejectConnect: false,
          unknownChain: false,
        };
        const provider = {
          on(event, cb) {
            (listeners[event] ??= []).push(cb);
          },
          removeListener(event, cb) {
            listeners[event] = (listeners[event] ?? []).filter((f) => f !== cb);
          },
          async request({ method, params }) {
            window.__fixtureWallet.requests.push({ method, params });
            if (method === "eth_chainId") return chainId;
            if (method === "eth_accounts") return authorized ? [account] : [];
            if (method === "eth_requestAccounts") {
              if (window.__fixtureWallet.rejectConnect)
                throw { code: 4001, message: "User rejected connection" };
              authorized = true;
              return [account];
            }
            if (method === "wallet_switchEthereumChain") {
              if (window.__fixtureWallet.unknownChain) {
                window.__fixtureWallet.unknownChain = false;
                throw { code: 4902, message: "Unknown chain" };
              }
              chainId = params[0].chainId;
              (listeners.chainChanged ?? []).forEach((cb) => cb(chainId));
              return null;
            }
            if (method === "wallet_addEthereumChain") return null;
            if (method === "wallet_requestPermissions")
              return [{ parentCapability: "eth_accounts" }];
            if (method === "wallet_getPermissions")
              return [{ parentCapability: "eth_accounts" }];
            if (method === "wallet_revokePermissions") {
              authorized = false;
              return null;
            }
            if (method === "eth_sendTransaction")
              return window.__fixtureSend(params[0]);
            if (method === "wallet_getCapabilities") return {};
            throw { code: 4200, message: "Unsupported test method " + method };
          },
        };
        window.ethereum = provider;
        const info = {
          uuid: "a484a830-cc4f-4ea9-8340-639a90b010ec",
          name: "Fixture wallet",
          icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28"><path d="M2 6h24v18H2Z" fill="gray"/></svg>',
          rdns: "test.cover.fixture",
        };
        const announce = () =>
          window.dispatchEvent(
            new CustomEvent("eip6963:announceProvider", {
              detail: { info, provider },
            }),
          );
        window.addEventListener("eip6963:requestProvider", announce);
        announce();
      },
      { account: ACCOUNT, initialChain: chain },
    );
  }
  await page.goto(url);
  await page.getByRole("heading", { name: "Choose your cover" }).waitFor();
  return { page, context, pageErrors };
}
async function test(name, run) {
  if (process.argv[4] && !name.includes(process.argv[4])) return;
  try {
    const details = await run();
    const status = details?.unperformed ? "not run" : "passed";
    results.push({ name, status, ...details });
    console.log(status.toUpperCase() + " " + name);
  } catch (e) {
    const page = browsers[0]?.contexts().at(-1)?.pages().at(-1);
    let detail;
    try {
      detail = await page?.evaluate(() => ({
        wallet: document.querySelector(".wallet-button")?.textContent,
        dialog: document.querySelector("dialog")?.innerText,
        fixture: window.__fixtureWallet,
      }));
    } catch {}
    results.push({ name, status: "failed", error: e.stack, detail });
    console.log(
      "FAIL " + name + "\n" + e.stack + "\n" + JSON.stringify(detail),
    );
  }
}
const waitText = (page, text) =>
  page.getByText(text, { exact: false }).first().waitFor({ timeout: 12000 });
async function connect(page) {
  await page.getByRole("button", { name: "Connect", exact: true }).click();
  await page.getByRole("button", { name: "Fixture wallet" }).click();
  await page.locator("dialog").waitFor({ state: "hidden" });
}
try {
  const browser = await chromium.launch();
  browsers.push(browser);
  await test("Responsive production export, first-screen action, local assets and accessibility", async () => {
    const s = state();
    const { page, context, pageErrors } = await fixturePage(browser, s);
    await waitText(page, "App code & dependency checks passed");
    const measurements = [];
    for (const width of [320, 390, 768, 1440]) {
      await page.setViewportSize({ width, height: 844 });
      await page.evaluate(() => scrollTo(0, 0));
      const r = await page.evaluate(() => ({
        viewport: innerWidth,
        width: document.documentElement.scrollWidth,
        quoteBottom: document
          .querySelector("button[type=submit]")
          .getBoundingClientRect().bottom,
        font: document.fonts.check("16px Inter"),
      }));
      assert.ok(r.width <= width);
      assert.ok(r.font);
      if (width === 390) assert.ok(r.quoteBottom < 844);
      measurements.push(r);
    }
    const a11y = await new AxeBuilder({ page })
      .withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"])
      .analyze();
    assert.deepEqual(a11y.violations, []);
    assert.deepEqual(pageErrors, []);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(
      () => (document.documentElement.style.fontSize = "200%"),
    );
    assert.ok(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    );
    await context.close();
    return {
      measurements,
      axeViolations: 0,
      textEnlargement: "200% root font, no horizontal overflow",
    };
  });
  await test("Quote validates inputs, all terms, stale responses and activation errors", async () => {
    const s = state();
    const { page, context } = await fixturePage(browser, s);
    await page.locator("#cover-amount").fill("0.0000000000000000001");
    await page.getByRole("button", { name: "Get quote", exact: true }).click();
    await waitText(page, "Enter a positive amount");
    assert.equal(
      await page.locator("#cover-amount").getAttribute("aria-invalid"),
      "true",
    );
    await page.locator("#cover-amount").fill("100");
    await page.getByRole("radio", { name: "144", exact: true }).check();
    await page.getByRole("radio", { name: "70%", exact: true }).check();
    await waitText(page, "101 or more");
    await page.getByRole("button", { name: "Get quote", exact: true }).click();
    await waitText(page, "Review your quote");
    assert.deepEqual(s.calls.findLast((c) => c.fn === "quote").args, [
      107n,
      144,
      7000,
      100n * UNIT,
    ]);
    await page.getByRole("radio", { name: "6", exact: true }).check();
    assert.equal(
      await page.getByText("Review your quote", { exact: true }).count(),
      0,
    );
    s.delayQuote = 200;
    await page.getByRole("button", { name: "Get quote", exact: true }).click();
    await page.locator("#cover-amount").fill("200");
    await page
      .getByRole("button", { name: "Get quote", exact: true })
      .waitFor();
    assert.equal(
      await page.getByText("Review your quote", { exact: true }).count(),
      0,
    );
    s.delayQuote = 0;
    s.configured = false;
    await page.getByRole("button", { name: /^(Get|Retry) quote$/ }).click();
    await waitText(page, "The pool is not bound");
    s.configured = true;
    s.rate = false;
    await page.getByRole("button", { name: /^(Get|Retry) quote$/ }).click();
    await waitText(page, "no configured premium rate");
    s.rate = true;
    s.paused = true;
    await page.getByRole("button", { name: /^(Get|Retry) quote$/ }).click();
    await waitText(page, "New COVER is paused");
    await context.close();
  });
  await test("Offline state is explicit, preserves read-only controls, and retries", async () => {
    const s = state();
    s.offline = true;
    const { page, context } = await fixturePage(browser, s);
    await waitText(page, "Live data unavailable");
    assert.equal(await page.locator(".metric .unavailable").count(), 6);
    await page.getByRole("button", { name: "Connect", exact: true }).click();
    await waitText(page, "Connect a wallet");
    await page.keyboard.press("Escape");
    assert.ok(
      await page
        .locator(".wallet-button")
        .evaluate((e) => e === document.activeElement),
    );
    s.offline = false;
    await page.getByRole("button", { name: "Retry", exact: true }).click();
    await waitText(page, "App code & dependency checks passed");
    await page.waitForFunction(
      () => document.querySelectorAll(".metric .unavailable").length === 0,
    );
    assert.equal(await page.locator(".metric .unavailable").count(), 0);
    await context.close();
  });
  await test("Browser offline retry reports paused reads and recovers on reconnect", async () => {
    const measurements = [];
    for (const width of [390, 1440]) {
      const s = state();
      s.offline = true;
      const { page, context, pageErrors } = await fixturePage(browser, s);
      try {
        await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
        const live = page.locator("#live");
        const retry = live.getByRole("button", { name: "Retry", exact: true });
        await retry.waitFor({ timeout: 12_000 });
        await context.setOffline(true);
        assert.equal(await page.evaluate(() => navigator.onLine), false);
        const pausedStarted = Date.now();
        await retry.click();
        await live.locator("#live-error").filter({
          hasText: "You are offline. Reconnect, then retry.",
        }).waitFor({ timeout: 1_000 });
        const offlineMessageMs = Date.now() - pausedStarted;
        // Wait beyond the active read's eight-second deadline. A paused query
        // never calls fetchSnapshot, so its promise deadline cannot help it.
        await page.waitForTimeout(10_500);
        const paused = await live.evaluate((section) => ({
          status: section.querySelector(".data-status").textContent,
          error: section.querySelector("#live-error")?.textContent ?? null,
          button: section.querySelector("button").textContent,
          describedBy: section.querySelector("button").getAttribute("aria-describedby"),
          disabled: section.querySelector("button").disabled,
        }));
        measurements.push({ width, offlineMessageMs, waitedOfflineMs: 10_500, ...paused });
        assert.match(
          paused.error ?? "",
          /You are offline\. Reconnect, then retry\./,
          JSON.stringify(paused),
        );
        assert.doesNotMatch(paused.status, /Reading Sepolia|Refreshes every/);
        assert.equal(paused.describedBy, "live-error");
        assert.equal(paused.button.trim(), "Retry");
        assert.equal(paused.disabled, false);
        assert.equal(await live.locator(".metric .unavailable").count(), 6);
        assert.ok(await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ));
        mkdirSync(resolve(output, ".."), { recursive: true });
        await retry.focus();
        await live.screenshot({ path: resolve(output, "..", `offline-retry-${width}.png`) });
        s.offline = false;
        await context.setOffline(false);
        await page.waitForFunction(
          () => document.querySelectorAll(".metric .unavailable").length === 0,
        );
        await live.getByRole("button", { name: "Refresh", exact: true }).waitFor();
        assert.equal(await live.locator("#live-error").count(), 0);
        // A paused refresh must also identify the connection problem when a
        // previous snapshot exists; the cached values must remain available.
        const assets = await live.locator(".metric").nth(3).innerText();
        await context.setOffline(true);
        await live.getByRole("button", { name: "Refresh", exact: true }).click();
        await live.locator("#live-error").filter({
          hasText: "You are offline. Reconnect, then retry.",
        }).waitFor({ timeout: 1_000 });
        assert.match(await live.locator("#live-error").innerText(), /last successful read/);
        assert.equal(await live.locator(".metric").nth(3).innerText(), assets);
        await context.setOffline(false);
        await live.getByRole("button", { name: "Refresh", exact: true }).waitFor();
        assert.equal(await live.locator("#live-error").count(), 0);
        assert.deepEqual(pageErrors, []);
      } finally {
        await context.close();
      }
    }
    return { measurements };
  });
  await test("Phone wallet sheet uses four deep links, local marks and focus return", async () => {
    const { page, context } = await fixturePage(browser, state(), {
      mobile: true,
    });
    await page.getByRole("button", { name: "Connect", exact: true }).click();
    const dialog = page.locator("dialog");
    assert.equal(await dialog.locator("a.sheet-row").count(), 4);
    assert.equal(
      await dialog
        .getByRole("button", { name: "Coinbase Smart Wallet" })
        .count(),
      1,
    );
    assert.equal(
      await dialog.getByText("Browser wallet", { exact: true }).count(),
      0,
    );
    for (const img of await dialog.locator("img").all())
      assert.ok(await img.evaluate((e) => e.complete && e.naturalWidth > 0));
    assert.ok(
      await dialog.evaluate(
        (e) => Math.abs(e.getBoundingClientRect().width - innerWidth) < 2,
      ),
    );
    const rabby = await dialog
      .getByRole("link", { name: "Open in Rabby" })
      .getAttribute("href");
    assert.equal(new URL(rabby).searchParams.get("_cmd"), "open-dapp");
    assert.equal(new URL(rabby).searchParams.get("dapp"), url);
    await page.keyboard.press("Escape");
    assert.ok(
      await page
        .locator(".wallet-button")
        .evaluate((e) => e === document.activeElement),
    );
    await context.close();
  });
  await test("EIP-6963 discovery, rejection, wrong chain and add-chain fallback", async () => {
    const { page, context } = await fixturePage(browser, state(), {
      wallet: true,
      chain: "0x1",
    });
    await page.evaluate(() => (window.__fixtureWallet.rejectConnect = true));
    await page.getByRole("button", { name: "Connect", exact: true }).click();
    assert.equal(
      await page
        .locator("dialog")
        .getByText("Browser wallet", { exact: true })
        .count(),
      0,
    );
    await page.getByRole("button", { name: "Fixture wallet" }).click();
    await waitText(page, "Request declined");
    await page.evaluate(() => (window.__fixtureWallet.rejectConnect = false));
    await page.getByRole("button", { name: "Fixture wallet" }).click();
    await page.locator("dialog").waitFor({ state: "hidden" });
    await waitText(page, "Switch to Sepolia");
    await page.evaluate(() => (window.__fixtureWallet.unknownChain = true));
    await page
      .getByRole("button", { name: "Switch to Sepolia", exact: true })
      .click();
    await page.waitForFunction(() =>
      document.querySelector(".wallet-button")?.textContent?.includes("0x"),
    );
    const requests = await page.evaluate(() => window.__fixtureWallet.requests);
    const add = requests.find((r) => r.method === "wallet_addEthereumChain");
    assert.equal(add.params[0].chainId, "0xaa36a7");
    assert.ok(
      add.params[0].rpcUrls.includes(
        "https://ethereum-sepolia-rpc.publicnode.com",
      ),
    );
    await page.locator(".wallet-button").click();
    await page.getByRole("button", { name: "Disconnect", exact: true }).click();
    await waitText(page, "Connect");
    await context.close();
  });
  await test("Exact approval, openPolicy calldata, receipt and emitted policy ID", async () => {
    const s = state();
    const { page, context, pageErrors } = await fixturePage(browser, s, {
      wallet: true,
    });
    await connect(page);
    await page.getByRole("button", { name: "Get quote", exact: true }).click();
    await waitText(page, "Review your quote");
    await page.getByRole("checkbox").check();
    await page
      .getByRole("button", { name: "Approve mSQK", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Open policy", exact: true })
      .waitFor({ timeout: 12000 });
    await page
      .getByRole("button", { name: "Open policy", exact: true })
      .click();
    await waitText(page, "Opened policy");
    assert.equal(s.sent.length, 2);
    assert.equal(s.sent[0].functionName, "approve");
    assert.equal(s.sent[0].args[0].toLowerCase(), addresses.PolicyBook);
    assert.equal(s.sent[0].args[1], 5n * UNIT);
    assert.equal(s.sent[1].functionName, "openPolicy");
    assert.deepEqual(s.sent[1].args.slice(0, 5), [
      107n,
      6,
      5000,
      100n * UNIT,
      5n * UNIT,
    ]);
    assert.ok(s.sent[1].args[5] > BigInt(Math.floor(Date.now() / 1000)));
    assert.deepEqual(pageErrors, []);
    await context.close();
  });
  await test("LP preview, exact deposit approval, minimum output and redeem raw shares", async () => {
    const s = state();
    const { page, context } = await fixturePage(browser, s, { wallet: true });
    await connect(page);
    await page.getByRole("tab", { name: "Liquidity", exact: true }).click();
    await page.locator("#lp-amount").fill("10");
    await page
      .getByRole("button", { name: "Preview deposit", exact: true })
      .click();
    await waitText(page, "Review deposit");
    await page.getByRole("checkbox").check();
    await page
      .getByRole("button", { name: "Approve mSQK", exact: true })
      .click();
    await page
      .getByRole("button", { name: "Deposit mSQK", exact: true })
      .waitFor({ timeout: 12000 });
    await page
      .getByRole("button", { name: "Deposit mSQK", exact: true })
      .click();
    await waitText(page, "Deposit confirmed");
    assert.equal(s.sent[0].args[0].toLowerCase(), addresses.CoverPool);
    assert.equal(s.sent[0].args[1], 10n * UNIT);
    assert.deepEqual(s.sent[1].args, [10n * UNIT, 9950000000000000000000000n]);
    await page.getByRole("radio", { name: "Redeem", exact: true }).check();
    await page.locator("#lp-amount").fill("1000000000000000000000000");
    await page
      .getByRole("button", { name: "Preview redemption", exact: true })
      .click();
    await waitText(page, "Review redemption");
    await page.getByRole("checkbox").check();
    await page
      .getByRole("button", { name: "Redeem shares", exact: true })
      .click();
    await waitText(page, "Redemption confirmed");
    assert.equal(s.sent[2].functionName, "redeem");
    assert.deepEqual(s.sent[2].args, [
      1000000000000000000000000n,
      995000000000000000n,
    ]);
    await context.close();
  });
  await test("Policy lookup, permissionless settle, unknown prefix and review", async () => {
    const s = state();
    const { page, context } = await fixturePage(browser, s, { wallet: true });
    await connect(page);
    await page.getByRole("tab", { name: "Settle", exact: true }).click();
    await page.locator("#policy-id").fill("999");
    await page
      .getByRole("button", { name: "Look up policy", exact: true })
      .click();
    await waitText(page, "No policy exists");
    await page.locator("#policy-id").fill("1");
    await page
      .getByRole("button", { name: "Look up policy", exact: true })
      .click();
    await waitText(page, "Certified history fixes");
    await page
      .getByRole("button", { name: "Settle policy", exact: true })
      .click();
    await waitText(page, "Settlement confirmed");
    assert.equal(s.sent[0].functionName, "settle");
    assert.deepEqual(s.sent[0].args, [1n]);
    s.policies.get(1n).status = 1;
    s.frontier = 89n;
    await page
      .getByRole("button", { name: "Look up policy", exact: true })
      .click();
    await waitText(page, "Outcome is not yet fixed");
    assert.ok(
      await page
        .getByRole("button", { name: "Settle policy", exact: true })
        .isDisabled(),
    );
    await page
      .getByRole("button", { name: "Review policy", exact: true })
      .click();
    await waitText(page, "Policy review confirmed");
    assert.equal(s.sent[1].functionName, "review");
    await context.close();
  });
  await test("RPC code mismatch gates writes; transaction rejection and reversion stay recoverable", async () => {
    const s = state();
    s.wrongCode = true;
    const { page, context } = await fixturePage(browser, s, { wallet: true });
    await connect(page);
    await page.getByRole("button", { name: "Get quote", exact: true }).click();
    await waitText(page, "Review your quote");
    await page.getByRole("checkbox").check();
    await waitText(page, "Deployment checks have not passed");
    assert.equal(
      await page
        .getByRole("button", { name: "Approve mSQK", exact: true })
        .count(),
      0,
    );
    s.wrongCode = false;
    await page.getByRole("button", { name: "Refresh", exact: true }).click();
    await page
      .getByRole("button", { name: "Approve mSQK", exact: true })
      .waitFor();
    s.reject = true;
    await page
      .getByRole("button", { name: "Approve mSQK", exact: true })
      .click();
    await waitText(page, "Request declined");
    assert.equal(s.sent.length, 0);
    s.reject = false;
    s.receiptStatus = "0x0";
    await page
      .getByRole("button", { name: "Approve mSQK", exact: true })
      .click();
    await waitText(page, "transaction reverted");
    assert.equal(
      await page
        .getByRole("button", { name: "Open policy", exact: true })
        .count(),
      0,
    );
    await context.close();
  });
  await test("Keyboard tabs, missing liquidity, settlement gate and anchor navigation", async () => {
    const s = state();
    const { page, context } = await fixturePage(browser, s);
    await page.getByRole("tab", { name: "Get COVER", exact: true }).focus();
    await page.keyboard.press("ArrowRight");
    assert.equal(
      await page
        .getByRole("tab", { name: "Liquidity", exact: true })
        .getAttribute("aria-selected"),
      "true",
    );
    s.pending = true;
    await page.locator("#lp-amount").fill("10");
    await page
      .getByRole("button", { name: "Preview deposit", exact: true })
      .click();
    await waitText(page, "Settlement or review is pending");
    await page.getByRole("tab", { name: "Settle", exact: true }).focus();
    await page.keyboard.press("Home");
    s.assets = 1n * UNIT;
    await page.getByRole("button", { name: "Get quote", exact: true }).click();
    await waitText(page, "not enough free pool liquidity");
    await page.locator(".token-note a").click();
    assert.ok(page.url().endsWith("#risks"));
    await context.close();
  });
  await test("Hung RPCs: spinners stop at the deadline and errors sit under the button", async () => {
    const s = state();
    s.hang = 30_000;
    const { page, context } = await fixturePage(browser, s);
    const started = Date.now();
    await waitText(page, "Reading Sepolia");
    await page
      .getByRole("button", { name: "Retry", exact: true })
      .waitFor({ timeout: 11_000 });
    const liveSeconds = (Date.now() - started) / 1000;
    assert.match(
      await page.locator("#live-error").innerText(),
      /took longer than 8 seconds|Sepolia could not be reached/,
    );
    await page.getByRole("button", { name: "Get quote", exact: true }).click();
    const quoteStarted = Date.now();
    await page
      .getByRole("button", { name: "Reading quote…", exact: true })
      .waitFor({ timeout: 2_000 });
    const retry = page.getByRole("button", { name: "Retry quote", exact: true });
    await retry.waitFor({ timeout: 11_000 });
    const quoteSeconds = (Date.now() - quoteStarted) / 1000;
    assert.ok(quoteSeconds < 10, `quote spinner ran ${quoteSeconds}s`);
    const placement = await retry.evaluate((button) => ({
      next: button.nextElementSibling?.id,
      text: button.nextElementSibling?.textContent,
      describedBy: button.getAttribute("aria-describedby"),
      className: button.className,
      gap:
        button.nextElementSibling.getBoundingClientRect().top -
        button.getBoundingClientRect().bottom,
    }));
    assert.equal(placement.next, "cover-error");
    assert.equal(placement.describedBy, "cover-error");
    assert.match(
      placement.text,
      /took longer than 8 seconds|Sepolia could not be reached/,
    );
    assert.match(placement.className, /failed/);
    assert.ok(placement.gap < 24);
    // Recovery: RPCs answer again, the same button retries successfully.
    s.hang = 0;
    await retry.click();
    await waitText(page, "Review your quote");
    s.hang = 30_000;
    await page.getByRole("tab", { name: "Settle" }).click();
    await page.locator("#policy-id").fill("1");
    await page.getByRole("button", { name: "Look up policy" }).click();
    const lookup = page.getByRole("button", {
      name: "Retry lookup",
      exact: true,
    });
    await lookup.waitFor({ timeout: 11_000 });
    assert.equal(
      await lookup.evaluate((b) => b.nextElementSibling?.id),
      "policy-error",
    );
    await page.getByRole("tab", { name: "Liquidity" }).click();
    await page.locator("#lp-amount").fill("10");
    await page.getByRole("button", { name: "Preview deposit" }).click();
    const preview = page.getByRole("button", {
      name: "Retry deposit",
      exact: true,
    });
    await preview.waitFor({ timeout: 11_000 });
    assert.equal(
      await preview.evaluate((b) => b.nextElementSibling?.id),
      "lp-error",
    );
    await context.close();
    return {
      liveReadCappedSeconds: Number(liveSeconds.toFixed(1)),
      quoteCappedSeconds: Number(quoteSeconds.toFixed(1)),
      errorPlacement: "directly under the action button (quote, lookup, preview)",
    };
  });
  await test("How COVER pays out explains Core, frontier, terms, settlement and LPs; token chips", async () => {
    const s = state();
    s.configured = false;
    const { page, context } = await fixturePage(browser, s);
    const how = page.locator("#how");
    for (const text of [
      "A buyer pays an mSQK premium for a fixed payout C.",
      "about 10 minutes per round",
      "Only rounds at or before the certified frontier count.",
      "missing active record inside certified history counts as",
      "Rounds past the frontier are unknown.",
      "If Core lags, settlement can wait indefinitely.",
      "6, 12, 24 or 144 rounds",
      "30%, 50% or 70% zero-work",
      "pool reserves C",
      "anyone may",
      "The premium stays in the pool either way.",
      "Early settlement is allowed",
      "A deposit mints shares",
      "Reservations have no automatic timeout.",
      "zero-work rounds / N ≥ T → payout C",
    ])
      assert.ok((await how.getByText(text, { exact: false }).count()) > 0, text);
    assert.equal(await how.locator("details summary").count(), 1);
    const order = await how.evaluate((section) => {
      const all = section.innerText;
      return [
        all.indexOf("Where rounds come from"),
        all.indexOf("Early settlement and LP gate details"),
      ];
    });
    assert.ok(order[0] > 0 && order[0] < order[1]);
    assert.ok(!/insurance/i.test(await page.locator("body").innerText()));
    assert.equal(
      await page
        .getByText("Illustrative window, not live round history.")
        .count(),
      1,
    );
    assert.equal(
      await page.locator("#cover-token").innerText(),
      "mSQK (on-chain symbol SQI)",
    );
    assert.match(
      await page.locator("#cover-amount").getAttribute("aria-describedby"),
      /cover-token/,
    );
    await waitText(page, "Demo pool not activated / unfunded");
    await page.getByRole("tab", { name: "Liquidity" }).click();
    assert.equal(
      await page.locator("#lp-token").innerText(),
      "mSQK (on-chain symbol SQI)",
    );
    await page.getByRole("radio", { name: "Redeem" }).check();
    assert.equal(
      await page.locator("#lp-token").innerText(),
      "Pays out mSQK (on-chain symbol SQI)",
    );
    await context.close();
  });
  await test("WebKit primary quote interaction", async () => {
    let browser;
    try {
      browser = await webkit.launch();
    } catch (e) {
      return {
        limitation:
          "WebKit could not start: " +
          e.message.split("\n").slice(0, 8).join("\n"),
        unperformed: true,
      };
    }
    browsers.push(browser);
    const { page, context } = await fixturePage(browser, state());
    await page.getByRole("button", { name: "Get quote", exact: true }).click();
    await waitText(page, "Review your quote");
    await context.close();
  });
} finally {
  for (const browser of browsers) await browser.close();
  await new Promise((resolve) => server.close(resolve));
  mkdirSync(resolve(output, ".."), { recursive: true });
  writeFileSync(
    output,
    JSON.stringify(
      {
        testedAt: new Date().toISOString(),
        mode: "Offline RPC and EIP-6963 wallet fixtures; no real transaction sent",
        results,
      },
      null,
      2,
    ) + "\n",
  );
}
if (results.some((r) => r.status === "failed")) process.exitCode = 1;
