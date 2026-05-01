import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [
    vue(),
    {
      // Serves /config.js in dev mode the same way entrypoint.sh does in
      // production, so docker-compose env vars are picked up without a rebuild.
      name: 'runtime-config',
      configureServer(server) {
        server.middlewares.use('/config.js', (_req, res) => {
          res.setHeader('Content-Type', 'application/javascript')
          res.end(
            `window.__APP_CONFIG__ = { ALLOW_DELETE: "${process.env.ALLOW_DELETE ?? 'true'}" };`
          )
        })
      }
    }
  ],
  server: {
    host: '0.0.0.0',
    port: 8080
  }
})

