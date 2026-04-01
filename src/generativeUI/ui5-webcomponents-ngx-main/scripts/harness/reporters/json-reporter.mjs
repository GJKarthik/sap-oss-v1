import { resolve } from 'node:path';
import { writeJson } from '../common.mjs';

export function writeJsonReport(outputDir, report) {
  const path = resolve(outputDir, 'demo-report.json');
  writeJson(path, report);
  return path;
}

