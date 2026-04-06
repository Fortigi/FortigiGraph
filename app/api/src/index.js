import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { authMiddleware } from './middleware/auth.js';
import { perfMetrics } from './middleware/perfMetrics.js';
import { enable as enablePerf, isEnabled as isPerfEnabled } from './perf/collector.js';
import permissionsRouter from './routes/permissions.js';
import tagsRouter from './routes/tags.js';
import categoriesRouter from './routes/categories.js';
import detailsRouter from './routes/details.js';
// import governanceRouter from './routes/governance.js'; // temporarily disabled
import perfRouter from './routes/perf.js';
import riskRouter from './routes/riskScores.js';
import orgChartRouter from './routes/orgChart.js';
import clusterRouter from './routes/clusters.js';
import identitiesRouter from './routes/identities.js';
import preferencesRouter from './routes/preferences.js';
import systemsRouter from './routes/systems.js';
import resourcesRouter from './routes/resources.js';
import contextsRouter from './routes/contexts.js';
import adminRouter from './routes/admin.js';
import { adminCrawlersRouter, selfServiceCrawlersRouter } from './routes/crawlers.js';
import { crawlerAuthMiddleware } from './middleware/crawlerAuth.js';
import ingestRouter from './routes/ingest.js';
import jobsRouter from './routes/jobs.js';
import swaggerUi from 'swagger-ui-express';
import YAML from 'yamljs';
import { join as pathJoin } from 'path';
import { bootstrapWorker } from './bootstrap.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const port = process.env.PORT || 3001;
const isProduction = process.env.NODE_ENV === 'production';
const authEnabled = process.env.AUTH_ENABLED === 'true';
const perfEnabled = process.env.PERF_METRICS_ENABLED === 'true';

// Resolve module version: env var (set during deployment) → fallback to .psd1 manifest
let moduleVersion = process.env.MODULE_VERSION || null;
if (!moduleVersion) {
  try {
    const psdPath = join(__dirname, '../../../setup/IdentityAtlas.psd1');
    const psdContent = readFileSync(psdPath, 'utf-8');
    const match = psdContent.match(/ModuleVersion\s*=\s*'([^']+)'/);
    if (match) moduleVersion = match[1];
  } catch {
    // .psd1 not available (deployed environment without env var)
  }
}

// ─── Performance metrics (opt-in via PERF_METRICS_ENABLED=true) ─
if (perfEnabled) {
  enablePerf();
}

// ─── Startup env validation ──────────────────────────────────────
if (isProduction && !authEnabled) {
  console.warn('WARNING: AUTH_ENABLED is not set to "true" in production. All API endpoints are unauthenticated!');
}

// ─── Security headers ────────────────────────────────────────────
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],  // Tailwind uses inline styles
      fontSrc: ["'self'"],
      connectSrc: [
        "'self'",
        'https://login.microsoftonline.com',
        'https://graph.microsoft.com',
      ],
      frameSrc: ["'self'", 'https://login.microsoftonline.com'],
      imgSrc: ["'self'", 'data:'],
    },
  },
  crossOriginEmbedderPolicy: false,  // Required for MSAL redirects
  referrerPolicy: { policy: 'strict-origin-when-cross-origin' },
}));

// ─── CORS ────────────────────────────────────────────────────────
const corsOptions = {
  origin: process.env.ALLOWED_ORIGINS
    ? process.env.ALLOWED_ORIGINS.split(',').map(o => o.trim())
    : isProduction
      ? false  // Disallow cross-origin in production if not explicitly configured
      : true,  // Allow all origins in development
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  exposedHeaders: ['Server-Timing'],  // Allow browser to read Server-Timing header
};
app.use(cors(corsOptions));

// ─── Body parsing with size limit ────────────────────────────────
app.use(express.json({ limit: '100kb' }));

// ─── Performance metrics middleware (before routes, after body parsing) ─
app.use('/api', perfMetrics);

// ─── Swagger / OpenAPI docs (public) ─────────────────────────────
try {
  const openapiSpec = YAML.load(pathJoin(__dirname, 'openapi.yaml'));
  app.get('/api/openapi.json', (req, res) => res.json(openapiSpec));
  app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(openapiSpec, {
    customSiteTitle: 'Identity Atlas Ingest API',
  }));
} catch {
  // OpenAPI spec not available — skip Swagger UI
}

