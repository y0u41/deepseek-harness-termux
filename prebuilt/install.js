#!/usr/bin/env node
// dsh-termux postinstall (Plan B — precompiled native modules).
//
// Installs the patched @deepseek-ai/dsh globally WITHOUT compiling anything:
//   1. npm install -g --ignore-scripts @deepseek-ai/dsh@<pinned>
//   2. apply the Android source patches (bundled in patches/)
//   3. drop in the prebuilt native modules (bundled in prebuilt/)
//      - node-pty  -> node-pty/build/Release/pty.node
//      - koffi     -> koffi/build/koffi/android_arm64/koffi.node
//
// Everything is idempotent: re-running `npm i -g <tarball>` re-applies the
// patches and re-drops the natives (npm re-extracts dsh first, which wipes
// the previous copies).

"use strict";

const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

// Bump together with patches/: only a dsh version whose sources the patches
// apply to cleanly is safe to pin here. Overridable via DSH_VERSION.
const DSH_VERSION = process.env.DSH_VERSION || "0.2.2-rc.1";
const PKG_DIR = __dirname;

function sh(cmd, opts) {
  try {
    return execSync(cmd, { stdio: "pipe", ...opts }).toString().trim();
  } catch {
    return "";
  }
}

// ── Pre-flight checks ───────────────────────────────────────────────────────
// Fail fast with a clear message instead of a confusing mid-install error.
const [nodeMajor] = process.versions.node.split(".").map(Number);
if (Number(nodeMajor) < 22) {
  console.error(`[ERROR] dsh needs Node.js >= 22.19 (found ${process.version}).`);
  console.error("        On Termux:  pkg install nodejs-lts   (then reopen the shell)");
  process.exit(1);
}
if (process.arch !== "arm64") {
  console.error(`[ERROR] this package ships android-arm64 binaries only (found ${process.arch}).`);
  console.error("        On an arm64 Termux device use the full install:  bash install.sh");
  process.exit(1);
}
if (process.platform !== "android") {
  console.warn("  [WARN] this package targets Termux/Android; continuing anyway");
}
console.log(`  [OK] ${process.platform}-${process.arch}, node ${process.version}`);

// ── Locate the npm global root ──────────────────────────────────────────────
let globalRoot = sh("npm root -g");
if (!globalRoot) {
  globalRoot = path.join(
    process.env.PREFIX || "/data/data/com.termux/files/usr",
    "lib",
    "node_modules",
  );
}
const dshDir = path.join(globalRoot, "@deepseek-ai", "dsh");
const dshPkgs = path.join(dshDir, "node_modules", "@deepseek-ai");

// ── Step 1: install dsh (download only, nothing compiles) ──────────────────
// Try the user's configured registry first (respects .npmrc / mirrors the
// user already set up), then fall back to the official registry and finally
// npmmirror (China) — same multi-source strategy as install.sh.
console.log(`==> [1/5] Installing @deepseek-ai/dsh@${DSH_VERSION} (no scripts — nothing compiles)`);
function installDsh(registry) {
  const flag = registry ? ` --registry="${registry}"` : "";
  execSync(`npm install -g --ignore-scripts @deepseek-ai/dsh@${DSH_VERSION}${flag}`, {
    stdio: "inherit",
    timeout: 600000,
  });
}
const REGISTRY_FALLBACKS = [null, "https://registry.npmjs.org", "https://registry.npmmirror.com"];
let dshInstalled = false;
for (const registry of REGISTRY_FALLBACKS) {
  try {
    installDsh(registry);
    dshInstalled = true;
    break;
  } catch {
    console.log(`  [WARN] registry ${registry ?? "(user default)"} failed — trying next`);
  }
}
if (!dshInstalled) {
  console.error("  [ERROR] could not install @deepseek-ai/dsh from any registry");
  process.exit(1);
}

