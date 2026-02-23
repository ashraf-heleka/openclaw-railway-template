#!/bin/bash
# OpenClaw Railway setup — runs on every container start
set -e

export OPENCLAW_HOME="/data"
OPENCLAW_DIR="/data/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
export OPENCLAW_CONFIG_PATH="$OPENCLAW_DIR/openclaw.json"

# ============================================================
# 1. Load persistent env vars (set via Setup UI or agent)
# ============================================================

if [ -f /data/.env ]; then
  # Safely parse .env line by line (avoids crash on malformed content)
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    if [[ "$line" == *=* ]]; then
      key="${line%%=*}"
      value="${line#*=}"
      if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        export "$key=$value" 2>/dev/null || true
      fi
    fi
  done < /data/.env
  echo "✓ Loaded /data/.env"
fi

# Auto-generate OPENCLAW_GATEWAY_TOKEN if not set (required by gateway config)
if [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; then
  export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
  echo "✓ Auto-generated OPENCLAW_GATEWAY_TOKEN"
fi

# Seed template if no .env exists yet
if [ ! -f /data/.env ]; then
  cp /app/setup/env.template /data/.env
  echo "✓ Created /data/.env template"
fi

# ============================================================
# 2. Install gog (Google Workspace CLI) if not present
# ============================================================

# Point gog config to persistent volume
export XDG_CONFIG_HOME="$OPENCLAW_DIR"

if ! command -v gog &> /dev/null; then
  echo "Installing gog CLI..."
  GOG_VERSION="${GOG_VERSION:-0.11.0}"
  curl -fsSL "https://github.com/steipete/gogcli/releases/download/v${GOG_VERSION}/gogcli_${GOG_VERSION}_linux_amd64.tar.gz" -o /tmp/gog.tar.gz
  tar -xzf /tmp/gog.tar.gz -C /tmp/
  mv /tmp/gog /usr/local/bin/gog
  chmod +x /usr/local/bin/gog
  rm -f /tmp/gog.tar.gz
  echo "✓ gog $(gog --version 2>/dev/null | head -1) installed"
fi

# Configure gog keyring to use file backend (no system keyring on Railway)
export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:-openclaw-railway}"
GOG_CONFIG_FILE="$OPENCLAW_DIR/gogcli/config.json"
if [ ! -f "$GOG_CONFIG_FILE" ]; then
  mkdir -p "$OPENCLAW_DIR/gogcli"
  gog auth keyring file 2>/dev/null || true
  echo "✓ gog keyring configured (file backend)"
fi

# ============================================================
# 3. Create directory structure
# ============================================================

mkdir -p "$OPENCLAW_DIR"

# Symlink so ~/.openclaw resolves to /data/.openclaw (for SSH/CLI access)
if [ ! -L "/root/.openclaw" ] && [ ! -d "/root/.openclaw" ]; then
  ln -s "$OPENCLAW_DIR" /root/.openclaw
fi

