'use strict';

require('dotenv').config();

const app = require('./app');
const { closePool } = require('./db/connection');

const PORT = parseInt(process.env.PORT || '3001', 10);

if (process.env.AUTH_ENABLED !== 'false' && !process.env.AZURE_TENANT_ID) {
  console.warn('[startup] WARNING: AUTH_ENABLED is not "false" but AZURE_TENANT_ID is not set.');
}

// Bind to 0.0.0.0 so the process is reachable inside containers
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`[startup] FortigiGraph Ingestion API v${require('../package.json').version} listening on 0.0.0.0:${PORT}`);
  if (process.env.SWAGGER_UI_ENABLED !== 'false') {
    console.log(`[startup] Swagger UI available at http://localhost:${PORT}/api-docs`);
  }
  console.log(`[startup] Auth: ${process.env.AUTH_ENABLED === 'false' ? 'DISABLED' : 'ENABLED'}`);
});

async function shutdown(signal) {
  console.log(`[shutdown] Received ${signal}, closing gracefully...`);

  // Force-exit if graceful shutdown takes more than 10 seconds (container kill timeout)
  const forceExit = setTimeout(() => {
    console.error('[shutdown] Graceful shutdown timed out, forcing exit.');
    process.exit(1);
  }, 10000);
  forceExit.unref();

  server.close(async () => {
    await closePool();
    console.log('[shutdown] Done.');
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
