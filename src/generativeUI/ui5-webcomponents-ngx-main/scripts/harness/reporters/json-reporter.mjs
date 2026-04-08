import { resolve } from 'node:path';
import { writeJson } from '../common.mjs';

export function writeJsonReport(outputDir, report) {
  const path = resolve(outputDir, 'workspace-report.json');
  writeJson(path, report);
  return path;
}
