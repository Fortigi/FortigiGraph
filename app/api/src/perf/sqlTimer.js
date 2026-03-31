// SQL query timer — wraps mssql pool.request() to capture per-query
// execution time without changing any calling code.
//
// Usage in a route handler:
//   import { timedRequest, getQueryTimings } from '../perf/sqlTimer.js';
//
//   // Instead of pool.request():
//   const req = timedRequest(pool, 'user-attributes');
//   req.input('id', userId);
//   await req.query('SELECT * FROM GraphUsers WHERE id = @id');
//
//   // At the end of the handler, collect all timings:
//   const sqlQueries = getQueryTimings(res);  // [{ label, ms }]

import { isEnabled } from './collector.js';

const TIMINGS_KEY = Symbol('sqlTimings');

/**
 * Create a timed wrapper around pool.request().
 * When perf is disabled, returns the plain request (zero overhead).
 *
 * @param {import('mssql').ConnectionPool} pool
 * @param {string} label - Human-readable label for this query (e.g. 'user-attributes')
 * @param {import('express').Response} res - Express response (timings are attached here)
 * @returns {import('mssql').Request}
 */
export function timedRequest(pool, label, res) {
  const request = pool.request();

  if (!isEnabled() || !res) return request;

  // Initialize timings array on the response object
  if (!res[TIMINGS_KEY]) res[TIMINGS_KEY] = [];
  const timings = res[TIMINGS_KEY];

  // Wrap .query() to capture duration
  const originalQuery = request.query.bind(request);
  request.query = async function (sqlText) {
    const start = performance.now();
    try {
      const result = await originalQuery(sqlText);
      const ms = +(performance.now() - start).toFixed(1);
      timings.push({ label, ms, rows: result.recordset?.length ?? 0 });
      return result;
    } catch (err) {
      const ms = +(performance.now() - start).toFixed(1);
      timings.push({ label, ms, error: err.message });
      throw err;
    }
  };

  return request;
}

/**
 * Retrieve collected query timings from the response object.
 * Returns empty array when perf is disabled or no queries were timed.
 */
export function getQueryTimings(res) {
  return res?.[TIMINGS_KEY] || [];
}