// ─── Rate limiting on unauthenticated endpoints ──────────────────
const publicLimiter = rateLimit({
  windowMs: 60 * 1000,  // 1 minute
  max: 30,               // 30 requests per minute per IP
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests, please try again later' },
});

// Unauthenticated endpoints (rate-limited)
app.get('/api/health', publicLimiter, (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/api/version', publicLimiter, (req, res) => {
  res.json({ version: moduleVersion || null });
});

app.get('/api/features', publicLimiter, (req, res) => {
  res.json({
    riskScoring: process.env.FEATURE_RISK_SCORING !== 'false',
    accountCorrelation: process.env.FEATURE_ACCOUNT_CORRELATION !== 'false',
  });
});

app.get('/api/auth-config', publicLimiter, (req, res) => {
  // Only return client/tenant IDs when auth is enabled (needed by MSAL).
  // When auth is disabled, return enabled:true with empty IDs so the
  // response doesn't reveal that auth is off.
  if (!authEnabled) {
    return res.json({ enabled: false });
  }
  res.json({
    enabled: true,
    clientId: process.env.AUTH_CLIENT_ID || '',
    tenantId: process.env.AUTH_TENANT_ID || '',
  });
});

// Performance metrics routes (auth-protected)
app.use('/api', authMiddleware, perfRouter);

// Auth middleware for all other API routes
app.use('/api', authMiddleware, permissionsRouter);
app.use('/api', authMiddleware, tagsRouter);
app.use('/api', authMiddleware, categoriesRouter);
app.use('/api', authMiddleware, detailsRouter);
app.use('/api', authMiddleware, riskRouter);
app.use('/api', authMiddleware, orgChartRouter);
app.use('/api', authMiddleware, clusterRouter);
app.use('/api', authMiddleware, identitiesRouter);
app.use('/api', authMiddleware, preferencesRouter);
app.use('/api', authMiddleware, systemsRouter);
app.use('/api', authMiddleware, resourcesRouter);
app.use('/api', authMiddleware, contextsRouter);
app.use('/api/admin/import', express.json({ limit: '2mb' }));  // larger limit for import payloads
app.use('/api', authMiddleware, adminRouter);
// app.use('/api', authMiddleware, governanceRouter); // temporarily disabled

// ─── Crawler & job routes ───────────────────────────────────────
// Admin crawler management (Entra ID auth) — /api/admin/crawlers/*
app.use('/api', authMiddleware, adminCrawlersRouter);
// Crawler jobs (Entra ID auth) — /api/admin/crawler-jobs/*, /api/admin/status
app.use('/api', authMiddleware, jobsRouter);
// Crawler self-service (API key auth) — /api/crawlers/whoami, /api/crawlers/rotate
app.use('/api', crawlerAuthMiddleware, selfServiceCrawlersRouter);
// Ingest endpoints (API key auth) — /api/ingest/*
app.use('/api/ingest', express.json({ limit: '10mb' }));  // larger limit for ingest payloads
app.use('/api', crawlerAuthMiddleware, ingestRouter);

// In production, serve the frontend build output
const frontendDist = join(__dirname, '../../frontend/dist');
app.use(express.static(frontendDist));
app.get('*', (req, res, next) => {
  // Only serve index.html for non-API routes (SPA fallback)
  if (req.path.startsWith('/api')) return next();
  res.sendFile(join(frontendDist, 'index.html'));
});

const server = app.listen(port, async () => {
  console.log(`Identity Atlas running on http://localhost:${port}`);
  console.log(`Mode: ${process.env.USE_SQL === 'true' ? 'SQL' : 'Mock data'}`);
  console.log(`Auth: ${authEnabled ? 'Entra ID' : 'Disabled'}`);
  console.log(`Perf: ${isPerfEnabled() ? 'Enabled (Server-Timing headers + /api/perf)' : 'Disabled'}`);

  // Auto-create built-in worker crawler + infrastructure tables
  await bootstrapWorker();
});

// Graceful shutdown: close SQL pool before exiting
async function shutdown(signal) {
  console.log(`${signal} received, shutting down...`);
  server.close(async () => {
    if (process.env.USE_SQL === 'true') {
      const { closePool } = await import('./db/connection.js');
      await closePool();
    }
    process.exit(0);
  });
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
