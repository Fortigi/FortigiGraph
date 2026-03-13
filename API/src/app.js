'use strict';

const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const YAML = require('yamljs');
const swaggerUi = require('swagger-ui-express');
const path = require('path');

const authMiddleware = require('./middleware/auth');
const routes = require('./routes');

const app = express();

// ── Security headers ─────────────────────────────────────────────────
app.use(
  helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'", "'unsafe-inline'"], // needed for Swagger UI
        styleSrc: ["'self'", "'unsafe-inline'"],
        imgSrc: ["'self'", 'data:'],
      },
    },
    hsts: { maxAge: 31536000, includeSubDomains: true },
  })
);

// ── CORS ─────────────────────────────────────────────────────────────
const allowedOrigins = process.env.ALLOWED_ORIGINS
  ? process.env.ALLOWED_ORIGINS.split(',').map((o) => o.trim())
  : [];

app.use(
  cors({
    origin: (origin, callback) => {
      if (!origin) return callback(null, true); // server-to-server / curl
      if (allowedOrigins.length === 0) return callback(null, false);
      if (allowedOrigins.includes(origin)) return callback(null, true);
      callback(new Error('Not allowed by CORS'));
    },
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  })
);

// ── Body parsing ─────────────────────────────────────────────────────
app.use(express.json({ limit: '5mb' })); // batch of 1000 records can be large

// ── Rate limiting ─────────────────────────────────────────────────────
const limiter = rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS || '60000', 10),
  max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS || '200', 10),
  standardHeaders: true,
  legacyHeaders: false,
  message: { code: 'RATE_LIMITED', message: 'Too many requests, please slow down' },
});
app.use('/api/', limiter);

// ── Swagger UI (optional) ─────────────────────────────────────────────
if (process.env.SWAGGER_UI_ENABLED !== 'false') {
  const specPath = path.join(__dirname, '../../spec/openapi.yaml');
  const swaggerDocument = YAML.load(specPath);
  app.use(
    '/api-docs',
    swaggerUi.serve,
    swaggerUi.setup(swaggerDocument, {
      customSiteTitle: 'FortigiGraph Ingestion API',
      swaggerOptions: {
        persistAuthorization: true,
      },
    })
  );
  app.get('/api-docs/openapi.yaml', (req, res) => {
    res.sendFile(specPath);
  });
}

// ── Health (no auth) ─────────────────────────────────────────────────
app.get('/api/v1/ingestion/health', (req, res) => {
  res.json({
    status: 'ok',
    version: require('../package.json').version,
    timestamp: new Date().toISOString(),
  });
});

// ── Protected routes ─────────────────────────────────────────────────
app.use('/api/v1/ingestion', authMiddleware, routes);

// ── 404 handler ───────────────────────────────────────────────────────
app.use((req, res) => {
  res.status(404).json({ code: 'NOT_FOUND', message: `Route ${req.method} ${req.path} not found` });
});

// ── Error handler ─────────────────────────────────────────────────────
app.use((err, req, res, _next) => {
  console.error('[app] Unhandled error:', err);
  res.status(500).json({ code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' });
});

module.exports = app;
