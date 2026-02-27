# Identity Risk Scoring Engine — Project Plan

## Project Summary

Build a privacy-preserving identity risk scoring engine that classifies AD/Entra ID entities (users, groups, apps, access packages) by organizational risk. The architecture separates **classifier generation** (LLM-assisted, no sensitive data) from **classification execution** (local, deterministic, fully private).

This module integrates into an existing role mining tool that already collects AD and Entra ID data including users, groups, and direct/indirect membership assignments. The tool has an existing UI and data layer.

### Key Design Principles

1. **No sensitive data leaves the environment.** The LLM only helps generate detection rules (classifiers). It never sees actual group names, user names, or membership data.
2. **Organizational context drives classification.** A bank needs different classifiers than a port authority or a hospital. The system researches the customer's domain to build industry-specific classifiers.
3. **Heuristic engine, not LLM inference.** The actual scoring runs locally as a deterministic weighted rule engine — fast, auditable, explainable, and privacy-safe.
4. **Transparent and tunable.** Every score must be explainable: "this group scored 87 because it matched classifier X (60pts) + contains a Global Admin (20pts) + is assigned to a high-risk app (7pts)."

### Scale Context

Typical large environment: ~5,000 users, ~10,000 groups, ~350,000 direct and indirect assignments. The heuristics engine must handle this efficiently in-memory without external API calls.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    PHASE 1: CLASSIFIER GENERATION        │
│                    (LLM-assisted, no sensitive data)      │
│                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────┐ │
│  │ Customer      │───▶│ LLM Context  │───▶│ Classifier │ │
│  │ Domain/Name   │    │ Discovery    │    │ Generator  │ │
│  └──────────────┘    └──────────────┘    └────────────┘ │
│                              │                    │      │
│                              ▼                    ▼      │
│                     ┌──────────────┐    ┌────────────┐  │
│                     │ Org Risk     │    │ Admin      │  │
│                     │ Profile      │    │ Review &   │  │
│                     │ (industry,   │    │ Dialog     │  │
│                     │  regulations,│    └────────────┘  │
│                     │  key systems)│           │        │
│                     └──────────────┘           ▼        │
│                                        ┌────────────┐   │
│                                        │ Classifier  │  │
│                                        │ Ruleset     │  │
│                                        │ (YAML/JSON) │  │
│                                        └────────────┘   │
└─────────────────────────────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │  HARD PRIVACY      │
                    │  BOUNDARY          │
                    │  (no data crosses) │
                    └─────────┬─────────┘
                              │
