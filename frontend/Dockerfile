# Multi-stage build: compile the Vite/React app, then serve the built
# static output (dist/) via nginx.
#
# Both deploy/docker-compose.yml and deploy/docker-compose.coolify.yml
# previously bind-mounted this directory's raw source straight into nginx's
# html root (`image: nginx:alpine` + `volumes: - ../frontend:/usr/share/
# nginx/html:ro`) — nginx was serving index.html/src/*.tsx unbuilt, since
# nothing ever ran `npm run build`. This Dockerfile is that missing build
# step; both compose files now build from it instead.
#
# Node version matches ci.yml's pinned "Set up Node" step (20), not whatever
# the base image's default happens to be.
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build   # tsc && vite build — see package.json

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
# SPA fallback: App.tsx uses react-router's BrowserRouter with client-side
# routes (/sessions/:id, /auth/callback, etc.) — without try_files falling
# back to index.html, a direct navigation or refresh on any non-root route
# 404s, since nginx would otherwise look for a literal file at that path.
COPY nginx.conf /etc/nginx/conf.d/default.conf
