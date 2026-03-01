// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
export async function askQuestion(config: any): Promise<any> {
  const { prompt } = await import('inquirer');
  config.name = 'question';
  const result = await prompt([config]);
  return result.question;
}