// ── Step 2: apply the Android source patches ───────────────────────────────
console.log("==> [2/3] Applying Android platform patches");
const PATCH_TARGETS = [
  ["01-terminal-bash-android-shell.patch", "dsh-terminal-bash"],
  ["02-session-persistence-link-rename.patch", "dsh-session-persistence-jsonl"],
  ["03-subprocess-local-android.patch", "dsh-subprocess-local"],
  ["04-native-command-termux-open.patch", "dsh-native-command"],
  ["05-host-directory-picker-native-android.patch", "dsh-host-directory-picker-native"],
  ["06-workspace-archive-skip-session-known-check.patch", "dsh-workspace"],
  ["07-sandbox-local-proot-runner.patch", "dsh-sandbox-local"],
  ["08-dsh-tool-fs-search-android-rg.patch", "dsh-tool-fs-search"],
  // 09/10 are NOT optional cosmetics: without them `dsh web` dies at boot with
  // "No usable native binding found for node-addon-require-builtin-android-arm64"
  // because upstream ships no android build of that addon. Omitting them here
  // was a real bug in this package — Plan B installs would crash immediately.
  ["09-app-boot-expose-internals.patch", "dsh-app-boot"],
  ["10-inspector-worker-expose-internals.patch", "dsh-experimental-inspector"],
  ["koffi-statx.patch", null], // koffi lives outside the @deepseek-ai scope
  ["11-node-addon-system-flock-android.patch", "node-addon-system"],
];

// Patches whose absence is fatal at runtime (not merely a lost feature).
// A silent `[SKIP] inapplicable` on these must abort the install, otherwise the
// user gets a package that installs "successfully" and then refuses to boot.
const BOOT_CRITICAL_PATCHES = new Set([
  "09-app-boot-expose-internals.patch",
  "10-inspector-worker-expose-internals.patch",
]);

const fatalPatches = [];

for (const [file, pkg] of PATCH_TARGETS) {
  const patch = path.join(PKG_DIR, "patches", file);
  const dir = pkg ? path.join(dshPkgs, pkg) : path.join(dshDir, "node_modules", "koffi");
  if (!fs.existsSync(patch)) {
    console.log("  [WARN] patch file missing:", file);
    if (BOOT_CRITICAL_PATCHES.has(file)) fatalPatches.push(`${file}: file not shipped`);
    continue;
  }
  if (!fs.existsSync(dir)) {
    console.log("  [SKIP]", file, "(package dir not found)");
    if (BOOT_CRITICAL_PATCHES.has(file)) fatalPatches.push(`${file}: target package missing (${pkg})`);
    continue;
  }
  if (sh(`patch -p1 --dry-run --forward < "${patch}"`, { cwd: dir })) {
    sh(`patch -p1 --forward < "${patch}"`, { cwd: dir });
    console.log("  [OK]", file);
  } else if (sh(`patch -p1 --dry-run --reverse < "${patch}"`, { cwd: dir })) {
    // Reverse-applies cleanly => it is genuinely already applied (idempotent rerun).
    console.log("  [SKIP]", file, "(already applied)");
  } else {
    // Neither forward nor reverse applies => the source has drifted from the
    // version these patches were generated against. Never treat this as "fine".
    console.log("  [SKIP]", file, "(INAPPLICABLE — upstream source drifted)");
    if (BOOT_CRITICAL_PATCHES.has(file)) fatalPatches.push(`${file}: inapplicable (dsh source changed)`);
  }
}

console.log("==> [2b/5] Verifying the boot-critical internals fallback...");
// Assert the patched source actually contains the fallback, rather than trusting
// that `patch` did what we think. This is the exact line whose absence causes
// "No usable native binding found for node-addon-require-builtin-android-arm64".
const appBootIdx = path.join(dshPkgs, "dsh-app-boot", "lib", "index.js");
let bootFallbackOk = false;
if (fs.existsSync(appBootIdx)) {
  const src = fs.readFileSync(appBootIdx, "utf8");
  bootFallbackOk =
    src.includes("function requireInternal(") &&
    src.includes('require("node-addon-require-builtin").requireBuiltin(id)') &&
    src.includes('requireInternal("internal/modules/esm/loader")');
}
if (bootFallbackOk) {
  console.log("  [OK] dsh-app-boot uses the --expose-internals fallback");
} else {
  fatalPatches.push("dsh-app-boot/lib/index.js lacks the requireInternal() fallback");
}

