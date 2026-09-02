import { createHash } from "node:crypto";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const sourceRoot = resolve(projectRoot, "../ui-production-v2");
const sourcePublic = join(sourceRoot, "public");
const releaseRoot = join(projectRoot, "release");
const webRoot = join(releaseRoot, "www");
const deploymentRoot = join(releaseRoot, "deploy");

const webFiles = [
  "index.html",
  "assets/favicon.svg",
  "assets/layersentry-mark.svg",
  "assets/layersentry.css",
  "assets/layersentry.js",
];

const responsiveCorrection = `

/* Canonical mobile grid placement: merged by the production-v3 assembler. */
@media (max-width: 860px) {
  .app-shell {
    grid-template:
      "topbar" auto
      "sidebar" auto
      "main" minmax(0, 1fr)
      "footer" auto /
      minmax(0, 1fr);
  }

  .sidebar {
    grid-area: sidebar;
  }
}
`;

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function sha384Integrity(bytes) {
  return `sha384-${createHash("sha384").update(bytes).digest("base64")}`;
}

function normaliseCommit() {
  const candidate = String(process.env.GITHUB_SHA ?? process.env.LAYERSENTRY_BUILD_SHA ?? "development").trim();
  return /^[a-f0-9]{40}$/i.test(candidate) ? candidate.toLowerCase() : "development";
}

function normaliseBuildTime() {
  const candidate = String(process.env.SOURCE_DATE_EPOCH ?? "0").trim();
  const epoch = Number(candidate);
  if (Number.isSafeInteger(epoch) && epoch > 0) return new Date(epoch * 1000).toISOString();
  return "1970-01-01T00:00:00.000Z";
}

async function readDigest(path) {
  const bytes = await readFile(path);
  return {
    bytes: bytes.length,
    sha256: sha256(bytes),
    integrity: sha384Integrity(bytes),
  };
}

async function copyWebAsset(relativePath) {
  const source = join(sourcePublic, relativePath);
  const destination = join(webRoot, relativePath);
  await mkdir(dirname(destination), { recursive: true });
  await cp(source, destination, { force: true });
}

await rm(releaseRoot, { recursive: true, force: true });
await mkdir(webRoot, { recursive: true });
await mkdir(deploymentRoot, { recursive: true });

for (const relativePath of webFiles) await copyWebAsset(relativePath);

const cssPath = join(webRoot, "assets/layersentry.css");
const css = await readFile(cssPath, "utf8");
if (!css.includes("Canonical mobile grid placement")) {
  await writeFile(cssPath, `${css.trimEnd()}${responsiveCorrection}`, "utf8");
}

await cp(join(sourceRoot, "nginx.conf"), join(deploymentRoot, "nginx.conf"), { force: true });

const packageMetadata = JSON.parse(await readFile(join(projectRoot, "package.json"), "utf8"));
const releaseMetadata = {
  schemaVersion: "1.0",
  product: "LayerSentry",
  component: "production-ui",
  releaseChannel: "release-candidate",
  version: packageMetadata.version,
  sourcePackage: "ui-production-v2",
  canonicalAssembler: "ui-production-v3",
  commit: normaliseCommit(),
  builtAtUtc: normaliseBuildTime(),
  externalRuntimeDependencies: 0,
  browserCredentialStorage: "none",
  apiSessionMode: "same-origin-cookie",
  liveClusterDeploymentPerformed: false,
  productionReleaseApprovalImplied: false,
};
await writeFile(
  join(releaseRoot, "release-metadata.json"),
  `${JSON.stringify(releaseMetadata, null, 2)}\n`,
  "utf8",
);

const manifest = {
  schemaVersion: "1.0",
  product: "LayerSentry",
  generatedAtUtc: releaseMetadata.builtAtUtc,
  files: {},
};
for (const relativePath of [
  ...webFiles.map((path) => `www/${path}`),
  "deploy/nginx.conf",
  "release-metadata.json",
].sort()) {
  manifest.files[relativePath] = await readDigest(join(releaseRoot, relativePath));
}
await writeFile(join(releaseRoot, "asset-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");

const sbomFiles = [];
for (const [path, details] of Object.entries(manifest.files)) {
  sbomFiles.push({
    SPDXID: `SPDXRef-File-${sha256(Buffer.from(path)).slice(0, 16)}`,
    fileName: `./${path}`,
    checksums: [{ algorithm: "SHA256", checksumValue: details.sha256 }],
  });
}
const sbom = {
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: `LayerSentry-production-ui-${packageMetadata.version}`,
  documentNamespace: `urn:layersentry:sbom:${releaseMetadata.commit}:${packageMetadata.version}`,
  creationInfo: {
    created: releaseMetadata.builtAtUtc,
    creators: ["Organization: LayerSentry", "Tool: ui-production-v3/scripts/build.mjs"],
  },
  packages: [{
    SPDXID: "SPDXRef-Package-LayerSentry-UI",
    name: "LayerSentry production UI",
    versionInfo: packageMetadata.version,
    downloadLocation: "NOASSERTION",
    filesAnalyzed: true,
    licenseConcluded: "NOASSERTION",
    licenseDeclared: "NOASSERTION",
    copyrightText: "NOASSERTION",
  }],
  files: sbomFiles,
  relationships: sbomFiles.map((file) => ({
    spdxElementId: "SPDXRef-Package-LayerSentry-UI",
    relationshipType: "CONTAINS",
    relatedSpdxElement: file.SPDXID,
  })),
};
await writeFile(join(releaseRoot, "sbom.spdx.json"), `${JSON.stringify(sbom, null, 2)}\n`, "utf8");

const checksumTargets = [
  ...Object.keys(manifest.files),
  "asset-manifest.json",
  "sbom.spdx.json",
].sort();
const checksumLines = [];
for (const relativePath of checksumTargets) {
  const bytes = await readFile(join(releaseRoot, relativePath));
  checksumLines.push(`${sha256(bytes)}  ${relativePath}`);
}
await writeFile(join(releaseRoot, "SHA256SUMS"), `${checksumLines.join("\n")}\n`, "utf8");

console.log(`LayerSentry canonical UI release assembled: ${releaseRoot}`);
console.log(`Web assets: ${webFiles.length}`);
console.log(`Commit: ${releaseMetadata.commit}`);
console.log(`Build time: ${releaseMetadata.builtAtUtc}`);
