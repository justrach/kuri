#!/usr/bin/env node
/**
 * kuri-skill — Pi skill CLI for Kuri browser automation.
 *
 * Available as a standalone command after npm install -g:
 *   kuri-skill health
 *   kuri-skill navigate <url>
 *   ...
 *
 * Or run directly:
 *   node scripts/kuri.js health
 *
 * Core operations are always available directly.
 * Advanced operations (click, type, fill, audit, etc.) are documented
 * in references/ADVANCED.md and invoked via 'action <args>'.
 *
 * Usage:
 *   kuri-skill health
 *   kuri-skill tabs
 *   kuri-skill navigate <url> [tab_id]
 *   kuri-skill tab-new [url]
 *   kuri-skill screenshot [tab_id] [--output path]
 *   kuri-skill page-info [tab_id]
 *   kuri-skill text [tab_id]
 *   kuri-skill markdown [tab_id]
 *   kuri-skill links [tab_id]
 *   kuri-skill snap [tab_id]
 *   kuri-skill action <click|type|fill|select|scroll|evaluate|cookies|audit|har|har-start|har-stop|back|forward|reload|close-tab> [args...]
 *   kuri-skill advanced               # Print reference to ADVANCED.md
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

// ── Configuration ──────────────────────────────────────────────────────────

const __dirname = dirname(fileURLToPath(import.meta.url));
const SKILL_ROOT = resolve(__dirname, "..");

function kuriBaseUrl() {
  return process.env.KURI_BASE_URL || "http://127.0.0.1:9223";
}

function kuriApiToken() {
  if (process.env.KURI_API_TOKEN) return process.env.KURI_API_TOKEN;
  if (process.env.KURI_SECRET) return process.env.KURI_SECRET;
  try {
    return readFileSync(`${homedir()}/.kuri/api.token`, "utf-8").trim();
  } catch {
    return "";
  }
}

function defaultSession() {
  return process.env.KURI_SESSION || "pi-kuri-skill";
}

function sessionTabId() {
  return process.env.KURI_TAB_ID || "";
}

function headers(session) {
  const h = {
    "X-Kuri-Session": session || defaultSession(),
    Accept: "application/json",
  };
  const token = kuriApiToken();
  if (token) h["Authorization"] = `Bearer ${token}`;
  return h;
}

// ── Error recovery — detect if Kuri server is not running ────────────────

function isKuriInstalled() {
  try {
    execSync("command -v kuri", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function isBuiltLocally() {
  return existsSync(resolve(SKILL_ROOT, "..", "..", "zig-out", "bin", "kuri"));
}

function platform() {
  const os = process.platform;
  if (os === "darwin") return "macos";
  if (os === "linux") return "linux";
  return os;
}

/** Print structured, LLM-parsable recovery hints when Kuri server is unreachable. */
function printKuriNotRunning(originalError) {
  const hints = {
    status: "kuri_not_running",
    message: "Kuri server is not reachable. The server must be running on " +
      `${kuriBaseUrl()} before any browser operations work.`,
    error: originalError,
    platform: platform(),
    kuri_on_path: isKuriInstalled(),
    built_in_repo: isBuiltLocally(),
    suggestions: []
  };

  if (isKuriInstalled()) {
    hints.suggestions.push({
      action: "start_kuri",
      command: "kuri",
      detail: "Kuri is installed on PATH. Start it with the 'kuri' command."
    });
  }

  if (isBuiltLocally()) {
    hints.suggestions.push({
      action: "start_kuri_local",
      command: "./zig-out/bin/kuri",
      cwd: resolve(SKILL_ROOT, "..", ".."),
      detail: "A local build exists in the kuri repo. Start it from the repo root."
    });
  }

  if (!isKuriInstalled() && !isBuiltLocally()) {
    const installScript =
      "curl -fsSL https://raw.githubusercontent.com/justrach/kuri/main/install.sh | sh";
    hints.suggestions.push({
      action: "install_kuri",
      install_url: "https://github.com/justrach/kuri",
      install_script: installScript,
      detail: "Kuri is not installed. Use the one-line install script, or build from source."
    });
    hints.suggestions.push({
      action: "build_from_source",
      clone_url: "https://github.com/justrach/kuri.git",
      build_commands: ["git clone https://github.com/justrach/kuri.git", "cd kuri", "zig build", "./zig-out/bin/kuri"],
      requires_zig: true,
      detail: "Clone the kuri repo and build with Zig 0.16."
    });
  }

  hints.suggestions.push({
    action: "check_port_or_url",
    detail: `Verify the server URL. The default is http://127.0.0.1:9223. ` +
      `Override with KURI_BASE_URL env var.`
  });

  console.log(JSON.stringify(hints, null, 2));
}

