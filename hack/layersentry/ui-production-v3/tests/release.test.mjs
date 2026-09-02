import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(testDirectory, "..");
const releaseRoot = join(projectRoot, "release");

execFileSync(process.execPath, [join(projectRoot, "scripts/build.mjs")], {
  cwd: projectRoot,
  env: {
    ...process.env,
    SOURCE_DATE_EPOCH: "1788393600",
    LAYERSENTRY_BUILD_SHA: "0123456789abcdef0123456789abcdef01234567",
  },
  stdio: "pipe",
});

const html = await readFile(join(releaseRoot, "www/index.html"), "utf8");
const css = await readFile(join(releaseRoot, "www/assets/layersentry.css"), "utf8");
const js = await readFile(join(releaseRoot, "www/assets/layersentry.js"), "utf8");
const metadata = JSON.parse(await readFile(join(releaseRoot, "release-metadata.json"), "utf8"));
const manifest = JSON.parse(await readFile(join(releaseRoot, "asset-manifest.json"), "utf8"));
const sbom = JSON.parse(await readFile(join(releaseRoot, "sbom.spdx.json"), "utf8"));

async function listFiles(directory, prefix = "") {
  const paths = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) paths.push(...await listFiles(join(directory, entry.name), relativePath));
    else if (entry.isFile()) paths.push(relativePath);
  }
  return paths.sort();
}

test("builds the exact production release file set", async () => {
  assert.deepEqual(await listFiles(releaseRoot), [
    "SHA256SUMS",
    "asset-manifest.json",
    "deploy/nginx.conf",
    "release-metadata.json",
    "sbom.spdx.json",
    "www/assets/favicon.svg",
    "www/assets/layersentry-mark.svg",
    "www/assets/layersentry.css",
    "www/assets/layersentry.js",
    "www/index.html",
  ]);
});

test("merges the responsive correction into the canonical stylesheet", () => {
  assert.match(css, /Canonical mobile grid placement/);
  assert.match(css, /"sidebar" auto/);
  assert.match(css, /\.sidebar\s*\{\s*grid-area:\s*sidebar;/s);
});

test("does not ship disconnected override files", async () => {
  const files = await listFiles(releaseRoot);
  assert.equal(files.some((path) => /responsive-fix|mobile-layout/i.test(path)), false);
});

test("retains LayerSentry-only visible shell branding", () => {
  assert.match(html, /<title>LayerSentry<\/title>/);
  assert.match(html, />LayerSentry</);
  assert.doesNotMatch(html, />\s*(?:Harvester|Rancher)\s*</i);
});

test("retains strict same-origin browser security controls", () => {
  assert.match(html, /default-src 'self'/);
  assert.match(html, /frame-ancestors 'none'/);
  assert.match(js, /credentials: "same-origin"/);
  assert.match(js, /cache: "no-store"/);
  assert.match(js, /redirect: "error"/);
  assert.match(js, /AbortController/);
  assert.doesNotMatch(js, /\.innerHTML\s*=/);
  assert.doesNotMatch(js, /sessionStorage/);
  assert.doesNotMatch(js, /Authorization\s*:/i);
  assert.doesNotMatch(js, /Bearer\s+/i);
});

test("records deterministic build provenance without claiming deployment", () => {
  assert.equal(metadata.product, "LayerSentry");
  assert.equal(metadata.commit, "0123456789abcdef0123456789abcdef01234567");
  assert.equal(metadata.builtAtUtc, "2026-09-03T00:00:00.000Z");
  assert.equal(metadata.externalRuntimeDependencies, 0);
  assert.equal(metadata.browserCredentialStorage, "none");
  assert.equal(metadata.liveClusterDeploymentPerformed, false);
  assert.equal(metadata.productionReleaseApprovalImplied, false);
});

test("covers every deployable asset in the integrity manifest", () => {
  const paths = Object.keys(manifest.files).sort();
  assert.deepEqual(paths, [
    "deploy/nginx.conf",
    "release-metadata.json",
    "www/assets/favicon.svg",
    "www/assets/layersentry-mark.svg",
    "www/assets/layersentry.css",
    "www/assets/layersentry.js",
    "www/index.html",
  ]);
  for (const details of Object.values(manifest.files)) {
    assert.match(details.sha256, /^[a-f0-9]{64}$/);
    assert.match(details.integrity, /^sha384-[A-Za-z0-9+/]+={0,2}$/);
    assert.equal(Number.isSafeInteger(details.bytes) && details.bytes > 0, true);
  }
});

test("generates an SPDX 2.3 file-level SBOM", () => {
  assert.equal(sbom.spdxVersion, "SPDX-2.3");
  assert.equal(sbom.dataLicense, "CC0-1.0");
  assert.equal(sbom.packages.length, 1);
  assert.equal(sbom.files.length, Object.keys(manifest.files).length);
  assert.equal(sbom.relationships.length, sbom.files.length);
});

test("passes the independent distribution verifier", () => {
  assert.doesNotThrow(() => {
    execFileSync(process.execPath, [join(projectRoot, "scripts/verify-dist.mjs")], {
      cwd: projectRoot,
      stdio: "pipe",
    });
  });
});
