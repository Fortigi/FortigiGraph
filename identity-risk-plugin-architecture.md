# Identity Risk Scoring Engine — Plugin Architecture & Open Source Strategy

## Addendum to: identity-risk-scoring-plan.md

This document extends the project plan with a plugin architecture designed for open-source community contribution. The guiding principle: **make the knowledge shareable, not just the code.**

---

## The Community Value Proposition

Commercial IGA vendors (SailPoint, Saviynt, Microsoft) all have proprietary risk scoring. There is no open-source tool that lets identity practitioners:

1. Collectively build and share classification knowledge across industries
2. Contribute detection methods without exposing organizational data
3. Reuse each other's work across engagements and customers

This tool fills that gap. The plugin architecture should make contributing as frictionless as possible — from someone sharing a single YAML classifier file to someone building a full scoring module.

Think of the model as: **Sigma rules, but for identity risk.**

---

## Plugin Levels

There are five distinct extension points, ordered from easiest to contribute to most complex:

```
Contribution complexity
         │
         │  ┌──────────────────────────────┐
    Low  │  │ 1. Classifier Packs (YAML)   │  ◄── Just data, no code
         │  └──────────────────────────────┘
         │  ┌──────────────────────────────┐
         │  │ 2. Scoring Plugins (Python)  │  ◄── Implement a scoring interface
         │  └──────────────────────────────┘
         │  ┌──────────────────────────────┐
         │  │ 3. Context Discovery Plugins │  ◄── Research strategies
         │  └──────────────────────────────┘
         │  ┌──────────────────────────────┐
         │  │ 4. Data Source Connectors    │  ◄── AD, Entra, Okta, AWS IAM...
         │  └──────────────────────────────┘
         │  ┌──────────────────────────────┐
   High  │  │ 5. Export/Integration Plugins│  ◄── SIEM, SOAR, GRC platforms
         │  └──────────────────────────────┘
         │
```

---

## 1. Classifier Packs

**The most important contribution type.** Zero code required — just YAML files.

### Structure

Each classifier pack is a self-contained YAML file with metadata:

```yaml
# classifiers/community/banking-nl.yaml
pack:
  id: "banking-nl"
  name: "Dutch Banking Sector"
  version: "1.2.0"
  description: "Classifiers for Dutch banks under DNB/ECB supervision"
  author: "contributor-handle"
  license: "Apache-2.0"
  industries: ["banking", "financial-services"]
  regions: ["NL", "EU"]
  tags: ["DNB", "DORA", "PSD2", "SWIFT"]
  
  # Dependencies on other packs (optional)
  extends:
    - "universal"           # Always implicit
    - "financial-services"  # Broader financial pack
  
  # Minimum engine version required
  engine_version: ">=1.0.0"

classifiers:
  groups:
    - id: "bank-nl-swift-ops"
      category: "critical-infrastructure"
      name_patterns: ["swift", "sag", "alliance.?lite", "payment.?gateway"]
      description_patterns: ["swift", "interbank", "payment.?processing"]
      base_score: 90
      rationale: "SWIFT-related groups — interbank payment infrastructure"
      references:
        - "https://www.swift.com/myswift/customer-security-programme-csp"
      mitre_attack: ["T1078"]  # Valid Accounts

    # ... more classifiers

  users:
    - id: "bank-nl-mlro"
      category: "regulatory-role"
      title_patterns: ["MLRO", "money.?laundering.?reporting",
                        "compliance.?officer", "wwft.?officer"]
      base_score: 75
      rationale: "Wwft/AML reporting officer — regulatory accountability"

  apps: []
  access_packages: []
```

### Community Registry

Classifier packs live in a community directory structure:

```
classifiers/
├── universal/
│   └── universal.yaml                # Ships with core tool
├── industry/
│   ├── banking/
│   │   ├── banking-general.yaml      # Generic banking
│   │   ├── banking-nl.yaml           # Dutch banking specifics
│   │   ├── banking-swift.yaml        # SWIFT-focused deep dive
│   │   └── banking-trading.yaml      # Trading floor specific
│   ├── healthcare/
│   │   ├── healthcare-general.yaml
│   │   ├── healthcare-nl.yaml        # Dutch healthcare (NEN 7510)
│   │   └── healthcare-epic.yaml      # Epic EHR specific
│   ├── critical-infrastructure/
│   │   ├── port-authority.yaml
│   │   ├── energy.yaml
│   │   ├── water-management.yaml
│   │   └── ot-scada-general.yaml
│   ├── government/
│   │   ├── government-nl.yaml        # Dutch government (BIO)
│   │   ├── government-eu.yaml
│   │   └── municipality-nl.yaml
│   └── education/
│       ├── university-nl.yaml
│       └── research-institution.yaml
├── compliance/
│   ├── nis2.yaml                     # NIS2 specific classifiers
│   ├── dora.yaml                     # DORA (financial)
│   ├── gdpr.yaml                     # GDPR data handling roles
│   ├── sox.yaml                      # SOX compliance
│   └── iso27001.yaml                 # ISO 27001 control mapping
└── technology/
    ├── sap.yaml                      # SAP ecosystem deep dive
    ├── microsoft-365.yaml            # M365 admin roles
    ├── azure-infrastructure.yaml     # Azure IaaS/PaaS
    ├── servicenow.yaml               # ServiceNow roles
    └── citrix.yaml                   # Citrix access patterns
```

### Pack Composition

An admin selects which packs to activate for a customer. Packs can extend each other. The engine merges them with a clear precedence: organization-specific > industry > compliance > technology > universal. When two classifiers match the same entity, the highest score wins.

### Contributing a Classifier Pack

Contributing should be as easy as:

1. Fork the repo
2. Create a YAML file following the schema
3. Run the built-in validator: `idrisk validate classifiers/my-pack.yaml`
4. Submit a PR

The validator checks: schema compliance, pattern syntax (are regexes valid?), no duplicate IDs across loaded packs, score ranges within bounds, required metadata present.

---

## 2. Scoring Plugins

For contributors who want to add new **detection logic** beyond pattern matching.

### Plugin Interface

Every scoring plugin implements a simple interface:

```python
# engine/plugins/base.py

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import List, Optional
from enum import Enum

class EntityType(Enum):
    USER = "user"
    GROUP = "group"
    APP = "app"
    ACCESS_PACKAGE = "access_package"

@dataclass
class ScoreContribution:
    """A single scoring contribution from a plugin."""
    plugin_id: str
    plugin_name: str
    entity_id: str
    entity_type: EntityType
    score: float              # 0-100
    weight: float             # 0-1, how much this contributes to final score
    reason: str               # Human-readable explanation
    details: dict             # Machine-readable details for UI
    references: List[str]     # Links to documentation/rationale
    confidence: float         # 0-1, how confident the plugin is

class ScoringPlugin(ABC):
    """Base class for all scoring plugins."""
    
    @property
    @abstractmethod
    def id(self) -> str:
        """Unique plugin identifier, e.g. 'toxic-combinations'"""
        pass
    
    @property
    @abstractmethod
    def name(self) -> str:
        """Human-readable name"""
        pass
    
    @property
    @abstractmethod
    def description(self) -> str:
        """What this plugin detects"""
        pass
    
    @property
    @abstractmethod
    def version(self) -> str:
        """Semantic version"""
        pass
    
    @property
    def entity_types(self) -> List[EntityType]:
        """Which entity types this plugin scores. Default: all."""
        return list(EntityType)
    
    @property
    def default_weight(self) -> float:
        """Default weight in the scoring mix. Admin can override."""
        return 0.5
    
    @abstractmethod
    def score(self, entity: dict, context: 'ScoringContext') -> Optional[ScoreContribution]:
        """
        Score a single entity.
        
        Args:
            entity: The entity to score (user, group, app, or access package)
                    with all properties and resolved memberships.
            context: Access to the full environment graph, classifier results,
                     customer profile, and other plugins' scores.
        
        Returns:
            ScoreContribution if this plugin has something to say about this entity,
            None if the plugin has no opinion.
        """
        pass
    
    def configure(self, config: dict) -> None:
        """Optional: accept plugin-specific configuration."""
        pass
    
    def validate_environment(self, context: 'ScoringContext') -> List[str]:
        """Optional: check if required data is available. Return list of warnings."""
        return []


class ScoringContext:
    """
    Read-only access to the full environment for scoring plugins.
    
    Plugins use this to look up related entities, check memberships,
    inspect the customer profile, and see other plugins' results.
    """
    
    def get_entity(self, entity_type: EntityType, entity_id: str) -> Optional[dict]:
        """Look up any entity by type and ID."""
        ...
    
    def get_members(self, group_id: str, recursive: bool = False) -> List[dict]:
        """Get members of a group, optionally recursive."""
        ...
    
    def get_memberships(self, user_id: str, recursive: bool = False) -> List[dict]:
        """Get groups a user belongs to, optionally recursive."""
        ...
    
    def get_app_assignments(self, app_id: str) -> List[dict]:
        """Get users/groups assigned to an app."""
        ...
    
    def get_user_app_roles(self, user_id: str) -> List[dict]:
        """Get app roles assigned to a user (direct + via groups)."""
        ...
    
    def get_customer_profile(self) -> dict:
        """Get the organizational risk profile."""
        ...
    
    def get_classifier_results(self, entity_id: str) -> List[dict]:
        """Get classifier match results for an entity (from Layer 1)."""
        ...
    
    def get_all_entities(self, entity_type: EntityType) -> List[dict]:
        """Iterate all entities of a type. Use for aggregate analysis."""
        ...
    
    def get_directory_roles(self, user_id: str) -> List[dict]:
        """Get Entra ID directory roles assigned to a user."""
        ...
    
    def get_conditional_access_policies(self) -> List[dict]:
        """Get all Conditional Access policies."""
        ...
```