┌─────────────────────────────▼───────────────────────────┐
│                    PHASE 2: LOCAL SCORING ENGINE          │
│                    (deterministic, no LLM, no network)    │
│                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────┐ │
│  │ Classifier   │───▶│ Heuristics   │───▶│ Risk       │ │
│  │ Ruleset      │    │ Engine       │    │ Scores     │ │
│  └──────────────┘    └──────────────┘    └────────────┘ │
│                              ▲                    │      │
│                              │                    ▼      │
│                     ┌──────────────┐    ┌────────────┐  │
│                     │ Existing     │    │ UI: Score  │  │
│                     │ Data Layer   │    │ Dashboard  │  │
│                     │ (users,      │    │ & Explain  │  │
│                     │  groups,     │    │ View       │  │
│                     │  memberships)│    └────────────┘  │
│                     └──────────────┘                    │
└─────────────────────────────────────────────────────────┘
```

---

## Phase 1: Organizational Context & Classifier Generation

### Step 1.1 — Customer Context Discovery

**Input:** Customer domain name or organization name (e.g., "portofrotterdam.com" or "Havenbedrijf Rotterdam")

**Process:** Use LLM with web search to research the organization and build an organizational risk profile.

**Research targets:**
- What does the organization do? (industry, sector, sub-sector)
- What regulations apply? (NIS2, DORA, SOX, HIPAA, Wbni, DNB supervision, etc.)
- What are their critical business processes?
- What key systems/platforms are publicly known? (e.g., HaMIS, Pronto for a port; SWIFT, Murex for a bank)
- What is their organizational structure? (divisions, subsidiaries)
- What security frameworks do they likely follow? (ISO 27001, NIST, BIO for government)
- What are typical critical roles/titles in this industry?

**Output:** An organizational risk profile document (JSON/YAML):

```yaml
customer_profile:
  name: "Havenbedrijf Rotterdam N.V."
  domain: "portofrotterdam.com"
  industry: "critical-infrastructure"
  sub_industry: "port-authority"
  country: "NL"
  
  regulations:
    - id: "nis2"
      name: "NIS2 Directive"
      relevance: "Essential entity - port operator"
    - id: "wbni"
      name: "Wet Beveiliging Netwerk- en Informatiesystemen"
      relevance: "Critical infrastructure designation"
    - id: "isps"
      name: "ISPS Code"
      relevance: "International Ship and Port Facility Security"
  
  critical_business_processes:
    - "Vessel traffic management and port safety"
    - "Terminal operations and logistics coordination"
    - "Customs and border security integration"
    - "Environmental monitoring and hazardous cargo"
    - "Infrastructure management (quays, waterways)"
  
  known_systems:
    - name: "HaMIS"
      type: "Harbor Master Information System"
      criticality: "critical"
      description: "Core system for vessel traffic and harbor operations"
    - name: "Pronto"
      type: "Port call optimization platform"
      criticality: "high"
      description: "Digital platform for port call coordination"
  
  critical_roles:
    - title_patterns: ["havenmester", "harbor.?master", "havenkapitein"]
      rationale: "Legally responsible for port safety"
    - title_patterns: ["nautisch.?adviseur", "nautical.?advisor"]
      rationale: "Vessel traffic guidance authority"
    - title_patterns: ["PFSO", "port.?facility.?security"]
      rationale: "ISPS security officer"
  
  risk_domains:
    - domain: "safety"
      description: "Vessel traffic, hazardous materials, emergency response"
      weight: 1.0
    - domain: "security"
      description: "Physical port security, ISPS, cyber-physical systems"
      weight: 0.95
    - domain: "operational"
      description: "Terminal operations, logistics, scheduling"
      weight: 0.8
    - domain: "environmental"
      description: "Emissions, spills, environmental monitoring"
      weight: 0.7
    - domain: "financial"
      description: "Revenue, contracts, procurement"
      weight: 0.6
```

### Step 1.2 — Admin Review Dialog

After context discovery, present the organizational risk profile to the admin for review. The admin should be able to:

- **Confirm or correct** industry classification and regulatory landscape
- **Add missing systems** that aren't publicly known (internal LOB apps, custom tools)
- **Add critical roles/titles** specific to this organization
- **Adjust risk domain weights** based on organizational priorities
- **Remove irrelevant items** the LLM may have incorrectly included
- **Have a dialog** with the LLM to refine: "We also have an OT network managing container cranes — add that as a critical domain"

This is an interactive refinement step. The LLM can ask clarifying questions: "I see Port of Rotterdam has chemical storage facilities — should I add SEVESO/BRZO classifiers for hazardous materials management?"

### Step 1.3 — Classifier Generation

Based on the finalized organizational risk profile, generate classifiers for all four entity types. Combine:

1. **Universal classifiers** (ship with the tool as defaults — always applicable)
2. **Industry classifiers** (generated based on industry/sub-industry)
3. **Organization-specific classifiers** (generated from the customer research)
4. **Admin-added custom classifiers**

---

## Classifier Schema

### Structure

```yaml
# classifier-ruleset.yaml
version: "1.0"
customer: "portofrotterdam.com"
generated_at: "2025-02-27T12:00:00Z"
profile_ref: "./customer-profile.yaml"

# ─── UNIVERSAL CLASSIFIERS (defaults, always active) ─────────────

