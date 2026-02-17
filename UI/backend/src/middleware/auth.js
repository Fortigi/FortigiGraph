import jwt from 'jsonwebtoken';
import jwksClient from 'jwks-rsa';

const authEnabled = process.env.AUTH_ENABLED === 'true';
const tenantId = process.env.AUTH_TENANT_ID;
const clientId = process.env.AUTH_CLIENT_ID;

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
    audience: `api://${clientId}`,
    issuer: `https://login.microsoftonline.com/${tenantId}/v2.0`,
    algorithms: ['RS256'],
  }, (err, decoded) => {
    if (err) {
      console.error('Token validation failed:', err.message);
      return res.status(401).json({ error: 'Invalid or expired token' });
    }
    req.user = decoded;
    next();
  });
}
