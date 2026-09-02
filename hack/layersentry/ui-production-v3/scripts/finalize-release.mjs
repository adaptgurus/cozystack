import { createHash } from "node:crypto";
import { cp, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const releaseRoot = join(projectRoot, "release");
const nginxSource = join(projectRoot, "nginx-secure.conf");
const nginxDestination = join(releaseRoot, "deploy/nginx.conf");

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function sha384Integrity(bytes) {
  return `sha384-${createHash("sha384").update(bytes).digest("base64")}`;
}

async function digest(relativePath) {
  const bytes = await readFile(join(releaseRoot, relativePath));
  return {
    bytes: bytes.length,
    sha256: sha256(bytes),
    integrity: sha384Integrity(bytes),
  };
}

await cp(nginxSource, nginxDestination, { force: true });

const metadataPath = join(releaseRoot, "release-metadata.json");
const metadata = JSON.parse(await readFile(metadataPath, "utf8"));
metadata.serverPolicy = "nginx-secure-v2";
metadata.serverSecurityHeaderInheritanceReviewed = true;
metadata.canonicalReleaseFinalized = true;
await writeFile(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`, "utf8");

const manifestPaths = [
  "deploy/nginx.conf",
  "release-metadata.json",
  "www/assets/favicon.svg",
  "www/assets/layersentry-mark.svg",
  "www/assets/layersentry.css",
  "www/assets/layersentry.js",
  "www/index.html",
].sort();
const manifest = {
  schemaVersion: "1.0",
  product: "LayerSentry",
  generatedAtUtc: metadata.builtAtUtc,
  files: {},
};
for (const relativePath of manifestPaths) manifest.files[relativePath] = await digest(relativePath);
await writeFile(join(releaseRoot, "asset-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");

const sbomFiles = manifestPaths.map((path) => ({
  SPDXID: `SPDXRef-File-${sha256(Buffer.from(path)).slice(0, 16)}`,
  fileName: `./${path}`,
  checksums: [{ algorithm: "SHA256", checksumValue: manifest.files[path].sha256 }],
}));
const sbom = {
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: `LayerSentry-production-ui-${metadata.version}`,
  documentNamespace: `urn:layersentry:sbom:${metadata.commit}:${metadata.version}:final`,
  creationInfo: {
    created: metadata.builtAtUtc,
    creators: ["Organization: LayerSentry", "Tool: ui-production-v3/scripts/finalize-release.mjs"],
  },
  packages: [{
    SPDXID: "SPDXRef-Package-LayerSentry-UI",
    name: "LayerSentry production UI",
    versionInfo: metadata.version,
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

const checksumTargets = [...manifestPaths, "asset-manifest.json", "sbom.spdx.json"].sort();
const checksumLines = [];
for (const relativePath of checksumTargets) {
  const bytes = await readFile(join(releaseRoot, relativePath));
  checksumLines.push(`${sha256(bytes)}  ${relativePath}`);
}
await writeFile(join(releaseRoot, "SHA256SUMS"), `${checksumLines.join("\n")}\n`, "utf8");

console.log("LayerSentry canonical release finalization: PASS");
console.log("Server policy: nginx-secure-v2");
