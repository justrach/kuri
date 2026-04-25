#!/usr/bin/env node
// Downloads the correct kuri-agent binary for the current platform at install time.
// Inspired by the pattern used by esbuild, agent-browser, etc.
const https = require("https");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");
const os = require("os");
const assert = require("assert/strict");

const REPO = "justrach/kuri";
const VERSION = require("../package.json").version;
const CHANNEL_BASE = process.env.KURI_RELEASE_BASE || `https://raw.githubusercontent.com/${REPO}/release-channel/stable`;
const BIN_DIR = path.join(__dirname);
const BIN_PATH = path.join(BIN_DIR, "kuri-agent-bin");
const SUPPORTED_ARCHES = {
  arm64: "aarch64",
  x64: "x86_64",
};
const SUPPORTED_PLATFORMS = {
  darwin: "macos",
  linux: "linux",
};

function resolveTarget(nodePlatform = process.platform, nodeArch = process.arch) {
  const arch = SUPPORTED_ARCHES[nodeArch];
  if (!arch) {
    throw new Error(`unsupported architecture: ${nodeArch}. kuri-agent publishes binaries for x64 and arm64 only`);
  }

  const opsys = SUPPORTED_PLATFORMS[nodePlatform];
  if (!opsys) {
    throw new Error(`unsupported platform: ${nodePlatform}. kuri-agent publishes binaries for darwin and linux only`);
  }

  return `${arch}-${opsys}`;
}

function platform() {
  return resolveTarget(process.platform, process.arch);
}

function downloadFile(url, dest) {
  return new Promise((resolve, reject) => {
    const follow = (u) => {
      https.get(u, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          return follow(res.headers.location);
        }
        if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode} for ${u}`));
        const out = fs.createWriteStream(dest);
        res.pipe(out);
        out.on("finish", resolve);
        out.on("error", reject);
      }).on("error", reject);
    };
    follow(url);
  });
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode} for ${url}`));
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { body += chunk; });
      res.on("end", () => {
        try { resolve(JSON.parse(body)); } catch (err) { reject(err); }
      });
    }).on("error", reject);
  });
}

function sha256File(file) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(file));
  return hash.digest("hex");
}

async function main() {
  const target = platform();
  const manifestUrl = `${CHANNEL_BASE}/v${VERSION}/manifest.json`;
  const manifest = await fetchJson(manifestUrl);
  const asset = manifest.assets && manifest.assets[target];
  if (!asset || !asset.url) throw new Error(`no ${target} asset in ${manifestUrl}`);

  const url = asset.url;
  const tmp = path.join(os.tmpdir(), `kuri-${Date.now()}.tar.gz`);

  console.log(`kuri-agent: downloading ${target} binary...`);
  await downloadFile(url, tmp);
  if (asset.sha256) {
    const actual = sha256File(tmp);
    if (actual !== asset.sha256) throw new Error(`checksum mismatch for ${target}`);
  }

  // Extract kuri-agent from tarball using tar
  fs.mkdirSync(BIN_DIR, { recursive: true });
  execFileSync("tar", ["-xzf", tmp, "-C", BIN_DIR, "kuri-agent"]);
  fs.renameSync(path.join(BIN_DIR, "kuri-agent"), BIN_PATH);
  fs.chmodSync(BIN_PATH, 0o755);
  fs.unlinkSync(tmp);

  // Remove macOS quarantine
  if (process.platform === "darwin") {
    try { execFileSync("xattr", ["-d", "com.apple.quarantine", BIN_PATH]); } catch {}
  }
  console.log(`kuri-agent: installed to ${BIN_PATH}`);
}

function runSelfTest() {
  assert.equal(resolveTarget("darwin", "arm64"), "aarch64-macos");
  assert.equal(resolveTarget("darwin", "x64"), "x86_64-macos");
  assert.equal(resolveTarget("linux", "arm64"), "aarch64-linux");
  assert.equal(resolveTarget("linux", "x64"), "x86_64-linux");
  assert.throws(() => resolveTarget("win32", "x64"), /unsupported platform: win32/);
  assert.throws(() => resolveTarget("linux", "ia32"), /unsupported architecture: ia32/);
}

module.exports = {
  platform,
  resolveTarget,
  runSelfTest,
};

if (require.main === module) {
  main().catch((e) => {
    console.error("kuri-agent install failed:", e.message);
    process.exit(1);
  });
}
