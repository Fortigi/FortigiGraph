# FortigiGraph UI - Role Mining MVP Plan

## Architecture

```
UI/
├── backend/                    # Node.js + Express API
│   ├── src/
│   │   ├── index.js            # Express server entry point
│   │   ├── routes/
│   │   │   └── permissions.js  # API routes for permission data
│   │   ├── db/
│   │   │   └── connection.js   # Azure SQL connection (mssql package)
│   │   └── mock/
│   │       └── data.js         # Mock data for development without SQL
│   ├── package.json
│   └── .env.example            # Connection string template
│
├── frontend/                   # React + Vite SPA
│   ├── src/
│   │   ├── App.jsx             # Main app layout with view switching
│   │   ├── components/
│   │   │   ├── PermissionGrid.jsx    # TanStack Table grid view
│   │   │   ├── PivotView.jsx         # PivotTable.js wrapper
│   │   │   └── ViewToggle.jsx        # Switch between grid/pivot
│   │   ├── hooks/
│   │   │   └── usePermissions.js     # Data fetching hook
│   │   └── main.jsx            # Vite entry point
│   ├── package.json
│   ├── vite.config.js
│   └── index.html
│
└── PLAN.md                     # This file
```

## MVP Scope

### What it does
1. **Backend** serves permission data from SQL views (or mock data)
2. **Grid View** (TanStack Table): filterable, sortable, groupable table of user-permission assignments
3. **Pivot View** (PivotTable.js): drag-and-drop pivot analysis with heatmap coloring
4. **View Toggle**: switch between grid and pivot on the same dataset

### What it does NOT do (yet)
- Authentication (Entra ID / OpenID Connect)
- Annotations/tagging
- Export to Excel
- Deployment to Azure
- Persistent filter/view state

## Data Flow

```
SQL Views (or mock data)
    → GET /api/permissions          → vw_UserPermissionAssignments
    → GET /api/unmanaged            → vw_UnmanagedPermissions
    → GET /api/groups               → GraphGroups (for display names)
    → GET /api/users                → GraphUsers (for display names)
        ↓
React Frontend
    → Grid View (TanStack Table)
    → Pivot View (PivotTable.js)
```

## Tech Choices

| Component | Choice | Why |
|-----------|--------|-----|
| Backend runtime | Node.js 20+ | Simple, fast, huge ecosystem |
| Backend framework | Express | Minimal, well-known |
| SQL client | mssql (tedious) | Native Azure SQL support, AAD auth ready |
| Frontend framework | React 18 | Most ecosystem support for TanStack/PivotTable |
| Build tool | Vite | Fast, modern, zero-config for React |
| Data grid | @tanstack/react-table v8 | MIT, headless, actively maintained |
| Pivot table | pivottable + react-pivottable | Best drag-and-drop pivot UX available |
| Styling | Tailwind CSS | Utility-first, fast to prototype |

## Mock Data Structure

The mock data mirrors your SQL views exactly, so switching from mock → real SQL is just a config change:

```javascript
// Mock vw_UserPermissionAssignments
[
  {
    groupId: "g-001",
    groupDisplayName: "SG-Finance-Read",
    memberId: "u-001",
    memberDisplayName: "John Doe",
    memberType: "#microsoft.graph.user",
    membershipType: "Direct",      // Direct | Indirect | Owner | Eligible
    department: "Finance",
    jobTitle: "Analyst"
  },
  // ... ~200 rows covering realistic patterns
]
```

## Steps to Build

### Step 1: Backend scaffold
- Initialize Node.js project with Express
- Create mock data that mirrors SQL view structures
- Implement API routes returning mock data
- Add SQL connection module (disabled by default, uses mock)

### Step 2: Frontend scaffold
- Initialize React + Vite project
- Install TanStack Table, pivottable, react-pivottable, Tailwind
- Create basic layout with view toggle

### Step 3: Grid View (TanStack Table)
- Render permission assignments in a table
- Add column filtering (text filter on user/group, dropdown on membershipType)
- Add grouping (by department, by group, by membershipType)
- Color-code cells by membership type
- Add column visibility toggle (show/hide groups)

### Step 4: Pivot View (PivotTable.js)
- Wrap PivotTable.js in a React component
- Pre-configure with sensible defaults (users as rows, groups as columns)
- Enable heatmap renderer
- Pass filtered data from the grid view

### Step 5: Wire to real SQL (optional, needs connection string)
- Enable SQL connection via .env
- Query actual views instead of mock data
- Verify performance with real data volumes
