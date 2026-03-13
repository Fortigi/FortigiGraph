'use strict';

/**
 * Unit tests for src/middleware/auth.js
 *
 * The middleware is tested in isolation by:
 *   - mocking jsonwebtoken and jwks-rsa so no real Azure AD calls are made
 *   - injecting controlled decoded tokens or controlled errors
 */

const { jest } = require('@jest/globals');

// ── Mocks (must be set up before importing the module under test) ─────────────

const mockVerify = jest.fn();
jest.mock('jsonwebtoken', () => ({ verify: mockVerify }));

const mockGetSigningKey = jest.fn();
jest.mock('jwks-rsa', () =>
  jest.fn(() => ({ getSigningKey: mockGetSigningKey }))
);

const authMiddleware = require('../../src/middleware/auth');

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeReq(authHeader) {
  return { headers: { authorization: authHeader } };
}

function makeRes() {
  const res = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json   = jest.fn().mockReturnValue(res);
  return res;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('auth middleware', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    jest.resetAllMocks();
    process.env = {
      ...originalEnv,
      AZURE_TENANT_ID: 'test-tenant-id',
      AZURE_CLIENT_ID: 'test-client-id',
      AUTH_ENABLED: 'true',
    };
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  test('calls next() when AUTH_ENABLED=false', () => {
    process.env.AUTH_ENABLED = 'false';
    const req  = makeReq(undefined);
    const res  = makeRes();
    const next = jest.fn();

    authMiddleware(req, res, next);

    expect(next).toHaveBeenCalledTimes(1);
    expect(req.user).toEqual({ sub: 'anonymous', roles: [] });
    expect(res.status).not.toHaveBeenCalled();
  });

  test('returns 401 when Authorization header is missing', () => {
    const req  = makeReq(undefined);
    const res  = makeRes();
    const next = jest.fn();

    authMiddleware(req, res, next);

    expect(res.status).toHaveBeenCalledWith(401);
    expect(res.json).toHaveBeenCalledWith(
      expect.objectContaining({ code: 'UNAUTHORIZED' })
    );
    expect(next).not.toHaveBeenCalled();
  });

  test('returns 401 when Authorization header is not Bearer', () => {
    const req  = makeReq('Basic dXNlcjpwYXNz');
    const res  = makeRes();
    const next = jest.fn();

    authMiddleware(req, res, next);

    expect(res.status).toHaveBeenCalledWith(401);
    expect(next).not.toHaveBeenCalled();
  });

  test('returns 401 when jwt.verify errors', () => {
    mockGetSigningKey.mockImplementation((kid, cb) =>
      cb(null, { getPublicKey: () => 'fake-key' })
    );
    mockVerify.mockImplementation((_token, _getKey, _opts, cb) =>
      cb(new Error('jwt expired'))
    );

    const req  = makeReq('Bearer bad.token.here');
    const res  = makeRes();
    const next = jest.fn();

    authMiddleware(req, res, next);

    expect(res.status).toHaveBeenCalledWith(401);
    expect(res.json).toHaveBeenCalledWith(
      expect.objectContaining({ code: 'UNAUTHORIZED', message: 'Invalid or expired token' })
    );
    expect(next).not.toHaveBeenCalled();
  });

  test('returns 401 when token tenant does not match', () => {
    mockGetSigningKey.mockImplementation((kid, cb) =>
      cb(null, { getPublicKey: () => 'fake-key' })
    );
    mockVerify.mockImplementation((_token, _getKey, _opts, cb) =>
      cb(null, { sub: 'user1', tid: 'WRONG-TENANT', roles: [] })
    );

    const req  = makeReq('Bearer valid.token.here');
    const res  = makeRes();
    const next = jest.fn();

    authMiddleware(req, res, next);

    expect(res.status).toHaveBeenCalledWith(401);
    expect(res.json).toHaveBeenCalledWith(
      expect.objectContaining({ code: 'UNAUTHORIZED', message: 'Token tenant mismatch' })
    );
  });

  test('returns 403 when required role is missing', () => {
    process.env.AUTH_REQUIRED_ROLES = 'Ingestion.Write';
    mockGetSigningKey.mockImplementation((kid, cb) =>
      cb(null, { getPublicKey: () => 'fake-key' })
    );
    mockVerify.mockImplementation((_token, _getKey, _opts, cb) =>
      cb(null, { sub: 'app1', tid: 'test-tenant-id', roles: ['Ingestion.Read'] })
    );

    const req  = makeReq('Bearer valid.token');
    const res  = makeRes();
    const next = jest.fn();

    authMiddleware(req, res, next);

    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json).toHaveBeenCalledWith(
      expect.objectContaining({ code: 'FORBIDDEN' })
    );
    expect(next).not.toHaveBeenCalled();

    delete process.env.AUTH_REQUIRED_ROLES;
  });

  test('calls next() and sets req.user on valid token', () => {
    mockGetSigningKey.mockImplementation((kid, cb) =>
      cb(null, { getPublicKey: () => 'fake-key' })
    );
    mockVerify.mockImplementation((_token, _getKey, _opts, cb) =>
      cb(null, {
        sub: 'app-guid',
        oid: 'app-guid',
        tid: 'test-tenant-id',
        appid: 'some-app-id',
        roles: ['Ingestion.Write'],
      })
    );

    const req  = makeReq('Bearer good.token.here');
    const res  = makeRes();
    const next = jest.fn();

    authMiddleware(req, res, next);

    expect(next).toHaveBeenCalledTimes(1);
    expect(req.user).toMatchObject({
      sub: 'app-guid',
      tenantId: 'test-tenant-id',
      roles: ['Ingestion.Write'],
    });
  });

  test('calls next() when required role is present', () => {
    process.env.AUTH_REQUIRED_ROLES = 'Ingestion.Write';
    mockGetSigningKey.mockImplementation((kid, cb) =>
      cb(null, { getPublicKey: () => 'fake-key' })
    );
    mockVerify.mockImplementation((_token, _getKey, _opts, cb) =>
      cb(null, {
        sub: 'app1',
        tid: 'test-tenant-id',
        roles: ['Ingestion.Write', 'Ingestion.Read'],
      })
    );

    const req  = makeReq('Bearer good.token');
    const res  = makeRes();
    const next = jest.fn();

    authMiddleware(req, res, next);

    expect(next).toHaveBeenCalledTimes(1);
    delete process.env.AUTH_REQUIRED_ROLES;
  });
});