### Example Scoring Plugins

These demonstrate the kinds of detection logic community members might contribute:

```python
# plugins/toxic_combinations.py

class ToxicCombinationsPlugin(ScoringPlugin):
    """
    Detects users who hold group memberships that together create
    separation-of-duty violations.
    
    Example: A user in both "AP-Invoice-Approve" and "AP-Payment-Execute"
    can both approve and execute payments — classic SoD violation.
    """
    
    id = "toxic-combinations"
    name = "Toxic Access Combinations"
    description = "Detects separation-of-duty violations from combined group memberships"
    version = "1.0.0"
    entity_types = [EntityType.USER]
    default_weight = 0.7
    
    # Toxic pairs are defined in config — community can contribute these too
    default_toxic_pairs = [
        {
            "name": "Payment SoD",
            "group_a_patterns": ["invoice.?approv", "payment.?approv", "factuur.?goedkeur"],
            "group_b_patterns": ["payment.?execut", "betaling.?uitvoer", "payment.?release"],
            "severity": 85,
            "rationale": "Can both approve and execute payments"
        },
        {
            "name": "User Lifecycle SoD",
            "group_a_patterns": ["user.?creat", "account.?provision", "onboard"],
            "group_b_patterns": ["access.?approv", "role.?assign", "permission.?grant"],
            "severity": 70,
            "rationale": "Can both create accounts and grant them access"
        }
    ]
    
    def score(self, entity, context):
        user_groups = context.get_memberships(entity['id'], recursive=True)
        group_names = [g['displayName'] for g in user_groups]
        
        violations = self._check_toxic_pairs(group_names)
        if not violations:
            return None
        
        worst = max(violations, key=lambda v: v['severity'])
        return ScoreContribution(
            plugin_id=self.id,
            plugin_name=self.name,
            entity_id=entity['id'],
            entity_type=EntityType.USER,
            score=worst['severity'],
            weight=self.default_weight,
            reason=f"SoD violation: {worst['name']} — {worst['rationale']}",
            details={"violations": violations, "total_violations": len(violations)},
            references=[],
            confidence=0.8
        )
```

