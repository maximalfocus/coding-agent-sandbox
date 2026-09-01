#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs';

const normalizeBundle = process.argv[2] === '--normalize-bundle';
const target = process.argv[normalizeBundle ? 3 : 2];
if (!target) {
    console.error('[PATCH argument] expected the installed addon-clipboard JavaScript path');
    process.exit(2);
}

const before = 'async readText(t){return"c"!==t?Promise.resolve(""):navigator.clipboard.readText()}async writeText(t,e){return"c"!==t?Promise.resolve():navigator.clipboard.writeText(e)}';
const after = 'async readText(e){return""!==e&&"c"!==e?Promise.resolve(""):navigator.clipboard.readText()}async writeText(e,t){if(""!==e&&"c"!==e)return;try{await navigator.clipboard.writeText(t)}catch(e){const i=document.createElement("textarea");i.value=t,i.setAttribute("readonly",""),i.style.position="fixed",i.style.opacity="0",document.body.appendChild(i),i.select();try{if(!document.execCommand("copy"))throw e}finally{i.remove(),null!=window.term&&window.term.focus()}}}';
const optimizedBranch = 'async writeText(e,t){if(""===e||"c"===e)try{';
const recordedBranch = 'async writeText(e,t){if(""!==e&&"c"!==e)return;try{';
const generatedMapPattern = /sourceMappingURL=app\.[0-9a-f]{20}\.js\.map/;
const recordedMap = 'sourceMappingURL=app.9e0d4a1df46caf31b896.js.map';

let source;
try {
    source = readFileSync(target, 'utf8');
} catch (error) {
    console.error(`[PATCH read-input] ${error.message}`);
    process.exit(1);
}

const expected = normalizeBundle ? optimizedBranch : before;
const replacement = normalizeBundle ? recordedBranch : after;
const first = source.indexOf(expected);
if (first === -1 || source.indexOf(expected, first + expected.length) !== -1) {
    console.error(`[PATCH ${normalizeBundle ? 'bundle-shape' : 'source-shape'}] expected exactly one unmodified target`);
    process.exit(1);
}
if (source.includes(replacement)) {
    console.error(`[PATCH ${normalizeBundle ? 'bundle-shape' : 'source-shape'}] target already contains the local patch`);
    process.exit(1);
}

try {
    let patched = source.replace(expected, replacement);
    if (normalizeBundle) {
        const maps = patched.match(new RegExp(generatedMapPattern.source, 'g')) ?? [];
        if (maps.length !== 1) {
            console.error('[PATCH bundle-map] expected exactly one generated JavaScript source-map name');
            process.exit(1);
        }
        patched = patched.replace(generatedMapPattern, recordedMap);
    }
    writeFileSync(target, patched);
} catch (error) {
    console.error(`[PATCH write-output] ${error.message}`);
    process.exit(1);
}

console.log(normalizeBundle
    ? '[PATCH complete] preserved the recorded selector guard in the final bundle'
    : '[PATCH complete] accepted empty OSC 52 selectors and installed denied-write fallback');
