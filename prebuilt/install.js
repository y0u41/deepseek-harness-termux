#!/usr/bin/env node
// dsh-termux installer (Plan B — precompiled native modules).
//
// Installs the patched @deepseek-ai/dsh globally WITHOUT compiling anything:
//   1. npm install -g --ignore-scripts @deepseek-ai/dsh@<pinned>
//   2. install the sharp WASM fallback (must happen BEFORE the shims below,
//      because npm's reify() prunes anything it does not find in the
//      dependency tree — see the note at step 3)
//   3. apply the Android source patches (bundled in patches/)
//   4. drop in the prebuilt native modules (bundled in prebuilt/)
//      - node-pty  -> node-pty/build/Release/pty.node
//      - koffi     -> koffi/build/koffi/android_arm64/koffi.node
//      - flock     -> @deepseek-ai/node-addon-system-android-arm64 (shim)
//   5. verify the natives actually load, and that `dsh --version` works
//
// HOW TO RUN ON npm >= 12
// -----------------------
// npm 12 does not execute a dependency's postinstall unless it is allow-listed
// ("allowScripts"), and it exits 0 anyway. So this file has TWO entry points:
//   - postinstall (npm <= 11 only)
//   - `dsh-termux-setup` bin, which always works:
//         npm i -g <tarball> && dsh-termux-setup
// `bin/dsh` also self-bootstraps: if the deployment is missing it runs this
// installer before starting dsh.
//
// Everything is idempotent: re-running re-applies the patches and re-drops the
// natives (npm re-extracts dsh first, which wipes the previous copies).

"use strict";

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// Bump together with patches/: only a dsh version whose sources the patches
// apply to cleanly is safe to pin here. Overridable via DSH_VERSION.
// Keep in sync with install.sh (CI checks both).
const DSH_VERSION = process.env.DSH_VERSION || "0.2.2-rc.1";

// The patches and the --expose-internals fallback are validated on this range.
// dsh's own engines field is >=24.9.0; stay exact, do not guess.
const MIN_NODE = [24, 9, 0];

const PKG_DIR = __dirname;
const IS_MAIN = require.main === module;

function log(...args) {
  console.log(...args);
}
function warn(...args) {
  console.warn(...args);
}

function run(file, args, opts = {}) {
  return execFileSync(file, args, { stdio: "pipe", encoding: "utf8", ...opts });
}
function tryRun(file, args, opts = {}) {
  try {
    return run(file, args, opts);
  } catch {
    return null;
  }
}
function npmHas(registry) {
  return registry ? ["--registry=" + registry] : [];
}

function checkPreflight() {
  const [maj, min] = process.versions.node.split(".").map(Number);
  if (maj < MIN_NODE[0] || (maj === MIN_NODE[0] && min < MIN_NODE[1])) {
    console.error(`[ERROR] dsh needs Node.js >= ${MIN_NODE.join(".")} (found ${process.version}).`);
    console.error("        On Termux:  pkg install nodejs-lts   (then reopen the shell)");
    process.exit(1);
  }
  if (process.arch !== "arm64") {
    console.error(`[ERROR] this package ships android-arm64 binaries only (found ${process.arch}).`);
    console.error("        On an arm64 Termux device use the full install:  bash install.sh");
    process.exit(1);
  }
  if (process.platform !== "android") {
    // Refuse BEFORE touching the global dsh install: a desktop user who lands
    // here would otherwise have their working global dsh replaced and patched,
    // then see the native verification fail with no way back.
    console.error(`[ERROR] this package targets Termux/Android (found ${process.platform}).`);
    console.error("        On a desktop host install upstream:  npm i -g @deepseek-ai/dsh");
    process.exit(1);
  }
  if (!tryRun("patch", ["--version"])) {
    console.error("[ERROR] `patch` is required to apply the Android source patches.");
    console.error("        On Termux:  pkg install patch");
    process.exit(1);
  }
  log(`  [OK] ${process.platform}-${process.arch}, node ${process.version}`);
}

function findGlobalRoot() {
  const fromNpm = (tryRun("npm", ["root", "-g"]) || "").trim();
  if (fromNpm) return fromNpm;
  return path.join(process.env.PREFIX || "/data/data/com.termux/files/usr", "lib", "node_modules");
}

