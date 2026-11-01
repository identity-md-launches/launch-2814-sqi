import { useEffect, useRef, useState } from "react";
import {
  useConnect,
  useConnection,
  useConnectors,
  useDisconnect,
  useSwitchChain,
} from "wagmi";
import { getAddress, type EIP1193Provider } from "viem";
import { chain, explorerAddress, RPC_URLS, EXPLORER } from "./config";
import { explainError, shortAddress } from "./domain";
import { Icon } from "./Icons";

export const openIn = [
  {
    id: "metamask",
    name: "MetaMask",
    href: (url: string) =>
      `https://link.metamask.io/dapp/${url.replace(/^https?:\/\//, "")}`,
  },
  {
    id: "coinbase",
    name: "Coinbase Wallet",
    href: (url: string) =>
      `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(url)}`,
  },
  {
    id: "rabby",
    name: "Rabby",
    href: (url: string) =>
      `https://go.rabby.io/mobile/?_cmd=open-dapp&dapp=${encodeURIComponent(url)}`,
  },
  {
    id: "phantom",
    name: "Phantom",
    href: (url: string) =>
      `https://phantom.app/ul/browse/${encodeURIComponent(url)}?ref=${encodeURIComponent(new URL(url).origin)}`,
  },
];

export function WalletControl({
  open,
  onOpen,
  onClose,
}: {
  open: boolean;
  onOpen: () => void;
  onClose: () => void;
}) {
  const { address, isConnected, chainId, connector } = useConnection();
  const connectors = useConnectors();
  const { mutateAsync: connect, isPending, variables } = useConnect();
  const { mutate: disconnect } = useDisconnect();
  const { mutateAsync: switchChain } = useSwitchChain();
  const [switching, setSwitching] = useState(false);
  const [error, setError] = useState("");
  const dialog = useRef<HTMLDialogElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const opener = useRef<HTMLElement | null>(null);
  const named = connectors.some(
    (c) => c.type === "injected" && c.id !== "injected",
  );
  const mobile =
    /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) &&
    !named &&
    !("ethereum" in window);
  const listed = connectors.filter(
    (c) =>
      !(named && c.id === "injected") && !(mobile && c.type === "injected"),
  );
  useEffect(() => {
    if (open && !dialog.current?.open) {
      opener.current = document.activeElement as HTMLElement;
      dialog.current?.showModal();
    } else if (!open && dialog.current?.open) {
      dialog.current.close();
      (opener.current?.isConnected ? opener.current : trigger.current)?.focus();
    }
  }, [open]);
  async function switchNetwork() {
    setError("");
    setSwitching(true);
    try {
      const provider = (await connector?.getProvider()) as
        | EIP1193Provider
        | undefined;
      if (!provider)
        throw new Error("Reconnect your wallet before switching networks.");
      try {
        await provider.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: "0xaa36a7" }],
        });
      } catch (error) {
        const e = error as {
          code?: number;
          data?: { originalError?: { code?: number } };
        };
        if (e.code !== 4902 && e.data?.originalError?.code !== 4902)
          throw error;
        await provider.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: "0xaa36a7",
              chainName: chain.name,
              rpcUrls: [...RPC_URLS],
              nativeCurrency: chain.nativeCurrency,
              blockExplorerUrls: [EXPLORER],
            },
          ],
        });
        await provider.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: "0xaa36a7" }],
        });
      }
      // Reconcile connector state even for providers that omit chainChanged.
      await switchChain({ chainId: chain.id });
    } catch (e) {
      setError(explainError(e));
      onOpen();
    } finally {
      setSwitching(false);
    }
  }
  const wrongChain = isConnected && chainId !== chain.id;
  return (
    <>
      <button
        ref={trigger}
        className="button wallet-button"
        onClick={
          wrongChain
            ? switchNetwork
            : () => {
                setError("");
                onOpen();
              }
        }
        disabled={switching}
      >
        <Icon name="wallet" />
        {switching
          ? "Switching…"
          : wrongChain
            ? "Switch to Sepolia"
            : address
              ? shortAddress(getAddress(address))
              : "Connect"}
      </button>
      <dialog
        ref={dialog}
        className="wallet-sheet"
        aria-labelledby="wallet-title"
        onCancel={onClose}
        onClick={(e) => {
          if (e.target === dialog.current) {
            const r = dialog.current.getBoundingClientRect();
            if (
              e.clientX < r.left ||
              e.clientX > r.right ||
              e.clientY < r.top ||
              e.clientY > r.bottom
            )
              onClose();
          }
        }}
      >
        <div className="sheet-heading">
          <h2 id="wallet-title">
            {isConnected ? "Wallet connection" : "Connect a wallet"}
          </h2>
          <button
            className="icon-button"
            onClick={onClose}
            aria-label="Close wallet sheet"
          >
            <Icon name="close" />
          </button>
        </div>
        {isConnected && address ? (
          <>
            <p className="muted">
              Connected on{" "}
              {chainId === chain.id ? "Sepolia" : `chain ${chainId}`}
            </p>
            <a
              className="address wallet-address"
              href={explorerAddress(address)}
              target="_blank"
              rel="noreferrer"
            >
              {getAddress(address)} <Icon name="external" size={16} />
            </a>
            {wrongChain && (
              <button
                className="button sheet-row"
                onClick={switchNetwork}
                disabled={switching}
              >
                Switch to Sepolia <Icon name="arrow" />
              </button>
            )}
            <button
              className="button sheet-row"
              onClick={() => {
                disconnect();
                onClose();
              }}
            >
              Disconnect <Icon name="close" />
            </button>
          </>
        ) : (
          <>
            <p className="muted sheet-note">
              Read freely. Connect only to send a Sepolia transaction.
            </p>
            {mobile &&
              openIn.map((wallet) => (
                <a
                  className="sheet-row"
                  key={wallet.id}
                  href={wallet.href(location.href)}
                >
                  <img
                    width="28"
                    height="28"
                    src={`./wallets/${wallet.id}.svg`}
                    alt=""
                  />
                  <span>Open in {wallet.name}</span>
                  <Icon name="external" size={16} />
                </a>
              ))}
            {listed.map((connector) => (
              <button
                className="sheet-row"
                key={connector.uid}
                disabled={isPending}
                onClick={async () => {
                  setError("");
                  try {
                    await connect({ connector });
                    onClose();
                  } catch (e) {
                    setError(explainError(e));
                  }
                }}
              >
                {connector.icon ? (
                  <img width="28" height="28" src={connector.icon} alt="" />
                ) : connector.id === "coinbaseWalletSDK" ? (
                  <img
                    width="28"
                    height="28"
                    src="./wallets/coinbase.svg"
                    alt=""
                  />
                ) : (
                  <Icon name="wallet" size={28} />
                )}
                <span>
                  {connector.id === "injected"
                    ? "Browser wallet"
                    : connector.id === "coinbaseWalletSDK"
                      ? mobile
                        ? "Coinbase Smart Wallet"
                        : "Coinbase Wallet"
                      : connector.name}
                  {isPending && variables?.connector === connector
                    ? " · opening…"
                    : ""}
                </span>
                <Icon name="arrow" size={16} />
              </button>
            ))}
            <p className="small muted">
              Coinbase uses a passkey smart wallet. Sepolia ETH pays gas; mSQK
              is supplied by the token owner.
            </p>
          </>
        )}
        <p className="error-text small" role="status">
          {error}
        </p>
      </dialog>
    </>
  );
}
