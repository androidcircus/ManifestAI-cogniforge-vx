# rack-engine/frontend/Dockerfile
# Serves the production React build and proxies /api + /ws to the backend.
# Build is produced by scripts/deploy-cluster.sh before docker build.
FROM nginx:1.27-alpine

COPY build/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
