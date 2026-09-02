import { access, readFile, stat } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const sourceRoot = resolve(projectRoot, "../ui-production-v2");
const publicRoot = join(sourceRoot, "public");

const paths = {
  package: join(projectRoot, "package.json"),
  html: join(publicRoot, "index.html"),
  css: join(publicRoot, "assets/layersentry.css"),
  js: join(publicRoot, "assets/layersentry.js"),
  mark: join(publicRoot, "assets/layersentry-mark.svg"),
  favicon: join(publicRoot, "assets/favicon.svg"),
  nginx: join(sourceRoot, "nginx.conf"),
  build: join(projectRoot, "scripts/build.mjs"),
  verify: join(projectRoot, "scripts/verify-dist.mjs"),
};

const failures = [];
const requireContract = (condition, message) => {
  if (!condition) failures.push(message);
};

for (const [name, path] of Object.entries(paths)) {
  try {
    await access(path, constants.R_OK);
  } catch {
    failures.push(`Required ${name} file is not readable: ${path}`);
  }
}

const [packageText, html, css, js, mark, favicon, nginx, build, verify] = await Promise.all(
  Object.values(paths).map((path) => readFile(path, "utf8")),
);
const packageJson = JSON.parse(packageText);

requireContract(packageJson.private === true, "The UI package must be private.");
requireContract(packageJson.type === "module", "The UI package must use ECMAScript modules.");
requireContract(Object.keys(packageJson.dependencies ?? {}).length === 0, "Runtime npm dependencies are forbidden.");
requireContract(Object.keys(packageJson.devDependencies ?? {}).length === 0, "Development npm dependencies are forbidden.");
requireContract(packageJson.engines?.node === ">=20", "Node.js 20 or newer must be required.");