```python
# plugins/shadow_it_detector.py

class ShadowITDetectorPlugin(ScoringPlugin):
    """
    Detects groups that may represent shadow IT:
    - Created by non-IT users
    - Have app assignments or mail-enabled
    - No owner from IT department
    - No governance (no access review, no expiry)
    """
    
    id = "shadow-it-detector"
    name = "Shadow IT Group Detector"
    description = "Identifies groups likely created outside IT governance"
    version = "1.0.0"
    entity_types = [EntityType.GROUP]
    default_weight = 0.4


# plugins/orphaned_access.py

class OrphanedAccessPlugin(ScoringPlugin):
    """
    Detects access that has become orphaned:
    - Groups with no owner where the last owner left the organization
    - App assignments where the app owner account is disabled
    - Groups still granting access to apps that are disabled
    """
    
    id = "orphaned-access"
    name = "Orphaned Access Detector"
    description = "Finds access grants with no active governance ownership"
    version = "1.0.0"
    entity_types = [EntityType.GROUP, EntityType.APP]
    default_weight = 0.5


# plugins/blast_radius.py

class BlastRadiusPlugin(ScoringPlugin):
    """
    Calculates the 'blast radius' of a compromised entity:
    - If this user account is compromised, how many systems are reachable?
    - If this group is hijacked, how many users and apps are affected?
    - Accounts for transitive access through group nesting.
    
    Scores higher for entities where compromise has outsized impact.
    """
    
    id = "blast-radius"
    name = "Blast Radius Calculator"
    description = "Measures the impact scope of entity compromise"
    version = "1.0.0"
    entity_types = [EntityType.USER, EntityType.GROUP]
    default_weight = 0.6


# plugins/stale_privileged_access.py

class StalePrivilegedAccessPlugin(ScoringPlugin):
    """
    Specifically targets: privileged access that shows no recent use.
    Combines sign-in activity with privilege level:
    - Global Admin who hasn't signed in for 60 days: critical
    - VPN group member with no VPN connection events: flag for review
    - App assignment with no app sign-in: potential cleanup candidate
    """
    
    id = "stale-privileged-access"
    name = "Stale Privileged Access"
    description = "Finds unused privileged access — high-value cleanup targets"
    version = "1.0.0"
    entity_types = [EntityType.USER]
    default_weight = 0.6


# plugins/naming_convention_anomaly.py

class NamingConventionAnomalyPlugin(ScoringPlugin):
    """
    Learns the naming conventions in the environment and flags anomalies.
    
    If 95% of groups follow "APP-{AppName}-{Role}" or "SEC-{Purpose}",
    a group named "john_temp_access_2" is an anomaly worth investigating.
    
    Uses statistical analysis, not ML — counts prefix/suffix patterns
    and flags entities that don't match the dominant patterns.
    """
    
    id = "naming-anomaly"
    name = "Naming Convention Anomaly Detector"
    description = "Flags entities that deviate from observed naming patterns"
    version = "1.0.0"
    entity_types = [EntityType.GROUP, EntityType.USER]
    default_weight = 0.3
```

### Plugin Discovery & Loading

Plugins are discovered automatically from a directory:

```
plugins/
├── builtin/                          # Ship with the tool
│   ├── classifier_matcher.py         # Layer 1: the core pattern matching
│   ├── membership_analyzer.py        # Layer 2: membership scoring
│   ├── structural_analyzer.py        # Layer 3: hygiene signals
│   └── risk_propagation.py           # Layer 4: cross-entity propagation
├── community/                        # Installed from community
│   ├── toxic_combinations.py
│   ├── shadow_it_detector.py
│   ├── blast_radius.py
│   └── ...
└── custom/                           # User's own plugins
    └── my_org_specific_scorer.py
```

Each plugin is loaded, validated (does it implement the interface?), and registered. The admin can enable/disable plugins and adjust their weights per customer.

---

## 3. Context Discovery Plugins

Extend how the system researches organizations in Phase 1.

