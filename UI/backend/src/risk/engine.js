// ─── Identity Risk Scoring Engine (MVP) ──────────────────────────────
//
// Implements the four scoring layers from the risk scoring plan:
//   Layer 1: Direct classifier match (regex pattern matching)
//   Layer 2: Membership/relationship analysis
//   Layer 3: Structural/hygiene signals
//   Layer 4: Cross-entity risk propagation
//
// All scoring runs locally in-memory — no external API calls, no LLM.

import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ─── Configuration ──────────────────────────────────────────────────

const DEFAULT_WEIGHTS = {
  direct: 0.50,
  membership: 0.20,
  structural: 0.10,
  propagated: 0.20,
};

const PROPAGATION_FACTORS = {
  groupToUser: 0.30,
  userToGroup: 0.25,
};

const RISK_TIERS = [
  { min: 90, label: 'Critical', color: '#ef4444' },
  { min: 70, label: 'High',     color: '#f97316' },
  { min: 40, label: 'Medium',   color: '#eab308' },
  { min: 20, label: 'Low',      color: '#3b82f6' },
  { min: 1,  label: 'Minimal',  color: '#6b7280' },
  { min: 0,  label: 'None',     color: '#d1d5db' },
];

// ─── Classifier Loading ─────────────────────────────────────────────

let _classifiers = null;

function loadClassifiers() {
  if (_classifiers) return _classifiers;
  try {
    const raw = readFileSync(join(__dirname, 'classifiers/universal.json'), 'utf-8');
    _classifiers = JSON.parse(raw);
    return _classifiers;
  } catch (err) {
    console.error('Failed to load classifiers:', err.message);
    _classifiers = { groups: [], users: [] };
    return _classifiers;
  }
}

// ─── Pattern Matching ───────────────────────────────────────────────

function matchesAnyPattern(text, patterns) {
  if (!text || !patterns || patterns.length === 0) return false;
  for (const pattern of patterns) {
    try {
      if (new RegExp(pattern, 'i').test(text)) return true;
    } catch {
      // Invalid regex — skip
    }
  }
  return false;
}

// ─── Layer 1: Direct Classifier Match ───────────────────────────────

function scoreGroupDirect(group, classifiers) {
  const matches = [];
  for (const c of classifiers) {
    const nameMatch = matchesAnyPattern(group.displayName, c.name_patterns);
    const descMatch = matchesAnyPattern(group.description, c.description_patterns);
    if (nameMatch || descMatch) {
      matches.push({
        classifierId: c.id,
        category: c.category,
        score: c.base_score,
        rationale: c.rationale,
        matchedOn: nameMatch ? 'name' : 'description',
      });
    }
  }
  // Take the highest matching classifier score (don't stack)
  const best = matches.reduce((max, m) => m.score > max ? m.score : max, 0);
  return { score: best, matches };
}

function scoreUserDirect(user, classifiers) {
  const matches = [];
  for (const c of classifiers) {
    const titleMatch = matchesAnyPattern(user.jobTitle, c.title_patterns);
    const nameMatch = matchesAnyPattern(user.displayName, c.name_patterns);
    const upnMatch = matchesAnyPattern(user.userPrincipalName, c.upn_patterns);
    if (titleMatch || nameMatch || upnMatch) {
      matches.push({
        classifierId: c.id,
        category: c.category,
        score: c.base_score,
        rationale: c.rationale,
        matchedOn: titleMatch ? 'jobTitle' : nameMatch ? 'displayName' : 'upn',
      });
    }
  }
  const best = matches.reduce((max, m) => m.score > max ? m.score : max, 0);
  return { score: best, matches };
}

// ─── Layer 2: Membership/Relationship Analysis ──────────────────────

