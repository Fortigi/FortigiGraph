'use strict';

const express = require('express');
const { createEntityRouter } = require('./entityRouter');
const { createCompositeRouter } = require('./composite-router');

const router = express.Router();

// ── HEALTH ──────────────────────────────────────────────────────────
router.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    version: require('../../package.json').version,
    timestamp: new Date().toISOString(),
  });
});

// ── USERS ───────────────────────────────────────────────────────────
router.use(
  '/users',
  createEntityRouter({
    table: 'dbo.GraphUsers',
    keyColumn: 'id',
    filterColumns: ['userPrincipalName', 'displayName', 'department', 'companyName', 'userType', 'accountEnabled'],
  })
);

// ── GROUPS ──────────────────────────────────────────────────────────
router.use(
  '/groups',
  createEntityRouter({
    table: 'dbo.GraphGroups',
    keyColumn: 'id',
    filterColumns: ['displayName', 'mailNickname', 'securityEnabled', 'mailEnabled', 'visibility', 'groupTypeCalculated'],
  })
);

// ── GROUP MEMBERS (composite key: groupId + memberId) ───────────────
router.use(
  '/group-members',
  createCompositeRouter({
    table: 'dbo.GraphGroupMembers',
    key1: 'groupId',
    key2: 'memberId',
    filterColumns: ['groupId', 'memberId', 'memberType'],
  })
);

// ── GROUP OWNERS (composite key: groupId + ownerId) ─────────────────
router.use(
  '/group-owners',
  createCompositeRouter({
    table: 'dbo.GraphGroupOwners',
    key1: 'groupId',
    key2: 'ownerId',
    filterColumns: ['groupId', 'ownerId'],
  })
);

// ── GROUP ELIGIBLE MEMBERS (composite: groupId + memberId) ──────────
router.use(
  '/group-eligible-members',
  createCompositeRouter({
    table: 'dbo.GraphGroupEligibleMembers',
    key1: 'groupId',
    key2: 'memberId',
    filterColumns: ['groupId', 'memberId', 'memberType'],
  })
);

// ── CATALOGS ────────────────────────────────────────────────────────
router.use(
  '/catalogs',
  createEntityRouter({
    table: 'dbo.GraphCatalogs',
    keyColumn: 'id',
    filterColumns: ['displayName', 'catalogType', 'catalogStatus', 'isExternallyVisible'],
  })
);

// ── ACCESS PACKAGES ─────────────────────────────────────────────────
router.use(
  '/access-packages',
  createEntityRouter({
    table: 'dbo.GraphAccessPackages',
    keyColumn: 'id',
    filterColumns: ['displayName', 'catalogId', 'isHidden'],
  })
);

// ── ACCESS PACKAGE ASSIGNMENTS ───────────────────────────────────────
router.use(
  '/access-package-assignments',
  createEntityRouter({
    table: 'dbo.GraphAccessPackageAssignments',
    keyColumn: 'id',
    filterColumns: ['accessPackageId', 'targetId', 'assignmentStatus', 'assignmentState'],
  })
);

// ── ACCESS PACKAGE RESOURCE ROLE SCOPES ─────────────────────────────
router.use(
  '/access-package-resource-role-scopes',
  createEntityRouter({
    table: 'dbo.GraphAccessPackageResourceRoleScopes',
    keyColumn: 'id',
    filterColumns: ['accessPackageId', 'roleOriginSystem', 'scopeOriginSystem'],
  })
);

// ── ACCESS PACKAGE ASSIGNMENT POLICIES ──────────────────────────────
router.use(
  '/access-package-assignment-policies',
  createEntityRouter({
    table: 'dbo.GraphAccessPackageAssignmentPolicies',
    keyColumn: 'id',
    filterColumns: ['accessPackageId', 'displayName'],
  })
);

// ── ACCESS PACKAGE ASSIGNMENT REQUESTS ──────────────────────────────
router.use(
  '/access-package-assignment-requests',
  createEntityRouter({
    table: 'dbo.GraphAccessPackageAssignmentRequests',
    keyColumn: 'id',
    filterColumns: ['accessPackageId', 'targetId', 'requestType', 'requestState'],
  })
);

// ── ACCESS PACKAGE ACCESS REVIEWS ───────────────────────────────────
router.use(
  '/access-package-access-reviews',
  createEntityRouter({
    table: 'dbo.GraphAccessPackageAccessReviewDecisions',
    keyColumn: 'id',
    filterColumns: ['accessPackageId', 'accessReviewId', 'decision'],
  })
);

module.exports = router;
