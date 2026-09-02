import { createHash } from "node:crypto";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const sourceDirectory = join(projectRoot, "public");
const outputDirectory = join(projectRoot, "dist");
const requiredAssets = [
  "index.html",
  "assets/favicon.svg",
  "assets/layersentry-mark.svg",
  "assets/layersentry.css",
  "assets/layersentry.js",
];

function normaliseBuildTime() {
  const epoch = Number(process.env.SOURCE_DATE_EPOCH ?? 0);
  if (Number.isSafeInteger(epoch) && epoch > 0) return new Date(epoch * 1000).toISOString();
  return new Date().toISOString();
}

function normaliseCommit() {
  const candidate = String(process.env.GITHUB_SHA ?? process.env.LAYERSENTRY_BUILD_SHA ?? "development").trim();
  return /^[a-f0-9]{40}$/i.test(candidate) ? candidate.toLowerCase() : "development";
}

async function digest(path) {
  const bytes = await readFile(path);
  return {
    bytes: bytes.length,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    integrity: `sha384-${createHash("sha384").update(bytes).digest("base64")}`,
  };
}

await rm(outputDirectory, { recursive: true, force: true });
await mkdir(outputDirectory, { recursive: true });
await cp(sourceDirectory, outputDirectory, { recursive: true, force: true });

const sourcePackage = JSON.parse(await readFile(join(projectRoot, "package.json"), "utf8"));
const metadata = {
  schemaVersion: "1.0",
  product: "LayerSentry",
  component: "production-ui",
  version: sourcePackage.version,
  commit: normaliseCommit(),
  builtAtUtc: normaliseBuildTime(),
  externalRuntimeDependencies: 0,
  credentialStorage: "none",
  apiSessionMode: "same-origin-cookie",
};
await writeFile(join(outputDirectory, "release-metadata.json"), `${JSON.stringify(metadata, null, 2)}\n`, "utf8");

const manifest = {
  schemaVersion: "1.0",
  generatedAtUtc: metadata.builtAtUtc,
  files: {},
};
for (const asset of [...requiredAssets, "release-metadata.json"].sort()) {
  const absolute = join(outputDirectory, asset);
  manifest.files[relative(outputDirectory, absolute).replaceAll("\\", "/")] = await digest(absolute);
}
await writeFile(join(outputDirectory, "asset-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");

const manifestDigest = await digest(join(outputDirectory, "asset-manifest.json"));
await writeFile(
  join(outputDirectory, "SHA256SUMS"),
  [
    `${manifestDigest.sha256}  asset-manifest.json`,
    ...Object.entries(manifest.files).map(([name, details]) => `${details.sha256}  ${name}`),
    "",
  ].join("\n"),
  "utf8",
);

console.log(`LayerSentry production UI built at ${outputDirectory}`);
console.log(`Files: ${Object.keys(manifest.files).length + 2}`);
console.log(`Commit: ${metadata.commit}`);