```python
# discovery/plugins/base.py

class DiscoveryPlugin(ABC):
    """
    Contributes organizational intelligence for classifier generation.
    
    Discovery plugins research specific aspects of an organization
    and return structured findings that feed into the risk profile.
    """
    
    @property
    @abstractmethod
    def id(self) -> str:
        pass
    
    @property
    @abstractmethod
    def name(self) -> str:
        pass
    
    @property
    @abstractmethod
    def data_sources(self) -> List[str]:
        """What this plugin queries, e.g. ['web', 'kvk-api', 'dnb-register']"""
        pass
    
    @abstractmethod
    async def discover(self, customer_domain: str, customer_name: str,
                       existing_profile: dict) -> 'DiscoveryResult':
        """
        Research the organization and return findings.
        
        Args:
            customer_domain: e.g. "portofrotterdam.com"
            customer_name: e.g. "Havenbedrijf Rotterdam N.V."
            existing_profile: Current profile state (other plugins may have run first)
        
        Returns:
            DiscoveryResult with findings to merge into the profile
        """
        pass

@dataclass
class DiscoveryResult:
    """Structured findings from a discovery plugin."""
    plugin_id: str
    confidence: float  # 0-1
    industry_indicators: List[dict]       # Industry classifications found
    regulations: List[dict]               # Applicable regulations
    known_systems: List[dict]             # Critical systems identified
    critical_roles: List[dict]            # Important job titles/functions
    risk_domains: List[dict]              # Business risk areas
    raw_findings: dict                    # Plugin-specific raw data
```

### Example Discovery Plugins

```python
# discovery/plugins/kvk_lookup.py
class KvKDiscoveryPlugin(DiscoveryPlugin):
    """
    Queries Dutch KvK (Chamber of Commerce) data to determine:
    - Legal entity type and SBI sector codes
    - Number of employees (risk scale)
    - Trade names and subsidiaries
    - Registered activities
    
    SBI codes map directly to industry classifiers.
    """
    id = "kvk-lookup"
    name = "Dutch KvK Registry Lookup"
    data_sources = ["kvk-api"]


# discovery/plugins/regulatory_mapper.py
class RegulatoryMapperPlugin(DiscoveryPlugin):
    """
    Based on industry and jurisdiction, determines applicable regulations:
    - NIS2 essential/important entity classification
    - Sector-specific: DORA (financial), NEN 7510 (healthcare), BIO (government)
    - Cross-sector: GDPR, Wbni
    
    Maps regulations to specific control requirements that affect
    identity risk classification.
    """
    id = "regulatory-mapper"
    name = "Regulatory Framework Mapper"
    data_sources = ["web", "regulation-database"]


# discovery/plugins/annual_report_analyzer.py
class AnnualReportAnalyzerPlugin(DiscoveryPlugin):
    """
    Finds and analyzes the organization's annual report to identify:
    - Key business segments and revenue drivers
    - Mentioned technology platforms
    - Risk disclosures (what the org considers its own key risks)
    - Organizational structure and subsidiaries
    """
    id = "annual-report"
    name = "Annual Report Analyzer"
    data_sources = ["web"]


# discovery/plugins/tender_scanner.py
class TenderScannerPlugin(DiscoveryPlugin):
    """
    Searches public procurement/tender platforms for the organization's
    technology purchases. Tender documents often reveal:
    - Which systems they use (they're buying support/licenses)
    - Migration projects (old system → new system)
    - Security tool purchases
    
    Sources: TenderNed, TED (EU), vendor case studies.
    """
    id = "tender-scanner"
    name = "Public Tender Scanner"
    data_sources = ["web", "tendernet"]
```

---

## 4. Data Source Connectors

Allow the tool to collect identity data from sources beyond AD/Entra ID.

