const DEFAULT_CONFIG = Object.freeze({
  productName: "LayerSentry",
  environment: "Local",
  overviewEndpoint: "/v1/layersentry/ui/overview",
  consolePath: "/dashboard",
  refreshIntervalMs: 30000,
  requestTimeoutMs: 8000,
  buildVersion: "v1.0.0",
});

const HEALTH_STATES = new Set(["healthy", "degraded", "critical", "unknown"]);
const NODE_STATES = new Set(["ready", "warning", "not-ready", "unknown"]);
const EVENT_SEVERITIES = new Set(["info", "warning", "critical"]);
const MAX_EVENTS = 8;
const MAX_NODES = 64;

function readRuntimeConfig() {
  const supplied = globalThis.__LAYERSENTRY_UI_CONFIG__;
  if (!supplied || typeof supplied !== "object" || Array.isArray(supplied)) {
    return { ...DEFAULT_CONFIG };
  }

  const config = { ...DEFAULT_CONFIG };
  if (isSafeLabel(supplied.productName, 64)) config.productName = supplied.productName.trim();
  if (isSafeLabel(supplied.environment, 32)) config.environment = supplied.environment.trim();
  if (isSameOriginPath(supplied.overviewEndpoint)) config.overviewEndpoint = supplied.overviewEndpoint;
  if (isSameOriginPath(supplied.consolePath)) config.consolePath = supplied.consolePath;
  if (isBoundedInteger(supplied.refreshIntervalMs, 10000, 300000)) config.refreshIntervalMs = supplied.refreshIntervalMs;
  if (isBoundedInteger(supplied.requestTimeoutMs, 2000, 30000)) config.requestTimeoutMs = supplied.requestTimeoutMs;
  if (isSafeLabel(supplied.buildVersion, 48)) config.buildVersion = supplied.buildVersion.trim();
  return config;
}

function isSafeLabel(value, maximumLength) {
  return typeof value === "string" && value.trim().length > 0 && value.trim().length <= maximumLength;
}

function isSameOriginPath(value) {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) return false;
  try {
    const parsed = new URL(value, globalThis.location.origin);
    return parsed.origin === globalThis.location.origin;
  } catch {
    return false;
  }
}

function isBoundedInteger(value, minimum, maximum) {
  return Number.isInteger(value) && value >= minimum && value <= maximum;
}

const config = readRuntimeConfig();
const elements = {};
let refreshTimer = null;
let inFlightController = null;
let lastSuccessfulPayload = null;
let consecutiveFailures = 0;