universal_classifiers:

  groups:
    - id: "univ-domain-admins"
      category: "privilege-tier0"
      name_patterns: ["domain.?admin", "domein.?beheer", "DA[-_\\s]", "tier.?0"]
      description_patterns: ["domain.?admin", "full.?control.?directory"]
      base_score: 95
      rationale: "Direct domain administration — Tier 0 asset"

    - id: "univ-global-admins"
      category: "privilege-tier0"
      name_patterns: ["global.?admin", "GA[-_\\s]", "tenant.?admin"]
      base_score: 95
      rationale: "Entra ID Global Administrator equivalent"

    - id: "univ-privileged-access"
      category: "privilege"
      name_patterns: ["privileged", "PAM", "PIM", "break.?glass", "emergency.?access", "noodtoegang"]
      base_score: 90
      rationale: "Privileged or emergency access groups"

    - id: "univ-vpn-remote"
      category: "network-access"
      name_patterns: ["VPN", "remote.?access", "always.?on", "directaccess", "SSLVPN", "ZTNA"]
      base_score: 70
      rationale: "Remote network access — perimeter boundary"

    - id: "univ-firewall-network"
      category: "network-infrastructure"
      name_patterns: ["firewall", "network.?admin", "switch", "router", "VLAN.?admin"]
      base_score: 80
      rationale: "Network infrastructure management"

    - id: "univ-sap"
      category: "erp"
      name_patterns: ["SAP", "S4.?HANA", "SAP.?basis", "SAP.?admin"]
      description_patterns: ["SAP", "enterprise.?resource"]
      base_score: 75
      rationale: "ERP system access — typically financial/operational data"

    - id: "univ-exchange-mail"
      category: "communication"
      name_patterns: ["exchange.?admin", "mail.?admin", "transport.?rule", "journaling"]
      base_score: 65
      rationale: "Email infrastructure administration"

    - id: "univ-backup-recovery"
      category: "data-protection"
      name_patterns: ["backup", "disaster.?recovery", "DR[-_\\s]", "veeam", "commvault", "recovery"]
      base_score: 75
      rationale: "Backup systems — compromise enables ransomware impact"

    - id: "univ-security-ops"
      category: "security"
      name_patterns: ["SOC", "SIEM", "sentinel", "security.?operations", "incident.?response"]
      base_score: 80
      rationale: "Security operations — visibility and response capability"

    - id: "univ-certificate-pki"
      category: "trust-infrastructure"
      name_patterns: ["PKI", "certificate", "CA[-_\\s]admin", "cert.?auth"]
      base_score: 85
      rationale: "PKI/certificate infrastructure — trust anchor"

  users:
    - id: "univ-c-suite"
      category: "high-value-target"
      title_patterns: ["CEO", "CFO", "CTO", "CISO", "COO", "CIO", "CRO",
                        "chief.?executive", "chief.?financial", "chief.?technology",
                        "directeur", "bestuurder", "bestuursvoorzitter"]
      base_score: 85
      rationale: "C-suite accounts are primary targets for BEC and account takeover"

    - id: "univ-it-admin"
      category: "privilege"
      title_patterns: ["system.?admin", "systeembeheerder", "IT.?manager",
                        "infrastructure.?engineer", "platform.?engineer"]
      base_score: 70
      rationale: "IT administrators typically hold elevated privileges"

    - id: "univ-service-account"
      category: "non-human"
      name_patterns: ["^svc[-_]", "^sa[-_]", "service.?account", "^app[-_]"]
      upn_patterns: ["^svc", "^sa[-_]", "noreply"]
      base_score: 65
      rationale: "Service accounts often have broad persistent access with weak controls"

  apps:
    - id: "univ-high-graph-permissions"
      category: "overprivileged-app"
      permission_patterns: ["Mail.ReadWrite.All", "Files.ReadWrite.All",
                            "Directory.ReadWrite.All", "RoleManagement.ReadWrite.All",
                            "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"]
      base_score: 80
      rationale: "Application-level permissions enabling broad tenant data access"

    - id: "univ-app-credentials"
      category: "credential-risk"
      signals:
        - type: "credential_expiry"
          condition: "expired_or_expiring_30_days"
          weight_multiplier: 1.3
        - type: "credential_count"
          condition: "multiple_active_secrets"
          weight_multiplier: 1.2
      base_score: 50
      rationale: "App credential hygiene — expired/multiple credentials indicate poor lifecycle management"

  access_packages:
    - id: "univ-auto-approval-privileged"
      category: "governance-gap"
      signals:
        - type: "approval_policy"
          condition: "auto_approve"
        - type: "contains_high_risk_resource"
          condition: "any_resource_score_above_70"
      base_score: 85
      rationale: "Auto-approved access to high-risk resources — governance gap"

