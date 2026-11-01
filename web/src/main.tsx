import React, { Component, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { walletConfig } from "./config";
import App from "./App";
import "./styles.css";

const queries = new QueryClient({
  defaultOptions: { queries: { retry: false, refetchOnWindowFocus: true } },
});
class ErrorBoundary extends Component<
  { children: ReactNode },
  { failed: boolean }
> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  render() {
    return this.state.failed ? (
      <main className="shell fallback">
        <h1>COVER</h1>
        <p>
          The interface could not load. Your wallet has not been asked to send
          any new transaction by this error screen.
        </p>
        <button className="button primary" onClick={() => location.reload()}>
          Reload the page
        </button>
        <p>
          If a transaction was already submitted, check your wallet activity
          before retrying it.
        </p>
      </main>
    ) : (
      this.props.children
    );
  }
}
createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <ErrorBoundary>
      <WagmiProvider config={walletConfig}>
        <QueryClientProvider client={queries}>
          <App />
        </QueryClientProvider>
      </WagmiProvider>
    </ErrorBoundary>
  </React.StrictMode>,
);
