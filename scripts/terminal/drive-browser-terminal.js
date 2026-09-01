#!/usr/bin/env node
/* Drive ttyd's real xterm.js input path with the Chromium bundled in the image. */

const fs = require('node:fs');
const { chromium } = require('@playwright/test');

function value(name) {
  const index = process.argv.indexOf(`--${name}`);
  if (index < 0 || !process.argv[index + 1]) throw new Error(`missing --${name}`);
  return process.argv[index + 1];
}

async function waitForFile(path, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await fs.promises.access(path, fs.constants.R_OK);
      return;
    } catch (_) {
      await new Promise(resolve => setTimeout(resolve, 50));
    }
  }
  throw new Error(`probe file did not appear: ${path}`);
}

async function withTimeout(promise, timeoutMs, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  const url = value('url');
  const user = value('user');
  const password = value('password');
  const output = value('output');
  const ready = value('ready');
  const token = value('token');
  const probe = value('probe');
  const command = [
    `python3 ${probe}`,
    '--path browser', `--output ${output}`, `--ready ${ready}`, `--token ${token}`,
  ].join(' ');

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-proxy-server', '--proxy-server=direct://', '--proxy-bypass-list=*'],
  });
  try {
    const context = await browser.newContext({
      httpCredentials: { username: user, password },
      viewport: { width: 1100, height: 800 },
    });
    const page = await context.newPage();
    const firstTerminalFrame = new Promise(resolve => {
      page.on('websocket', socket => socket.once('framereceived', resolve));
    });
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30_000 });
    const input = page.locator('.xterm-helper-textarea');
    await input.waitFor({ state: 'attached', timeout: 30_000 });
    await withTimeout(firstTerminalFrame, 30_000, 'the first ttyd terminal frame');
    await input.focus();
    await page.keyboard.type(command);
    await page.keyboard.press('Enter');
    await waitForFile(ready, 30_000);

    const actions = [
      async () => page.keyboard.type('cas'),
      async () => page.keyboard.press('Enter'),
      async () => page.keyboard.press('Control+C'),
      async () => page.keyboard.press('ArrowUp'),
      async () => page.keyboard.press('ArrowDown'),
      async () => page.keyboard.press('ArrowRight'),
      async () => page.keyboard.press('ArrowLeft'),
      async () => page.keyboard.press('Home'),
      async () => page.keyboard.press('End'),
      async () => page.keyboard.press('Alt+b'),
      async () => page.keyboard.press('Shift+Enter'),
      async () => page.keyboard.press('Control+ArrowLeft'),
      async () => page.keyboard.press('Control+ArrowRight'),
      async () => page.keyboard.press('Alt+Enter'),
    ];
    for (const action of actions) {
      await action();
      await page.keyboard.press('Control+\\');
    }

    await page.setViewportSize({ width: 1500, height: 1000 });
    await page.keyboard.type('r');
    await page.keyboard.press('Control+\\');
    await waitForFile(output, 30_000);
    process.stdout.write(await fs.promises.readFile(output, 'utf8'));
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