// ── HTTP helpers ────────────────────────────────────────────────────────────

async function kuriFetch(path, query = {}, method = "GET", body = null) {
  const base = kuriBaseUrl().replace(/\/+$/, "");
  const params = new URLSearchParams(query).toString();
  const url = `${base}${path}${params ? `?${params}` : ""}`;
  const opts = {
    method,
    headers: headers(query.session || ""),
    signal: AbortSignal.timeout(30_000),
  };
  if (body) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  try {
    const resp = await fetch(url, opts);
    const ct = resp.headers.get("content-type") || "";
    if (ct.includes("image/png") || ct.includes("image/")) {
      const buf = await resp.arrayBuffer();
      return { _binary: true, data: Buffer.from(buf), contentType: ct };
    }
    if (!resp.ok) {
      const text = await resp.text().catch(() => "");
      throw new Error(`Kuri ${path}: ${resp.status} ${resp.statusText} — ${text.slice(0, 300)}`);
    }
    return resp.json();
  } catch (err) {
    // Distinguish connection refused (server not running) from other errors
    if (err?.cause?.code === "ECONNREFUSED" || err?.message?.includes("ECONNREFUSED") || err?.message?.includes("fetch failed")) {
      const nfe = new Error("KURI_NOT_RUNNING");
      nfe.code = "KURI_NOT_RUNNING";
      nfe.originalMessage = err.message;
      throw nfe;
    }
    throw err;
  }
}

// ── Output helpers ──────────────────────────────────────────────────────────

function printJson(data) {
  console.log(JSON.stringify(data, null, 2));
}

function printText(label, data) {
  if (typeof data === "string") {
    console.log(data);
    return;
  }
  if (data._binary) {
    console.log(`[binary: ${data.data.length} bytes, ${data.contentType}]`);
    return;
  }
  // Navigate through common response shapes
  let result = data;
  if (data && typeof data === "object") {
    if (data.result && typeof data.result === "object") {
      const r = data.result;
      if (r.result && r.result.value !== undefined) result = r.result.value;
      else if (r.value !== undefined) result = r.value;
      else if (r.text !== undefined) result = r.text;
      else if (r.data !== undefined) result = r.data;
      else if (r.markdown !== undefined) result = r.markdown;
      else result = r;
    } else if (data.value !== undefined) {
      result = data.value;
    } else if (data.text !== undefined) {
      result = data.text;
    } else if (data.markdown !== undefined) {
      result = data.markdown;
    }
  }
  if (typeof result === "string") {
    console.log(result);
  } else {
    console.log(JSON.stringify(result, null, 2));
  }
}

// ── Core operations ─────────────────────────────────────────────────────────

async function cmdHealth() {
  const data = await kuriFetch("/health");
  printJson(data);
}

async function cmdTabs() {
  const data = await kuriFetch("/tabs");
  printJson(data);
}

async function cmdTabNew(url) {
  const params = {};
  if (url) params.url = url;
  const data = await kuriFetch("/tab/new", params);
  const tabId = data?.result?.tabId || data?.result?.id || data?.id || "";
  if (tabId) {
    // Store the tab ID for convenience
    console.log(`Tab created: ${tabId}`);
    // Also print full response
    printJson(data);
  } else {
    printJson(data);
  }
}

async function cmdNavigate(url, tabId) {
  if (!url) {
    console.error("Usage: kuri.js navigate <url> [tab_id]");
    process.exit(1);
  }
  if (!tabId) {
    // Try to find the current tab
    try {
      const tabs = await kuriFetch("/tabs");
      const list = Array.isArray(tabs) ? tabs : (tabs.tabs || tabs.result || []);
      const current = list.find((t) => t.current);
      if (current) tabId = current.id;
    } catch { /* ignore */ }
  }
  if (!tabId) {
    console.error("No tab available. Open one first: kuri.js tab-new <url>");
    process.exit(1);
  }
  const params = { url, tab_id: tabId };
  const data = await kuriFetch("/navigate", params);
  printText("Navigated", data);
}

async function resolveTabId(requested) {
  if (requested) return requested;
  if (sessionTabId()) return sessionTabId();
  try {
    const tabs = await kuriFetch("/tabs");
    const list = Array.isArray(tabs) ? tabs : (tabs.tabs || tabs.result || []);
    const current = list.find((t) => t.current);
    if (current) return current.id;
  } catch { /* ignore */ }
  return "";
}