# ─── INDUSTRY CLASSIFIERS (generated per industry) ─────────────

industry_classifiers:

  groups:
    - id: "port-vts-access"
      category: "critical-infrastructure"
      industry: "port-authority"
      name_patterns: ["VTS", "vessel.?traffic", "VTMS", "radar", "AIS"]
      description_patterns: ["vessel.?traffic", "shipping", "navigation"]
      base_score: 90
      rationale: "Vessel Traffic Service systems — safety-critical infrastructure"

    - id: "port-hamis"
      category: "critical-infrastructure"
      industry: "port-authority"
      name_patterns: ["HaMIS", "harbor.?master.?info", "havenmeester.?systeem"]
      base_score: 95
      rationale: "Harbor Master Information System — core port operations"

    - id: "port-customs-border"
      category: "regulatory"
      industry: "port-authority"
      name_patterns: ["customs", "douane", "portbase", "border", "GIDR"]
      base_score: 80
      rationale: "Customs and border security systems — regulatory requirement"

    - id: "port-ot-scada"
      category: "critical-infrastructure"
      industry: "port-authority"
      name_patterns: ["SCADA", "OT[-_\\s]", "PLC", "industrial.?control", "ICS",
                       "crane", "bridge.?control", "lock.?control", "sluis"]
      base_score: 90
      rationale: "Operational Technology — cyber-physical systems, safety impact"

  users:
    - id: "port-harbor-master"
      category: "critical-role"
      industry: "port-authority"
      title_patterns: ["havenmester", "harbor.?master", "havenkapitein",
                        "haven.?meester"]
      base_score: 90
      rationale: "Legally responsible for port safety and vessel traffic management"

    - id: "port-pfso"
      category: "security-role"
      industry: "port-authority"
      title_patterns: ["PFSO", "port.?facility.?security", "ISPS.?officer"]
      base_score: 85
      rationale: "ISPS Code designated security officer"

  apps:
    - id: "port-vts-application"
      category: "critical-infrastructure"
      industry: "port-authority"
      name_patterns: ["VTS", "vessel.?traffic", "HaMIS", "Pronto", "port.?call"]
      base_score: 90
      rationale: "Core port operational applications"

# ─── ORGANIZATION-SPECIFIC (generated from research + admin input) ───

organization_classifiers:
  # These are populated during the admin review dialog
  # Example:
  groups: []
  users: []
  apps: []
  access_packages: []
