import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The chat surface is served by its own image (docker/Dockerfile.ui); the
// supervisor base URL is injected at deploy time, never baked in here.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
})
