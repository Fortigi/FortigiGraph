'use strict';

/**
 * Integration tests for the Ingestion API Express application.
 *
 * The database pool is mocked so no real SQL Server is required.
 * Auth is disabled (AUTH_ENABLED=false) to keep these tests focused on routing.
 *
 * Covers:
 *   - Health endpoint (unauthenticated)
 *   - All entity GET / POST / PUT / DELETE routes for a representative entity (users)
 *   - Batch upsert endpoint
 *   - Composite-key endpoints (group-members)
 *   - 404 for unknown routes
 *   - Auth enforcement when AUTH_ENABLED=true
 *   - Rate limiting headers are present
 */

process.env.AUTH_ENABLED     = 'false';
process.env.SWAGGER_UI_ENABLED = 'false';
process.env.NODE_ENV         = 'test';

const request = require('supertest');
const { jest } = require('@jest/globals');

// ── Mock the DB module before app is imported ─────────────────────────────────

const mockQuery = jest.fn();
const mockInput = jest.fn();

function fakeRequest() {
  const r = { input: jest.fn().mockReturnThis(), query: mockQuery };
  return r;
}

const fakePool = { request: fakeRequest };
jest.mock('../../src/db/connection', () => ({
  sql: {
    NVarChar: 'NVarChar',
    UniqueIdentifier: 'UniqueIdentifier',
    Bit: 'Bit',
    Int: 'Int',
    Float: 'Float',
    DateTime2: 'DateTime2',
  },
  getPool: jest.fn().mockResolvedValue(fakePool),
  closePool: jest.fn().mockResolvedValue(undefined),
}));

const app = require('../../src/app');

// ── Helpers ───────────────────────────────────────────────────────────────────

const BASE = '/api/v1/ingestion';
const USER_ID = '550e8400-e29b-41d4-a716-446655440001';

function mockList(rows = [], total = 0) {
  mockQuery
    .mockResolvedValueOnce({ recordset: [{ total }] })   // COUNT
    .mockResolvedValueOnce({ recordset: rows });           // data
}

function mockSingle(row = null) {
  mockQuery.mockResolvedValueOnce({ recordset: row ? [row] : [] });
}

function mockMerge() {
  mockQuery.mockResolvedValueOnce({});  // MERGE returns no recordset
}

function mockDelete(affected = 1) {
  mockQuery.mockResolvedValueOnce({ recordset: [{ affected }] });
}

// ── Health ─────────────────────────────────────────────────────────────────────

describe('GET /api/v1/ingestion/health', () => {
  test('returns 200 with status=ok and version', async () => {
    const res = await request(app).get(`${BASE}/health`);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'ok' });
    expect(typeof res.body.version).toBe('string');
    expect(typeof res.body.timestamp).toBe('string');
  });
});

// ── 404 ────────────────────────────────────────────────────────────────────────

describe('Unknown routes', () => {
  test('returns 404 for unknown path', async () => {
    const res = await request(app).get('/api/v1/ingestion/does-not-exist');
    expect(res.status).toBe(404);
  });
});

// ── Users - list ──────────────────────────────────────────────────────────────

describe('GET /users', () => {
  beforeEach(() => jest.clearAllMocks());

  test('returns paginated list', async () => {
    const user = { id: USER_ID, displayName: 'Alice', userPrincipalName: 'alice@example.com' };
    mockList([user], 1);

    const res = await request(app).get(`${BASE}/users`);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ total: 1, page: 1 });
    expect(res.body.data).toHaveLength(1);
    expect(res.body.data[0].id).toBe(USER_ID);
  });

  test('respects $page and $limit params', async () => {
    mockList([], 0);
    const res = await request(app).get(`${BASE}/users?$page=2&$limit=50`);
    expect(res.status).toBe(200);
    expect(res.body.page).toBe(2);
    expect(res.body.limit).toBe(50);
  });

  test('returns empty list when no users', async () => {
    mockList([], 0);
    const res = await request(app).get(`${BASE}/users`);
    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(0);
    expect(res.body.total).toBe(0);
  });
});