```

---

## Phase 2: Heuristics Scoring Engine

### Scoring Layers

The engine applies four scoring layers to each entity, then combines them into a final score.

#### Layer 1 — Direct Classifier Match (name/description/property matching)

For each entity, iterate through all applicable classifiers. Apply fuzzy matching on name and description fields against the classifier's patterns. Use regex for pattern matching with case-insensitive flags. Consider implementing token-based matching for multi-word patterns.

**Matching strategy:**
- Regex patterns from classifier `name_patterns` and `description_patterns`
- Case-insensitive
- Support Dutch and English terms (many AD environments mix languages)
- Match against: `displayName`, `description`, `mail`, `mailNickname`, `samAccountName`
- For users: also match `jobTitle`, `department`, `userPrincipalName`
- For apps: also match `appDisplayName`, `servicePrincipalType`, `oauth2PermissionScopes`

**Score:** Take the highest matching classifier's `base_score` as the direct match score. If multiple classifiers match, take the maximum (don't add — a group that matches both "domain admin" and "tier 0" shouldn't get double the score).

#### Layer 2 — Membership/Relationship Analysis (structural)

This layer scores based on who/what is connected to the entity.

**For groups:**
- Contains members who hold privileged Entra ID directory roles → +15-25 points
- Contains members who are in Domain Admins / Enterprise Admins / Schema Admins → +20 points
- Contains C-suite members (by title match) → +10-15 points
- Contains service accounts → +5 points (service accounts in user groups = risk signal)
- Member count analysis: very small groups (<5) with privileged access = higher risk per member
- Contains external/guest members → +5-10 points (depends on group purpose)

**For users:**
- Number of privileged role assignments → weighted score
- Number of group memberships vs. departmental average → outlier detection
- Is member of any group scoring >80 → inherits partial risk
- Has direct app role assignments to high-risk apps → +10-20 points

**For apps:**
- Number of users assigned → scale factor (more users = broader blast radius)
- Has application-level permissions (vs. delegated) → +15 points
- Number of app roles defined → complexity indicator

**For access packages:**
- Aggregated risk of contained resources (groups, app roles)
- Approval policy strictness (auto-approve = +20, single approver = +10, multi-stage = +0)
- Review frequency (no review = +15, annual = +10, quarterly = +0)
- Expiry policy (no expiry = +10, >1 year = +5)

#### Layer 3 — Structural/Hygiene Signals

These are entity-specific red flags that don't require organizational context:

**For groups:**
- Nesting depth > 3 levels → +5-10 points (audit complexity)
- No description set → +3 points (poor documentation)
- No owner set → +5 points (governance gap)
- Last membership change > 12 months ago but still has assignments → +5 points (stale)
- Is mail-enabled security group → +3 points (broader exposure)
- Is used in Conditional Access policies → informational flag (not necessarily higher risk, but important)
- Is excluded from Conditional Access policies → +10 points (potential bypass)

**For users:**
- Account enabled but no sign-in in 90+ days → +10 points (stale account)
- No MFA registered → +15 points
- Password never expires flag set → +5 points
- Account not in any Conditional Access scope → +10 points

**For apps:**
- Credentials expired or expiring within 30 days → +10 points
- Multiple active credential secrets → +5 points
- No owner assigned → +5 points
- Third-party (non-Microsoft) publisher → +3 points (not inherently risky, but less controlled)
- Created > 2 years ago with no recent modification → +5 points (abandoned app risk)

#### Layer 4 — Cross-Entity Risk Propagation

Risk flows between connected entities with decay:

```
propagated_score = max_connected_entity_score × propagation_factor
```

**Propagation factors (tunable):**
- Group → User: 0.3 (a user inherits 30% of their riskiest group's score)
- User → Group: 0.25 (a group inherits 25% of its riskiest member's score)
- App → Group: 0.35 (a group inherits 35% of the riskiest app it grants access to)
- Group → App: 0.2 (an app inherits 20% of its riskiest assigned group)
- Access Package → contained resources: 0.4

### Final Score Calculation

```
final_score = min(100, (
    weight_direct × direct_classifier_score +
    weight_membership × membership_score +
    weight_structural × structural_score +
    weight_propagated × max_propagated_score
))
```

**Default weights (tunable per customer):**
- `weight_direct`: 0.50 (classifier matches are the primary signal)
- `weight_membership`: 0.20 (who's in it / what it connects to)
- `weight_structural`: 0.10 (hygiene and configuration signals)
- `weight_propagated`: 0.20 (inherited risk from connected entities)

### Risk Tiers

| Tier | Score Range | Label | Color |
|------|-------------|-------|-------|
| 1 | 90-100 | Critical | Red |
| 2 | 70-89 | High | Orange |
| 3 | 40-69 | Medium | Yellow |
| 4 | 20-39 | Low | Blue |
| 5 | 0-19 | Minimal | Gray |
| — | N/A | Unclassified | White |

"Unclassified" means no classifier matched and no significant structural or membership signals were detected. These should be surfaced for manual review.

---

## Phase 3 (Optional): LLM-Assisted Unclassified Review

For entities that score very low or remain unclassified, the admin can optionally choose to send **anonymized metadata** to an LLM for classification suggestions:

- Group name with internal identifiers stripped/hashed
- Member count (not member names)
- Type and properties
- Connected app count (not app names)

This is strictly opt-in and requires explicit admin consent per batch.

---

## Data Collection — New Requirements

### Apps (Enterprise Applications & App Registrations)

The existing tool collects users, groups, and memberships. To support risk scoring, we need to add collection of application data from Entra ID via Microsoft Graph API.

**Endpoints needed:**

```
# Enterprise Applications (Service Principals)
GET /servicePrincipals
  - id, displayName, appId, servicePrincipalType
  - appRoleAssignmentRequired
  - accountEnabled
  - tags (to identify gallery vs. custom)
  - publisherName
  - notes, description

