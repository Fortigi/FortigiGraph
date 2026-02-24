import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { authMiddleware } from './middleware/auth.js';
import { perfMetrics } from './middleware/perfMetrics.js';
import { enable as enablePerf, isEnabled as isPerfEnabled } from './perf/collector.js';
import permissionsRouter from './routes/permissions.js';
import tagsRouter from './routes/tags.js';
import categoriesRouter from './routes/categories.js';
import detailsRouter from './routes/details.js';
import governanceRouter from './routes/governance.js';
import perfRouter from './routes/perf.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const port = process.env.PORT || 3001;
const isProduction = process.env.NODE_ENV === 'production';
const authEnabled = process.env.AUTH_ENABLED === 'true';
const perfEnabled = process.env.PERF_METRICS_ENABLED === 'true';

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
  methods: ['GET', 'POST', 'PATCH', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  exposedHeaders: ['Server-Timing'],  // Allow browser to read Server-Timing header
};
app.use(cors(corsOptions));

// ─── Body parsing with size limit ────────────────────────────────
app.use(express.json({ limit: '100kb' }));

// ─── Performance metrics middleware (before routes, after body parsing) ─
app.use('/api', perfMetrics);

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
app.use('/api', authMiddleware, governanceRouter);

// In production, serve the frontend build output
const frontendDist = join(__dirname, '../../frontend/dist');
app.use(express.static(frontendDist));
app.get('*', (req, res, next) => {
  // Only serve index.html for non-API routes (SPA fallback)
  if (req.path.startsWith('/api')) return next();
  res.sendFile(join(frontendDist, 'index.html'));
});

const server = app.listen(port, () => {
  console.log(`FortigiGraph UI running on http://localhost:${port}`);
  console.log(`Mode: ${process.env.USE_SQL === 'true' ? 'SQL' : 'Mock data'}`);
  console.log(`Auth: ${authEnabled ? 'Entra ID' : 'Disabled'}`);
  console.log(`Perf: ${isPerfEnabled() ? 'Enabled (Server-Timing headers + /api/perf)' : 'Disabled'}`);
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