function getRequiredElement(id) {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Required UI element is missing: ${id}`);
  return element;
}

function cacheElements() {
  for (const id of [
    "alerts-detail", "alerts-state", "alerts-value", "build-version", "cluster-health",
    "connection-state", "console-link", "environment-badge", "events-body", "footer-status",
    "last-updated", "node-list", "nodes-detail", "nodes-state", "nodes-value", "notice-detail",
    "notice-title", "platform-notice", "refresh-button", "retry-button", "storage-detail",
    "storage-state", "storage-value", "theme-button", "vms-detail", "vms-state", "vms-value",
  ]) {
    elements[id] = getRequiredElement(id);
  }
}

function initialiseStaticContent() {
  document.title = config.productName;
  elements["environment-badge"].textContent = config.environment;
  elements["build-version"].textContent = config.buildVersion;
  elements["console-link"].href = config.consolePath;

  const storedTheme = readStoredTheme();
  const preferredTheme = globalThis.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark";
  applyTheme(storedTheme ?? preferredTheme);
}

function readStoredTheme() {
  try {
    const value = globalThis.localStorage.getItem("layersentry-ui-theme");
    return value === "light" || value === "dark" ? value : null;
  } catch {
    return null;
  }
}

function applyTheme(theme) {
  const acceptedTheme = theme === "light" ? "light" : "dark";
  document.documentElement.dataset.theme = acceptedTheme;
  const nextTheme = acceptedTheme === "dark" ? "light" : "dark";
  elements["theme-button"].setAttribute("aria-label", `Switch to ${nextTheme} theme`);
  elements["theme-button"].setAttribute("title", `Switch to ${nextTheme} theme`);
}

function toggleTheme() {
  const current = document.documentElement.dataset.theme === "light" ? "light" : "dark";
  const next = current === "dark" ? "light" : "dark";
  applyTheme(next);
  try {
    globalThis.localStorage.setItem("layersentry-ui-theme", next);
  } catch {
    // Theme persistence is optional and contains no session or credential data.
  }
}

function bindEvents() {
  elements["refresh-button"].addEventListener("click", () => void refreshOverview({ userInitiated: true }));
  elements["retry-button"].addEventListener("click", () => void refreshOverview({ userInitiated: true }));
  elements["theme-button"].addEventListener("click", toggleTheme);

  globalThis.addEventListener("online", () => void refreshOverview({ userInitiated: false }));
  globalThis.addEventListener("offline", renderOfflineState);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void refreshOverview({ userInitiated: false });
  });
}

function scheduleRefresh() {
  if (refreshTimer) globalThis.clearInterval(refreshTimer);
  refreshTimer = globalThis.setInterval(() => {
    if (document.visibilityState === "visible" && navigator.onLine) {
      void refreshOverview({ userInitiated: false });
    }
  }, config.refreshIntervalMs);
}

async function requestJson(path) {
  if (inFlightController) inFlightController.abort();
  const controller = new AbortController();
  inFlightController = controller;
  const timeout = globalThis.setTimeout(() => controller.abort("request-timeout"), config.requestTimeoutMs);

  try {
    const response = await fetch(path, {
      method: "GET",
      credentials: "same-origin",
      cache: "no-store",
      redirect: "error",
      headers: {
        Accept: "application/json",
        "X-LayerSentry-UI": "overview-v1",
      },
      signal: controller.signal,
    });

    if (response.status === 401 || response.status === 403) {
      throw new UiRequestError("authentication-required", response.status, "Authentication is required.");
    }
    if (response.status === 404) {
      throw new UiRequestError("endpoint-unavailable", response.status, "The overview API is not installed.");
    }
    if (!response.ok) {
      throw new UiRequestError("upstream-error", response.status, `The overview API returned HTTP ${response.status}.`);
    }

    const contentType = response.headers.get("content-type") ?? "";
    if (!contentType.toLowerCase().includes("application/json")) {
      throw new UiRequestError("invalid-content-type", response.status, "The overview API did not return JSON.");
    }

    const contentLength = Number(response.headers.get("content-length") ?? 0);
    if (Number.isFinite(contentLength) && contentLength > 1_000_000) {
      throw new UiRequestError("payload-too-large", response.status, "The overview response exceeded the UI limit.");
    }

    return await response.json();
  } catch (error) {
    if (error instanceof UiRequestError) throw error;
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new UiRequestError("timeout", 0, "The overview request timed out.");
    }
    throw new UiRequestError("network-error", 0, "The overview API could not be reached.");
  } finally {
    globalThis.clearTimeout(timeout);
    if (inFlightController === controller) inFlightController = null;
  }
}

class UiRequestError extends Error {
  constructor(code, status, message) {
    super(message);
    this.name = "UiRequestError";
    this.code = code;
    this.status = status;
  }
}

function normalisePayload(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new UiRequestError("invalid-schema", 0, "The overview response is not an object.");
  }

  const health = HEALTH_STATES.has(input.health) ? input.health : "unknown";
  const environment = isSafeLabel(input.environment, 32) ? input.environment.trim() : config.environment;
  const version = isSafeLabel(input.version, 48) ? input.version.trim() : config.buildVersion;

  const nodeSource = input.nodes && typeof input.nodes === "object" ? input.nodes : {};
  const nodeItems = Array.isArray(nodeSource.items) ? nodeSource.items.slice(0, MAX_NODES).map(normaliseNode) : [];
  const nodeTotal = safeNonNegativeInteger(nodeSource.total, nodeItems.length);
  const nodeReady = safeNonNegativeInteger(
    nodeSource.ready,
    nodeItems.filter((node) => node.state === "ready").length,
  );

  const vmSource = input.virtualMachines && typeof input.virtualMachines === "object" ? input.virtualMachines : {};
  const vmTotal = safeNonNegativeInteger(vmSource.total, 0);
  const vmRunning = Math.min(safeNonNegativeInteger(vmSource.running, 0), vmTotal);

  const storageSource = input.storage && typeof input.storage === "object" ? input.storage : {};
  const storageTotal = safeNonNegativeNumber(storageSource.totalBytes, 0);
  const storageUsed = Math.min(safeNonNegativeNumber(storageSource.usedBytes, 0), storageTotal || Number.MAX_SAFE_INTEGER);
  const volumeTotal = safeNonNegativeInteger(storageSource.totalVolumes, 0);
  const volumeHealthy = Math.min(safeNonNegativeInteger(storageSource.healthyVolumes, 0), volumeTotal);

  const alertSource = input.alerts && typeof input.alerts === "object" ? input.alerts : {};
  const criticalAlerts = safeNonNegativeInteger(alertSource.critical, 0);
  const warningAlerts = safeNonNegativeInteger(alertSource.warning, 0);
  const totalAlerts = Math.max(safeNonNegativeInteger(alertSource.total, criticalAlerts + warningAlerts), criticalAlerts + warningAlerts);

  const events = Array.isArray(input.events) ? input.events.slice(0, MAX_EVENTS).map(normaliseEvent) : [];

  return {
    health,
    environment,
    version,
    nodes: { ready: Math.min(nodeReady, nodeTotal), total: nodeTotal, items: nodeItems },
    virtualMachines: { running: vmRunning, total: vmTotal },
    storage: {
      usedBytes: storageUsed,
      totalBytes: storageTotal,
      healthyVolumes: volumeHealthy,
      totalVolumes: volumeTotal,
    },
    alerts: { critical: criticalAlerts, warning: warningAlerts, total: totalAlerts },
    events,
    observedAt: normaliseTimestamp(input.observedAt) ?? new Date().toISOString(),
  };
}

function normaliseNode(input, index) {
  const source = input && typeof input === "object" ? input : {};
  const name = isSafeLabel(source.name, 63) ? source.name.trim() : `node-${index + 1}`;
  const address = isSafeLabel(source.address, 96) ? source.address.trim() : "Address unavailable";
  const role = isSafeLabel(source.role, 48) ? source.role.trim() : "Worker";
  const state = NODE_STATES.has(source.state) ? source.state : "unknown";
  const cpuPercent = safePercentage(source.cpuPercent);
  const memoryPercent = safePercentage(source.memoryPercent);
  return { name, address, role, state, cpuPercent, memoryPercent };
}

function normaliseEvent(input) {
  const source = input && typeof input === "object" ? input : {};
  return {
    severity: EVENT_SEVERITIES.has(source.severity) ? source.severity : "info",
    resource: isSafeLabel(source.resource, 96) ? source.resource.trim() : "Platform",
    message: isSafeLabel(source.message, 512) ? source.message.trim() : "No event detail was supplied.",
    timestamp: normaliseTimestamp(source.timestamp),
  };
}

function safeNonNegativeInteger(value, fallback) {
  return Number.isSafeInteger(value) && value >= 0 ? value : fallback;
}

function safeNonNegativeNumber(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : fallback;
}

function safePercentage(value) {
  return typeof value === "number" && Number.isFinite(value) ? Math.min(100, Math.max(0, Math.round(value))) : null;
}

function normaliseTimestamp(value) {
  if (typeof value !== "string" || value.length > 64) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

async function refreshOverview({ userInitiated }) {
  if (!navigator.onLine) {
    renderOfflineState();
    return;
  }

  setRefreshBusy(true);
  if (!lastSuccessfulPayload || userInitiated) renderLoadingState();

  try {
    const raw = await requestJson(config.overviewEndpoint);
    const payload = normalisePayload(raw);
    lastSuccessfulPayload = payload;
    consecutiveFailures = 0;
    renderPayload(payload);
  } catch (error) {
    consecutiveFailures += 1;
    renderRequestFailure(error);
  } finally {
    setRefreshBusy(false);
  }
}

function setRefreshBusy(busy) {
  elements["refresh-button"].disabled = busy;
  elements["refresh-button"].setAttribute("aria-busy", String(busy));
}

function renderLoadingState() {
  document.querySelector(".app-shell")?.setAttribute("data-ui-state", "loading");
  setConnectionState("degraded", "Connecting");
  setNotice("loading", "Connecting to LayerSentry", "Securely requesting current platform health.", false);
}

function renderOfflineState() {
  document.querySelector(".app-shell")?.setAttribute("data-ui-state", "offline");
  setConnectionState("unavailable", "Offline");
  setNotice("warning", "This browser is offline", "Reconnect the workstation network, then retry platform status.", true);
  elements["footer-status"].textContent = "Browser network unavailable";
}

function renderRequestFailure(error) {
  const failure = error instanceof UiRequestError ? error : new UiRequestError("unknown", 0, "Unexpected UI error.");
  document.querySelector(".app-shell")?.setAttribute("data-ui-state", "error");

  if (lastSuccessfulPayload) {
    setConnectionState("degraded", "Stale data");
    setNotice(
      "warning",
      "Live status is temporarily unavailable",
      `Showing the last verified response. ${humanFailureDetail(failure)}`,
      true,
    );
    elements["footer-status"].textContent = `Last refresh failed (${consecutiveFailures})`;
    return;
  }

  setConnectionState("unavailable", failure.code === "authentication-required" ? "Sign-in required" : "Unavailable");
  setNotice(
    failure.code === "authentication-required" ? "warning" : "danger",
    failureTitle(failure),
    humanFailureDetail(failure),
    true,
  );
  elements["last-updated"].textContent = "No verified platform response";
  elements["footer-status"].textContent = "No platform data cached";
  renderUnavailableMetrics();
}

function failureTitle(error) {
  switch (error.code) {
    case "authentication-required": return "Sign in to view platform status";
    case "endpoint-unavailable": return "Overview service is not installed";
    case "timeout": return "Platform response timed out";
    case "invalid-schema":
    case "invalid-content-type":
    case "payload-too-large": return "Overview response was rejected";
    default: return "LayerSentry status is unavailable";
  }
}

function humanFailureDetail(error) {
  switch (error.code) {
    case "authentication-required": return "Open the management console and complete the secure sign-in flow.";
    case "endpoint-unavailable": return "Deploy the LayerSentry overview API adapter before enabling this page for operators.";
    case "timeout": return "The platform did not respond within the configured safety timeout.";
    case "invalid-schema": return "The service returned data that did not match the LayerSentry UI contract.";
    case "invalid-content-type": return "The service returned an unexpected content type.";
    case "payload-too-large": return "The service returned more data than the UI safety limit permits.";
    case "upstream-error": return error.status ? `The platform returned HTTP ${error.status}.` : "The upstream platform returned an error.";
    default: return "Check same-origin routing and management API availability, then retry.";
  }
}

function renderUnavailableMetrics() {
  for (const prefix of ["nodes", "vms", "storage", "alerts"]) {
    elements[`${prefix}-value`].textContent = "—";
    elements[`${prefix}-state`].textContent = "Unavailable";
    elements[`${prefix}-state`].dataset.state = "critical";
  }
  elements["nodes-detail"].textContent = "No verified cluster inventory";
  elements["vms-detail"].textContent = "No verified compute inventory";
  elements["storage-detail"].textContent = "No verified capacity information";
  elements["alerts-detail"].textContent = "No verified alert status";
  elements["cluster-health"].textContent = "Unavailable";
  elements["cluster-health"].dataset.state = "unavailable";
  elements["node-list"].setAttribute("aria-busy", "false");
  elements["node-list"].replaceChildren(createEmptyState("Node inventory is unavailable."));
  elements["events-body"].replaceChildren(createEmptyTableRow("Event data is unavailable."));
}

function renderPayload(payload) {
  document.querySelector(".app-shell")?.setAttribute("data-ui-state", "ready");
  elements["environment-badge"].textContent = payload.environment;
  elements["build-version"].textContent = payload.version;

  const connectionState = payload.health === "healthy" ? "healthy" : payload.health === "critical" ? "unavailable" : "degraded";
  setConnectionState(connectionState, healthLabel(payload.health));
  setNoticeForHealth(payload.health);
  renderMetrics(payload);
  renderNodes(payload.nodes, payload.health);
  renderEvents(payload.events);

  const observedDate = new Date(payload.observedAt);
  elements["last-updated"].textContent = `Updated ${formatRelativeTime(observedDate)}`;
  elements["last-updated"].title = observedDate.toLocaleString();
  elements["footer-status"].textContent = "Secure same-origin status verified";
}

function healthLabel(health) {
  switch (health) {
    case "healthy": return "Operational";
    case "degraded": return "Degraded";
    case "critical": return "Critical";
    default: return "Unknown";
  }
}

function setNoticeForHealth(health) {
  if (health === "healthy") {
    setNotice("success", "Platform services are operational", "Compute, storage, networking and cluster status were retrieved successfully.", false);
  } else if (health === "degraded") {
    setNotice("warning", "Platform attention is required", "One or more infrastructure services reported a degraded condition.", false);
  } else if (health === "critical") {
    setNotice("danger", "Critical platform condition detected", "Review active alerts and node health before starting new workloads.", false);
  } else {
    setNotice("warning", "Platform health is unknown", "The overview service did not provide a recognised aggregate health state.", false);
  }
}

function setNotice(type, title, detail, showRetry) {
  elements["platform-notice"].className = `notice notice--${type}`;
  const icon = elements["platform-notice"].querySelector(".notice__icon");
  if (icon) icon.classList.toggle("loading-spinner", type === "loading");
  elements["notice-title"].textContent = title;
  elements["notice-detail"].textContent = detail;
  elements["retry-button"].hidden = !showRetry;
}

function setConnectionState(state, label) {
  elements["connection-state"].dataset.state = state;
  const labelElement = elements["connection-state"].querySelector("span:last-child");
  if (labelElement) labelElement.textContent = label;
}

function renderMetrics(payload) {
  const { nodes, virtualMachines, storage, alerts } = payload;
  setMetric(
    "nodes",
    String(nodes.total),
    nodes.ready === nodes.total && nodes.total > 0 ? "Healthy" : `${nodes.ready} ready`,
    nodes.ready === nodes.total && nodes.total > 0 ? "healthy" : nodes.ready > 0 ? "warning" : "critical",
    `${nodes.ready} of ${nodes.total} nodes Ready`,
  );

  setMetric(
    "vms",
    String(virtualMachines.total),
    virtualMachines.running === virtualMachines.total ? "Running" : "Attention",
    virtualMachines.total === 0 || virtualMachines.running === virtualMachines.total ? "healthy" : "warning",
    `${virtualMachines.running} of ${virtualMachines.total} powered on`,
  );

  const usagePercent = storage.totalBytes > 0 ? Math.round((storage.usedBytes / storage.totalBytes) * 100) : 0;
  setMetric(
    "storage",
    storage.totalBytes > 0 ? `${usagePercent}%` : "—",
    usagePercent >= 90 ? "Critical" : usagePercent >= 75 ? "Watch" : "Healthy",
    usagePercent >= 90 ? "critical" : usagePercent >= 75 ? "warning" : "healthy",
    storage.totalBytes > 0
      ? `${formatBytes(storage.usedBytes)} of ${formatBytes(storage.totalBytes)} used; ${storage.healthyVolumes}/${storage.totalVolumes} volumes healthy`
      : `${storage.healthyVolumes}/${storage.totalVolumes} volumes healthy`,
  );

  setMetric(
    "alerts",
    String(alerts.total),
    alerts.critical > 0 ? "Critical" : alerts.warning > 0 ? "Warning" : "Clear",
    alerts.critical > 0 ? "critical" : alerts.warning > 0 ? "warning" : "healthy",
    `${alerts.critical} critical and ${alerts.warning} warning`,
  );
}

function setMetric(prefix, value, stateLabel, state, detail) {
  elements[`${prefix}-value`].textContent = value;
  elements[`${prefix}-state`].textContent = stateLabel;
  elements[`${prefix}-state`].dataset.state = state;
  elements[`${prefix}-detail`].textContent = detail;
}

function renderNodes(nodes, aggregateHealth) {
  elements["cluster-health"].textContent = healthLabel(aggregateHealth);
  elements["cluster-health"].dataset.state = aggregateHealth === "healthy" ? "healthy" : aggregateHealth === "critical" ? "unavailable" : "degraded";
  elements["node-list"].setAttribute("aria-busy", "false");

  if (nodes.items.length === 0) {
    elements["node-list"].replaceChildren(createEmptyState("No node details were returned by the overview service."));
    return;
  }

  const fragment = document.createDocumentFragment();
  for (const node of nodes.items) fragment.append(createNodeRow(node));
  elements["node-list"].replaceChildren(fragment);
}

function createNodeRow(node) {
  const row = document.createElement("div");
  row.className = "node-row";
  row.dataset.state = node.state === "ready" ? "healthy" : node.state === "warning" ? "warning" : "critical";

  const name = document.createElement("div");
  name.className = "node-row__name";
  name.textContent = node.name;

  const address = document.createElement("div");
  address.className = "node-row__meta";
  address.textContent = node.address;

  const utilisation = document.createElement("div");
  utilisation.className = "node-row__meta";
  const cpu = node.cpuPercent === null ? "CPU —" : `CPU ${node.cpuPercent}%`;
  const memory = node.memoryPercent === null ? "RAM —" : `RAM ${node.memoryPercent}%`;
  utilisation.textContent = `${cpu} · ${memory}`;

  const status = document.createElement("div");
  status.className = "node-row__status";
  status.textContent = `${node.role} · ${nodeStateLabel(node.state)}`;

  row.append(name, address, utilisation, status);
  return row;
}

function nodeStateLabel(state) {
  switch (state) {
    case "ready": return "Ready";
    case "warning": return "Warning";
    case "not-ready": return "Not Ready";
    default: return "Unknown";
  }
}

function createEmptyState(message) {
  const element = document.createElement("p");
  element.className = "empty-state";
  element.textContent = message;
  return element;
}

function renderEvents(events) {
  if (events.length === 0) {
    elements["events-body"].replaceChildren(createEmptyTableRow("No recent platform events were returned."));
    return;
  }

  const fragment = document.createDocumentFragment();
  for (const event of events) {
    const row = document.createElement("tr");

    const severityCell = document.createElement("td");
    const severity = document.createElement("span");
    severity.className = "event-severity";
    severity.dataset.severity = event.severity;
    severity.textContent = event.severity;
    severityCell.append(severity);

    const resourceCell = document.createElement("td");
    resourceCell.textContent = event.resource;

    const messageCell = document.createElement("td");
    messageCell.textContent = event.message;

    const timeCell = document.createElement("td");
    if (event.timestamp) {
      const date = new Date(event.timestamp);
      timeCell.textContent = formatRelativeTime(date);
      timeCell.title = date.toLocaleString();
    } else {
      timeCell.textContent = "Time unavailable";
    }

    row.append(severityCell, resourceCell, messageCell, timeCell);
    fragment.append(row);
  }
  elements["events-body"].replaceChildren(fragment);
}

function createEmptyTableRow(message) {
  const row = document.createElement("tr");
  row.className = "empty-row";
  const cell = document.createElement("td");
  cell.colSpan = 4;
  cell.textContent = message;
  row.append(cell);
  return row;
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / 1024 ** exponent;
  return `${new Intl.NumberFormat(undefined, { maximumFractionDigits: value >= 100 ? 0 : 1 }).format(value)} ${units[exponent]}`;
}

function formatRelativeTime(date) {
  const deltaSeconds = Math.round((date.getTime() - Date.now()) / 1000);
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const absolute = Math.abs(deltaSeconds);
  if (absolute < 60) return formatter.format(deltaSeconds, "second");
  if (absolute < 3600) return formatter.format(Math.round(deltaSeconds / 60), "minute");
  if (absolute < 86400) return formatter.format(Math.round(deltaSeconds / 3600), "hour");
  return formatter.format(Math.round(deltaSeconds / 86400), "day");
}

function start() {
  try {
    cacheElements();
    initialiseStaticContent();
    bindEvents();
    scheduleRefresh();
    void refreshOverview({ userInitiated: false });
  } catch {
    document.documentElement.dataset.uiFatal = "true";
    const fallback = document.createElement("p");
    fallback.className = "noscript-message";
    fallback.textContent = "LayerSentry could not initialise the management overview. Open the management console directly or contact the platform administrator.";
    document.body.append(fallback);
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start, { once: true });
} else {
  start();
}
