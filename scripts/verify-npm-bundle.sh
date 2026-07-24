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

const floors = new Map([
  ['tar', '7.5.19'],
  ['brace-expansion', '2.1.2'],
  ['picomatch', '4.0.4'],
  ['sigstore', '4.1.1'],
]);
const found = new Map([...floors.keys()].map((name) => [name, []]));

function compareVersions(actual, minimum) {
  const parse = (value) => value.split('-')[0].split('.').map(Number);
  const a = parse(actual);
  const b = parse(minimum);
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const delta = (a[i] || 0) - (b[i] || 0);
    if (delta !== 0) return Math.sign(delta);
  }
  return 0;
}

function inspectPackage(packageDir) {
  const manifest = path.join(packageDir, 'package.json');
  if (!fs.existsSync(manifest)) return;
  const pkg = JSON.parse(fs.readFileSync(manifest));
  if (floors.has(pkg.name)) {
    found.get(pkg.name).push(pkg.version);
    if (compareVersions(pkg.version, floors.get(pkg.name)) < 0) {
      throw new Error(`${pkg.name}@${pkg.version} is below fixed ${floors.get(pkg.name)}`);
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

docker run --rm --entrypoint sh "$IMAGE" -lc '
  set -eu
  npm --version
  claude --version
  codex --version
  opencode --version
  pi --version
  bun --version
  playwright --version
'
