import { access, readFile, stat } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const publicRoot = join(projectRoot, "public");

const files = {
  html: join(publicRoot, "index.html"),
  css: join(publicRoot, "assets", "layersentry.css"),
  js: join(publicRoot, "assets", "layersentry.js"),
  mark: join(publicRoot, "assets", "layersentry-mark.svg"),
  favicon: join(publicRoot, "assets", "favicon.svg"),
};

const failures = [];
function requireContract(condition, message) {
  if (!condition) failures.push(message);
}

for (const [name, path] of Object.entries(files)) {
  try {
    await access(path, constants.R_OK);
  } catch {
    failures.push(`Required ${name} file is not readable: ${path}`);
  }
}

const [html, css, js, mark, favicon] = await Promise.all(
  Object.values(files).map((path) => readFile(path, "utf8")),
);

requireContract(/^<!doctype html>/i.test(html), "index.html must declare an HTML5 doctype.");
requireContract(/<html\s+lang="en"/i.test(html), "index.html must define the document language.");
requireContract(/href="#main-content"/.test(html), "A keyboard skip link to main-content is required.");
requireContract(/<main\s+id="main-content"/.test(html), "A named main landmark is required.");
requireContract(/aria-live="polite"/.test(html), "A polite live region is required for status changes.");
requireContract(/<noscript>/.test(html), "A no-JavaScript fallback is required.");
requireContract(/Content-Security-Policy/.test(html), "A restrictive CSP meta policy is required as defence in depth.");
requireContract(/referrer" content="no-referrer"/.test(html), "The no-referrer policy is required.");
requireContract(!/<script(?![^>]*\bsrc=)/i.test(html), "Inline executable scripts are forbidden.");
requireContract(!/<style[\s>]/i.test(html), "Inline style blocks are forbidden.");
requireContract(!/\son[a-z]+\s*=/i.test(html), "Inline event handlers are forbidden.");
requireContract(!/target="_blank"/i.test(html), "Uncontrolled new-window links are forbidden.");

requireContract(/:focus-visible/.test(css), "Visible keyboard focus styling is required.");
requireContract(/prefers-reduced-motion/.test(css), "Reduced-motion support is required.");
requireContract(/prefers-contrast/.test(css), "High-contrast preference support is required.");
requireContract((css.match(/@media\s*\(max-width:/g) ?? []).length >= 3, "At least three responsive breakpoints are required.");
requireContract(!/@import\s/i.test(css), "CSS @import is forbidden for deterministic air-gap operation.");
requireContract(!/url\s*\(\s*['\"]?https?:/i.test(css), "External CSS assets are forbidden.");

requireContract(/credentials:\s*"same-origin"/.test(js), "API requests must use the same-origin browser session.");
requireContract(/cache:\s*"no-store"/.test(js), "Status requests must disable HTTP cache reuse.");
requireContract(/redirect:\s*"error"/.test(js), "Status requests must reject redirects.");
requireContract(/AbortController/.test(js), "API requests require a bounded timeout with AbortController.");
requireContract(/content-type/i.test(js), "The response content type must be validated.");
requireContract(/content-length/i.test(js), "The response size must be bounded.");
requireContract(!/\.innerHTML\s*=/.test(js), "innerHTML assignment is forbidden.");
requireContract(!/document\.write\s*\(/.test(js), "document.write is forbidden.");
requireContract(!/\beval\s*\(/.test(js), "eval is forbidden.");
requireContract(!/new\s+Function\s*\(/.test(js), "The Function constructor is forbidden.");
requireContract(!/sessionStorage/.test(js), "Session storage is forbidden for the UI runtime.");
requireContract(!/localStorage\.(?:setItem|getItem)\((?!"layersentry-ui-theme")/.test(js), "Local storage may only contain the non-sensitive theme preference.");
requireContract(!/authorization\s*:/i.test(js), "The frontend must not construct Authorization headers.");
requireContract(!/bearer\s+/i.test(js), "Bearer tokens must not be embedded in frontend source.");

for (const [name, source] of Object.entries({ html, css, js })) {
  requireContract(!/https?:\/\//i.test(source), `${name} contains an external URL and is not air-gap deterministic.`);
  requireContract(!/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(source), `${name} contains private-key material.`);
  requireContract(!/(?:password|passwd|secret|token)\s*[:=]\s*["'][^"']{4,}["']/i.test(source), `${name} appears to contain a hard-coded credential.`);
}

for (const [name, source] of Object.entries({ mark, favicon })) {
  requireContract(/^<svg\s/i.test(source.trim()), `${name} must be an SVG document.`);
  requireContract(!/<script[\s>]/i.test(source), `${name} must not contain scripts.`);
  requireContract(!/<foreignObject[\s>]/i.test(source), `${name} must not contain foreignObject.`);
  requireContract(!/\son[a-z]+\s*=/i.test(source), `${name} must not contain event handlers.`);
  requireContract(!/(?:href|xlink:href)="https?:/i.test(source), `${name} must not reference external resources.`);
}

const budgets = {
  html: 40 * 1024,
  css: 45 * 1024,
  js: 50 * 1024,
  mark: 8 * 1024,
  favicon: 4 * 1024,
};
for (const [name, path] of Object.entries(files)) {
  const details = await stat(path);
  requireContract(details.size <= budgets[name], `${name} exceeds its production size budget (${details.size} > ${budgets[name]} bytes).`);
}

if (failures.length > 0) {
  console.error("LayerSentry production UI validation failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log("LayerSentry production UI validation: PASS");
  console.log("Security, accessibility, responsive, size-budget and air-gap contracts passed.");
}
