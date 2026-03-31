import jwt from 'jsonwebtoken';
import jwksClient from 'jwks-rsa';

const authEnabled = process.env.AUTH_ENABLED === 'true';
const tenantId = process.env.AUTH_TENANT_ID;
const clientId = process.env.AUTH_CLIENT_ID;
// Optional: comma-separated list of required roles (e.g., "FortigiGraph.Read,FortigiGraph.Admin")
const requiredRoles = process.env.AUTH_REQUIRED_ROLES
  ? process.env.AUTH_REQUIRED_ROLES.split(',').map(r => r.trim())
  : null;

let client;
if (authEnabled && tenantId) {
  client = jwksClient({
    jwksUri: `https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`,
    cache: true,
    cacheMaxAge: 86400000,
  });
}

function getKey(header, callback) {
  client.getSigningKey(header.kid, (err, key) => {
    if (err) return callback(err);
    callback(null, key.getPublicKey());
  });
}

export function authMiddleware(req, res, next) {
  if (!authEnabled) return next();

  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid authorization header' });
  }

  const token = authHeader.split(' ')[1];

  jwt.verify(token, getKey, {
    audience: [`api://${clientId}`, clientId],
    issuer: [
      `https://login.microsoftonline.com/${tenantId}/v2.0`,
      `https://sts.windows.net/${tenantId}/`,
    ],
    algorithms: ['RS256'],
  }, (err, decoded) => {
    if (err) {
      console.error('Token validation failed:', err.message);
      return res.status(401).json({ error: 'Invalid or expired token' });
    }

    // Validate tenant ID from token claims (defense-in-depth)
    const tokenTid = decoded.tid;
    if (tokenTid && tokenTid !== tenantId) {
      console.error(`Token tenant mismatch: expected ${tenantId}, got ${tokenTid}`);
      return res.status(401).json({ error: 'Token issued by unexpected tenant' });
    }

    // Validate required roles if configured
    // Entra ID puts app roles in the 'roles' claim
    if (requiredRoles && requiredRoles.length > 0) {
      const tokenRoles = decoded.roles || [];
      const hasRequiredRole = requiredRoles.some(r => tokenRoles.includes(r));
      if (!hasRequiredRole) {
        console.error(`Token missing required role. Has: [${tokenRoles.join(', ')}], needs one of: [${requiredRoles.join(', ')}]`);
        return res.status(403).json({ error: 'Insufficient permissions' });
      }
    }

    req.user = decoded;
    next();
  });
}
