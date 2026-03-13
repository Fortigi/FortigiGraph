# ─── Build stage ──────────────────────────────────────────────────────────────
FROM node:20-alpine AS build

WORKDIR /app

# Copy package files and install production deps only
COPY package.json ./
RUN npm install --omit=dev --frozen-lockfile

# ─── Runtime stage ────────────────────────────────────────────────────────────
FROM node:20-alpine AS runtime

# Install dumb-init for proper signal handling and PID 1 management
RUN apk add --no-cache dumb-init

# Non-root user for security
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy production node_modules from build stage
COPY --from=build /app/node_modules ./node_modules

# Copy application source and OpenAPI spec
COPY src/       ./src/
COPY spec/      ./spec/
COPY package.json ./

# Set ownership
RUN chown -R appuser:appgroup /app

USER appuser

# Expose API port (override with PORT env var)
EXPOSE 3001

# Health check — polls the /health endpoint every 30s
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:${PORT:-3001}/api/v1/ingestion/health || exit 1

# Use dumb-init to reap zombie processes and forward signals correctly
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "src/index.js"]
