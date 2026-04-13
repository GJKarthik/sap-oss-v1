import { execSync } from 'node:child_process';

function isPortListening(port) {
  try {
    const out = execSync(`lsof -n -P -i :${port}`, { stdio: ['ignore', 'pipe', 'ignore'] }).toString();
    return out.includes(`:${port}`);
  } catch {
    return false;
  }
}

export async function runPortsCheck() {
  const requiredPorts = [4200, 8400, 9160];
  const listening = requiredPorts.map((port) => ({ port, listening: isPortListening(port) }));
  const missing = listening.filter((item) => !item.listening).map((item) => item.port);
  const ok = missing.length === 0;

  return {
    name: 'ports-check',
    required: false,
    status: ok ? 'pass' : 'fail',
    code: ok ? null : 'PORT_CONFLICT',
    message: ok
      ? 'Required ports are active'
      : `Expected service ports not active: ${missing.join(', ')}`,
    evidence: { listening },
    remediation: ok ? null : `Start services: yarn start:all (needs ports ${missing.join(', ')})`,
  };
}
