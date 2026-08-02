/**
 * E2E flow runner: launched once per test by TimelessCanvas.E2ECase.
 *
 *   node run_flow.js <flow-name>
 *
 * Env (set by the ExUnit case):
 *   BASE_URL      http://127.0.0.1:<port> of the test endpoint
 *   LOGIN_URL     /e2e/login?token=...&to=... (session login + redirect)
 *   E2E_BROWSER   chromium (default) | firefox | webkit
 *   FLOW_PARAMS   JSON params for the flow
 *   ARTIFACT_DIR  where failure screenshots land
 *
 * Exits 0 iff the flow ran without throwing. On failure it prints the
 * error + captured console output and saves a screenshot artifact.
 */
const fs = require("fs");
const path = require("path");
const playwright = require("playwright");
const flows = require("./flows");

const flowName = process.argv[2];
const engine = process.env.E2E_BROWSER || "chromium";
const artifactDir = process.env.ARTIFACT_DIR || path.join(__dirname, "artifacts");
const params = JSON.parse(process.env.FLOW_PARAMS || "{}");

async function launch() {
  const type = playwright[engine];
  if (!type) throw new Error(`unknown E2E_BROWSER: ${engine}`);
  try {
    return await type.launch({ headless: true });
  } catch (err) {
    // Local fallback: registry chromium missing but a system chromium exists.
    if (engine === "chromium" && fs.existsSync("/usr/bin/chromium")) {
      return await type.launch({ headless: true, executablePath: "/usr/bin/chromium" });
    }
    throw err;
  }
}

(async () => {
  const flow = flows[flowName];
  if (!flow) {
    console.error(`unknown flow: ${flowName}`);
    console.error(`known flows: ${Object.keys(flows).join(", ")}`);
    process.exit(2);
  }

  const browser = await launch();
  const page = await browser.newPage({ viewport: { width: 1600, height: 950 } });

  const consoleLines = [];
  page.on("console", (m) => consoleLines.push(`[console:${m.type()}] ${m.text()}`));
  page.on("pageerror", (e) => consoleLines.push(`[pageerror] ${e.message}`));

  try {
    await flow(page, { ...require("./helpers")(page), params, engine });
    console.log("FLOW-OK");
    await browser.close();
    process.exit(0);
  } catch (err) {
    console.error(`FLOW-FAIL ${flowName}: ${err.stack || err.message}`);
    console.error("--- page console ---");
    for (const line of consoleLines.slice(-40)) console.error(line);
    try {
      fs.mkdirSync(artifactDir, { recursive: true });
      await page.screenshot({
        path: path.join(artifactDir, `${engine}-${flowName}-failure.png`),
      });
      console.error(`screenshot: ${artifactDir}/${engine}-${flowName}-failure.png`);
    } catch (_e) {
      // best effort
    }
    await browser.close();
    process.exit(1);
  }
})();