# Install/reconcile system cron entry for deterministic hourly git sync.
if [ -f "$OPENCLAW_DIR/hourly-git-sync.sh" ]; then
  SYNC_CRON_CONFIG="$OPENCLAW_DIR/cron/system-sync.json"
  SYNC_CRON_ENABLED="true"
  SYNC_CRON_SCHEDULE="0 * * * *"

  if [ -f "$SYNC_CRON_CONFIG" ]; then
    SYNC_CRON_ENABLED=$(node -e "
      const fs = require('fs');
      try {
        const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
        process.stdout.write(String(cfg.enabled !== false));
      } catch {
        process.stdout.write('true');
      }
    " "$SYNC_CRON_CONFIG")
    SYNC_CRON_SCHEDULE=$(node -e "
      const fs = require('fs');
      try {
        const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
        const schedule = String(cfg.schedule || '').trim();
        const valid = /^(\\S+\\s+){4}\\S+$/.test(schedule);
        process.stdout.write(valid ? schedule : '0 * * * *');
      } catch {
        process.stdout.write('0 * * * *');
      }
    " "$SYNC_CRON_CONFIG")
  fi

  if [ "$SYNC_CRON_ENABLED" = "true" ]; then
    cat > /etc/cron.d/openclaw-hourly-sync <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$SYNC_CRON_SCHEDULE root bash "$OPENCLAW_DIR/hourly-git-sync.sh" >> /var/log/openclaw-hourly-sync.log 2>&1
EOF
    chmod 0644 /etc/cron.d/openclaw-hourly-sync
    echo "✓ System cron entry installed"
  else
    rm -f /etc/cron.d/openclaw-hourly-sync
    echo "✓ System cron entry disabled"
  fi
fi

if command -v cron >/dev/null 2>&1; then
  if ! pgrep -x cron >/dev/null 2>&1; then
    cron
  fi
  echo "✓ Cron daemon running"
fi

# ============================================================
# 4. Google Workspace (gog CLI) — env-var based setup
# ============================================================

if [ -n "$GOG_CLIENT_CREDENTIALS_JSON" ] && [ -n "$GOG_REFRESH_TOKEN" ]; then
  mkdir -p /root/.config/gogcli

  TEMP_CREDS=$(mktemp)
  printf '%s' "$GOG_CLIENT_CREDENTIALS_JSON" > "$TEMP_CREDS"
  /usr/local/bin/gog auth credentials set "$TEMP_CREDS" 2>/dev/null
  rm -f "$TEMP_CREDS"

  TEMP_TOKEN=$(mktemp)
  echo "{\"email\": \"${GOG_ACCOUNT}\", \"refresh_token\": \"$GOG_REFRESH_TOKEN\"}" > "$TEMP_TOKEN"
  /usr/local/bin/gog auth tokens import "$TEMP_TOKEN" 2>/dev/null
  rm -f "$TEMP_TOKEN"
  echo "✓ gog CLI configured for ${GOG_ACCOUNT}"
else
  echo "⚠ Google credentials not set — skipping gog setup"
fi

# ============================================================
# 4b. Repair invalid config entries (cleanup from bad deploys)
# ============================================================

if [ -f "$OPENCLAW_CONFIG_PATH" ]; then
  node -e "
    const fs = require('fs');
    const path = process.env.OPENCLAW_CONFIG_PATH;
    try {
      const cfg = JSON.parse(fs.readFileSync(path, 'utf8'));
      let changed = false;
      // Remove invalid channels.whatsapp.enabled (not a valid top-level key)
      if (cfg.channels && cfg.channels.whatsapp) {
        const wa = cfg.channels.whatsapp;
        if (Object.keys(wa).length === 1 && wa.enabled !== undefined) {
          delete cfg.channels.whatsapp;
          changed = true;
          console.log('✓ Removed invalid channels.whatsapp.enabled');
        } else if (wa.enabled !== undefined) {
          delete cfg.channels.whatsapp.enabled;
          changed = true;
          console.log('✓ Removed invalid channels.whatsapp.enabled key');
        }
      }
      if (changed) fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
    } catch(e) { console.log('Config repair skipped:', e.message); }
  "
fi

# ============================================================
# 4c. Force-update auth.json with current ANTHROPIC_API_KEY
# ============================================================

if [ -n "$ANTHROPIC_API_KEY" ]; then
  node -e "
    const fs = require('fs');
    const authPath = '/data/.openclaw/agents/main/agent/auth.json';
    const apiKey = process.env.ANTHROPIC_API_KEY;
    try {
      fs.mkdirSync('/data/.openclaw/agents/main/agent', { recursive: true });
      let auth = {};
      if (fs.existsSync(authPath)) {
        auth = JSON.parse(fs.readFileSync(authPath, 'utf8'));
      }
      if (!auth.anthropic) auth.anthropic = {};
      if (auth.anthropic.key !== apiKey) {
        auth.anthropic = { type: 'api_key', key: apiKey };
        fs.writeFileSync(authPath, JSON.stringify(auth, null, 2));
        console.log('✓ Updated Anthropic API key in auth.json');
      }
    } catch(e) { console.log('auth.json update skipped:', e.message); }
  "
fi

# ============================================================
# 5. If already onboarded, reconcile channels on boot
# ============================================================

if [ -f "$OPENCLAW_CONFIG_PATH" ]; then
  echo "Config exists, reconciling channels..."

  # Git remote update (if GITHUB_TOKEN is available)
  if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_WORKSPACE_REPO" ] && [ -d "$OPENCLAW_DIR/.git" ]; then
    REPO_URL="$GITHUB_WORKSPACE_REPO"
    REPO_URL=$(echo "$REPO_URL" | sed 's|^git@github.com:||; s|^https://github.com/||; s|\.git$||')
    REMOTE_URL="https://${GITHUB_TOKEN}@github.com/${REPO_URL}.git"
    cd "$OPENCLAW_DIR"
    git remote set-url origin "$REMOTE_URL" 2>/dev/null || true
    echo "✓ Repo ready"
  fi

  # Reconcile channels: pick up new/changed env vars on every boot
  node -e "
    const fs = require('fs');
    const configPath = process.env.OPENCLAW_CONFIG_PATH;
    const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    if (!cfg.channels) cfg.channels = {};
    if (!cfg.plugins) cfg.plugins = {};
    if (!cfg.plugins.entries) cfg.plugins.entries = {};
    let changed = false;

    if (process.env.TELEGRAM_BOT_TOKEN && !cfg.channels.telegram) {
      cfg.channels.telegram = {
        enabled: true,
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        dmPolicy: 'pairing',
        groupPolicy: 'allowlist',
      };
      cfg.plugins.entries.telegram = { enabled: true };
      console.log('✓ Telegram added');
      changed = true;
    }

    if (process.env.DISCORD_BOT_TOKEN && !cfg.channels.discord) {
      cfg.channels.discord = {
        enabled: true,
        token: process.env.DISCORD_BOT_TOKEN,
        dmPolicy: 'pairing',
        groupPolicy: 'allowlist',
      };
      cfg.plugins.entries.discord = { enabled: true };
      console.log('✓ Discord added');
      changed = true;
    }

    if (changed) {
      let content = JSON.stringify(cfg, null, 2);

      // Sanitize new secrets
      const replacements = [
        [process.env.OPENCLAW_GATEWAY_TOKEN, '\${OPENCLAW_GATEWAY_TOKEN}'],
        [process.env.ANTHROPIC_API_KEY, '\${ANTHROPIC_API_KEY}'],
        [process.env.ANTHROPIC_TOKEN, '\${ANTHROPIC_TOKEN}'],
        [process.env.TELEGRAM_BOT_TOKEN, '\${TELEGRAM_BOT_TOKEN}'],
        [process.env.DISCORD_BOT_TOKEN, '\${DISCORD_BOT_TOKEN}'],
        [process.env.OPENAI_API_KEY, '\${OPENAI_API_KEY}'],
        [process.env.GEMINI_API_KEY, '\${GEMINI_API_KEY}'],
        [process.env.NOTION_API_KEY, '\${NOTION_API_KEY}'],
        [process.env.BRAVE_API_KEY, '\${BRAVE_API_KEY}'],
      ];

      for (const [secret, envRef] of replacements) {
        if (secret && secret.length > 8) {
          content = content.split(secret).join(envRef);
        }
      }

      fs.writeFileSync(configPath, content);
      console.log('✓ Config updated and sanitized');
    }
  "
else
  echo "No config yet — onboarding will run from the Setup UI"
fi

echo "✓ Setup complete — starting wrapper"
# Validate openclaw.json — restore from backup if corrupted
if [ -f "$OPENCLAW_DIR/openclaw.json" ]; then
  if ! node -e "JSON.parse(require('fs').readFileSync('$OPENCLAW_DIR/openclaw.json','utf8'))" 2>/dev/null; then
    echo "[setup] openclaw.json is invalid JSON — restoring from backup"
    RESTORED=false
    for BAK in "$OPENCLAW_DIR/openclaw.json.bak" "$OPENCLAW_DIR/openclaw.json.bak.1" "$OPENCLAW_DIR/openclaw.json.bak.2"; do
      if [ -f "$BAK" ] && node -e "JSON.parse(require('fs').readFileSync('$BAK','utf8'))" 2>/dev/null; then
        cp "$BAK" "$OPENCLAW_DIR/openclaw.json"
        echo "[setup] Restored from $BAK"
        RESTORED=true
        break
      fi
    done
    if [ "$RESTORED" = "false" ]; then
      echo "[setup] No valid backup found — removing corrupted config"
      rm -f "$OPENCLAW_DIR/openclaw.json"
    fi
  fi
fi

exec node /app/src/server.js
