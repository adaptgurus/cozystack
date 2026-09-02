import { createHash } from "node:crypto";
import { readFile, readdir, stat } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const releaseRoot = join(projectRoot, "release");

const expectedFiles = [
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
].sort();

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const absolute = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(absolute));
    else if (entry.isFile()) files.push(relative(releaseRoot, absolute).replaceAll("\\", "/"));
  }
  return files;
}

const failures = [];
const requireContract = (condition, message) => {
  if (!condition) failures.push(message);
};

let actualFiles = [];
try {
  actualFiles = (await walk(releaseRoot)).sort();
} catch (error) {
  console.error(`Release directory is unavailable: ${error.message}`);
  process.exit(1);
}

requireContract(
  JSON.stringify(actualFiles) === JSON.stringify(expectedFiles),
  `Release file set is not exact. Expected ${JSON.stringify(expectedFiles)}, observed ${JSON.stringify(actualFiles)}.`,
);

const manifest = JSON.parse(await readFile(join(releaseRoot, "asset-manifest.json"), "utf8"));
const metadata = JSON.parse(await readFile(join(releaseRoot, "release-metadata.json"), "utf8"));
const sbom = JSON.parse(await readFile(join(releaseRoot, "sbom.spdx.json"), "utf8"));
const checksumText = await readFile(join(releaseRoot, "SHA256SUMS"), "utf8");
const checksumLines = checksumText.trim().split(/\r?\n/).filter(Boolean);
const checksums = new Map();
for (const line of checksumLines) {
  const match = /^([a-f0-9]{64})  (.+)$/.exec(line);
  requireContract(Boolean(match), `Invalid SHA256SUMS line: ${line}`);
  if (match) checksums.set(match[2], match[1]);
}

for (const [path, expected] of checksums) {
  const bytes = await readFile(join(releaseRoot, path));
  requireContract(sha256(bytes) === expected, `SHA-256 mismatch for ${path}.`);
}
requireContract(checksums.size === expectedFiles.length - 1, "SHA256SUMS must cover every release file except itself.");

const manifestFiles = Object.keys(manifest.files ?? {}).sort();
const expectedManifestFiles = expectedFiles.filter((path) => !["SHA256SUMS", "asset-manifest.json", "sbom.spdx.json"].includes(path));
requireContract(
  JSON.stringify(manifestFiles) === JSON.stringify(expectedManifestFiles),
  "The asset manifest must cover every web/deployment asset and release metadata file exactly once.",
);
for (const [path, details] of Object.entries(manifest.files ?? {})) {
  const bytes = await readFile(join(releaseRoot, path));
  requireContract(details.bytes === bytes.length, `Manifest byte size mismatch for ${path}.`);
  requireContract(details.sha256 === sha256(bytes), `Manifest SHA-256 mismatch for ${path}.`);
  requireContract(/^sha384-[A-Za-z0-9+/]+={0,2}$/.test(details.integrity ?? ""), `Invalid SHA-384 integrity value for ${path}.`);
}

requireContract(metadata.product === "LayerSentry", "Release product identity is invalid.");
requireContract(metadata.component === "production-ui", "Release component identity is invalid.");
requireContract(metadata.canonicalAssembler === "ui-production-v3", "Canonical assembler identity is invalid.");
requireContract(metadata.externalRuntimeDependencies === 0, "External runtime dependency count must be zero.");
requireContract(metadata.browserCredentialStorage === "none", "Browser credential storage must be none.");
requireContract(metadata.apiSessionMode === "same-origin-cookie", "API session mode must be same-origin-cookie.");
requireContract(metadata.liveClusterDeploymentPerformed === false, "Build metadata must not claim a live deployment.");
requireContract(metadata.productionReleaseApprovalImplied === false, "Build metadata must not imply release approval.");
requireContract(/^(development|[a-f0-9]{40})$/.test(metadata.commit), "Release commit provenance is invalid.");

