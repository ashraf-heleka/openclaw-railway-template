const express = require("express");
const http = require("http");
const httpProxy = require("http-proxy");
const path = require("path");
const fs = require("fs");

const constants = require("./server/constants");
const {
  parseJsonFromNoisyOutput,
  normalizeOnboardingModels,
  resolveModelProvider,
  resolveGithubRepoUrl,
  createPkcePair,
  parseCodexAuthorizationInput,
  getCodexAccountId,
  getBaseUrl,
  getApiEnableUrl,
  readGoogleCredentials,
  getClientKey,
} = require("./server/helpers");
const { readEnvFile, writeEnvFile, reloadEnv, startEnvWatcher } = require("./server/env");
const {
  gatewayEnv,
  isOnboarded,
  isGatewayRunning,
  startGateway,
  restartGateway: restartGatewayWithReload,
  attachGatewaySignalHandlers,
  ensureGatewayProxyConfig,
  syncChannelConfig,
  getChannelStatus,
} = require("./server/gateway");
const { createCommands } = require("./server/commands");
const { createAuthProfiles } = require("./server/auth-profiles");
const { createLoginThrottle } = require("./server/login-throttle");
const { createOpenclawVersionService } = require("./server/openclaw-version");
const { syncBootstrapPromptFiles } = require("./server/onboarding/workspace");

const { registerAuthRoutes } = require("./server/routes/auth");
const { registerPageRoutes } = require("./server/routes/pages");
const { registerModelRoutes } = require("./server/routes/models");
const { registerOnboardingRoutes } = require("./server/routes/onboarding");
const { registerSystemRoutes } = require("./server/routes/system");
const { registerPairingRoutes } = require("./server/routes/pairings");
const { registerCodexRoutes } = require("./server/routes/codex");
const { registerGoogleRoutes } = require("./server/routes/google");
const { registerProxyRoutes } = require("./server/routes/proxy");

const { PORT, GATEWAY_URL, kTrustProxyHops, SETUP_API_PREFIXES } = constants;

startEnvWatcher();
attachGatewaySignalHandlers();

const app = express();
app.set("trust proxy", kTrustProxyHops);
app.use(express.json());

const proxy = httpProxy.createProxyServer({
  target: GATEWAY_URL,
  ws: true,
  changeOrigin: true,
});
proxy.on("error", (err, req, res) => {
  if (res && res.writeHead) {
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Gateway unavailable" }));
  }
});

const authProfiles = createAuthProfiles();
const loginThrottle = { ...createLoginThrottle(), getClientKey };
const { shellCmd, clawCmd, gogCmd } = createCommands({ gatewayEnv });
const restartGateway = () => restartGatewayWithReload(reloadEnv);
const openclawVersionService = createOpenclawVersionService({
  gatewayEnv,
  restartGateway,
  isOnboarded,
});

const { requireAuth } = registerAuthRoutes({ app, loginThrottle });
app.use(express.static(path.join(__dirname, "public")));

registerPageRoutes({ app, requireAuth, isGatewayRunning });
registerModelRoutes({
  app,
  shellCmd,
  gatewayEnv,
  parseJsonFromNoisyOutput,
  normalizeOnboardingModels,
});
registerOnboardingRoutes({
  app,
  fs,
  constants,
  shellCmd,
  gatewayEnv,
  writeEnvFile,
  reloadEnv,
  isOnboarded,
  resolveGithubRepoUrl,
  resolveModelProvider,
  hasCodexOauthProfile: authProfiles.hasCodexOauthProfile,
  ensureGatewayProxyConfig,
  getBaseUrl,
  startGateway,
});
registerSystemRoutes({
  app,
  fs,
  readEnvFile,
  writeEnvFile,
  reloadEnv,
  kKnownVars: constants.kKnownVars,
  kKnownKeys: constants.kKnownKeys,
  kSystemVars: constants.kSystemVars,
  syncChannelConfig,
  isGatewayRunning,
  isOnboarded,
  getChannelStatus,
  openclawVersionService,
  clawCmd,
  restartGateway,
  OPENCLAW_DIR: constants.OPENCLAW_DIR,
});
registerPairingRoutes({ app, clawCmd, isOnboarded });
registerCodexRoutes({
  app,
  createPkcePair,
  parseCodexAuthorizationInput,
  getCodexAccountId,
  authProfiles,
});
registerGoogleRoutes({
  app,
  fs,
  isGatewayRunning,
  gogCmd,
  getBaseUrl,
  readGoogleCredentials,
  getApiEnableUrl,
  constants,
});
registerProxyRoutes({ app, proxy, SETUP_API_PREFIXES });

const server = http.createServer(app);
server.on("upgrade", (req, socket, head) => {
  proxy.ws(req, socket, head);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[wrapper] Express listening on :${PORT}`);
  syncBootstrapPromptFiles({ fs, workspaceDir: constants.WORKSPACE_DIR });
  if (isOnboarded()) {
    reloadEnv();
    syncChannelConfig(readEnvFile());
    ensureGatewayProxyConfig(null);
    // Force-sync ANTHROPIC_API_KEY from env into auth-profiles.json on every start
    if (process.env.ANTHROPIC_API_KEY) {
      try {
        const profilesPath = path.join(constants.OPENCLAW_DIR, "agents", "main", "agent", "auth-profiles.json");
        fs.mkdirSync(path.dirname(profilesPath), { recursive: true });
        let profiles = { version: 1, profiles: {}, lastGood: {}, usageStats: {} };
        if (fs.existsSync(profilesPath)) {
          profiles = JSON.parse(fs.readFileSync(profilesPath, "utf8"));
        }
        if (!profiles.profiles) profiles.profiles = {};
        const currentKey = profiles.profiles["anthropic:default"]?.key;
        if (currentKey !== process.env.ANTHROPIC_API_KEY) {
          profiles.profiles["anthropic:default"] = { type: "api_key", provider: "anthropic", key: process.env.ANTHROPIC_API_KEY };
          if (!profiles.lastGood) profiles.lastGood = {};
          profiles.lastGood["anthropic"] = "anthropic:default";
          fs.writeFileSync(profilesPath, JSON.stringify(profiles, null, 2));
          console.log("[wrapper] Synced Anthropic API key to auth-profiles.json");
        }
      } catch (e) {
        console.error("[wrapper] Failed to sync auth-profiles.json:", e.message);
      }
    }
    startGateway();
  } else {
    console.log("[wrapper] Awaiting onboarding via Setup UI");
  }
});
