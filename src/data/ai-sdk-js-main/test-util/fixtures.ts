// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Reads a fixture file from test-util/data/<client>/<fileName> and returns it as a string.
 */
export async function parseFileToString(
  client: string,
  fileName: string
): Promise<string> {
  return readFile(path.join(__dirname, 'data', client, fileName), 'utf-8');
}

/**
 * Reads a fixture JSON file from test-util/data/<client>/<fileName> and parses it.
 */
export async function parseMockResponse<T>(
  client: string,
  fileName: string
): Promise<T> {
  const fileContent = await readFile(
    path.join(__dirname, 'data', client, fileName),
    'utf-8'
  );
  return JSON.parse(fileContent);
}

