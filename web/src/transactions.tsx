import { useRef, useState } from "react";
import { useConnection, useWalletClient } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { type Address, type TransactionReceipt } from "viem";
import { chain, publicClient, type ContractName, explorerTx } from "./config";
import { transactionRequest, verifyDeployment, type TxRecord } from "./chain";
import { explainError } from "./domain";
import { Icon } from "./Icons";

type Send = (
  name: ContractName,
  method: string,
  args: readonly unknown[],
  label: string,
) => Promise<TransactionReceipt>;
export function useTransactions() {
  const { address, chainId } = useConnection();
  const { data: wallet } = useWalletClient();
  const queryClient = useQueryClient();
  const connection = useRef({ address, chainId });
  connection.current = { address, chainId };
  const running = useRef(false);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState("");
  const [error, setError] = useState("");
  const [records, setRecords] = useState<TxRecord[]>([]);
  const [policyId, setPolicyId] = useState<bigint>();
  async function run(
    label: string,
    work: (send: Send, account: Address) => Promise<void>,
  ) {
    if (running.current) return;
    if (!wallet || !address || chainId !== chain.id) {
      setError("Connect a wallet on Sepolia before sending a transaction.");
      return;
    }
    running.current = true;
    setBusy(true);
    setError("");
    setProgress("Checking deployed contracts…");
    const account = address;
    async function assertConnection() {
      if (
        !wallet ||
        connection.current.address !== account ||
        connection.current.chainId !== chain.id ||
        (await wallet.getChainId()) !== chain.id
      )
        throw new Error(
          "The wallet account or chain changed. Review the action again on Sepolia.",
        );
      const accounts = await wallet.getAddresses();
      if (!accounts.some((a) => a.toLowerCase() === account.toLowerCase()))
        throw new Error(
          "The selected account is no longer authorized. Reconnect and review the action.",
        );
    }
    try {
      await assertConnection();
      await verifyDeployment();
      await work(async (name, method, args, actionLabel) => {
        await assertConnection();
        setProgress(`Simulating ${actionLabel.toLowerCase()}…`);
        const { request } = await publicClient.simulateContract(
          transactionRequest(name, method, args, account),
        );
        await assertConnection();
        setProgress(`Confirm ${actionLabel.toLowerCase()} in your wallet.`);
        const hash = await wallet.writeContract(request);
        setRecords((previous) => [
          ...previous,
          { hash, label: actionLabel, state: "pending" },
        ]);
        setProgress(`${actionLabel} submitted. Waiting for a Sepolia receipt…`);
        let activeHash = hash;
        let cancelled = false;
        try {
          const receipt = await publicClient.waitForTransactionReceipt({
            hash,
            timeout: 120_000,
            pollingInterval: 3_000,
            onReplaced: (replacement) => {
              activeHash = replacement.transaction.hash;
              cancelled = replacement.reason === "cancelled";
              setRecords((previous) =>
                previous.map((item) =>
                  item.hash === hash
                    ? {
                        ...item,
                        hash: activeHash,
                        label: `${actionLabel} (${replacement.reason})`,
                      }
                    : item,
                ),
              );
            },
          });
          setRecords((previous) =>
            previous.map((item) =>
              item.hash === activeHash
                ? {
                    ...item,
                    state:
                      receipt.status === "success" && !cancelled
                        ? "confirmed"
                        : "reverted",
                  }
                : item,
            ),
          );
          if (cancelled)
            throw new Error(
              "The transaction was cancelled in your wallet. Review before trying again.",
            );
          if (receipt.status !== "success")
            throw new Error(
              "The transaction reverted on Sepolia. Refresh the state before retrying; gas may have been spent.",
            );
          return receipt;
        } catch (e) {
          setRecords((previous) =>
            previous.map((item) =>
              item.hash === activeHash && item.state === "pending"
                ? { ...item, state: "unknown" }
                : item,
            ),
          );
          throw e;
        }
      }, account);
      setProgress(`${label} confirmed on Sepolia.`);
    } catch (e) {
      setError(explainError(e));
      setProgress("");
    } finally {
      running.current = false;
      setBusy(false);
      await queryClient.invalidateQueries();
    }
  }
  return { busy, progress, error, records, run, policyId, setPolicyId };
}
export type Transactions = ReturnType<typeof useTransactions>;
export function TransactionStatus({ tx }: { tx: Transactions }) {
  return (
    <div className="transaction-status">
      <p role="status" className="small">
        {tx.progress}
      </p>
      {tx.error && (
        <p role="alert" className="notice error">
          {tx.error}
        </p>
      )}
      {tx.records.length > 0 && (
        <ul className="transaction-list">
          {tx.records.map((item) => (
            <li key={item.hash}>
              <a href={explorerTx(item.hash)} target="_blank" rel="noreferrer">
                {item.label} ·{" "}
                {item.state === "unknown"
                  ? "receipt not confirmed; check explorer"
                  : item.state}{" "}
                <Icon name="external" size={16} />
              </a>
            </li>
          ))}
        </ul>
      )}
      {tx.policyId !== undefined && (
        <p className="small">
          Opened policy <strong>#{tx.policyId.toString()}</strong>. Inspect it
          in the Settle panel.
        </p>
      )}
    </div>
  );
}
