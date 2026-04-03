# CLAUDE_CODE_OPERATING_MANUAL

## 1. Purpose

This manual tells Claude Code how to work on the Identity Atlas test pipeline and test framework.

Claude Code must use this manual to:
- understand the project context
- stay inside the guardrails
- produce a reviewable paper starter package first
- avoid unnecessary complexity
- design a maintainable and extensible framework
- prepare implementation only after explicit approval

This manual is directive. Claude Code must treat it as operational instruction, not as background notes.

---

## 2. Project Identity

### Product name
Identity Atlas

### Current repository name
FortigiGraph

### Primary sponsor
Rob Bosma

### Working audience
Claude Code builds and maintains the test pipeline and test framework for Rob Bosma and colleagues.

---

## 3. Product Context

Identity Atlas creates graphical overviews of identities, accounts, and permissions across systems.

Supported and planned source types include:
- Microsoft Entra ID
- Active Directory
- CyberArk
- applications with their own user and permission model
- CSV imports
- API-based integrations

Target users include:
- security staff
- IAM engineers
- role managers
- related operational and governance users

The application can run locally or in Azure.

### Current technology direction
- PowerShell currently holds the main application logic
- JavaScript supports the UI
- Python is the target replacement for PowerShell logic over time

---

## 4. Primary Phase 1 Success Condition

Rob Bosma can trust the pipeline output as evidence of quality, secure operation, and correct functioning of the application.

---

## 5. Primary Design Risk

The pipeline must not become too complex to maintain.

If the pipeline becomes too complex, it will create false confidence instead of reliable evidence.

Claude Code must therefore prefer the simpler design whenever the simpler design still provides trustworthy evidence.
Claude Code may only choose a more complete or more complex design when the simpler design would weaken trust.

---

## 6. Core Working Principles

Claude Code must:
- prefer simple, explicit, maintainable structures
- avoid hidden magic and unnecessary abstraction
- keep the framework self-describing
- design for extension without redesign
- separate facts, assumptions, and proposals
- define explicit exit criteria for every stage
- define a definition of done for every proposed change set
- work in minimal viable changes
- preserve rollbackability and reviewability

Claude Code must not:
- optimize for cleverness over maintainability
- add duplicate mechanisms for the same purpose
- introduce multiple metadata systems without strong reason
- create hardcoded path assumptions across the framework
- create false confidence by hiding missing coverage, flaky behavior, or degraded confidence

---

## 7. Guardrails

### 7.1 Change control
Claude Code must ask for approval before it:
- creates files
- changes files
- adds dependencies
- changes pipeline files
- changes shared assets

Claude Code may execute tests without prior approval.

### 7.2 Product code changes
Claude Code may propose product code refactoring, but may not autonomously refactor product code.
Refactoring proposals must be reviewable and must lead to a PR-worthy change set after approval.

### 7.3 Secrets
Secrets may never appear in code, scripts, configuration files, logs, or artifacts.
Secrets must be stored and accessed through Key Vault or an equivalent approved secret mechanism.
Claude Code must define a full secrets handling policy, not only a storage rule.

### 7.4 Production safety
The pipeline may never use production systems or production data.
Only local mock data, fixed test CSV files, sandbox APIs, test tenants, test directories, test CyberArk environments, and synthetic or anonymized data may be used.

### 7.5 Approval behavior
Claude Code must first produce a complete change plan.
That plan must include:
- purpose
- files affected
- expected impact
- risks
- rollback impact
- tests to run
- whether guarded assets are touched

Small non-functional changes may be bundled in one approval request.
Larger or riskier changes must be proposed separately.

---

## 8. Required Delivery Sequence

Claude Code must follow this sequence:
1. read the index file first
2. identify the task type
3. read only the minimum required supporting documents
4. state which documents were consulted
5. separate facts, assumptions, and proposals
6. ask targeted questions if uncertainty affects correctness, security, or architecture
7. otherwise make the smallest safe assumption, state it clearly, and continue
8. produce a paper starter package first
9. wait for approval
10. only then propose implementation scripts and executable pipeline changes

No scripting or pipeline implementation work may be proposed for execution before the paper design is reviewed and approved.

---

## 9. Phase 1 Scope

Phase 1 must produce a paper starter package that defines a maintainable, extensible, trustworthy test framework and pipeline design.

Phase 1 must include at least:
- installation validation design
- linting and static analysis design
- unit test design
- regression test design
- vulnerability and dependency scanning design
- UI functional testing design
- Excel export validation design
- reporting and evidence model
- Azure DevOps and GitHub integration proposal
- repository structure proposal
- document set proposal
- bootstrap strategy for a repo with no existing test assets
- one minimal but real walking skeleton

### Walking skeleton for phase 1
The first walking skeleton must use the CSV import path.
It must prove this business outcome:

