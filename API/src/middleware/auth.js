'use strict';

const jwt = require('jsonwebtoken');
const jwksClient = require('jwks-rsa');

// Cache JWKS client per tenant
const clientCache = new Map();

function getJwksClient(tenantId) {
  if (!clientCache.has(tenantId)) {
    clientCache.set(
      tenantId,
      jwksClient({
        jwksUri: `https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`,
        cache: true,
        cacheMaxEntries: 5,
        cacheMaxAge: 600000, // 10 minutes
      })
    );
  }
  return clientCache.get(tenantId);
}

function getKey(tenantId) {
  return (header, callback) => {
    const client = getJwksClient(tenantId);
    client.getSigningKey(header.kid, (err, key) => {
      if (err) return callback(err);
      callback(null, key.getPublicKey());
    });
  };
}

/**
 * Azure AD service principal authentication middleware.
 * Validates JWT Bearer tokens issued by Azure AD (v1 and v2).
 * Callers must have obtained a token with scope: api://<AZURE_CLIENT_ID>/.default
 */
function authMiddleware(req, res, next) {
  if (process.env.AUTH_ENABLED === 'false') {
    req.user = { sub: 'anonymous', roles: [] };
    return next();
  }

  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ code: 'UNAUTHORIZED', message: 'Bearer token is required' });
  }

  const token = authHeader.slice(7);
  const tenantId = process.env.AZURE_TENANT_ID;
  const clientId = process.env.AZURE_CLIENT_ID;

  if (!tenantId || !clientId) {
    console.error('[auth] AZURE_TENANT_ID or AZURE_CLIENT_ID not configured');
    return res.status(500).json({ code: 'INTERNAL_ERROR', message: 'Auth not configured' });
  }

  const validIssuers = [
    `https://login.microsoftonline.com/${tenantId}/v2.0`,
    `https://sts.windows.net/${tenantId}/`,
  ];

  jwt.verify(
    token,
    getKey(tenantId),
    {
      algorithms: ['RS256'],
      audience: [clientId, `api://${clientId}`],
      issuer: validIssuers,
    },
    (err, decoded) => {
      if (err) {
        console.warn('[auth] Token validation failed:', err.message);
        return res.status(401).json({ code: 'UNAUTHORIZED', message: 'Invalid or expired token' });
      }

      // Validate tenant
      const tokenTid = decoded.tid;
      if (tokenTid && tokenTid !== tenantId) {
        return res.status(401).json({ code: 'UNAUTHORIZED', message: 'Token tenant mismatch' });
      }

      // Optional role check
      const requiredRoles = process.env.AUTH_REQUIRED_ROLES
        ? process.env.AUTH_REQUIRED_ROLES.split(',').map((r) => r.trim()).filter(Boolean)
        : [];

      if (requiredRoles.length > 0) {
        const tokenRoles = decoded.roles || [];
        const hasRole = requiredRoles.some((r) => tokenRoles.includes(r));
        if (!hasRole) {
          return res.status(403).json({
            code: 'FORBIDDEN',
            message: `Required role(s): ${requiredRoles.join(', ')}`,
          });
        }
      }

      req.user = {
        sub: decoded.sub || decoded.oid,
        appId: decoded.appid || decoded.azp,
        tenantId: decoded.tid,
        roles: decoded.roles || [],
      };
      next();
    }
  );
}

module.exports = authMiddleware;