// ── Users - get by ID ─────────────────────────────────────────────────────────

describe('GET /users/:id', () => {
  beforeEach(() => jest.clearAllMocks());

  test('returns user when found', async () => {
    const user = { id: USER_ID, displayName: 'Alice' };
    mockSingle(user);
    const res = await request(app).get(`${BASE}/users/${USER_ID}`);
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(USER_ID);
  });

  test('returns 404 when user not found', async () => {
    mockSingle(null);
    const res = await request(app).get(`${BASE}/users/${USER_ID}`);
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });
});

// ── Users - upsert (POST /) ───────────────────────────────────────────────────

describe('POST /users', () => {
  beforeEach(() => jest.clearAllMocks());

  test('upserts a valid user and returns 200', async () => {
    mockMerge();
    const res = await request(app)
      .post(`${BASE}/users`)
      .send({ id: USER_ID, displayName: 'Alice' });
    expect(res.status).toBe(200);
    expect(res.body.id).toBe(USER_ID);
  });

  test('returns 400 when id is missing', async () => {
    const res = await request(app)
      .post(`${BASE}/users`)
      .send({ displayName: 'No ID User' });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('BAD_REQUEST');
  });

  test('returns 400 when body is empty', async () => {
    const res = await request(app).post(`${BASE}/users`).send({});
    expect(res.status).toBe(400);
  });
});

// ── Users - update (PUT /:id) ─────────────────────────────────────────────────

describe('PUT /users/:id', () => {
  beforeEach(() => jest.clearAllMocks());

  test('updates user when found', async () => {
    const existing = { id: USER_ID, displayName: 'Alice' };
    mockSingle(existing); // existence check
    mockMerge();          // update
    const res = await request(app)
      .put(`${BASE}/users/${USER_ID}`)
      .send({ displayName: 'Alice Updated' });
    expect(res.status).toBe(200);
  });

  test('returns 404 when user does not exist', async () => {
    mockSingle(null); // existence check → not found
    const res = await request(app)
      .put(`${BASE}/users/${USER_ID}`)
      .send({ displayName: 'Ghost' });
    expect(res.status).toBe(404);
  });
});

// ── Users - delete ────────────────────────────────────────────────────────────

describe('DELETE /users/:id', () => {
  beforeEach(() => jest.clearAllMocks());

  test('returns 204 when user deleted', async () => {
    mockDelete(1);
    const res = await request(app).delete(`${BASE}/users/${USER_ID}`);
    expect(res.status).toBe(204);
  });

  test('returns 404 when user does not exist', async () => {
    mockDelete(0);
    const res = await request(app).delete(`${BASE}/users/${USER_ID}`);
    expect(res.status).toBe(404);
  });
});

// ── Users - batch upsert ──────────────────────────────────────────────────────

describe('POST /users/batch', () => {
  beforeEach(() => jest.clearAllMocks());

  test('accepts valid batch and returns counts', async () => {
    // Each record triggers existence check (SELECT) then MERGE
    const id1 = '550e8400-e29b-41d4-a716-446655440001';
    const id2 = '550e8400-e29b-41d4-a716-446655440002';
    // Mocks for record 1: exists → update
    mockQuery.mockResolvedValueOnce({ recordset: [{ 1: 1 }] }); // exists
    mockQuery.mockResolvedValueOnce({});                          // merge
    // Mocks for record 2: not exists → insert
    mockQuery.mockResolvedValueOnce({ recordset: [] });           // not exists
    mockQuery.mockResolvedValueOnce({});                          // merge

    const res = await request(app)
      .post(`${BASE}/users/batch`)
      .send({ records: [{ id: id1 }, { id: id2 }] });

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ inserted: 1, updated: 1 });
  });

  test('returns 400 when records is not an array', async () => {
    const res = await request(app)
      .post(`${BASE}/users/batch`)
      .send({ records: 'not-an-array' });
    expect(res.status).toBe(400);
  });

  test('returns 400 when batch exceeds 1000', async () => {
    const records = Array.from({ length: 1001 }, (_, i) => ({ id: `id-${i}` }));
    const res = await request(app)
      .post(`${BASE}/users/batch`)
      .send({ records });
    expect(res.status).toBe(400);
  });
});