async function cmdPageInfo(tabId) {
      const params = {};
      if (tabId) params.tab_id = tabId;
      const data = await kuriFetch("/page/info", params);
      printJson(data);
    }

    async function cmdScreenshot(tabId, outputPath) {
  tabId = await resolveTabId(tabId);
  const params = {};
  if (tabId) params.tab_id = tabId;
  const data = await kuriFetch("/screenshot", params);

  if (data._binary) {
    const path = outputPath || `/tmp/kuri-screenshot-${Date.now()}.png`;
    writeFileSync(path, data.data);
    console.log(`Screenshot saved: ${path} (${data.data.length} bytes)`);
    return;
  }

  // Handle JSON-wrapped base64
  let raw = data;
  if (data.result?.data) raw = data.result.data;
  else if (data.data) raw = data.data;
  else if (typeof data === "string") raw = data;

  if (typeof raw === "string") {
    // Strip data URI prefix
    if (raw.includes(",")) raw = raw.split(",")[1];
    const buf = Buffer.from(raw, "base64");
    const path = outputPath || `/tmp/kuri-screenshot-${Date.now()}.png`;
    writeFileSync(path, buf);
    console.log(`Screenshot saved: ${path} (${buf.length} bytes)`);
  } else {
    printJson(data);
  }
}

async function cmdText(tabId) {
  tabId = await resolveTabId(tabId);
  const params = {};
  if (tabId) params.tab_id = tabId;
  const data = await kuriFetch("/text", params);
  printText("Text", data);
}

async function cmdMarkdown(tabId) {
  tabId = await resolveTabId(tabId);
  const params = {};
  if (tabId) params.tab_id = tabId;
  const data = await kuriFetch("/markdown", params);
  printText("Markdown", data);
}

async function cmdLinks(tabId) {
  tabId = await resolveTabId(tabId);
  const params = {};
  if (tabId) params.tab_id = tabId;
  const data = await kuriFetch("/links", params);
  printJson(data);
}

async function cmdSnap(tabId) {
  tabId = await resolveTabId(tabId);
  const params = {};
  if (tabId) params.tab_id = tabId;
  try {
    const data = await kuriFetch("/snapshot", { ...params, filter: "interactive", format: "compact" });
    printText("Accessibility snapshot", data);
  } catch {
    // Fallback to full snapshot
    const data = await kuriFetch("/snapshot", params);
    printText("Accessibility snapshot", data);
  }
}

// ── Advanced operation dispatcher ───────────────────────────────────────────

async function cmdAction(action, args) {
  const tabId = args.tab_id || sessionTabId();
  const params = { ...args };
  if (tabId) params.tab_id = tabId;

  switch (action) {
    // Navigation
    case "back": {
      const data = await kuriFetch("/back", params);
      printText("Back", data);
      break;
    }
    case "forward": {
      const data = await kuriFetch("/forward", params);
      printText("Forward", data);
      break;
    }
    case "reload": {
      const data = await kuriFetch("/reload", params);
      printText("Reload", data);
      break;
    }

    // Interaction
    case "click": {
      if (!args.ref) { console.error("Usage: click <ref> [tab_id]"); process.exit(1); }
      const data = await kuriFetch("/action", { ...params, action: "click", ref: args.ref });
      printText("Click", data);
      break;
    }
    case "type": {
      if (!args.ref || !args.value) { console.error("Usage: type <ref> <value> [tab_id]"); process.exit(1); }
      const data = await kuriFetch("/action", { ...params, action: "type", ref: args.ref, value: args.value });
      printText("Type", data);
      break;
    }
    case "fill": {
      if (!args.ref || !args.value) { console.error("Usage: fill <ref> <value> [tab_id]"); process.exit(1); }
      const data = await kuriFetch("/action", { ...params, action: "fill", ref: args.ref, value: args.value });
      printText("Fill", data);
      break;
    }
    case "select": {
      if (!args.ref || !args.value) { console.error("Usage: select <ref> <value> [tab_id]"); process.exit(1); }
      const data = await kuriFetch("/action", { ...params, action: "select", ref: args.ref, value: args.value });
      printText("Select", data);
      break;
    }
    case "scroll": {
      const dir = args.direction || "down";
      const amount = args.amount || "";
      const data = await kuriFetch("/action", { ...params, action: "scroll", direction: dir, ...(amount ? { amount } : {}) });
      printText("Scroll", data);
      break;
    }

    // Content
    case "evaluate": {
      if (!args.expression) { console.error("Usage: evaluate <expression> [tab_id]"); process.exit(1); }
      const data = await kuriFetch("/evaluate", { ...params, expression: args.expression });
      printText("Evaluate", data);
      break;
    }

    // Cookies & Security
    case "cookies": {
      const data = await kuriFetch("/cookies", params);
      printJson(data);
      break;
    }
    case "audit": {
      const data = await kuriFetch("/audit", params);
      printJson(data);
      break;
    }

    // Tab management
    case "close-tab": {
      if (!args.tab_id && !tabId) { console.error("Usage: close-tab <tab_id>"); process.exit(1); }
      const data = await kuriFetch("/tab/close", { tab_id: args.tab_id || tabId });
      printText("Close tab", data);
      break;
    }

    // HAR recording
    case "har": {
      const data = await kuriFetch("/har", params);
      printJson(data);
      break;
    }
    case "har-start": {
      const data = await kuriFetch("/har/start", params);
      printJson(data);
      break;
    }
    case "har-stop": {
      const data = await kuriFetch("/har/stop", params);
      printJson(data);
      break;
    }

    default:
      console.error(`Unknown action: ${action}`);
      console.error("See references/ADVANCED.md for all available actions.");
      process.exit(1);
  }
}

