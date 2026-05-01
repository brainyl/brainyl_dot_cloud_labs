#!/bin/sh
# Runs at container start. Writes runtime env vars into a JS file that the
# Vue app reads via window.__APP_CONFIG__. This lets AppConfig/ECS control
# feature flags without rebuilding the image.
cat > /usr/share/nginx/html/config.js <<EOF
window.__APP_CONFIG__ = {
  ALLOW_DELETE: "${ALLOW_DELETE:-true}"
};
EOF

exec nginx -g "daemon off;"