function scoreGroupMembership(group, membershipIndex) {
  const signals = [];
  let score = 0;

  const members = membershipIndex.groupMembers.get(group.id) || [];
  const owners = membershipIndex.groupOwners.get(group.id) || [];
  const eligibleMembers = membershipIndex.groupEligible.get(group.id) || [];

  // Small group with privileged members = concentrated risk
  const memberCount = members.length;
  if (memberCount > 0 && memberCount <= 5) {
    signals.push({ signal: 'small-privileged-group', detail: `Only ${memberCount} members`, points: 5 });
    score += 5;
  }

  // Has eligible (PIM) members — indicates privileged access
  if (eligibleMembers.length > 0) {
    signals.push({ signal: 'has-pim-eligible', detail: `${eligibleMembers.length} PIM-eligible members`, points: 10 });
    score += 10;
  }

  // Has owners
  if (owners.length === 0 && memberCount > 0) {
    signals.push({ signal: 'no-owner', detail: 'Group has members but no owner', points: 5 });
    score += 5;
  }

  // Contains c-suite members (check user scores later via cross-reference)
  return { score: Math.min(score, 40), signals };
}

function scoreUserMembership(user, membershipIndex, groupScores) {
  const signals = [];
  let score = 0;

  const memberships = membershipIndex.userMemberships.get(user.id) || [];
  const ownerships = membershipIndex.userOwnerships.get(user.id) || [];
  const eligibleFor = membershipIndex.userEligible.get(user.id) || [];

  // Number of group memberships (outlier detection)
  const totalGroups = memberships.length + ownerships.length + eligibleFor.length;
  if (totalGroups > 15) {
    const points = Math.min(15, Math.floor((totalGroups - 15) / 3) * 3);
    if (points > 0) {
      signals.push({ signal: 'high-membership-count', detail: `Member of ${totalGroups} groups (above average)`, points });
      score += points;
    }
  }

  // Member of any high-risk group (>70 score)?
  const highRiskGroups = memberships.filter(gId => {
    const gs = groupScores.get(gId);
    return gs && gs.directScore > 70;
  });
  if (highRiskGroups.length > 0) {
    signals.push({ signal: 'high-risk-group-member', detail: `Member of ${highRiskGroups.length} high-risk groups`, points: 15 });
    score += 15;
  }

  // Eligible for privileged groups
  if (eligibleFor.length > 0) {
    const points = Math.min(20, eligibleFor.length * 5);
    signals.push({ signal: 'pim-eligible', detail: `PIM-eligible for ${eligibleFor.length} groups`, points });
    score += points;
  }

  // Is owner of groups
  if (ownerships.length > 3) {
    signals.push({ signal: 'many-ownerships', detail: `Owner of ${ownerships.length} groups`, points: 5 });
    score += 5;
  }

  return { score: Math.min(score, 40), signals };
}

// ─── Layer 3: Structural/Hygiene Signals ────────────────────────────

function scoreGroupStructural(group) {
  const signals = [];
  let score = 0;

  // No description
  if (!group.description || group.description.trim() === '') {
    signals.push({ signal: 'no-description', detail: 'No description set', points: 3 });
    score += 3;
  }

  // Mail-enabled security group (broader exposure)
  if (group.mailEnabled && group.securityEnabled) {
    signals.push({ signal: 'mail-enabled-security', detail: 'Mail-enabled security group', points: 3 });
    score += 3;
  }

  // Is role-assignable (used for Entra ID directory roles)
  if (group.isAssignableToRole) {
    signals.push({ signal: 'role-assignable', detail: 'Used for Entra ID directory role assignment', points: 15 });
    score += 15;
  }

  // Dynamic membership group — automatically includes users by rule
  if (group.membershipRuleProcessingState === 'On') {
    signals.push({ signal: 'dynamic-membership', detail: 'Dynamic membership rule active', points: 3 });
    score += 3;
  }

  return { score: Math.min(score, 25), signals };
}

function scoreUserStructural(user) {
  const signals = [];
  let score = 0;

  // Account disabled but still has memberships
  if (user.accountEnabled === false || user.accountEnabled === 0) {
    signals.push({ signal: 'account-disabled', detail: 'Account is disabled', points: 5 });
    score += 5;
  }

  // No sign-in in 90+ days (stale account)
  if (user.lastSignInDateTime) {
    const lastSignIn = new Date(user.lastSignInDateTime);
    const daysSinceSignIn = Math.floor((Date.now() - lastSignIn.getTime()) / (1000 * 60 * 60 * 24));
    if (daysSinceSignIn > 90) {
      signals.push({ signal: 'stale-sign-in', detail: `No sign-in for ${daysSinceSignIn} days`, points: 10 });
      score += 10;
    }
  }

  // Guest/external user
  if (user.userType === 'Guest') {
    signals.push({ signal: 'guest-user', detail: 'External/guest user', points: 5 });
    score += 5;
  }

  return { score: Math.min(score, 25), signals };
}

