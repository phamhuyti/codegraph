/**
 * Corporate / restricted-network build flag.
 *
 * Company forks that can reach an npm registry but must not phone home
 * (telemetry, GitHub update checks, beta waitlist) set
 * `package.json → "codegraph": { "corporate": true }` (this fork does).
 *
 * Operators can also force the same behavior at runtime with
 * `CODEGRAPH_CORPORATE=1` without rebuilding. `CODEGRAPH_CORPORATE=0`
 * overrides a corporate package.json for debugging.
 */

import * as fs from 'fs';
import * as path from 'path';

let cached: boolean | undefined;

function isCodegraphPackageName(name: unknown): boolean {
  if (typeof name !== 'string') return false;
  return name === 'codegraph' || name.endsWith('/codegraph');
}

function readPackageCorporateFlag(): boolean {
  // Running from dist/: __dirname is …/dist → package.json is one level up.
  // From-source ts-node/tsx or tests may resolve differently — also try cwd
  // only when that package.json is clearly the codegraph package.
  const candidates = [
    path.resolve(__dirname, '..', 'package.json'),
    path.resolve(__dirname, '..', '..', 'package.json'),
    path.resolve(process.cwd(), 'package.json'),
  ];
  for (const pkgPath of candidates) {
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8')) as {
        name?: string;
        codegraph?: { corporate?: boolean };
      };
      if (!isCodegraphPackageName(pkg.name)) continue;
      return pkg.codegraph?.corporate === true;
    } catch {
      /* try next */
    }
  }
  return false;
}

/**
 * True when this build must not contact external CodeGraph services.
 * npm registry access is unaffected — only first-party phone-homes.
 */
export function isCorporateMode(env: NodeJS.ProcessEnv = process.env): boolean {
  const forced = env.CODEGRAPH_CORPORATE;
  if (forced !== undefined && forced !== '') {
    return forced !== '0' && forced.toLowerCase() !== 'false';
  }
  if (cached === undefined) {
    cached = readPackageCorporateFlag();
  }
  return cached;
}

/** Test helper — clear the package.json memo. */
export function resetCorporateModeCache(): void {
  cached = undefined;
}
