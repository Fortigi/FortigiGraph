## Changes in this branch

- Fixed categories endpoint handling in UI backend
- Updated access package detail page components
- Updated access packages page with improved export functionality
- Improved Excel export for access packages
- Updated module configuration setup
- Fixed: Access packages with zero active assignments no longer show "Overdue" or "In Progress" review status — if there are no assigned users there is nothing for a reviewer to act on
- `New-FGConfig`: Wizard now offers to run `New-FGRiskProfile` + `New-FGRiskClassifiers` immediately after setup when Risk Scoring is enabled and an LLM API key was configured
- Access Packages page now shows how many past review cycles were completely skipped (no reviewer acted) — displayed as "N reviews not done" under the compliance status badge, making it visible when an owner is not taking their review responsibility seriously
- Renamed review status "Overdue" to "Missed" — the deadline has passed and cannot be corrected until the next cycle, so "Missed" more accurately reflects the situation
- Access review reviewer type "User's manager" (targetManager) now displays as readable text instead of the raw Graph API type name
- Access packages with zero active assignments now show "No assignments" in the Review Status column instead of "Pending first review" — there are no users to review, so no review action is possible
- Access package detail page: "Open in Entra ID" link now points to the correct Azure Portal ELM blade (includes catalog ID and names)
- Access package detail page: policy scope values (e.g. "specificDirectoryUsers") now display as human-readable labels (e.g. "Specific directory users")
- Access package detail page: auto-assignment policy scope now shows the filter rule expression (e.g. which department or attribute conditions determine who gets the package automatically)
