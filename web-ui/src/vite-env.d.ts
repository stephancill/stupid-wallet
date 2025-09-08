/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly [key: `VITE_RPC_URL_${number}`]: string;
  readonly VITE_ETHERSCAN_API_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