# App Role Assignments (who/what is assigned to apps)
GET /servicePrincipals/{id}/appRoleAssignedTo
  - principalId, principalType (User, Group, ServicePrincipal)
  - appRoleId, resourceDisplayName

# App Registrations (API permissions)
GET /applications
  - id, displayName, appId
  - requiredResourceAccess (API permissions requested)
  - passwordCredentials (secret expiry dates)
  - keyCredentials (certificate expiry dates)

# Delegated permissions granted
GET /oauth2PermissionGrants
  - clientId, consentType, scope
  - resourceId

# Directory Role Assignments (for user risk scoring)
GET /roleManagement/directory/roleAssignments
  - principalId, roleDefinitionId, directoryScopeId

# Conditional Access Policies (for structural signals)
GET /identity/conditionalAccess/policies
  - conditions.applications.includeApplications
  - conditions.applications.excludeApplications
  - conditions.users.includeGroups / excludeGroups
  - grantControls
```

### Access Packages (Entra ID Governance)

```
# Access Packages
GET /identityGovernance/entitlementManagement/accessPackages
  - id, displayName, description, catalogId
  - isHidden, createdDateTime

# Access Package Resources (what's in the package)
GET /identityGovernance/entitlementManagement/accessPackages/{id}/resourceRoleScopes
  - accessPackageResourceRole (the role being granted)
  - accessPackageResourceScope (the resource)

# Assignment Policies (approval/review settings)
GET /identityGovernance/entitlementManagement/assignmentPolicies
  - accessPackageId
  - requestApprovalSettings (approval stages, auto-approve)
  - reviewSettings (frequency, reviewers)
  - expirationSettings
