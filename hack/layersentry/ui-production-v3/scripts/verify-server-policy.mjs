import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const releaseRoot = join(projectRoot, "release");
const nginx = await readFile(join(releaseRoot, "deploy/nginx.conf"), "utf8");
const metadata = JSON.parse(await readFile(join(releaseRoot, "release-metadata.json"), "utf8"));

const failures = [];
const requireContract = (condition, message) => {
  if (!condition) failures.push(message);
};

const requiredHeaders = [
  "Content-Security-Policy",
  "X-Content-Type-Options",
  "X-Frame-Options",
  "Referrer-Policy",
  "Permissions-Policy",
  "Cross-Origin-Opener-Policy",
  "Cross-Origin-Resource-Policy",
  "X-Permitted-Cross-Domain-Policies",
  "Cache-Control",
];
for (const header of requiredHeaders) {
  const escaped = header.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const matches = nginx.match(new RegExp(`add_header\\s+${escaped}\\b`, "g")) ?? [];
  requireContract(matches.length === 1, `${header} must be declared exactly once at server scope; observed ${matches.length}.`);
}

const locationBlocks = [...nginx.matchAll(/location\s+[^\{]+\{([\s\S]*?)\n\s*\}/g)].map((match) => match[1]);
requireContract(locationBlocks.length >= 5, "Expected static, health, metadata and fallback location blocks.");
for (const block of locationBlocks) {
  requireContract(!/\badd_header\b/.test(block), "Location-level add_header is forbidden because it can suppress inherited security headers.");
}

requireContract(/map \$uri \$cache_control/.test(nginx), "Cache policy must be selected through a URI map.");
requireContract(/~\^\/assets\/ "public, max-age=31536000, immutable";/.test(nginx), "Versioned assets must use immutable one-year caching.");
requireContract(/default "no-store, max-age=0";/.test(nginx), "HTML and metadata must default to no-store.");
requireContract(/~\^text\/html/.test(nginx), "HTML CSP selection must tolerate an appended charset.");
requireContract(/listen 8080 default_server;/.test(nginx), "The server must listen on unprivileged port 8080.");
requireContract(/server_tokens off;/.test(nginx), "Nginx version disclosure must be disabled.");
requireContract(/client_max_body_size 64k;/.test(nginx), "Request bodies must be tightly bounded.");
requireContract(/return 200 "ok\\n";/.test(nginx), "A deterministic health endpoint is required.");
requireContract(metadata.serverPolicy === "nginx-secure-v2", "Release metadata does not bind the canonical server policy.");
requireContract(metadata.serverSecurityHeaderInheritanceReviewed === true, "Release metadata does not record header inheritance review.");
requireContract(metadata.canonicalReleaseFinalized === true, "Release metadata does not record finalization.");

if (failures.length > 0) {
  console.error("LayerSentry server-policy verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exitCode = 1;
} else {
  console.log("LayerSentry server-policy verification: PASS");
  console.log("Security headers are declared once at server scope and inherited by all response locations.");
}
