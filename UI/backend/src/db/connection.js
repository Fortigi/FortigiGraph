import sql from 'mssql';

let pool = null;

const config = {
  server: process.env.SQL_SERVER,
  database: process.env.SQL_DATABASE,
  user: process.env.SQL_USER,
  password: process.env.SQL_PASSWORD,
  requestTimeout: 120000,  // 2 min – recursive CTE views can be slow on large datasets
  options: {
    encrypt: true,
    trustServerCertificate: false
  },
  pool: {
    max: 10,
    min: 0,
    idleTimeoutMillis: 30000
  }
};

export async function getPool() {
  if (!pool) {
    pool = await sql.connect(config);

    pool.on('error', (err) => {
      console.error('SQL pool error:', err.message);
      pool = null; // Force reconnect on next request
    });
  }
  return pool;
}

export async function closePool() {
  if (pool) {
    try {
      await pool.close();
    } catch (err) {
      console.error('Error closing SQL pool:', err.message);
    }
    pool = null;
  }
}

// Note: prefer pool.request().input(...).query(...) for parameterized queries.
// This helper is only for static SQL with no user input.
export async function query(text) {
  const p = await getPool();
  return p.request().query(text);
}
