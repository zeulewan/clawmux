import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

export default defineConfig({
  plugins: [react()],
  server: {
    // Listen on all interfaces so the dev server is reachable over Tailscale.
    host: true,
    // Forward backend traffic to the main clawmux server so `npm run dev` gives
    // HMR on the frontend while the backend keeps handling agents/SSE/WS.
    proxy: {
      '/api': 'http://localhost:3470',
      '/ws': { target: 'ws://localhost:3470', ws: true },
    },
  },
  build: {
    outDir: resolve(__dirname, 'dist'),
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: 'webview.js',
        assetFileNames: (info) => {
          if (info.name?.endsWith('.css')) return 'webview.css';
          return 'assets/[name]-[hash][extname]';
        },
      },
    },
  },
});
