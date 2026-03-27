# Build context: ./UI  (one level above backend/)
# Usage: docker build -f backend/Dockerfile -t fortigraph-backend .

# ── Stage 1: Build frontend ───────────────────────────────────────────────────
FROM node:20-slim AS frontend-build
WORKDIR /app/frontend
COPY frontend/package*.json ./
RUN npm ci
COPY frontend/ .
RUN npm run build

# ── Stage 2: Backend runtime ──────────────────────────────────────────────────
FROM node:20-slim AS runtime
WORKDIR /app/backend
COPY backend/package*.json ./
RUN npm ci --omit=dev
COPY backend/src ./src
# Copy the compiled frontend so Express can serve it as static files
COPY --from=frontend-build /app/frontend/dist ../frontend/dist

EXPOSE 3001
CMD ["node", "src/index.js"]