**The application can import controlled IAM data, show relationships, filter them, and export the result.**

The walking skeleton must include:
- environment check
- dependency install
- configuration
- controlled CSV data load
- application start
- one meaningful UI action
- one validation step
- one Excel export
- one report output

---

## 10. Phase 1 Is Not Meant To Do These Things

Phase 1 is not meant to:
- use production systems or production data
- fully replace PowerShell with Python
- enforce strict coverage thresholds yet
- build a full visual regression suite yet
- allow autonomous product refactoring
- create a highly abstract enterprise framework before basic trust is proven

The framework must, however, be designed so stricter gates and broader coverage can be added later without redesign.

---

## 11. Pipeline Shape

Claude Code must propose:
- one orchestration pipeline
- reusable modules or templates per test type
- clear stage ordering
- explicit stage exit criteria
- clear trigger rules
- clear blocking and non-blocking behavior

### Initial stage order
1. preparation and environment check
2. dependency install
3. configuration
4. lint and static analysis
5. unit tests
6. integration and connector tests
7. UI and regression tests
8. export validation
9. security scans
10. reporting

Claude Code must apply fast-fail logic.
If a failure makes further testing meaningless, the pipeline must stop.
If further testing still provides useful evidence, the pipeline may continue with honest confidence reporting.

---

## 12. Blocking Logic

A finding is blocking when it shows that the application or the current test chain is not functionally workable, and further testing would not provide meaningful evidence.

A finding is non-blocking when further testing can still provide useful evidence.

Warnings are allowed.

For failures, Claude Code must produce a report that includes:
- cause
- impact
- proposed fix
- and, where useful, a proposal for a new permanent test

---

## 13. Technology Quality Baseline

Claude Code must align with leading ecosystem standards and broadly accepted industry norms.

Initial preferred tools and standards are:
- PowerShell: Pester, PSScriptAnalyzer
- Python: pytest, Ruff, mypy
- JavaScript/UI: ESLint, Playwright
- Security and supply chain: dependency scanning, secret scanning, SBOM-oriented design

These are preferred defaults, not unchangeable dogma.
Claude Code must define a tool selection and replacement policy so better tools can be adopted later without redesigning the framework.

---

## 14. Migration Rules: PowerShell To Python

During migration, Claude Code must support both PowerShell and Python.

Claude Code must:
- support testing of existing PowerShell logic and new Python logic in parallel
- distinguish evidence for current PowerShell behavior from evidence for target Python behavior
- distinguish equivalence evidence from ordinary test evidence
- propose language-neutral tests and datasets where possible

For business logic, PowerShell and Python must produce functionally equivalent outcomes on the same controlled dataset where equivalence is expected.

---

## 15. Golden Dataset Rules

Claude Code must design and use a managed golden dataset strategy.

The first golden dataset must:
- use multiple CSV files by entity type
- use UTF-8 encoding
- use semicolon-separated columns
- use fixed headers
- use a strict CSV contract

The first dataset must include at least:
- identities
- accounts
- permissions
- relationships between them
- an identity without an account
- an account without a valid identity link
- a duplicate or conflicting linkage
- incomplete data
- at least one expected warning or error case

Claude Code must define expected outcomes for:
- import validation
- relationship building
- UI-visible filtering behavior
- warnings and errors
- Excel export content

Claude Code may create test data, mocks, and fixtures, but they must be synthetic, controlled, reviewable, and non-production.

---

## 16. Excel Export Validation

The first Excel export validation must be both rule-based and AI-assisted.
Rule-based validation is the formal pass or fail mechanism in phase 1.
AI may support analysis and explanation, but may not determine the formal outcome in phase 1.

Claude Code must define an explicit export contract, including:
- expected worksheets
- expected columns
- minimum required content
- relationship and count checks
- warning conditions
- failure conditions

The framework must be designed so AI can become co-decisive later without redesign.

---

## 17. Document Architecture

Claude Code must propose:
- one small index file
- one primary operating manual
- a small supporting document set
- a clear document hierarchy
- clear reading obligations per document type
- a task routing section in the index
- a reading strategy for Claude Code itself

### Document location
The initial default document root is:
`docs/claude-code/`

The document root must be configurable.
The framework must not rely on a hardcoded document location.

### Index file requirements
The index file must be:
- small
- navigational
- normative
- token-efficient

It must contain:
- document map
- mandatory reading order
- critical guardrails
- task routing
- pointers to deeper documents

Claude Code must always read the index first.

---

## 18. Repository Structure Requirements

Claude Code must propose an initial repository layout for:
- pipeline files
- reusable templates
- tests by category
- golden datasets
- fixtures and mocks
- reports and artifacts
- migration comparison tests
- shared utilities
- decision records
- approval request records where appropriate

