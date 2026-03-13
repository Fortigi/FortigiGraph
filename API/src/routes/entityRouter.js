'use strict';

/**
 * Creates a standard CRUD Express router for a single-primary-key entity.
 * Covers: GET / (list), POST / (upsert), POST /batch, GET /:id, PUT /:id, DELETE /:id
 */

const express = require('express');
const {
  pagedList,
  upsertRecord,
  batchUpsert,
  deleteRecord,
  getById,
  sanitizeError,
} = require('./helpers');

/**
 * @param {object} opts
 * @param {string} opts.table          - SQL table (e.g. 'dbo.GraphUsers')
 * @param {string} opts.keyColumn      - Primary key column (e.g. 'id')
 * @param {string[]} opts.filterColumns - Columns allowed in $filter param
 * @param {Function} [opts.validate]   - Optional validate(record) => string|null
 * @param {Function} [opts.extraWhere] - (req) => {clauses: string[], params: []}
 */
function createEntityRouter(opts) {
  const {
    table,
    keyColumn = 'id',
    filterColumns = [],
    validate = null,
    extraWhere = null,
  } = opts;

  const router = express.Router();

  // ── LIST ────────────────────────────────────────────────────────────
  router.get('/', async (req, res) => {
    try {
      const extra = extraWhere ? extraWhere(req) : { clauses: [], params: [] };
      const result = await pagedList({
        table,
        idColumn: keyColumn,
        query: req.query,
        filterColumns,
        extraWhere: extra.clauses,
        extraParams: extra.params,
      });
      res.json(result);
    } catch (err) {
      console.error(`[${table}] list error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  // ── UPSERT (POST /) ─────────────────────────────────────────────────
  router.post('/', async (req, res) => {
    try {
      const record = req.body;
      if (validate) {
        const err = validate(record);
        if (err) return res.status(400).json({ code: 'BAD_REQUEST', message: err });
      }
      if (!record[keyColumn]) {
        return res.status(400).json({ code: 'BAD_REQUEST', message: `${keyColumn} is required` });
      }
      const result = await upsertRecord({ table, keyColumn, record });
      res.json(result);
    } catch (err) {
      console.error(`[${table}] upsert error:`, err);
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
      const result = await batchUpsert({ table, keyColumn, records, mode });
      res.json(result);
    } catch (err) {
      console.error(`[${table}] batch error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  // ── GET BY ID ───────────────────────────────────────────────────────
  router.get('/:id', async (req, res) => {
    try {
      const record = await getById(table, keyColumn, req.params.id, req.query.asOf);
      if (!record) return res.status(404).json({ code: 'NOT_FOUND', message: 'Resource not found' });
      res.json(record);
    } catch (err) {
      console.error(`[${table}] getById error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  // ── UPDATE (PUT /:id) ───────────────────────────────────────────────
  router.put('/:id', async (req, res) => {
    try {
      const record = { ...req.body, [keyColumn]: req.params.id };
      if (validate) {
        const err = validate(record);
        if (err) return res.status(400).json({ code: 'BAD_REQUEST', message: err });
      }
      const exists = await getById(table, keyColumn, req.params.id);
      if (!exists) return res.status(404).json({ code: 'NOT_FOUND', message: 'Resource not found' });
      const result = await upsertRecord({ table, keyColumn, record });
      res.json(result);
    } catch (err) {
      console.error(`[${table}] update error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  // ── DELETE ──────────────────────────────────────────────────────────
  router.delete('/:id', async (req, res) => {
    try {
      const affected = await deleteRecord(table, keyColumn, req.params.id);
      if (!affected) return res.status(404).json({ code: 'NOT_FOUND', message: 'Resource not found' });
      res.status(204).send();
    } catch (err) {
      console.error(`[${table}] delete error:`, err);
      res.status(500).json({ code: 'INTERNAL_ERROR', message: sanitizeError(err) });
    }
  });

  return router;
}

module.exports = { createEntityRouter };