// ─── Layer 4: Cross-Entity Risk Propagation ─────────────────────────

function propagateRisk(groupScores, userScores, membershipIndex) {
  // Group → User: user inherits 30% of riskiest group
  for (const [userId, memberships] of membershipIndex.userMemberships) {
    const userScore = userScores.get(userId);
    if (!userScore) continue;

    let maxGroupScore = 0;
    let sourceGroup = null;
    for (const gId of memberships) {
      const gs = groupScores.get(gId);
      if (gs && gs.prePropagate > maxGroupScore) {
        maxGroupScore = gs.prePropagate;
        sourceGroup = gId;
      }
    }
    if (maxGroupScore > 0) {
      const propagated = Math.round(maxGroupScore * PROPAGATION_FACTORS.groupToUser);
      userScore.propagatedScore = propagated;
      userScore.propagationSource = { type: 'group', id: sourceGroup, score: maxGroupScore };
    }
  }

  // User → Group: group inherits 25% of riskiest member
  for (const [groupId, members] of membershipIndex.groupMembers) {
    const groupScore = groupScores.get(groupId);
    if (!groupScore) continue;

    let maxUserScore = 0;
    let sourceUser = null;
    for (const uId of members) {
      const us = userScores.get(uId);
      if (us && us.prePropagate > maxUserScore) {
        maxUserScore = us.prePropagate;
        sourceUser = uId;
      }
    }
    if (maxUserScore > 0) {
      const propagated = Math.round(maxUserScore * PROPAGATION_FACTORS.userToGroup);
      groupScore.propagatedScore = propagated;
      groupScore.propagationSource = { type: 'user', id: sourceUser, score: maxUserScore };
    }
  }
}

// ─── Final Score Calculation ────────────────────────────────────────

function calculateFinalScore(directScore, membershipScore, structuralScore, propagatedScore, weights = DEFAULT_WEIGHTS) {
  const final = Math.round(Math.min(100,
    weights.direct * directScore +
    weights.membership * membershipScore +
    weights.structural * structuralScore +
    weights.propagated * propagatedScore
  ));
  return final;
}

function getRiskTier(score) {
  for (const tier of RISK_TIERS) {
    if (score >= tier.min) return tier;
  }
  return RISK_TIERS[RISK_TIERS.length - 1];
}

// ─── Build Membership Index ─────────────────────────────────────────

function buildMembershipIndex(assignments) {
  const index = {
    groupMembers: new Map(),     // groupId -> [memberId]
    groupOwners: new Map(),      // groupId -> [ownerId]
    groupEligible: new Map(),    // groupId -> [memberId]
    userMemberships: new Map(),  // userId -> [groupId]
    userOwnerships: new Map(),   // userId -> [groupId]
    userEligible: new Map(),     // userId -> [groupId]
  };

  for (const a of assignments) {
    const groupId = a.groupId;
    const memberId = a.memberId;
    const type = a.membershipType;

    if (type === 'Owner') {
      if (!index.groupOwners.has(groupId)) index.groupOwners.set(groupId, []);
      index.groupOwners.get(groupId).push(memberId);
      if (!index.userOwnerships.has(memberId)) index.userOwnerships.set(memberId, []);
      index.userOwnerships.get(memberId).push(groupId);
    } else if (type === 'Eligible') {
      if (!index.groupEligible.has(groupId)) index.groupEligible.set(groupId, []);
      index.groupEligible.get(groupId).push(memberId);
      if (!index.userEligible.has(memberId)) index.userEligible.set(memberId, []);
      index.userEligible.get(memberId).push(groupId);
    } else {
      // Direct or Indirect
      if (!index.groupMembers.has(groupId)) index.groupMembers.set(groupId, []);
      index.groupMembers.get(groupId).push(memberId);
      if (!index.userMemberships.has(memberId)) index.userMemberships.set(memberId, []);
      index.userMemberships.get(memberId).push(groupId);
    }
  }

  return index;
}

// ─── Main Scoring Function ──────────────────────────────────────────

