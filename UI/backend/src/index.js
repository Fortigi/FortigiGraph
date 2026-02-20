import express from 'express';
import cors from 'cors';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { authMiddleware } from './middleware/auth.js';
import permissionsRouter from './routes/permissions.js';
import tagsRouter from './routes/tags.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const port = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());

// Unauthenticated endpoints
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', mode: process.env.USE_SQL === 'true' ? 'sql' : 'mock' });
});

app.get('/api/auth-config', (req, res) => {
  const enabled = process.env.AUTH_ENABLED === 'true';
  res.json({
    enabled,
    clientId: enabled ? (process.env.AUTH_CLIENT_ID || '') : '',
    tenantId: enabled ? (process.env.AUTH_TENANT_ID || '') : '',
  });
});

// Auth middleware for all other API routes
app.use('/api', authMiddleware, permissionsRouter);
app.use('/api', authMiddleware, tagsRouter);

// In production, serve the frontend build output
const frontendDist = join(__dirname, '../../frontend/dist');
app.use(express.static(frontendDist));
app.get('*', (req, res, next) => {
  // Only serve index.html for non-API routes (SPA fallback)
  if (req.path.startsWith('/api')) return next();
  res.sendFile(join(frontendDist, 'index.html'));
});

app.listen(port, () => {
  console.log(`FortigiGraph UI running on http://localhost:${port}`);
  console.log(`Mode: ${process.env.USE_SQL === 'true' ? 'SQL' : 'Mock data'}`);
  console.log(`Auth: ${process.env.AUTH_ENABLED === 'true' ? 'Entra ID' : 'Disabled'}`);
});