if (fatalPatches.length > 0) {
  console.error("");
  console.error("  [ERROR] Boot-critical patch(es) did not apply:");
  for (const p of fatalPatches) console.error("          -", p);
  console.error("");
  console.error("          Without them `dsh web` crashes at startup with");
  console.error("          'No usable native binding found for node-addon-require-builtin-android-arm64'.");
  console.error("          Most likely DSH_VERSION drifted from the version these patches were");
  console.error("          generated against (pinned: " + DSH_VERSION + ").");
  console.error("          See troubleshooting.md > problem 1.");
  process.exit(1);
}

// ── Step 3: drop in the prebuilt native modules ─────────────────────────────
console.log("==> [3/3] Installing prebuilt native modules (android-arm64)");
const prebuiltDir = path.join(PKG_DIR, "prebuilt", "android-arm64");
const TARGETS = [
  ["pty.node", path.join(dshDir, "node_modules", "node-pty", "build", "Release", "pty.node")],
  ["koffi.node", path.join(dshDir, "node_modules", "koffi", "build", "koffi", "android_arm64", "koffi.node")],
];
for (const [file, dest] of TARGETS) {
  const src = path.join(prebuiltDir, file);
  if (!fs.existsSync(src)) {
    console.log("  [WARN] prebuilt module missing:", file, "(this package only ships android-arm64)");
    continue;
  }
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
  fs.chmodSync(dest, 0o755);
  console.log("  [OK]", file, "->", path.relative(globalRoot, dest));
}

// flock: create the android platform-package shim and drop in the prebuilt
// system.node. The patched flock.js (patch 11) require.resolve()s
// `@deepseek-ai/node-addon-system-android-arm64`; upstream ships no such
// package, and Android bionic is neither glibc nor musl, so the linux binaries
// cannot load. This mirrors the ripgrep shim created by install.sh.
const flockShimDir = path.join(dshDir, "node_modules", "@deepseek-ai", "node-addon-system-android-arm64");
const flockNodeSrc = path.join(prebuiltDir, "system.node");
const flockNodeDest = path.join(flockShimDir, "bin", "system.node");
if (fs.existsSync(flockNodeSrc)) {
  fs.mkdirSync(path.dirname(flockNodeDest), { recursive: true });
  fs.copyFileSync(flockNodeSrc, flockNodeDest);
  fs.chmodSync(flockNodeDest, 0o755);
  fs.writeFileSync(path.join(flockShimDir, "package.json"), JSON.stringify({
    name: "@deepseek-ai/node-addon-system-android-arm64",
    version: "0.1.2",
    description: "Termux shim: prebuilt N-API flock addon for android-arm64 (bionic); upstream @deepseek-ai/node-addon-system has no android platform package.",
    license: "BSD-3-Clause",
    os: ["android"],
    cpu: ["arm64"],
  }, null, 2) + "\n");
  console.log("  [OK] system.node ->", path.relative(globalRoot, flockNodeDest));
} else {
  console.log("  [WARN] prebuilt module missing: system.node (flock will be unavailable)");
}

