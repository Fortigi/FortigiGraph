import { useState, useCallback } from 'react';
import { useAuth } from '../auth/AuthGate';

export default function AdminPage() {
  const { authFetch } = useAuth();
  const [status, setStatus] = useState(null); // { type: 'success'|'error'|'info', message, details? }
  const [exporting, setExporting] = useState(false);
  const [importing, setImporting] = useState(false);
  const [preview, setPreview] = useState(null); // parsed import file for preview
  const [importFile, setImportFile] = useState(null);

  // ── Export ──────────────────────────────────────────────────────
  const handleExport = useCallback(async () => {
    setExporting(true);
    setStatus({ type: 'info', message: 'Exporting data...' });
    try {
      const res = await authFetch('/api/admin/export');
      if (!res.ok) throw new Error('Export failed');
      const data = await res.json();

      // Download as file
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
      a.href = url;
      a.download = `fortigraph-export-${timestamp}.json`;
      a.click();
      URL.revokeObjectURL(url);

      const counts = summarizeCounts(data);
      setStatus({ type: 'success', message: 'Export downloaded successfully.', details: counts });
    } catch (err) {
      setStatus({ type: 'error', message: `Export failed: ${err.message}` });
    } finally {
      setExporting(false);
    }
  }, [authFetch]);

  // ── File selection ─────────────────────────────────────────────
  const handleFileSelect = useCallback((e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setImportFile(file);
    setStatus(null);

    const reader = new FileReader();
    reader.onload = (ev) => {
      try {
        const data = JSON.parse(ev.target.result);
        if (!data.version) throw new Error('Invalid export file — missing version field');
        setPreview(data);
        setStatus({ type: 'info', message: `File loaded: ${file.name}`, details: summarizeCounts(data) });
      } catch (err) {
        setPreview(null);
        setStatus({ type: 'error', message: `Invalid file: ${err.message}` });
      }
    };
    reader.readAsText(file);
  }, []);

  // ── Import ─────────────────────────────────────────────────────
  const handleImport = useCallback(async () => {
    if (!preview) return;
    setImporting(true);
    setStatus({ type: 'info', message: 'Importing data...' });
    try {
      const res = await authFetch('/api/admin/import', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(preview),
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.error || 'Import failed');
      }
      const result = await res.json();
      setStatus({ type: 'success', message: 'Import completed successfully.', details: formatImportResults(result.results) });
      setPreview(null);
      setImportFile(null);
    } catch (err) {
      setStatus({ type: 'error', message: `Import failed: ${err.message}` });
    } finally {
      setImporting(false);
    }
  }, [authFetch, preview]);

  return (
    <div className="max-w-3xl mx-auto">
      <div className="mb-6">
        <h2 className="text-lg font-semibold text-gray-900">Data Administration</h2>
        <p className="text-sm text-gray-500 mt-1">
          Export and import manually-curated data (tags, categories, risk overrides, analyst notes).
          Use this to migrate data between environments.
        </p>
      </div>

      {/* Status banner */}
      {status && (
        <div className={`mb-6 rounded-lg border p-4 ${
          status.type === 'success' ? 'bg-green-50 border-green-200 text-green-800' :
          status.type === 'error' ? 'bg-red-50 border-red-200 text-red-800' :
          'bg-blue-50 border-blue-200 text-blue-800'
        }`}>
          <p className="font-medium text-sm">{status.message}</p>
          {status.details && (
            <div className="mt-2 text-xs space-y-0.5">
              {status.details.map((line, i) => (
                <p key={i}>{line}</p>
              ))}
            </div>
          )}
        </div>
      )}

      <div className="grid gap-6 md:grid-cols-2">
        {/* Export card */}
        <div className="bg-white rounded-lg border border-gray-200 p-6">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-10 h-10 rounded-lg bg-blue-100 text-blue-600 flex items-center justify-center">
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
              </svg>
            </div>
            <div>
              <h3 className="font-semibold text-gray-900">Export Data</h3>
              <p className="text-xs text-gray-500">Download all curated data as JSON</p>
            </div>
          </div>
          <p className="text-sm text-gray-600 mb-4">
            Exports tags, categories, risk overrides, identity verifications, and cluster owner assignments.
          </p>
          <button
            onClick={handleExport}
            disabled={exporting}
            className="w-full px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {exporting ? 'Exporting...' : 'Export to JSON'}
          </button>
        </div>

        {/* Import card */}
        <div className="bg-white rounded-lg border border-gray-200 p-6">
          <div className="flex items-center gap-3 mb-3">
            <div className="w-10 h-10 rounded-lg bg-purple-100 text-purple-600 flex items-center justify-center">
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
              </svg>
            </div>
            <div>
              <h3 className="font-semibold text-gray-900">Import Data</h3>
              <p className="text-xs text-gray-500">Upload a previously exported JSON file</p>
            </div>
          </div>
          <p className="text-sm text-gray-600 mb-4">
            Tags and categories are matched by name. Existing items are updated, new items are created.
          </p>
          <div className="space-y-3">
            <label className="block">
              <input
                type="file"
                accept=".json"
                onChange={handleFileSelect}
                className="block w-full text-sm text-gray-500 file:mr-3 file:py-2 file:px-4 file:rounded-lg file:border-0 file:text-sm file:font-medium file:bg-purple-50 file:text-purple-700 hover:file:bg-purple-100 file:cursor-pointer"
              />
            </label>
            {preview && (
              <button
                onClick={handleImport}
                disabled={importing}
                className="w-full px-4 py-2 bg-purple-600 text-white text-sm font-medium rounded-lg hover:bg-purple-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              >
                {importing ? 'Importing...' : 'Import Data'}
              </button>
            )}
          </div>
        </div>
      </div>

      {/* Data overview */}
      <div className="mt-8 bg-white rounded-lg border border-gray-200 p-6">
        <h3 className="font-semibold text-gray-900 mb-3">What gets exported?</h3>
        <div className="grid gap-3 sm:grid-cols-2 text-sm">
          <div className="flex items-start gap-2">
            <span className="inline-block w-2 h-2 rounded-full bg-blue-500 mt-1.5 shrink-0"></span>
            <div>
              <p className="font-medium text-gray-800">Tags & Assignments</p>
              <p className="text-gray-500 text-xs">User/group tags with their entity assignments</p>
            </div>
          </div>
          <div className="flex items-start gap-2">
            <span className="inline-block w-2 h-2 rounded-full bg-purple-500 mt-1.5 shrink-0"></span>
            <div>
              <p className="font-medium text-gray-800">Categories & Assignments</p>
              <p className="text-gray-500 text-xs">Access package categories with AP mappings</p>
            </div>
          </div>
          <div className="flex items-start gap-2">
            <span className="inline-block w-2 h-2 rounded-full bg-orange-500 mt-1.5 shrink-0"></span>
            <div>
              <p className="font-medium text-gray-800">Risk Overrides</p>
              <p className="text-gray-500 text-xs">Analyst score adjustments on users and groups</p>
            </div>
          </div>
          <div className="flex items-start gap-2">
            <span className="inline-block w-2 h-2 rounded-full bg-green-500 mt-1.5 shrink-0"></span>
            <div>
              <p className="font-medium text-gray-800">Identity Verifications</p>
              <p className="text-gray-500 text-xs">Analyst verification status and notes</p>
            </div>
          </div>
          <div className="flex items-start gap-2">
            <span className="inline-block w-2 h-2 rounded-full bg-red-500 mt-1.5 shrink-0"></span>
            <div>
              <p className="font-medium text-gray-800">Member Overrides</p>
              <p className="text-gray-500 text-xs">Account correlation analyst decisions</p>
            </div>
          </div>
          <div className="flex items-start gap-2">
            <span className="inline-block w-2 h-2 rounded-full bg-teal-500 mt-1.5 shrink-0"></span>
            <div>
              <p className="font-medium text-gray-800">Cluster Owners</p>
              <p className="text-gray-500 text-xs">Resource cluster owner assignments</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ─── Helpers ───────────────────────────────────────────────────────

function summarizeCounts(data) {
  const lines = [];
  if (data.tags?.length) lines.push(`Tags: ${data.tags.length}`);
  if (data.tagAssignments?.length) lines.push(`Tag assignments: ${data.tagAssignments.length}`);
  if (data.categories?.length) lines.push(`Categories: ${data.categories.length}`);
  if (data.categoryAssignments?.length) lines.push(`Category assignments: ${data.categoryAssignments.length}`);
  const userOv = data.riskOverrides?.users?.length || 0;
  const groupOv = data.riskOverrides?.groups?.length || 0;
  if (userOv + groupOv > 0) lines.push(`Risk overrides: ${userOv} users, ${groupOv} groups`);
  if (data.identityVerifications?.length) lines.push(`Identity verifications: ${data.identityVerifications.length}`);
  if (data.identityMemberOverrides?.length) lines.push(`Identity member overrides: ${data.identityMemberOverrides.length}`);
  if (data.clusterOwners?.length) lines.push(`Cluster owners: ${data.clusterOwners.length}`);
  if (lines.length === 0) lines.push('No data found');
  return lines;
}

function formatImportResults(r) {
  const lines = [];
  if (r.tags) lines.push(`Tags: ${r.tags.created} created, ${r.tags.skipped} existing`);
  if (r.tagAssignments) lines.push(`Tag assignments: ${r.tagAssignments.created} created, ${r.tagAssignments.skipped} skipped`);
  if (r.categories) lines.push(`Categories: ${r.categories.created} created, ${r.categories.skipped} existing`);
  if (r.categoryAssignments) lines.push(`Category assignments: ${r.categoryAssignments.created} created, ${r.categoryAssignments.skipped} updated`);
  const userOv = r.riskOverrides?.users || 0;
  const groupOv = r.riskOverrides?.groups || 0;
  if (userOv + groupOv > 0) lines.push(`Risk overrides: ${userOv} users, ${groupOv} groups`);
  if (r.identityVerifications) lines.push(`Identity verifications: ${r.identityVerifications.updated} updated, ${r.identityVerifications.skipped} not found`);
  if (r.identityMemberOverrides) lines.push(`Identity member overrides: ${r.identityMemberOverrides.updated} updated, ${r.identityMemberOverrides.skipped} not found`);
  if (r.clusterOwners) lines.push(`Cluster owners: ${r.clusterOwners.updated} updated, ${r.clusterOwners.skipped} not found`);
  return lines;
}
