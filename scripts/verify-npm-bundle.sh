#!/usr/bin/env bash
# Verify issue #28's patched npm distribution and npm-installed CLI smoke gate.
set -euo pipefail

IMAGE="${1:-coding-agent-sandbox:latest}"
EXPECTED_NPM="${EXPECTED_NPM_VERSION:-11.18.0}"

docker image inspect "$IMAGE" >/dev/null

docker run --rm -i --entrypoint node "$IMAGE" - "$EXPECTED_NPM" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const expectedNpm = process.argv[2];
const npmRoot = '/usr/local/lib/node_modules/npm';
const npmVersion = JSON.parse(fs.readFileSync(path.join(npmRoot, 'package.json'))).version;
if (npmVersion !== expectedNpm) {
  throw new Error(`npm version ${npmVersion}; expected exact pin ${expectedNpm}`);
}

const semver = require(path.join(npmRoot, 'node_modules/semver'));
const safeRanges = new Map([
  ['tar', '>=7.5.19'],
  // CVE-2026-13149 was fixed independently on the 1.x, 2.x, and 5.x lines;
  // the vulnerable 3.x/4.x lines must not pass a simple >=2.1.2 comparison.
  ['brace-expansion', '>=1.1.16 <2.0.0 || >=2.1.2 <3.0.0 || >=5.0.7'],
  ['picomatch', '>=4.0.4'],
  ['sigstore', '>=4.1.1'],
]);
const found = new Map([...safeRanges.keys()].map((name) => [name, []]));

function inspectPackage(packageDir) {
  const manifest = path.join(packageDir, 'package.json');
  if (!fs.existsSync(manifest)) return;
  const pkg = JSON.parse(fs.readFileSync(manifest));
  if (safeRanges.has(pkg.name)) {
    found.get(pkg.name).push(pkg.version);
    const safeRange = safeRanges.get(pkg.name);
    if (!semver.satisfies(pkg.version, safeRange)) {
      throw new Error(`${pkg.name}@${pkg.version} is outside safe range ${safeRange}`);
    }
  }
  inspectModules(path.join(packageDir, 'node_modules'));
}

function inspectModules(modulesDir) {
  if (!fs.existsSync(modulesDir)) return;
  for (const entry of fs.readdirSync(modulesDir, {withFileTypes: true})) {
    if (!entry.isDirectory()) continue;
    const entryPath = path.join(modulesDir, entry.name);
    if (entry.name.startsWith('@')) {
      for (const scoped of fs.readdirSync(entryPath, {withFileTypes: true})) {
        if (scoped.isDirectory()) inspectPackage(path.join(entryPath, scoped.name));
      }
    } else {
      inspectPackage(entryPath);
    }
  }
}

inspectModules(path.join(npmRoot, 'node_modules'));
for (const [name, versions] of found) {
  if (versions.length === 0) throw new Error(`${name} not found under npm distribution`);
  console.log(`${name}: ${[...new Set(versions)].join(', ')}`);
}
console.log(`npm: ${npmVersion}`);
NODE

docker run --rm --user node --env HOME=/home/node --entrypoint sh "$IMAGE" -lc '
  set -eu
  npm --version
  claude --version
  codex --version
  pi --version
  bun --version
  playwright --version
'