requireContract(/^<!doctype html>/i.test(html), "HTML5 doctype is required.");
requireContract(/<html\s+lang="en"/i.test(html), "The document language is required.");
requireContract(/href="#main-content"/.test(html), "A keyboard skip link is required.");
requireContract(/<main\s+id="main-content"/.test(html), "A main landmark is required.");
requireContract(/aria-live="polite"/.test(html), "Live regions are required for asynchronous status.");
requireContract(/<noscript>/.test(html), "A no-JavaScript fallback is required.");
requireContract(/Content-Security-Policy/.test(html), "CSP defence in depth is required.");
requireContract(/referrer" content="no-referrer"/.test(html), "The no-referrer policy is required.");
requireContract(!/<script(?![^>]*\bsrc=)/i.test(html), "Inline executable scripts are forbidden.");
requireContract(!/<style[\s>]/i.test(html), "Inline style blocks are forbidden.");
requireContract(!/\son[a-z]+\s*=/i.test(html), "Inline event handlers are forbidden.");
requireContract(!/target="_blank"/i.test(html), "Uncontrolled new-window links are forbidden.");
requireContract(!/>\s*(?:Harvester|Rancher)\s*</i.test(html), "Upstream vendor names are forbidden in user-visible shell text.");

requireContract(/:focus-visible/.test(css), "Visible keyboard focus styling is required.");
requireContract(/prefers-reduced-motion/.test(css), "Reduced-motion support is required.");
requireContract(/prefers-contrast/.test(css), "High-contrast support is required.");
requireContract((css.match(/@media\s*\(max-width:/g) ?? []).length >= 3, "At least three responsive breakpoints are required.");
requireContract(!/@import\s/i.test(css), "CSS @import is forbidden.");
requireContract(!/url\s*\(\s*['\"]?https?:/i.test(css), "External CSS assets are forbidden.");

requireContract(/credentials:\s*"same-origin"/.test(js), "API requests must use same-origin browser sessions.");
requireContract(/cache:\s*"no-store"/.test(js), "Status requests must disable cache reuse.");
requireContract(/redirect:\s*"error"/.test(js), "Status requests must reject redirects.");
requireContract(/AbortController/.test(js), "Bounded request timeouts are required.");
requireContract(/content-type/i.test(js), "Response content type validation is required.");
requireContract(/content-length/i.test(js), "Response size validation is required.");
requireContract(!/\.innerHTML\s*=/.test(js), "innerHTML assignment is forbidden.");
requireContract(!/insertAdjacentHTML/.test(js), "insertAdjacentHTML is forbidden.");
requireContract(!/document\.write\s*\(/.test(js), "document.write is forbidden.");
requireContract(!/\beval\s*\(/.test(js), "eval is forbidden.");
requireContract(!/new\s+Function\s*\(/.test(js), "The Function constructor is forbidden.");
requireContract(!/sessionStorage/.test(js), "Session storage is forbidden.");
requireContract(!/authorization\s*:/i.test(js), "The frontend must not construct Authorization headers.");
requireContract(!/bearer\s+/i.test(js), "Bearer tokens must not be embedded in frontend source.");

for (const [name, source] of Object.entries({ html, css, js })) {
  requireContract(!/https?:\/\//i.test(source), `${name} contains an external URL.`);
  requireContract(!/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(source), `${name} contains private-key material.`);
  requireContract(!/(?:password|passwd|secret|token)\s*[:=]\s*["'][^"']{4,}["']/i.test(source), `${name} appears to contain a hard-coded credential.`);
}

for (const [name, source] of Object.entries({ mark, favicon })) {
  requireContract(/^<svg\s/i.test(source.trim()), `${name} must be an SVG document.`);
  requireContract(!/<script[\s>]/i.test(source), `${name} must not contain scripts.`);
  requireContract(!/<foreignObject[\s>]/i.test(source), `${name} must not contain foreignObject.`);
  requireContract(!/\son[a-z]+\s*=/i.test(source), `${name} must not contain event handlers.`);
  requireContract(!/(?:href|xlink:href)="https?:/i.test(source), `${name} must not reference external assets.`);
}

requireContract(/listen 8080 default_server;/.test(nginx), "Nginx must listen on an unprivileged port.");
requireContract(/server_tokens off;/.test(nginx), "Nginx version disclosure must be disabled.");
requireContract(/Content-Security-Policy/.test(nginx), "Nginx must emit a CSP header.");
requireContract(/X-Content-Type-Options "nosniff"/.test(nginx), "Nginx must emit nosniff.");
requireContract(/Referrer-Policy "no-referrer"/.test(nginx), "Nginx must emit no-referrer.");
requireContract(/Permissions-Policy/.test(nginx), "Nginx must emit a restrictive permissions policy.");
requireContract(/Cache-Control "public, max-age=31536000, immutable"/.test(nginx), "Static assets must use immutable caching.");
requireContract(/Cache-Control "no-store, max-age=0"/.test(nginx), "HTML and metadata must use no-store.");

requireContract(/Canonical mobile grid placement/.test(build), "The canonical assembler must merge the mobile grid correction.");
requireContract(/ui-production-v2/.test(build), "The canonical assembler must bind its reviewed source package.");
requireContract(/sbom\.spdx\.json/.test(build), "The release must generate an SPDX SBOM.");
requireContract(/SHA256SUMS/.test(build), "The release must generate SHA-256 checksums.");
requireContract(/externalRuntimeDependencies:\s*0/.test(build), "The release metadata must declare zero external runtime dependencies.");
requireContract(/productionReleaseApprovalImplied:\s*false/.test(build), "The build must not imply production release approval.");
requireContract(/asset-manifest\.json/.test(verify), "Distribution verification must validate the asset manifest.");
requireContract(/SHA256SUMS/.test(verify), "Distribution verification must validate checksums.");

const budgets = {
  html: 40 * 1024,
  css: 48 * 1024,
  js: 52 * 1024,
  mark: 8 * 1024,
  favicon: 4 * 1024,
  nginx: 12 * 1024,
};
for (const [name, limit] of Object.entries(budgets)) {
  const details = await stat(paths[name]);
  requireContract(details.size <= limit, `${name} exceeds its production size budget (${details.size} > ${limit} bytes).`);
}

if (failures.length > 0) {
  console.error("LayerSentry production UI v3 source validation failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log("LayerSentry production UI v3 source validation: PASS");
  console.log("Security, accessibility, branding, server-policy and air-gap contracts passed.");
}