// ── Step 3b: verify the natives actually load ───────────────────────────────
// Catches an ABI/Node-version mismatch at install time with a clear message
// instead of a confusing crash at first `dsh web`.
console.log("==> [3b/5] Verifying native modules load...");
const verify = sh(`node -e "require('${dshDir}/node_modules/node-pty'); require('${dshDir}/node_modules/koffi'); console.log('ok')"`);
if (verify.includes("ok")) {
  console.log("  [OK] node-pty + koffi load");
} else {
  console.error("  [ERROR] the prebuilt native modules failed to load on this Node.");
  console.error("          Node version:", process.version, "| platform:", process.platform, process.arch);
  console.error("          This package ships android-arm64 N-API binaries (Node >= 22.19).");
  process.exit(1);
}

// flock must load through the patched JS entry (this exercises both the patch
// and the dropped-in system.node). Session writes take a kernel write lease on
// every materializing write, so a broken flock is fatal to persistence.
const flockVerify = sh(
  `node --input-type=module -e 'import { tryLockExclusive } from "@deepseek-ai/node-addon-system/flock"; import { openSync } from "node:fs"; const fd = openSync(process.env.HOME + "/.dsh-flock-smoke", "w"); await tryLockExclusive(fd); console.log("flock-ok")'`,
  { cwd: dshDir },
);
if (flockVerify.includes("flock-ok")) {
  console.log("  [OK] flock android-arm64 loads");
} else {
  console.error("  [ERROR] flock android-arm64 addon failed to load — session writes will fail.");
  console.error("          Node version:", process.version, "| platform:", process.platform, process.arch);
  process.exit(1);
}

// ── Step 4: sharp WebAssembly fallback ──────────────────────────────────────
// sharp's native (libvips) binary is not available for android-arm64; dsh's
// attachment plugin fails to boot without it. The portable wasm build fixes it.
console.log("==> [4/5] Installing sharp WebAssembly fallback...");
let sharpOk = false;
for (const registry of REGISTRY_FALLBACKS) {
  try {
    const flag = registry ? ` --registry="${registry}"` : "";
    execSync(`npm install @img/sharp-wasm32${flag}`, { cwd: dshDir, stdio: "pipe", timeout: 300000 });
    sharpOk = true;
    break;
  } catch {
    // try next registry
  }
}
if (sharpOk) {
  console.log("  [OK] @img/sharp-wasm32 installed");
} else {
  console.log("  [WARN] could not install @img/sharp-wasm32 (sharp may fail to load)");
}

// ── Step 5: make the `dsh` bin run with --expose-internals ─────────────────
// The nested `npm install -g @deepseek-ai/dsh` links <prefix>/bin/dsh ->
// @deepseek-ai/dsh/lib/bin.js. That file's shebang is a bare `node`, but the
// HMR plugin needs --expose-internals, so we bake the flag into the shebang.
// When the symlink is exec'd the kernel reads the target's shebang and passes
// the flag — this is robust against npm re-linking bin entries. (We do NOT
// declare bin.dsh in our own package.json: that would collide with
// @deepseek-ai/dsh's bin during the nested install, EEXIST.)
console.log("==> [5/5] Ensuring the dsh bin runs with --expose-internals");
const binJs = path.join(dshDir, "lib", "bin.js");
const shebang = `#!${process.execPath} --expose-internals`;
const content = fs.readFileSync(binJs, "utf8");
if (!content.startsWith("#!")) {
  console.log("  [WARN] bin.js has no shebang — leaving as-is");
} else if (content.startsWith(shebang)) {
  console.log("  [OK] bin.js shebang already has --expose-internals");
} else {
  fs.writeFileSync(binJs, shebang + "\n" + content.slice(content.indexOf("\n") + 1));
  fs.chmodSync(binJs, 0o755); // writeFileSync preserves mode; be explicit anyway
  console.log("  [OK] bin.js shebang ->", shebang);
}

// ── Summary ─────────────────────────────────────────────────────────────────
console.log("");
console.log("==> dsh-termux installed!");
console.log("");
console.log("Run:  dsh web");
console.log("");
console.log("Optional extras after first boot:");
console.log("  dsh plugin --profile web add github:mexiaosqwq/dsh-web-mobile   # mobile UI");
