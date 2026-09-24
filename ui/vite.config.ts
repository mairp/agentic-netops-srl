import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// The chat surface is served by its own image (docker/Dockerfile.ui, ui/server.mjs); the
// supervisor base URL is injected at deploy time, never baked in here. In development the same
// same-origin /api prefix is proxied to SUPERVISOR_BASE_URL (default: a port-forward of the
// supervisor on 127.0.0.1:19090), with /api stripped — as ui/server.mjs does in the pod.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '')
  const target = env.SUPERVISOR_BASE_URL || 'http://127.0.0.1:19090'
  return {
    plugins: [react()],
    build: {
      outDir: 'dist',
      sourcemap: true,
    },
    server: {
      proxy: {
        '/api': {
          target,
          changeOrigin: true,
          rewrite: (path: string) => path.replace(/^\/api/, ''),
        },
      },
    },
  }
})