```python
# collection/plugins/base.py

class DataSourceConnector(ABC):
    """
    Collects identity data from a specific platform and normalizes it
    to the standard entity model.
    """
    
    @property
    @abstractmethod
    def id(self) -> str:
        pass
    
    @property
    @abstractmethod
    def name(self) -> str:
        """e.g. 'Microsoft Entra ID', 'Okta', 'AWS IAM'"""
        pass
    
    @property
    @abstractmethod
    def entity_types(self) -> List[EntityType]:
        """Which entity types this connector provides."""
        pass
    
    @abstractmethod
    async def collect(self, config: dict) -> 'CollectionResult':
        """
        Collect entities from the source and return normalized data.
        
        Config contains connection details (tenant ID, credentials, etc.)
        """
        pass
    
    @abstractmethod
    def get_required_permissions(self) -> List[str]:
        """
        Return list of permissions/scopes needed.
        Displayed to admin during setup.
        e.g. ['Directory.Read.All', 'Application.Read.All']
        """
        pass
```

### Planned Connectors

```
connectors/
├── builtin/
│   ├── entra_id.py           # Microsoft Entra ID (Graph API)
│   ├── active_directory.py   # On-prem AD (LDAP)
│   └── entra_governance.py   # Access packages, access reviews
├── community/
│   ├── okta.py               # Okta groups, apps, users
│   ├── aws_iam.py            # AWS IAM roles, policies, groups
│   ├── google_workspace.py   # Google Workspace groups, apps
│   ├── ping_identity.py      # PingOne / PingFederate
│   ├── sailpoint_iiq.py      # SailPoint IdentityIQ export
│   └── cyberark.py           # CyberArk safe/account structure
```

### Normalized Entity Model

All connectors output to a common entity model so scoring plugins work regardless of source:

```python
@dataclass
class NormalizedEntity:
    """Standard entity format that all connectors produce."""
    source: str               # "entra_id", "active_directory", "okta"
    entity_type: EntityType
    source_id: str            # ID in the source system
    canonical_id: str         # Globally unique (source + source_id)
    display_name: str
    description: Optional[str]
    entity_subtype: str       # "security_group", "m365_group", "distribution_list"
    
    properties: dict          # Source-specific properties
    
    # Relationships (populated during collection)
    member_of: List[str]      # canonical_ids of parent groups
    members: List[str]        # canonical_ids of direct members
    app_assignments: List[str]  # canonical_ids of assigned apps
    role_assignments: List[str] # Roles held (admin roles, app roles)
    owners: List[str]         # canonical_ids of owners
    
    # Standard timestamps
    created_at: Optional[datetime]
    modified_at: Optional[datetime]
    last_sign_in: Optional[datetime]
    
    # For cross-source correlation
    correlation_keys: dict    # {"upn": "user@domain.com", "email": "...", "employee_id": "..."}
```

---

## 5. Export/Integration Plugins

Output risk scores to other platforms:

```python
# export/plugins/base.py

class ExportPlugin(ABC):
    """Export risk scores and findings to external platforms."""
    
    @abstractmethod
    async def export(self, scores: List['EntityScore'],
                     profile: dict, config: dict) -> 'ExportResult':
        pass
```

### Planned Export Plugins

```
exports/
├── builtin/
│   ├── csv_export.py
│   ├── excel_report.py
│   └── json_export.py
├── community/
│   ├── sentinel_siem.py        # Push risk scores as watchlists to Microsoft Sentinel
│   ├── splunk_export.py        # Splunk lookup tables
│   ├── servicenow_cmdb.py      # Update ServiceNow CMDB risk attributes
│   ├── topdesk_export.py       # TopDesk integration (NL market)
│   └── powerbi_dataset.py      # Direct Power BI dataset push
```

---

## Plugin Configuration & Management

### Plugin Manifest

Each plugin (scoring, discovery, connector, export) ships with a manifest:

```yaml
# plugins/community/toxic_combinations/manifest.yaml
plugin:
  id: "toxic-combinations"
  name: "Toxic Access Combinations"
  version: "1.0.0"
  type: "scoring"                  # scoring | discovery | connector | export
  author: "github-handle"
  license: "Apache-2.0"
  description: "Detects separation-of-duty violations"
  
  engine_version: ">=1.0.0"
  
  # What this plugin needs from the data layer
  requires:
    entity_types: ["user", "group"]
    data_fields: ["group.members", "user.memberships"]
    connectors: []                  # Any specific connector required
  
  # Plugin-specific config schema
  config_schema:
    type: object
    properties:
      toxic_pairs_file:
        type: string
        description: "Path to custom toxic pairs definition"
      severity_threshold:
        type: number
        default: 50
        description: "Minimum severity to report"
  
  # Default enabled state
  default_enabled: true
  default_weight: 0.7
```