requireContract(sbom.spdxVersion === "SPDX-2.3", "SPDX version must be 2.3.");
requireContract(sbom.dataLicense === "CC0-1.0", "SPDX data license must be CC0-1.0.");
requireContract(Array.isArray(sbom.files) && sbom.files.length === expectedManifestFiles.length, "SPDX SBOM must enumerate every manifested release file.");
requireContract(Array.isArray(sbom.relationships) && sbom.relationships.length === sbom.files.length, "SPDX package relationships are incomplete.");

const html = await readFile(join(releaseRoot, "www/index.html"), "utf8");
const css = await readFile(join(releaseRoot, "www/assets/layersentry.css"), "utf8");
const js = await readFile(join(releaseRoot, "www/assets/layersentry.js"), "utf8");
const nginx = await readFile(join(releaseRoot, "deploy/nginx.conf"), "utf8");

requireContract(css.includes("Canonical mobile grid placement"), "The canonical mobile layout correction was not merged into the release stylesheet.");
requireContract(css.includes('"sidebar" auto'), "The mobile release grid does not reserve the sidebar row.");
requireContract(/\.sidebar\s*\{\s*grid-area:\s*sidebar;/s.test(css), "The mobile sidebar is not explicitly assigned to the sidebar grid area.");
requireContract(!actualFiles.some((path) => /responsive-fix|mobile-layout/i.test(path)), "Standalone responsive override files must not ship.");

for (const asset of ["assets/favicon.svg", "assets/layersentry-mark.svg", "assets/layersentry.css", "assets/layersentry.js"]) {
  requireContract(html.includes(asset), `index.html does not reference required asset ${asset}.`);
  requireContract(manifest.files[`www/${asset}`] !== undefined, `Referenced asset ${asset} is absent from the integrity manifest.`);
}

for (const [name, source] of Object.entries({ html, css, js })) {
  requireContract(!/https?:\/\//i.test(source), `${name} contains an external network URL.`);
  requireContract(!/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(source), `${name} contains private-key material.`);
  requireContract(!/(?:password|passwd|secret|token)\s*[:=]\s*["'][^"']{4,}["']/i.test(source), `${name} appears to contain a hard-coded credential.`);
}
requireContract(!/\.innerHTML\s*=/.test(js), "Release JavaScript contains innerHTML assignment.");
requireContract(!/sessionStorage/.test(js), "Release JavaScript contains sessionStorage usage.");
requireContract(!/authorization\s*:/i.test(js), "Release JavaScript constructs an Authorization header.");
requireContract(/credentials:\s*"same-origin"/.test(js), "Release JavaScript does not require same-origin credentials.");
requireContract(/Content-Security-Policy/.test(nginx), "Release Nginx configuration does not emit a CSP header.");
requireContract(/listen 8080 default_server;/.test(nginx), "Release Nginx configuration does not use unprivileged port 8080.");

const sizeBudgets = {
  "www/index.html": 40 * 1024,
  "www/assets/layersentry.css": 50 * 1024,
  "www/assets/layersentry.js": 52 * 1024,
  "www/assets/layersentry-mark.svg": 8 * 1024,
  "www/assets/favicon.svg": 4 * 1024,
  "deploy/nginx.conf": 12 * 1024,
  "asset-manifest.json": 16 * 1024,
  "release-metadata.json": 4 * 1024,
  "sbom.spdx.json": 32 * 1024,
  "SHA256SUMS": 4 * 1024,
};
for (const [path, budget] of Object.entries(sizeBudgets)) {
  const details = await stat(join(releaseRoot, path));
  requireContract(details.size <= budget, `${path} exceeds its production budget (${details.size} > ${budget}).`);
}

if (failures.length > 0) {
  console.error("LayerSentry canonical UI release verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log("LayerSentry canonical UI release verification: PASS");
  console.log(`Verified ${actualFiles.length} exact release files and ${checksums.size} SHA-256 entries.`);
}