function cmdAdvanced() {
  const advPath = resolve(SKILL_ROOT, "references", "ADVANCED.md");
  console.log(`\n  📖 Full Kuri API reference: ${advPath}`);
  console.log("  Read that file with the 'read' tool for all ~100 advanced options.\n");
}

// ── CLI routing ─────────────────────────────────────────────────────────────

async function main() {
  const cmd = process.argv[2];
  const args = process.argv.slice(3);

  if (!cmd || cmd === "--help" || cmd === "-h") {
    console.log(`
Kuri Browser Automation — Pi Skill CLI

Usage:
  kuri-skill <command> [args...]

Core Commands:
  health                  Check if Kuri server is running
  tabs                    List all browser tabs
  tab-new [url]           Open a new tab (optionally navigate to URL)
  navigate <url> [tab_id] Navigate tab to URL
  page-info [tab_id]      Get current page URL, title, ready state
  screenshot [tab_id]     Capture page screenshot
  text [tab_id]           Extract page text content
  markdown [tab_id]       Extract page as markdown
  links [tab_id]          Extract all links
  snap [tab_id]           Get accessibility snapshot (interactive refs)

Advanced (see references/ADVANCED.md for full docs):
  action click <ref> [tab_id]
  action type <ref> <value> [tab_id]
  action fill <ref> <value> [tab_id]
  action select <ref> <value> [tab_id]
  action scroll [direction] [amount] [tab_id]
  action evaluate <expression> [tab_id]
  action cookies [tab_id]
  action audit [tab_id]
  action har|har-start|har-stop [tab_id]
  action back|forward|reload [tab_id]
  action close-tab <tab_id>

Utilities:
  advanced                Print path to full API reference
`);
    return;
  }

  try {
    switch (cmd) {
      case "health":
        await cmdHealth();
        break;
      case "tabs":
        await cmdTabs();
        break;
      case "tab-new":
        await cmdTabNew(args[0]);
        break;
      case "navigate":
        await cmdNavigate(args[0], args[1]);
        break;
      case "page-info":
        await cmdPageInfo(args[0]);
        break;
      case "screenshot":
        await cmdScreenshot(args[0], process.env.KURI_OUTPUT);
        break;
      case "text":
        await cmdText(args[0]);
        break;
      case "markdown":
        await cmdMarkdown(args[0]);
        break;
      case "links":
        await cmdLinks(args[0]);
        break;
      case "snap":
        await cmdSnap(args[0]);
        break;
      case "action":
        // Parse remaining args: action <subcommand> [key=value...]
        const sub = args[0];
        const actionArgs = {};
        const actionSchemas = {
          // Schema: [paramName, ...] for positional filling
          // null means all remaining become expression
          click: ["ref"],
          type: ["ref", "value"],
          fill: ["ref", "value"],
          select: ["ref", "value"],
          scroll: ["direction", "amount"],
          evaluate: null,
          "close-tab": ["tab_id"],
        };
        for (let i = 1; i < args.length; i++) {
          if (args[i].includes("=")) {
            const [k, ...v] = args[i].split("=");
            actionArgs[k] = v.join("=");
          } else if (actionSchemas[sub]) {
            // Positional: fill schema slots in order
            const slot = actionSchemas[sub][Object.keys(actionArgs).length];
            if (slot) actionArgs[slot] = args[i];
          } else if (actionSchemas[sub] === null) {
            // evaluate: join all remaining as expression
            actionArgs.expression = args.slice(1).join(" ");
            break;
          }
        }
        await cmdAction(sub, actionArgs);
        break;
      case "advanced":
        cmdAdvanced();
        break;
      default:
        console.error(`Unknown command: ${cmd}`);
        console.error("Run 'node scripts/kuri.js --help' for usage.");
        process.exit(1);
    }
  } catch (err) {
    if (err?.code === "KURI_NOT_RUNNING") {
      printKuriNotRunning(err.originalMessage || err.message);
    } else {
      console.error(`Error: ${err.message}`);
    }
    process.exit(1);
  }
}

main();