function main() {
  log("dsh-termux — precompiled Termux deployment of @deepseek-ai/dsh");
  log("");
  checkPreflight();

  const globalRoot = findGlobalRoot();
  const dshDir = path.join(globalRoot, "@deepseek-ai", "dsh");
  const dshPkgs = path.join(dshDir, "node_modules", "@deepseek-ai");

  // ── Step 1: install dsh (download only, nothing compiles) ────────────────
  // Try the user's configured registry first (respects .npmrc / mirrors the
  // user already set up), then the official registry and finally npmmirror.
  log(`==> [1/6] Installing @deepseek-ai/dsh@${DSH_VERSION} (no scripts — nothing compiles)`);
  if (!/^[0-9A-Za-z.+-]+$/.test(DSH_VERSION)) {
    console.error(`[ERROR] refusing suspicious DSH_VERSION: ${JSON.stringify(DSH_VERSION)}`);
    process.exit(1);
  }
  const REGISTRIES = [null, "https://registry.npmjs.org", "https://registry.npmmirror.com"];
  let dshInstalled = false;
  for (const registry of REGISTRIES) {
    try {
      run(
        "npm",
        ["install", "-g", "--ignore-scripts", `@deepseek-ai/dsh@${DSH_VERSION}`, ...npmHas(registry)],
        { stdio: "inherit", timeout: 600000 },
      );
      dshInstalled = true;
      break;
    } catch {
      warn(`  [WARN] registry ${registry ?? "(user default)"} failed — trying next`);
    }
  }
  if (!dshInstalled) {
    console.error("  [ERROR] could not install @deepseek-ai/dsh from any registry");
    process.exit(1);
  }

  const installedVersion = JSON.parse(
    fs.readFileSync(path.join(dshDir, "package.json"), "utf8"),
  ).version;
  log(`  [OK] @deepseek-ai/dsh@${installedVersion} at ${dshDir}`);

  // ── Step 2: sharp WASM fallback ──────────────────────────────────────────
  // MUST run before any shim is created. `npm install` in the dsh dir runs
  // reify(), which deletes every top-level package that is not in dsh's
  // dependency tree — the hand-made platform shims included. Doing this last
  // (as this installer used to) silently removed the flock shim.
  log("==> [2/6] Installing sharp WebAssembly fallback");
  const sharpArgs = [
    "install",
    "@img/sharp-wasm32",
    "--no-save",
    "--package-lock=false",
    "--ignore-scripts",
  ];
  let sharpOk = false;
  for (const registry of REGISTRIES) {
    try {
      run("npm", [...sharpArgs, ...npmHas(registry)], { cwd: dshDir, timeout: 300000 });
      sharpOk = true;
      break;
    } catch {
      // next registry
    }
  }
  if (sharpOk) {
    log("  [OK] @img/sharp-wasm32 installed");
  } else {
    warn("  [WARN] could not install @img/sharp-wasm32 — attachments/preview will not work");
  }

  // ── Step 3: apply the Android source patches ─────────────────────────────
  log("==> [3/6] Applying Android platform patches");
  const PATCH_TARGETS = [
    ["01-terminal-bash-android-shell.patch", "dsh-terminal-bash"],
    ["02-session-persistence-link-rename.patch", "dsh-session-persistence-jsonl"],
    ["03-subprocess-local-android.patch", "dsh-subprocess-local"],
    ["04-native-command-termux-open.patch", "dsh-native-command"],
    ["05-host-directory-picker-native-android.patch", "dsh-host-directory-picker-native"],
    ["06-workspace-archive-skip-session-known-check.patch", "dsh-workspace"],
    ["07-sandbox-local-proot-runner.patch", "dsh-sandbox-local"],
    ["08-dsh-tool-fs-search-android-rg.patch", "dsh-tool-fs-search"],
    // 09 is what keeps the process alive at boot: upstream ships no android
    // build of node-addon-require-builtin, so dsh must go through
    // --expose-internals. 10 is only needed by the optional inspector bundle.
    ["09-app-boot-expose-internals.patch", "dsh-app-boot"],
    ["10-inspector-worker-expose-internals.patch", "dsh-experimental-inspector"],
    ["11-node-addon-system-flock-android.patch", "node-addon-system"],
    ["koffi-statx.patch", null], // koffi lives outside the @deepseek-ai scope
  ];

  // Without 09 (boot), 02 (session persistence), 11 (flock) or koffi's statx
  // patch the resulting install is broken in ways the user only discovers at
  // runtime, so a failure on these aborts instead of printing "installed".
  const CRITICAL = new Set([
    "02-session-persistence-link-rename.patch",
    "09-app-boot-expose-internals.patch",
    "11-node-addon-system-flock-android.patch",
    "koffi-statx.patch",
  ]);

  const failures = [];
  for (const [file, pkg] of PATCH_TARGETS) {
    const patch = path.join(PKG_DIR, "patches", file);
    const dir = pkg ? path.join(dshPkgs, pkg) : path.join(dshDir, "node_modules", "koffi");
    if (!fs.existsSync(patch)) {
      failures.push(`${file}: not shipped in this package`);
      continue;
    }
    if (!fs.existsSync(dir)) {
      failures.push(`${file}: target package missing (${pkg ?? "koffi"})`);
      continue;
    }
    // -F0: never let fuzz hide a drifted hunk. A patch that only applies with
    // fuzzy context is a patch that can land on the wrong lines.
    if (tryRun("patch", ["-p1", "-F0", "--dry-run", "--forward"], { cwd: dir, input: fs.readFileSync(patch) }) !== null) {
      tryRun("patch", ["-p1", "-F0", "--forward"], { cwd: dir, input: fs.readFileSync(patch) });
      log("  [OK]", file);
    } else if (tryRun("patch", ["-p1", "-F0", "--dry-run", "--reverse"], { cwd: dir, input: fs.readFileSync(patch) }) !== null) {
      log("  [SKIP]", file, "(already applied)");
    } else {
      log("  [FAIL]", file, "(inapplicable — upstream source drifted)");
      failures.push(`${file}: inapplicable (dsh source changed)`);
    }
  }

  // Content assertion for the boot-critical fallback: never trust that `patch`
  // did what we think. patch 09 rewrites lib/index.js; grep for the marker it
  // introduces rather than for an exact upstream line (which upstream may
  // reformat at any time).
  const appBootIdx = path.join(dshPkgs, "dsh-app-boot", "lib", "index.js");
  if (fs.existsSync(appBootIdx)) {
    const src = fs.readFileSync(appBootIdx, "utf8");
    if (src.includes("internal/modules/esm/loader")) {
      log("  [OK] dsh-app-boot has the --expose-internals fallback");
    } else {
      failures.push("dsh-app-boot/lib/index.js lacks the --expose-internals fallback");
    }
  } else {
    failures.push("dsh-app-boot/lib/index.js is missing");
  }

  const fatal = failures.filter((f) => {
    const name = f.split(":")[0];
    return CRITICAL.has(name) || name.startsWith("dsh-app-boot");
  });
  const nonFatal = failures.filter((f) => !fatal.includes(f));
  for (const f of nonFatal) warn("  [WARN]", f, "— feature degraded, install continues");

  if (fatal.length > 0) {
    console.error("");
    console.error("  [ERROR] Critical patch(es) did not apply:");
    for (const f of fatal) console.error("          -", f);
    console.error("");
    console.error("          Without them dsh either crashes at startup or loses session");
    console.error("          persistence. Most likely DSH_VERSION drifted from the version");
    console.error("          these patches were generated against (pinned: " + DSH_VERSION + ").");
    console.error("          See troubleshooting.md > problem 1.");
    process.exit(1);
  }

  // ── Step 4: drop in the prebuilt native modules ──────────────────────────
  log("==> [4/6] Installing prebuilt native modules (android-arm64)");
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
    log("  [OK]", file, "->", path.relative(globalRoot, dest));
  }

  // flock: the android platform-package shim. Patched flock.js (patch 11)
  // require.resolve()s `@deepseek-ai/node-addon-system-android-arm64`; upstream
  // ships no such package and bionic is neither glibc nor musl.
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
    log("  [OK] system.node ->", path.relative(globalRoot, flockNodeDest));
  } else {
    console.log("  [WARN] prebuilt module missing: system.node (flock will be unavailable)");
  }

  // ripgrep shim: @vscode/ripgrep resolves @vscode/ripgrep-android-arm64, which
  // does not exist. Patch 08 falls back to the system rg, but the shim keeps
  // require.resolve() working (and survives only until the next npm install).
  const rgSystem = process.env.RG_SYSTEM || path.join(process.env.PREFIX || "/data/data/com.termux/files/usr", "bin", "rg");
  const rgShimDir = path.join(dshDir, "node_modules", "@vscode", "ripgrep-android-arm64");
  if (fs.existsSync(rgSystem)) {
    fs.mkdirSync(path.join(rgShimDir, "bin"), { recursive: true });
    fs.writeFileSync(path.join(rgShimDir, "package.json"), JSON.stringify({
      name: "@vscode/ripgrep-android-arm64",
      version: "1.18.0",
      description: `Termux shim: resolves rgPath to the system ripgrep (${rgSystem}); @vscode/ripgrep has no android platform package.`,
      license: "MIT",
      bin: { rg: "bin/rg" },
    }, null, 2) + "\n");
    fs.rmSync(path.join(rgShimDir, "bin", "rg"), { force: true });
    fs.symlinkSync(rgSystem, path.join(rgShimDir, "bin", "rg"));
    log("  [OK] ripgrep android shim ->", rgSystem);
  } else {
    console.log("  [WARN] system rg not found at", rgSystem, "— run: pkg install ripgrep");
  }

  // ── Step 5: verify ───────────────────────────────────────────────────────
  log("==> [5/6] Verifying native modules and startup");
  const ptyDir = path.join(dshDir, "node_modules", "node-pty");
  const koffiDir = path.join(dshDir, "node_modules", "koffi");
  if (tryRun(process.execPath, ["-e", `require(${JSON.stringify(ptyDir)}); require(${JSON.stringify(koffiDir)});`]) === null) {
    console.error("  [ERROR] the prebuilt native modules failed to load on this Node.");
    console.error("          Node version:", process.version, "| platform:", process.platform, process.arch);
    console.error(`          This package ships android-arm64 N-API binaries (Node >= ${MIN_NODE.join(".")}).`);
    process.exit(1);
  }
  log("  [OK] node-pty + koffi load");

  // flock goes through the patched JS entry, exercising both patch 11 and the
  // shim we just dropped in. Session writes take a kernel lease on every
  // materializing write, so a broken flock is fatal to persistence.
  const smoke = path.join(os.tmpdir(), `dsh-flock-smoke-${process.pid}`);
  const flockProbe = tryRun(process.execPath, [
    "--input-type=module",
    "-e",
    'import { tryLockExclusive } from "@deepseek-ai/node-addon-system/flock";' +
      "import { openSync, closeSync } from 'node:fs';" +
      `const fd = openSync(${JSON.stringify(smoke)}, "w");` +
      "await tryLockExclusive(fd); closeSync(fd); console.log('flock-ok');",
  ], { cwd: dshDir });
  fs.rmSync(smoke, { force: true });
  if (!flockProbe || !flockProbe.includes("flock-ok")) {
    console.error("  [ERROR] flock android-arm64 addon failed to load — session writes will fail.");
    console.error("          Node version:", process.version, "| platform:", process.platform, process.arch);
    process.exit(1);
  }
  log("  [OK] flock android-arm64 loads");

  // ── Step 6: make the `dsh` bin run with --expose-internals ───────────────
  // `npm install -g @deepseek-ai/dsh` links <prefix>/bin/dsh ->
  // @deepseek-ai/dsh/lib/bin.js. That file's shebang is a bare `node`, but the
  // HMR plugin needs --expose-internals, so bake the flag into the shebang.
  // When the symlink is exec'd the kernel reads the target's shebang and passes
  // the flag — robust against npm re-linking bin entries.
  log("==> [6/6] Ensuring the dsh bin runs with --expose-internals");
  const binJs = path.join(dshDir, "lib", "bin.js");
  if (!fs.existsSync(binJs)) {
    console.error("  [ERROR] dsh/lib/bin.js is missing — the npm install did not complete.");
    process.exit(1);
  }
  const shebang = `#!${process.execPath} --expose-internals`;
  const content = fs.readFileSync(binJs, "utf8");
  if (!content.startsWith("#!")) {
    warn("  [WARN] bin.js has no shebang — leaving as-is");
  } else if (content.startsWith(shebang)) {
    log("  [OK] bin.js shebang already has --expose-internals");
    fs.chmodSync(binJs, 0o755);
  } else {
    fs.writeFileSync(binJs, shebang + "\n" + content.slice(content.indexOf("\n") + 1));
    fs.chmodSync(binJs, 0o755);
    log("  [OK] bin.js shebang ->", shebang);
  }

  // End-to-end smoke test: this is the check that actually proves the install
  // works. Everything above can pass while the boot patch is still missing.
  const versionOut = tryRun(process.execPath, ["--expose-internals", binJs, "--version"], {
    cwd: dshDir,
    timeout: 120000,
  });
  if (versionOut === null) {
    console.error("  [ERROR] `dsh --version` failed — the install is not usable.");
    console.error("          Re-run with a fresh shell and check troubleshooting.md.");
    process.exit(1);
  }
  log("  [OK] dsh --version ->", versionOut.trim().split("\n")[0]);

  log("");
  log("==> dsh-termux installed!");
  log("");
  log("Run:  dsh web");
  log("");
  log("Optional extras after first boot:");
  log("  dsh plugin --profile web add github:mexiaosqwq/dsh-web-mobile   # mobile UI");
}

if (IS_MAIN) {
  main();
}

module.exports = { main, DSH_VERSION, MIN_NODE };
