'use strict';

/**
 * Unit tests for src/routes/helpers.js
 *
 * The SQL connection module is mocked so no database is required.
 */

const { jest } = require('@jest/globals');

// ── Mock db/connection ────────────────────────────────────────────────────────

const mockQuery      = jest.fn();
const mockRequest    = jest.fn();
const mockInput      = jest.fn();
const mockGetPool    = jest.fn();

// request() returns an object with input() and query()
const fakeRequest = () => ({
  input: mockInput,
  query: mockQuery,
});

mockGetPool.mockResolvedValue({ request: fakeRequest });
mockRequest.mockReturnValue(fakeRequest());

jest.mock('../../src/db/connection', () => ({
  sql: {
    NVarChar:       'NVarChar',
    UniqueIdentifier: 'UniqueIdentifier',
    Bit:            'Bit',
    Int:            'Int',
    Float:          'Float',
    DateTime2:      'DateTime2',
  },
  getPool: mockGetPool,
}));

const { inferSqlType, sanitizeError } = require('../../src/routes/helpers');

// ── inferSqlType ──────────────────────────────────────────────────────────────

describe('inferSqlType', () => {
  test('returns Bit for boolean', () => {
    expect(inferSqlType(true)).toBe('Bit');
    expect(inferSqlType(false)).toBe('Bit');
  });

  test('returns Int for integer', () => {
    expect(inferSqlType(42)).toBe('Int');
    expect(inferSqlType(0)).toBe('Int');
  });

  test('returns Float for non-integer number', () => {
    expect(inferSqlType(3.14)).toBe('Float');
  });

  test('returns UniqueIdentifier for UUID string', () => {
    expect(inferSqlType('550e8400-e29b-41d4-a716-446655440000')).toBe('UniqueIdentifier');
  });

  test('returns DateTime2 for ISO date string', () => {
    expect(inferSqlType('2026-03-13T12:00:00Z')).toBe('DateTime2');
  });

  test('returns NVarChar for plain string', () => {
    expect(inferSqlType('hello')).toBe('NVarChar');
  });

  test('returns NVarChar for null', () => {
    expect(inferSqlType(null)).toBe('NVarChar');
  });

  test('returns NVarChar for undefined', () => {
    expect(inferSqlType(undefined)).toBe('NVarChar');
  });
});

// ── sanitizeError ─────────────────────────────────────────────────────────────

describe('sanitizeError', () => {
  test('strips SQL Server bracket annotations', () => {
    const err = new Error('[dbo].[GraphUsers] column [id] invalid at line 42');
    expect(sanitizeError(err)).not.toContain('[dbo]');
    expect(sanitizeError(err)).not.toContain('[GraphUsers]');
  });

  test('truncates very long messages to 200 chars', () => {
    const err = new Error('x'.repeat(300));
    expect(sanitizeError(err).length).toBeLessThanOrEqual(200);
  });

  test('returns fallback for empty message', () => {
    const err = new Error('');
    expect(sanitizeError(err)).toBeTruthy();
  });
});
