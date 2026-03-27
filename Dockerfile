# Root-context Dockerfile — used by New-FGUI / Update-FGUI for Azure App Service deployment.
# Build context: repo root  (contains UI/frontend/ and UI/backend/)

# ── Stage 1: Build frontend ───────────────────────────────────────────────────
FROM node:20-slim AS frontend-build
WORKDIR /app/frontend
COPY UI/frontend/package*.json ./
RUN npm ci
COPY UI/frontend/ .
RUN npm run build

# ── Stage 2: Backend runtime ──────────────────────────────────────────────────
FROM node:20-slim AS runtime
WORKDIR /app/backend
COPY UI/backend/package*.json ./
RUN npm ci --omit=dev
COPY UI/backend/src ./src
# Copy the compiled frontend so Express can serve it as static files
COPY --from=frontend-build /app/frontend/dist ../frontend/dist

EXPOSE 3001
CMD ["node", "src/index.js"]
