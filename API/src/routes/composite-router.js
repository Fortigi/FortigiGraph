'use strict';

/**
 * Creates a CRUD Express router for composite-key entities (e.g. GroupMembers: groupId+memberId).
 * Covers: GET / (list with query filters), POST / (add), POST /batch, DELETE /:key1/:key2
 */

const express = require('express');
const { sql } = require('../db/connection');
const {
  pagedList,
  upsertRecord,
  batchUpsert,
  deleteComposite,
  sanitizeError,
} = require('./helpers');

/**
 * @param {object} opts
 * @param {string} opts.table          - SQL table (e.g. 'dbo.GraphGroupMembers')
 * @param {string} opts.key1           - First key column (e.g. 'groupId')
 * @param {string} opts.key2           - Second key column (e.g. 'memberId')
 * @param {string[]} opts.filterColumns - Query params allowed as filters
 */
function createCompositeRouter(opts) {
  const { table, key1, key2, filterColumns = [] } = opts;

  const router = express.Router();

  // ── LIST ────────────────────────────────────────────────────────────
  router.get('/', async (req, res) => {
    try {
      const extraWhere = [];
      const extraParams = [];
      let pi = 0;

      for (const col of filterColumns) {
        if (req.query[col]) {
          extraWhere.push(`[${col}] = @qf${pi}`);
          extraParams.push({ name: `qf${pi}`, type: sql.NVarChar, value: req.query[col] });
          pi++;
        }
      }

      const result = await pagedList({
        table,
        idColumn: key1,
        query: req.query,
        filterColumns: [],
        extraWhere,
        extraParams,
      });
      res.json(result);
    } catch (err) {
      console.error(`[${table}] list error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  // ── ADD (POST /) ────────────────────────────────────────────────────
  router.post('/', async (req, res) => {
    try {
      const record = req.body;
      if (!record[key1] || !record[key2]) {
        return res.status(400).json({
          code: 'BAD_REQUEST',
          message: `${key1} and ${key2} are required`,
        });
      }
      await upsertRecord({ table, keyColumn: key1, record });
      res.json(record);
    } catch (err) {
      console.error(`[${table}] add error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  // ── BATCH ───────────────────────────────────────────────────────────
  router.post('/batch', async (req, res) => {
    try {
      const { records, mode = 'upsert' } = req.body;
      if (!Array.isArray(records)) {
        return res.status(400).json({ code: 'BAD_REQUEST', message: 'records must be an array' });
      }
      if (records.length > 1000) {
        return res.status(400).json({ code: 'BAD_REQUEST', message: 'Batch size exceeds maximum of 1000' });
      }
      const result = await batchUpsert({ table, keyColumn: key1, records, mode });
      res.json(result);
    } catch (err) {
      console.error(`[${table}] batch error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  // ── DELETE /:key1/:key2 ─────────────────────────────────────────────
  router.delete(`/:${key1}/:${key2}`, async (req, res) => {
    try {
      const conditions = {
        [key1]: req.params[key1],
        [key2]: req.params[key2],
      };
      const affected = await deleteComposite(table, conditions);
      if (!affected) return res.status(404).json({ code: 'NOT_FOUND', message: 'Resource not found' });
      res.status(204).send();
    } catch (err) {
      console.error(`[${table}] delete error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  return router;
}

module.exports = { createCompositeRouter };
