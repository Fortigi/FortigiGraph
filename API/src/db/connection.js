'use strict';

const sql = require('mssql');

let pool = null;

function buildConfig() {
  if (process.env.SQL_CONNECTION_STRING) {
    return process.env.SQL_CONNECTION_STRING;
  }
  return {
    server: process.env.SQL_SERVER,
    database: process.env.SQL_DATABASE,
    user: process.env.SQL_USER,
    password: process.env.SQL_PASSWORD,
    options: {
      encrypt: process.env.SQL_ENCRYPT !== 'false',
      trustServerCertificate: process.env.SQL_TRUST_SERVER_CERTIFICATE === 'true',
    },
    pool: {
      max: 10,
      min: 0,
      idleTimeoutMillis: 30000,
    },
    requestTimeout: 120000,
    connectionTimeout: 30000,
  };
}

async function getPool() {
  if (pool && pool.connected) return pool;

  pool = await new sql.ConnectionPool(buildConfig()).connect();

  pool.on('error', (err) => {
    console.error('[DB] Pool error, reconnecting...', err.message);
    pool = null;
  });

  return pool;
}

async function closePool() {
  if (pool) {
    await pool.close();
    pool = null;
  }
}

/**
 * Execute a parameterized query.
 * @param {string} text - SQL query with named params (@param)
 * @param {Array<{name:string, type:*, value:*}>} params
 * @returns {Promise<sql.IResult<any>>}
 */
async function query(text, params = []) {
  const p = await getPool();
  const req = p.request();
  for (const { name, type, value } of params) {
    req.input(name, type, value);
  }
  return req.query(text);
}

module.exports = { getPool, closePool, query, sql };