### Admin Plugin Management UI

The UI should let admins:
- Browse available plugins (installed + available from community)
- Enable/disable per customer engagement
- Configure plugin-specific settings
- Adjust scoring weights
- View plugin output explanations
- Install community plugins (from a registry or git URL)

---

## Open Source Repository Structure

```
identity-risk-engine/
├── README.md
├── LICENSE                          # Apache-2.0
├── CONTRIBUTING.md                  # How to contribute
├── docs/
│   ├── architecture.md
│   ├── getting-started.md
│   ├── writing-classifiers.md       # Guide for classifier contributions
│   ├── writing-plugins.md           # Guide for plugin development
│   ├── classifier-schema.md         # Full schema reference
│   └── plugin-api.md                # Full API reference
│
├── core/                            # Core engine (the framework)
│   ├── engine/
│   │   ├── scorer.py                # Orchestrates all scoring layers
│   │   ├── plugin_loader.py         # Discovers and loads plugins
│   │   ├── classifier_loader.py     # Loads and merges classifier packs
│   │   ├── entity_model.py          # Normalized entity definitions
│   │   └── config.py                # Engine configuration
│   ├── discovery/
│   │   ├── context_builder.py       # Orchestrates discovery plugins
│   │   └── profile_manager.py       # Customer profile CRUD
│   ├── collection/
│   │   └── collector_manager.py     # Orchestrates data collection
│   └── export/
│       └── export_manager.py        # Orchestrates exports
│
├── classifiers/                     # Classifier packs
│   ├── universal/
│   │   └── universal.yaml
│   ├── industry/
│   │   ├── banking/
│   │   ├── healthcare/
│   │   ├── critical-infrastructure/
│   │   ├── government/
│   │   └── education/
│   ├── compliance/
│   │   ├── nis2.yaml
│   │   ├── dora.yaml
│   │   └── iso27001.yaml
│   └── technology/
│       ├── sap.yaml
│       ├── microsoft-365.yaml
│       └── azure.yaml
│
├── plugins/                         # All plugin types
│   ├── scoring/
│   │   ├── builtin/
│   │   │   ├── classifier_matcher/
│   │   │   ├── membership_analyzer/
│   │   │   ├── structural_analyzer/
│   │   │   └── risk_propagation/
│   │   └── community/
│   │       ├── toxic_combinations/
│   │       ├── blast_radius/
│   │       ├── shadow_it_detector/
│   │       ├── naming_anomaly/
│   │       ├── stale_privileged_access/
│   │       └── orphaned_access/
│   ├── discovery/
│   │   ├── builtin/
│   │   │   └── llm_web_research/    # The core LLM + web search discovery
│   │   └── community/
│   │       ├── kvk_lookup/
│   │       ├── regulatory_mapper/
│   │       └── annual_report_analyzer/
│   ├── connectors/
│   │   ├── builtin/
│   │   │   ├── entra_id/
│   │   │   ├── active_directory/
│   │   │   └── entra_governance/
│   │   └── community/
│   │       ├── okta/
│   │       ├── aws_iam/
│   │       └── google_workspace/
│   └── exports/
│       ├── builtin/
│       │   ├── csv_export/
│       │   ├── excel_report/
│       │   └── json_export/
│       └── community/
│           ├── sentinel_siem/
│           └── powerbi_dataset/
│
├── ui/                              # Web UI
│   └── ...
│
├── cli/                             # Command-line interface
│   ├── main.py
│   ├── commands/
│   │   ├── discover.py              # Run context discovery
│   │   ├── collect.py               # Run data collection
│   │   ├── score.py                 # Run scoring engine
│   │   ├── validate.py              # Validate classifiers/plugins
│   │   └── export.py                # Run exports
│   └── ...
│
├── tests/
│   ├── test_classifiers/            # Validate all classifier packs
│   ├── test_plugins/                # Plugin test suites
│   ├── test_engine/                 # Core engine tests
│   └── fixtures/                    # Test data (synthetic, no real orgs)
│
└── tools/
    ├── classifier_validator.py       # CLI: validate a classifier pack
    ├── plugin_scaffold.py            # CLI: generate plugin boilerplate
    └── synthetic_data_generator.py   # Generate test environments
```