The structure must be self-describing, simple, and extensible.

---

## 19. Path And Configuration Strategy

Claude Code must define one simple central configuration strategy for important framework roots and paths.
This must include at least:
- document root
- pipeline root
- test root
- dataset root
- fixtures and mocks root
- reports and artifacts root
- shared utilities root

Claude Code must also define:
- configuration precedence
- local developer override policy
- separation of secrets from ordinary configuration

The solution must remain small, explicit, and easy to change later.

---

## 20. Metadata, Manifests, And Schema Rules

Claude Code must keep metadata as light as possible.
Metadata may only be added when naming and folder structure alone cannot support traceability, routing, ownership, or reporting.

When metadata is needed:
- JSON is the standard manifest format
- one standard manifest pattern must be used
- one small shared core schema must be defined in the starter package

Claude Code must not create multiple metadata mechanisms without strong reason.

---

## 21. Required Classification Models

Claude Code must define standard classification models for:
- test types and execution layers
- environments
- findings severity and priority
- evidence types
- release confidence levels

These models must remain simple, explicit, and useful.

---

## 22. Required Policies

Claude Code must define policies for at least the following:
- secrets handling
- test environment provisioning and teardown
- dependency pinning and update strategy
- logging, observability, and diagnostics
- test execution time and performance budgets
- flaky tests
- fallback behavior for unavailable external dependencies
- retries and idempotency
- parallel versus sequential execution
- not-yet-implemented coverage areas
- deprecated tests, datasets, and modules
- rollback
- audit trail
- review roles and review depth
- exception handling
- ownership handover
- test data lifecycle and refresh
- change policy for shared assets
- versioning rules for the framework itself

---

## 23. Traceability And Azure DevOps Integration

Claude Code must define a traceability model from:
- requirement or user story
- to test
- to result
- to defect or bug
- to regression test

Where possible, Azure DevOps work items must be used, including:
- user stories
- bugs
- questions
- related work items

The framework must make it easy to link a bug fix to a permanent regression test.

---

## 24. Standard Templates That Must Be Defined

Claude Code must define standard templates for:
- test cases
- pipeline modules
- reusable test templates
- decision records
- approval requests

Each template must remain small, explicit, and reviewable.

---

## 25. Evidence And Reporting

Test results and reporting must be both human-readable and machine-readable.

Claude Code must design reporting so the primary readers can quickly see:
- pass or fail per stage
- blocking findings
- non-blocking findings
- test coverage by category
- proposed fixes
- proposed new tests

Claude Code must distinguish evidence for:
- application functionality
- application security
- PowerShell behavior
- Python behavior
- equivalence between PowerShell and Python
- diagnostics only
- release confidence

Missing coverage must always be visible.
Unimplemented areas must never be mistaken for passing evidence.

---

## 26. Release Confidence Model

Claude Code must define a release confidence model that clearly distinguishes:
- local development confidence
- PR confidence
- merge confidence
- release confidence

Claude Code must not overstate what phase 1 evidence proves.

---

## 27. Complexity Control

Claude Code must define and follow an anti-complexity rule set.

For every framework or pipeline proposal, Claude Code must include a complexity review checkpoint that states:
- what complexity is added
- why it is necessary
- what simpler alternative was considered
- why the chosen approach still preserves maintainability and trust

Claude Code must always apply the minimal viable change rule.

---

## 28. Ownership Model

Claude Code must define a clear ownership model for:
- core framework assets
- test content
- shared datasets
- templates
- pipeline modules
- utilities
- governance documents

Shared assets must have stricter change control than ordinary test additions.

---

## 29. Starter Package Output Contract

Claude Code must define and then produce a paper starter package with a fixed, reviewable structure.

At minimum, the starter package must contain:
1. context and objectives
2. success condition and design risk
3. guardrails
4. working principles
5. proposed document set
6. document hierarchy and reading strategy
7. proposed repository structure
8. proposed pipeline architecture
9. stage model and exit criteria
10. bootstrap strategy
11. walking skeleton design
12. golden dataset strategy
13. migration strategy for PowerShell and Python
14. evidence and reporting model
15. quality baseline and tool strategy
16. required policies
17. traceability model
18. PR and review model
19. open questions
20. implementation order for phase 1

This package is paper-first. It must be reviewed and approved before implementation planning moves forward.

---

## 30. Output Discipline

For every meaningful task, Claude Code must clearly separate:
- facts
- assumptions
- proposals

Claude Code must explicitly state:
- which documents it read
- what remains uncertain
- what needs approval
- what the next smallest safe step is

---

## 31. Final Rule

This framework exists to produce trustworthy evidence without becoming unmaintainable.

If Claude Code must choose between a clever framework and a trustworthy maintainable framework, it must choose the trustworthy maintainable framework.
