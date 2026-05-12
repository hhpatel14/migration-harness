#!/usr/bin/env bash
# install.sh — one-shot installation of migration-harness.
#
# What it does:
#   1. Verifies goose, jq, git are installed.
#   2. Copies the migration-harness payload to ~/.migration-harness/install/
#   3. Symlinks ~/.local/bin/migration-harness → that payload
#   4. Installs the goose-migration skill bundle to ~/.config/goose/skills/
#   5. Prints next steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_G='\033[0;32m'; C_R='\033[0;31m'; C_Y='\033[1;33m'; C_B='\033[0;34m'; C_X='\033[0m'
ok()    { printf "${C_G}✓${C_X} %s\n" "$*"; }
warn()  { printf "${C_Y}⚠${C_X} %s\n" "$*"; }
err()   { printf "${C_R}✗${C_X} %s\n" "$*"; exit 1; }
info()  { printf "${C_B}→${C_X} %s\n" "$*"; }

# ── 1. Dependency check ─────────────────────────────────────────
info "Checking dependencies"
command -v goose >/dev/null 2>&1 || err "goose is not installed. https://block.github.io/goose/docs/getting-started/installation"
command -v jq    >/dev/null 2>&1 || err "jq is not installed (brew install jq | apt install jq)"
command -v git   >/dev/null 2>&1 || err "git is not installed"
ok "Dependencies present"

# ── 2. Copy payload ─────────────────────────────────────────────
INSTALL_DIR="$HOME/.migration-harness/install"
info "Installing payload to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR"/{bin,lib,recipes,skill-bundle}
cp -r "$SCRIPT_DIR/bin"           "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/lib"           "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/recipes"       "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/skill-bundle"  "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/migration-harness"
ok "Payload installed"

# ── 3. Symlink the command ──────────────────────────────────────
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/migration-harness" "$BIN_DIR/migration-harness"
ok "Symlink: $BIN_DIR/migration-harness → $INSTALL_DIR/bin/migration-harness"

# ── 4. Install skill bundle ─────────────────────────────────────
SKILLS_DIR="${GOOSE_SKILLS_DIR:-$HOME/.config/goose/skills}"
info "Installing skill bundle to $SKILLS_DIR/goose-migration"
mkdir -p "$SKILLS_DIR"
rm -rf "$SKILLS_DIR/goose-migration"
cp -r "$SCRIPT_DIR/skill-bundle/goose-migration" "$SKILLS_DIR/"
ok "Skill bundle installed"

# ── 5. PATH check ───────────────────────────────────────────────
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  warn "$BIN_DIR is not in your PATH"
  echo
  echo "  Add this to ~/.bashrc or ~/.zshrc:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo
  echo "  Then run:  source ~/.bashrc   (or open a new terminal)"
fi

echo
ok "Installation complete"
echo
echo "Next steps:"
echo "  1.  migration-harness init"
echo "  2.  migration-harness /path/to/your/app \"Migrate this Java EE app to Quarkus\""