```

---

## Implementation Plan — Step by Step

### Step 1: Classifier Schema & Storage
**Priority: First**

- Define the YAML/JSON schema for classifiers (as documented above)
- Create a default `universal-classifiers.yaml` file with the universal rules
- Implement classifier loading, validation, and merging (universal + industry + org-specific + custom)
- Storage: classifiers stored as files alongside the existing tool data

### Step 2: Customer Context Discovery Module
**Priority: Second**

- Build the context discovery workflow:
  1. Accept customer domain/name as input
  2. Use LLM (Claude API) with web search to research the organization
  3. Generate organizational risk profile (YAML)
  4. Present to admin for review
  5. Interactive refinement dialog
  6. Generate industry + organization classifiers from the profile
  7. Merge with universal classifiers
  8. Save finalized classifier ruleset

- **Important:** This module calls the Claude API. The only data sent is the customer's public domain name and the back-and-forth dialog about industry context. No AD/Entra data is ever sent.

### Step 3: App & Access Package Data Collection
**Priority: Can run in parallel with Step 2**

- Extend the existing data collection module to pull:
  - Enterprise applications and their properties
  - App role assignments (group → app, user → app)
  - App registrations with API permissions and credentials
  - OAuth2 permission grants
  - Directory role assignments
  - Conditional Access policies
  - Access packages, their resources, and assignment policies
- Store in the existing data layer alongside users, groups, memberships

### Step 4: Heuristics Scoring Engine
**Priority: Third (after Steps 1 and 3)**

- Implement the four scoring layers:
  1. **Direct classifier matching** — regex/fuzzy matching engine against entity properties
  2. **Membership/relationship analysis** — graph traversal using existing membership data + new app assignments
  3. **Structural/hygiene signals** — property-based checks per entity type
  4. **Cross-entity risk propagation** — iterative propagation with decay

- Scoring configuration (weights, propagation factors, tier boundaries) should be tunable per customer and stored alongside the classifier ruleset

- The engine should produce, for each entity:
  - `final_score` (0-100)
  - `risk_tier` (Critical/High/Medium/Low/Minimal/Unclassified)
  - `score_breakdown` — array of contributing factors with individual scores and rationale
  - `matched_classifiers` — which classifiers fired and why
  - `propagation_sources` — which connected entities contributed propagated risk

### Step 5: UI Integration
**Priority: Fourth**

- **Dashboard view:** Summary of risk distribution across all entity types (how many critical, high, medium, low, unclassified)
- **Entity list view:** Sortable/filterable by risk tier, with score displayed
- **Entity detail view:** Full score breakdown showing every contributing factor
- **Classifier management:** UI to view, edit, add, remove classifiers
- **Customer profile management:** View/edit the organizational risk profile
- **Configuration:** Tune weights, propagation factors, tier boundaries
- **Unclassified review:** List of entities that didn't match any classifier for manual review

### Step 6: Reporting & Export
**Priority: Fifth**

- Export risk scores to CSV/Excel for offline analysis
- Generate summary report suitable for management/audit presentation
- Comparison view: run scoring before and after classifier changes to see impact

---

## File Structure (suggested)

```
risk-scoring/
├── classifiers/
│   ├── universal-classifiers.yaml      # Ships with tool
│   ├── industry/
│   │   ├── banking.yaml                # Pre-built for common industries
│   │   ├── healthcare.yaml
│   │   ├── port-authority.yaml
│   │   ├── government.yaml
│   │   └── manufacturing.yaml
│   └── customers/
│       └── portofrotterdam.com/
│           ├── customer-profile.yaml    # Org risk profile
│           ├── generated-classifiers.yaml  # LLM-generated
│           └── custom-classifiers.yaml  # Admin-added
├── engine/
│   ├── matcher.py                      # Pattern matching (regex, fuzzy)
│   ├── membership_analyzer.py          # Relationship/membership scoring
│   ├── structural_analyzer.py          # Hygiene/structural signals
│   ├── propagation.py                  # Cross-entity risk propagation
│   ├── scorer.py                       # Combines all layers, calculates final scores
│   └── config.py                       # Scoring weights, tier definitions
├── discovery/
│   ├── context_builder.py              # LLM-assisted customer research
│   ├── classifier_generator.py         # Generates classifiers from profile
│   └── admin_dialog.py                 # Interactive refinement workflow
├── collection/
│   ├── apps_collector.py               # Graph API: apps, permissions, credentials
│   ├── access_packages_collector.py    # Graph API: entitlement management
│   ├── ca_policies_collector.py        # Graph API: Conditional Access
│   └── directory_roles_collector.py    # Graph API: role assignments
└── reports/
    ├── risk_dashboard.py               # Summary statistics
    └── export.py                       # CSV/Excel export
```

---

## Technical Notes

### Fuzzy Matching Implementation

For name matching, consider using a combination of:
1. **Regex** for structured patterns (e.g., `domain.?admin`)
2. **Token-based matching** for multi-word patterns (split on delimiters like `-`, `_`, ` `, `.`)
3. **Levenshtein distance** or **Jaro-Winkler** for typo tolerance (optional, may produce false positives)
4. **Synonym expansion** for Dutch/English: maintain a small dictionary (`admin` ↔ `beheerder`, `firewall` ↔ `brandmuur`, `user` ↔ `gebruiker`)

### Performance Considerations

At 10,000 groups with ~50 classifiers, pattern matching is trivially fast (< 1 second). Membership analysis with 350K assignments needs efficient graph traversal — build an adjacency list/dict in memory, don't do repeated lookups. Risk propagation should converge in 2-3 iterations max if you propagate from the highest-scored entities first and apply decay.

### Scoring Stability

Propagation can create feedback loops (A scores high because of B, B scores high because of A). Prevent this by:
- Running direct + membership + structural scoring first (these are stable)
- Running propagation as a separate pass using only those pre-propagation scores
- Never propagating a propagated score (only propagate from direct/membership/structural components)

---

## Open Questions for Admin Decision

1. **Language support:** Should fuzzy matching support Dutch, English, or both by default? (Recommendation: both, since most Dutch AD environments mix languages)
2. **Existing tool integration:** What is the current data layer format? (Database, JSON files, etc.) The scoring engine needs to read from it.
3. **LLM API choice:** Claude API for context discovery? Local model option for air-gapped environments?
4. **Re-scoring triggers:** Should scoring re-run automatically when data is refreshed, or only on-demand?
5. **Historical tracking:** Should we store score history to show risk trends over time?
