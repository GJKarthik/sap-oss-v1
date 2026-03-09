const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const { chromium } = require('playwright');

const projectRoot = path.resolve(__dirname, '..');
const widgetBundlePath = path.join(projectRoot, 'dist', 'sac-ai-widget', 'widget.js');

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function contentTypeFor(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  switch (ext) {
    case '.html':
      return 'text/html; charset=utf-8';
    case '.js':
    case '.mjs':
      return 'text/javascript; charset=utf-8';
    case '.json':
      return 'application/json; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    default:
      return 'application/octet-stream';
  }
}

function createStaticServer(rootDir) {
  return http.createServer((req, res) => {
    const requestUrl = new URL(req.url, 'http://127.0.0.1');
    const normalizedPath = path.normalize(decodeURIComponent(requestUrl.pathname));
    const relativePath = normalizedPath === path.sep ? path.join('harness', 'ai-widget', 'index.html') : normalizedPath.slice(1);
    const filePath = path.join(rootDir, relativePath);

    if (!filePath.startsWith(rootDir)) {
      res.writeHead(403);
      res.end('Forbidden');
      return;
    }

    let stat;
    try {
      stat = fs.statSync(filePath);
    } catch {
      res.writeHead(404);
      res.end('Not Found');
      return;
    }

    const targetPath = stat.isDirectory() ? path.join(filePath, 'index.html') : filePath;
    if (!fs.existsSync(targetPath)) {
      res.writeHead(404);
      res.end('Not Found');
      return;
    }

    res.writeHead(200, { 'Content-Type': contentTypeFor(targetPath) });
    fs.createReadStream(targetPath).pipe(res);
  });
}

async function withServer(rootDir, run) {
  const server = createStaticServer(rootDir);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const origin = `http://127.0.0.1:${address.port}`;

  try {
    return await run(origin);
  } finally {
    await new Promise((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  }
}

async function main() {
  assert(fs.existsSync(widgetBundlePath), 'Widget bundle is missing. Run `npm run build:widget` first.');

  await withServer(projectRoot, async (origin) => {
    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const consoleErrors = [];
    const pageErrors = [];

    page.on('console', (message) => {
      if (message.type() === 'error') {
        consoleErrors.push(message.text());
      }
    });
    page.on('pageerror', (error) => pageErrors.push(error.stack ?? error.message));

    try {
      await page.goto(`${origin}/harness/ai-widget/index.html`, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => typeof globalThis.customElements.get('sac-ai-widget') === 'function');

      await page.evaluate((currentOrigin) => {
        const widget = globalThis.document.getElementById('widget');
        const props = {
          capBackendUrl: `${currentOrigin}/mock-cap`,
          tenantUrl: `${currentOrigin}/mock-sac`,
          modelId: 'SALES_MODEL',
          widgetType: 'chart',
          sacBearerToken: 'sac-session-token',
        };

        widget.onCustomWidgetBeforeUpdate(props);
        widget.onCustomWidgetAfterUpdate(props);
      }, origin);

      await page.waitForSelector('sac-ai-widget .sac-chat-input');

      const initialSnapshot = await page.evaluate(() => globalThis.__widgetHarness);
      assert(initialSnapshot.runRequests.length >= 1, 'Expected initial AG-UI state sync request');
      assert(
        initialSnapshot.runRequests[0].authHeader === 'Bearer sac-session-token',
        'Expected bearer token on initial AG-UI request',
      );

      await page.evaluate(() => {
        const widget = globalThis.document.querySelector('sac-ai-widget');
        const input = widget?.shadowRoot?.querySelector('.sac-chat-input');
        if (!(input instanceof globalThis.HTMLInputElement)) {
          throw new Error('Chat input not found');
        }

        input.value = 'Filter to EMEA and use a line chart.';
        input.dispatchEvent(new globalThis.Event('input', { bubbles: true, composed: true }));
        input.dispatchEvent(new globalThis.KeyboardEvent('keyup', { key: 'Enter', bubbles: true, composed: true }));
      });

      await page.waitForSelector('text=Updating the widget.');
      await page.waitForSelector('text=Region: EMEA');
      await page.waitForFunction(() => {
        const harness = globalThis.__widgetHarness;
        return harness.toolResults.length >= 2;
      });
      await page.waitForSelector('text=Regional Revenue');

      const afterChatSnapshot = await page.evaluate(() => globalThis.__widgetHarness);
      const stateSyncThreadId = afterChatSnapshot.runRequests[0].payload.threadId;
      const chatThreadId = afterChatSnapshot.runRequests.find((entry) => entry.payload?.messages?.[0]?.content !== '__state_sync__')?.payload?.threadId;

      assert(stateSyncThreadId, 'Expected state sync thread id');
      assert(chatThreadId, 'Expected chat thread id');
      assert(stateSyncThreadId === chatThreadId, 'Expected chat and state sync to reuse the same thread id');
      assert(
        afterChatSnapshot.toolResults.every((entry) => entry.authHeader === 'Bearer sac-session-token'),
        'Expected bearer token on AG-UI tool result dispatches',
      );

      await page.evaluate(() => {
        const widget = globalThis.document.getElementById('widget');
        const props = { widgetType: 'table' };
        widget.onCustomWidgetBeforeUpdate(props);
        widget.onCustomWidgetAfterUpdate(props);
      });

      await page.waitForSelector('.sac-table__grid');
      await page.waitForFunction(() => {
        const harness = globalThis.__widgetHarness;
        return harness.dataRequests.some((entry) => entry.payload?.filters?.Region?.value === 'EMEA');
      });

      await page.evaluate((currentOrigin) => {
        const widget = globalThis.document.getElementById('widget');
        const props = { capBackendUrl: `${currentOrigin}/mock-cap-v2` };
        widget.onCustomWidgetBeforeUpdate(props);
        widget.onCustomWidgetAfterUpdate(props);
      }, origin);

      await page.waitForFunction(() => globalThis.__widgetHarness.runRequests.some((entry) => entry.url === '/mock-cap-v2/ag-ui/run'));

      const beforeDestroy = await page.evaluate(() => {
        const widget = globalThis.document.getElementById('widget');
        return {
          shadowChildren: widget.shadowRoot?.childElementCount ?? 0,
        };
      });

      assert(beforeDestroy.shadowChildren > 0, 'Expected shadow DOM content before destroy');

      await page.evaluate(() => {
        const widget = globalThis.document.getElementById('widget');
        widget.onCustomWidgetDestroy();
      });

      await page.waitForFunction(() => {
        const widget = globalThis.document.getElementById('widget');
        return widget.shadowRoot?.innerHTML === '';
      });

      const finalHarness = await page.evaluate(() => globalThis.__widgetHarness);
      assert(finalHarness.errors.length === 0, `Harness page reported errors: ${JSON.stringify(finalHarness.errors)}`);
      assert(
        finalHarness.dataRequests.every((entry) => entry.authHeader === 'Bearer sac-session-token'),
        'Expected bearer token on datasource requests',
      );
      assert(pageErrors.length === 0, `Page errors detected: ${pageErrors.join('\n')}`);
      assert(consoleErrors.length === 0, `Console errors detected: ${consoleErrors.join('\n')}`);
    } finally {
      await page.close();
      await browser.close();
    }
  });

  console.log('Widget harness verification passed.');
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
