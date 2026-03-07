#!/bin/bash
# Migrate TTS/STT services from VoiceMode to ClawMux
# Copies service directories from ~/.voicemode/services/ to ~/.clawmux/services/
# so ClawMux owns its own copy of the services.
set -e

CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
VOICEMODE_HOME="$HOME/.voicemode"

info()  { echo -e "\033[1;34m[migrate]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[migrate]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[migrate]\033[0m $*"; }

if [ ! -d "$VOICEMODE_HOME/services" ]; then
    warn "No VoiceMode services found at $VOICEMODE_HOME/services"
    warn "Nothing to migrate — run install scripts instead."
    exit 0
fi

mkdir -p "$CLAWMUX_HOME/services"

# --- Whisper ---
if [ -d "$VOICEMODE_HOME/services/whisper" ]; then
    if [ -d "$CLAWMUX_HOME/services/whisper" ] && [ ! -L "$CLAWMUX_HOME/services/whisper" ]; then
        warn "Whisper already exists at $CLAWMUX_HOME/services/whisper (not a symlink) — skipping"
    else
        # Remove symlink if present
        [ -L "$CLAWMUX_HOME/services/whisper" ] && rm "$CLAWMUX_HOME/services/whisper"
        info "Copying Whisper (~5GB, this may take a minute)..."
        cp -a "$VOICEMODE_HOME/services/whisper" "$CLAWMUX_HOME/services/whisper"
        ok "Whisper copied to $CLAWMUX_HOME/services/whisper"
    fi
else
    warn "No Whisper found at $VOICEMODE_HOME/services/whisper"
fi

# --- Kokoro ---
if [ -d "$VOICEMODE_HOME/services/kokoro" ]; then
    if [ -d "$CLAWMUX_HOME/services/kokoro" ] && [ ! -L "$CLAWMUX_HOME/services/kokoro" ]; then
        warn "Kokoro already exists at $CLAWMUX_HOME/services/kokoro (not a symlink) — skipping"
    else
        # Remove symlink if present
        [ -L "$CLAWMUX_HOME/services/kokoro" ] && rm "$CLAWMUX_HOME/services/kokoro"
        info "Copying Kokoro (~7GB, this may take a minute)..."
        cp -a "$VOICEMODE_HOME/services/kokoro" "$CLAWMUX_HOME/services/kokoro"
        ok "Kokoro copied to $CLAWMUX_HOME/services/kokoro"
    fi
else
    warn "No Kokoro found at $VOICEMODE_HOME/services/kokoro"
fi

# --- Migrate STT prompt from voicemode.env to .env ---
if [ -f "$VOICEMODE_HOME/voicemode.env" ]; then
    STT_PROMPT=$(grep "^VOICEMODE_STT_PROMPT=" "$VOICEMODE_HOME/voicemode.env" 2>/dev/null | head -1 | cut -d= -f2-)
    if [ -n "$STT_PROMPT" ]; then
        CLAWMUX_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
        if grep -q "^CLAWMUX_STT_PROMPT=" "$CLAWMUX_ENV" 2>/dev/null; then
            ok "CLAWMUX_STT_PROMPT already set in .env"
        else
            echo "CLAWMUX_STT_PROMPT=$STT_PROMPT" >> "$CLAWMUX_ENV"
            ok "Migrated STT prompt to .env"
        fi
    fi
fi

echo ""
ok "Migration complete. Services will use ~/.clawmux/services/ paths."
info "VoiceMode at $VOICEMODE_HOME is still intact — remove it manually when ready."
