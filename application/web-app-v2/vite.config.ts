import { resolve } from 'node:path';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// Backend (FastAPI) dev server — see application/server.py (uvicorn on :27099).
const BACKEND = 'http://localhost:27099';

// Same-origin API/book routes are proxied to the backend during dev so the
// browser sees one origin (cookies + no CORS surprises), matching production.
const proxy = {
  '/api': { target: BACKEND, changeOrigin: true },
  '/books': { target: BACKEND, changeOrigin: true },
  '/favicon.png': { target: BACKEND, changeOrigin: true },
} as const;

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      // The hand-maintained STATIC_ASSETS list in v1's sw.js broke on every
      // rename. Workbox precaches the hashed build output instead.
      workbox: {
        globPatterns: ['**/*.{js,css,html,png,svg,woff2}'],
        // /api/* is never cached; book pages are cache-first at runtime.
        navigateFallbackDenylist: [/^\/api/, /^\/books/],
        runtimeCaching: [
          {
            urlPattern: ({ url }) => url.pathname.startsWith('/books/'),
            handler: 'CacheFirst',
            options: {
              cacheName: 'bilingual-reader-books-v3',
              expiration: { maxEntries: 2000 },
              cacheableResponse: { statuses: [0, 200] },
            },
          },
          {
            urlPattern: ({ url }) => url.pathname.startsWith('/api/'),
            handler: 'NetworkOnly',
          },
        ],
      },
      manifest: {
        name: 'Bilingual Digital Library & AI Assistant',
        short_name: 'Bilingual Reader',
        lang: 'vi',
        start_url: '/',
        display: 'standalone',
        background_color: '#0f1115',
        theme_color: '#0f1115',
        icons: [
          { src: '/favicon.png', sizes: '512x512', type: 'image/png', purpose: 'any maskable' },
        ],
      },
      devOptions: { enabled: false },
    }),
  ],
  resolve: {
    alias: { '@': resolve(__dirname, 'src') },
  },
  build: {
    outDir: 'dist',
    // Two entry points → two bundles (reader SPA + admin), sharing chunks.
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        admin: resolve(__dirname, 'admin.html'),
      },
    },
  },
  server: {
    port: 5173,
    proxy,
  },
  preview: {
    port: 4173,
    proxy,
  },
});