/**
 * Score all entities from the provided data.
 *
 * @param {Object} data
 * @param {Array} data.users       - Array of user objects from GraphUsers
 * @param {Array} data.groups      - Array of group objects from GraphGroups
 * @param {Array} data.assignments - Array of membership assignments (from vw_UserPermissionAssignments)
 * @returns {{ groups: Array, users: Array, summary: Object }}
 */
export function scoreAll(data) {
  const classifiers = loadClassifiers();
  const { users = [], groups = [], assignments = [] } = data;

  // Build membership index
  const membershipIndex = buildMembershipIndex(assignments);

  // ─── Score Groups ──────────────────────────────────────────────
  const groupScores = new Map();

  for (const group of groups) {
    const direct = scoreGroupDirect(group, classifiers.groups || []);
    const membership = scoreGroupMembership(group, membershipIndex);
    const structural = scoreGroupStructural(group);

    const prePropagate = calculateFinalScore(
      direct.score, membership.score, structural.score, 0,
      { ...DEFAULT_WEIGHTS, propagated: 0, direct: 0.60, membership: 0.25, structural: 0.15 }
    );

    groupScores.set(group.id, {
      entityId: group.id,
      entityType: 'group',
      displayName: group.displayName,
      description: group.description,
      directScore: direct.score,
      membershipScore: membership.score,
      structuralScore: structural.score,
      propagatedScore: 0,
      propagationSource: null,
      prePropagate,
      classifierMatches: direct.matches,
      membershipSignals: membership.signals,
      structuralSignals: structural.signals,
    });
  }

  // ─── Score Users ───────────────────────────────────────────────
  const userScores = new Map();

  for (const user of users) {
    const direct = scoreUserDirect(user, classifiers.users || []);
    const membership = scoreUserMembership(user, membershipIndex, groupScores);
    const structural = scoreUserStructural(user);

    const prePropagate = calculateFinalScore(
      direct.score, membership.score, structural.score, 0,
      { ...DEFAULT_WEIGHTS, propagated: 0, direct: 0.60, membership: 0.25, structural: 0.15 }
    );

    userScores.set(user.id, {
      entityId: user.id,
      entityType: 'user',
      displayName: user.displayName,
      userPrincipalName: user.userPrincipalName,
      department: user.department,
      jobTitle: user.jobTitle,
      directScore: direct.score,
      membershipScore: membership.score,
      structuralScore: structural.score,
      propagatedScore: 0,
      propagationSource: null,
      prePropagate,
      classifierMatches: direct.matches,
      membershipSignals: membership.signals,
      structuralSignals: structural.signals,
    });
  }

  // ─── Layer 4: Propagation ──────────────────────────────────────
  propagateRisk(groupScores, userScores, membershipIndex);

  // ─── Calculate Final Scores ────────────────────────────────────
  const groupResults = [];
  for (const [, gs] of groupScores) {
    gs.finalScore = calculateFinalScore(gs.directScore, gs.membershipScore, gs.structuralScore, gs.propagatedScore);
    gs.riskTier = getRiskTier(gs.finalScore);
    groupResults.push(gs);
  }

  const userResults = [];
  for (const [, us] of userScores) {
    us.finalScore = calculateFinalScore(us.directScore, us.membershipScore, us.structuralScore, us.propagatedScore);
    us.riskTier = getRiskTier(us.finalScore);
    userResults.push(us);
  }

  // Sort by score descending
  groupResults.sort((a, b) => b.finalScore - a.finalScore);
  userResults.sort((a, b) => b.finalScore - a.finalScore);

  // ─── Summary ───────────────────────────────────────────────────
  const summary = {
    totalGroups: groupResults.length,
    totalUsers: userResults.length,
    groupsByTier: {},
    usersByTier: {},
    topGroups: groupResults.slice(0, 10),
    topUsers: userResults.slice(0, 10),
  };

  for (const tier of RISK_TIERS) {
    summary.groupsByTier[tier.label] = groupResults.filter(g => g.riskTier.label === tier.label).length;
    summary.usersByTier[tier.label] = userResults.filter(u => u.riskTier.label === tier.label).length;
  }

  return { groups: groupResults, users: userResults, summary };
}

export { RISK_TIERS, DEFAULT_WEIGHTS, loadClassifiers };
