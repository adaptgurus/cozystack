import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(testDirectory, "..");
const publicRoot = join(projectRoot, "public");
const html = await readFile(join(publicRoot, "index.html"), "utf8");
const css = await readFile(join(publicRoot, "assets", "layersentry.css"), "utf8");
const js = await readFile(join(publicRoot, "assets", "layersentry.js"), "utf8");
const mark = await readFile(join(publicRoot, "assets", "layersentry-mark.svg"), "utf8");

function count(pattern, source) {
  return [...source.matchAll(pattern)].length;
}

test("renders only LayerSentry product branding in the shell", () => {
  assert.match(html, /<title>LayerSentry<\/title>/);
  assert.match(html, />LayerSentry</);
  assert.doesNotMatch(html, />\s*(?:Harvester|Rancher)\s*</i);
});

test("uses a semantic, keyboard-accessible document structure", () => {
  assert.match(html, /<header\b/);
  assert.match(html, /<nav\b/);
  assert.match(html, /<main\b/);
  assert.match(html, /<footer\b/);
  assert.match(html, /<table\b/);
  assert.match(html, /<th scope="col">/);
  assert.match(html, /class="skip-link"/);
  assert.equal(count(/\saria-live=/g, html) >= 2, true);
  assert.equal(count(/<h1\b/g, html), 1);
});

test("keeps executable code and styles external to the HTML document", () => {
  assert.equal(count(/<script\b/g, html), 1);
  assert.match(html, /<script type="module" src="assets\/layersentry\.js"><\/script>/);
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)/);
  assert.doesNotMatch(html, /<style\b/);
  assert.doesNotMatch(html, /\son[a-z]+=/i);
});

test("defines strict browser security policy and same-origin assets", () => {
  assert.match(html, /default-src 'self'/);
  assert.match(html, /object-src 'none'/);
  assert.match(html, /script-src 'self'/);
  assert.match(html, /connect-src 'self'/);
  assert.match(html, /frame-ancestors 'none'/);
  assert.doesNotMatch(html, /https?:\/\//i);
  assert.doesNotMatch(css, /https?:\/\//i);
  assert.doesNotMatch(js, /https?:\/\//i);
});

test("does not retain authentication material in browser storage", () => {
  assert.doesNotMatch(js, /sessionStorage/);
  assert.doesNotMatch(js, /Authorization\s*:/i);
  assert.doesNotMatch(js, /Bearer\s+/i);
  assert.doesNotMatch(js, /(?:password|passwd|secret|token)\s*[:=]\s*["'][^"']+["']/i);
  const localStorageKeys = [...js.matchAll(/localStorage\.(?:getItem|setItem)\("([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual([...new Set(localStorageKeys)], ["layersentry-ui-theme"]);
});

test("bounds and validates all live overview requests", () => {
  assert.match(js, /new AbortController\(\)/);
  assert.match(js, /credentials: "same-origin"/);
  assert.match(js, /cache: "no-store"/);
  assert.match(js, /redirect: "error"/);
  assert.match(js, /content-type/);
  assert.match(js, /content-length/);
  assert.match(js, /1_000_000/);
  assert.match(js, /MAX_EVENTS = 8/);
  assert.match(js, /MAX_NODES = 64/);
});

test("uses safe DOM construction for untrusted platform data", () => {
  assert.doesNotMatch(js, /\.innerHTML\s*=/);
  assert.doesNotMatch(js, /insertAdjacentHTML/);
  assert.doesNotMatch(js, /document\.write/);
  assert.doesNotMatch(js, /\beval\s*\(/);
  assert.match(js, /\.textContent =/);
  assert.match(js, /document\.createElement/);
});

test("supports responsive, reduced-motion and high-contrast operation", () => {
  assert.equal(count(/@media \(max-width:/g, css) >= 3, true);
  assert.match(css, /prefers-reduced-motion: reduce/);
  assert.match(css, /prefers-contrast: more/);
  assert.match(css, /:focus-visible/);
  assert.match(css, /min-width: 320px/);
});

test("ships an original self-contained vector brand mark", () => {
  assert.match(mark, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
  assert.match(mark, /<title id="title">LayerSentry<\/title>/);
  assert.doesNotMatch(mark, /<script\b/i);
  assert.doesNotMatch(mark, /<foreignObject\b/i);
  assert.doesNotMatch(mark, /(?:href|xlink:href)="https?:/i);
});