---

## Community & Contribution Guidelines

### Contribution Types (ordered by accessibility)

| Type | Skill needed | Review process |
|------|-------------|----------------|
| Classifier pack | YAML + domain knowledge | Peer review for quality/accuracy |
| Toxic combination rules | Domain knowledge | Peer review |
| Scoring plugin | Python + identity knowledge | Code review + tests required |
| Discovery plugin | Python + API knowledge | Code review + tests |
| Data source connector | Python + platform API knowledge | Code review + extensive testing |
| Core engine changes | Deep architecture knowledge | Maintainer review |

### Classifier Quality Standards

Community classifier packs should:
- Include clear rationale for every classifier
- Include references (links to regulations, vendor docs, best practices)
- Use tested regex patterns (no overly broad matches)
- Include both English and local-language variants where applicable
- Not include any organization-specific data (no customer names, internal systems)
- Be reviewed by at least one practitioner from the relevant industry

### Synthetic Test Data

The repo should include a synthetic data generator that creates realistic-looking AD/Entra environments for different industries. This lets contributors test their classifiers and plugins without needing access to real environments. The generator would create fake but plausible group names, user accounts, and app registrations following common naming conventions per industry.

---

## CLI Quick Reference

```bash
# Context Discovery
idrisk discover --domain portofrotterdam.com --output ./customers/port-of-rotterdam/

# Review and refine profile interactively
idrisk discover --refine ./customers/port-of-rotterdam/profile.yaml

# Validate a classifier pack
idrisk validate ./classifiers/industry/banking/banking-nl.yaml

# Collect data
idrisk collect --connector entra_id --config ./config/entra.yaml --output ./data/
idrisk collect --connector active_directory --config ./config/ad.yaml --output ./data/

# Run scoring
idrisk score --data ./data/ --classifiers ./classifiers/ --customer ./customers/port-of-rotterdam/ --output ./results/

# Export
idrisk export --format excel --input ./results/ --output ./reports/risk-report.xlsx
idrisk export --plugin sentinel --input ./results/ --config ./config/sentinel.yaml

# Plugin management
idrisk plugins list
idrisk plugins install toxic-combinations
idrisk plugins scaffold --type scoring --name my-custom-scorer
```

---

## Naming

The project needs a name. Some candidates to consider:

- **IDRisk** — simple, direct
- **Sentinel-ID** — but might conflict with Microsoft Sentinel branding
- **Horus** — Egyptian god associated with observation/protection
- **Argus** — Greek mythology, the all-seeing guardian (Argus Panoptes)
- **Vigil** — watchfulness, fits the risk monitoring angle
- **Bastion** — defensive, identity as the perimeter

Whatever is chosen, the CLI command and package name should match.

---

## Implementation Priority for Open Source

### Phase A: Core + Classifiers (MVP)
1. Core engine with plugin interfaces
2. Universal classifier pack
3. Entra ID + AD connectors
4. CLI for scoring + export
5. Basic CSV/JSON export
6. `CONTRIBUTING.md` with classifier writing guide

### Phase B: Intelligence Layer
7. LLM-assisted context discovery (Phase 1)
8. 3-5 industry classifier packs
9. 3-5 community scoring plugins
10. Plugin scaffold tooling

### Phase C: Community & Integration
11. Web UI for plugin/classifier management
12. Community plugin registry
13. Export plugins (Sentinel, Power BI)
14. Synthetic data generator for testing

### Phase D: Multi-Platform
15. Okta connector
16. AWS IAM connector
17. Cross-platform correlation
18. Multi-source risk aggregation
