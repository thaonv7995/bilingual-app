/// <reference types="vite/client" />
/// <reference types="vite-plugin-pwa/client" />

interface ImportMetaEnv {
  readonly VITE_API_BASE?: string;
  readonly VITE_ENABLE_AUDIOBOOK?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
