import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

export function writeMarkdownReport(outputDir, report) {
  const path = resolve(outputDir, 'workspace-report.md');
  mkdirSync(outputDir, { recursive: true });

  const failed = report.checks.filter((item) => item.status === 'fail');
  const remediations = failed
    .filter((item) => item.remediation)
    .map((item) => `- **${item.code || item.name}**: ${item.remediation}`);

  const lines = [
    '# UI5 Harness Report',
    '',
    `**Verdict: ${report.verdict}**`,
    '',
    `| Field | Value |`,
    `|-------|-------|`,
    `| Run ID | \`${report.runId}\` |`,
    `| Mode | \`${report.mode}\` |`,
    `| Profile | \`${report.profile}\` |`,
    `| Timestamp | \`${report.timestamp}\` |`,
    `| Exit Code | \`${report.exitCode}\` |`,
    '',
    '## Checks',
    '',
    '| Check | Required | Status | Code |',
    '|-------|----------|--------|------|',
    ...report.checks.map(
      (check) =>
        `| ${check.name} | ${check.required ? 'yes' : 'no'} | ${check.status === 'pass' ? 'PASS' : 'FAIL'} | ${check.code || '-'} |`,
    ),
    '',
    '## Blockers',
    '',
    ...(failed.length
      ? failed.map((check) => `- \`${check.code || 'UNKNOWN'}\`: ${check.message}`)
      : ['None.']),
    '',
    '## Remediation',
    '',
    ...(remediations.length ? remediations : ['No action required.']),
  ];

  writeFileSync(path, `${lines.join('\n')}\n`);
  return path;
}
