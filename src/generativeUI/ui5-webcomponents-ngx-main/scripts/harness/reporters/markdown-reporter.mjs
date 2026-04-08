import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

export function writeMarkdownReport(outputDir, report) {
  const path = resolve(outputDir, 'workspace-report.md');
  mkdirSync(outputDir, { recursive: true });

  const failed = report.checks.filter((item) => item.status === 'fail');
  const lines = [
    '# UI5 Harness Report',
    '',
    `- Verdict: **${report.verdict}**`,
    `- Mode: \`${report.mode}\``,
    `- Profile: \`${report.profile}\``,
    `- Timestamp: \`${report.timestamp}\``,
    '',
    '## Checks',
    '',
    ...report.checks.map(
      (check) =>
        `- [${check.status === 'pass' ? 'x' : ' '}] \`${check.name}\` (${check.required ? 'required' : 'optional'}) - ${check.message}`,
    ),
    '',
    '## Blockers',
    '',
    ...(failed.length
      ? failed.map((check) => `- \`${check.code || 'UNKNOWN'}\`: ${check.message}`)
      : ['- None']),
  ];

  writeFileSync(path, `${lines.join('\n')}\n`);
  return path;
}