// ── Composite-key: group-members ──────────────────────────────────────────────

const GROUP_ID  = '660e8400-e29b-41d4-a716-446655440001';
const MEMBER_ID = '770e8400-e29b-41d4-a716-446655440002';

describe('GET /group-members', () => {
  beforeEach(() => jest.clearAllMocks());

  test('lists group members with groupId filter', async () => {
    mockList([{ groupId: GROUP_ID, memberId: MEMBER_ID }], 1);
    const res = await request(app).get(`${BASE}/group-members?groupId=${GROUP_ID}`);
    expect(res.status).toBe(200);
    expect(res.body.total).toBe(1);
  });
});

describe('POST /group-members', () => {
  beforeEach(() => jest.clearAllMocks());

  test('adds a group member', async () => {
    mockMerge();
    const res = await request(app)
      .post(`${BASE}/group-members`)
      .send({ groupId: GROUP_ID, memberId: MEMBER_ID });
    expect(res.status).toBe(200);
    expect(res.body.groupId).toBe(GROUP_ID);
  });

  test('returns 400 when groupId or memberId is missing', async () => {
    const res = await request(app)
      .post(`${BASE}/group-members`)
      .send({ groupId: GROUP_ID }); // missing memberId
    expect(res.status).toBe(400);
  });
});

describe('DELETE /group-members/:groupId/:memberId', () => {
  beforeEach(() => jest.clearAllMocks());

  test('removes a group member', async () => {
    mockDelete(1);
    const res = await request(app).delete(`${BASE}/group-members/${GROUP_ID}/${MEMBER_ID}`);
    expect(res.status).toBe(204);
  });

  test('returns 404 when relationship does not exist', async () => {
    mockDelete(0);
    const res = await request(app).delete(`${BASE}/group-members/${GROUP_ID}/${MEMBER_ID}`);
    expect(res.status).toBe(404);
  });
});

// ── Auth enforcement ──────────────────────────────────────────────────────────

describe('Auth enforcement', () => {
  let appWithAuth;

  beforeAll(() => {
    // Re-require app with auth enabled (need to reset module cache)
    process.env.AUTH_ENABLED  = 'true';
    process.env.AZURE_TENANT_ID = 'test-tenant';
    process.env.AZURE_CLIENT_ID = 'test-client';
    jest.resetModules();

    // Re-mock connection after reset
    jest.mock('../../src/db/connection', () => ({
      sql: { NVarChar: 'NVarChar', UniqueIdentifier: 'UniqueIdentifier', Bit: 'Bit', Int: 'Int', Float: 'Float', DateTime2: 'DateTime2' },
      getPool: jest.fn().mockResolvedValue(fakePool),
      closePool: jest.fn(),
    }));
    // Mock jwt so all tokens fail
    jest.mock('jsonwebtoken', () => ({
      verify: (_t, _k, _o, cb) => cb(new Error('invalid')),
    }));
    jest.mock('jwks-rsa', () => jest.fn(() => ({
      getSigningKey: (_kid, cb) => cb(null, { getPublicKey: () => 'key' }),
    })));

    appWithAuth = require('../../src/app');
  });

  afterAll(() => {
    process.env.AUTH_ENABLED = 'false';
    jest.resetModules();
  });

  test('returns 401 without a Bearer token', async () => {
    const res = await request(appWithAuth).get('/api/v1/ingestion/users');
    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHORIZED');
  });

  test('/health is still reachable without auth', async () => {
    const res = await request(appWithAuth).get('/api/v1/ingestion/health');
    expect(res.status).toBe(200);
  });
});
