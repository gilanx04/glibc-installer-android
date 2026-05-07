#!/data/data/com.termux/files/usr/bin/bash
# glibc-installer-android: all-in-one Termux glibc runner/wrapper/linker installer.

set -euo pipefail

APP_NAME="glibc-installer-android"
APP_DIR="${HOME}/.glibc-installer-android"
NODE_DIR="${APP_DIR}/node"
BIN_DIR="${APP_DIR}/bin"
COMPAT_JS="${APP_DIR}/glibc-compat.js"
NODE_VERSION="${NODE_VERSION:-22.22.2}"
NPM_PREFIX="${NPM_PREFIX:-${PREFIX:-}/lib/node_modules}"

CLAUDE_PKG="@anthropic-ai/claude-code"
OPENCODE_PKG="opencode-ai"
CODEX_PKG="@openai/codex"
OPENCLAW_PKG="openclaw"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { printf "${GREEN}[%s]${NC} %s\n" "$APP_NAME" "$*" >&2; }
warn() { printf "${YELLOW}[%s][warn]${NC} %s\n" "$APP_NAME" "$*" >&2; }
fail() { printf "${RED}[%s][fail]${NC} %s\n" "$APP_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  bash glibc-installer.sh
  bash glibc-installer.sh menu
  bash glibc-installer.sh --help
  bash glibc-installer.sh install [--claude] [--opencode] [--codex] [--openclaw] [--all]
  bash glibc-installer.sh repair  [--claude] [--opencode] [--codex] [--openclaw] [--all]
  bash glibc-installer.sh uninstall [--keep-node]
  bash glibc-installer.sh status

Examples:
  bash glibc-installer.sh
  bash glibc-installer.sh --help
  bash glibc-installer.sh install
  bash glibc-installer.sh install --all
  bash glibc-installer.sh repair --all

Env:
  NODE_VERSION=22.22.2 bash glibc-installer.sh install
USAGE
}

require_termux() {
  [ -n "${PREFIX:-}" ] || fail "PREFIX kosong. Jalankan di Termux."
  [ -d "$PREFIX/bin" ] || fail "Termux PREFIX tidak valid: $PREFIX"
  [ "$(uname -m 2>/dev/null || true)" = "aarch64" ] || fail "Hanya aarch64/arm64 didukung."
  mkdir -p "$APP_DIR" "$BIN_DIR" "${TMPDIR:-$PREFIX/tmp}"
}

find_ldso() {
  local p
  for p in \
    "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
    "$PREFIX/glibc/lib/ld-linux.so.1" \
    "$PREFIX/opt/glibc/lib/ld-linux-aarch64.so.1"; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

install_base_deps() {
  require_termux
  command -v pkg >/dev/null 2>&1 || fail "pkg tidak ada. Pakai Termux dari F-Droid."
  log "install paket dasar"
  pkg update -y
  pkg install -y bash curl tar xz-utils coreutils findutils grep sed gawk git pacman
}

install_glibc_runner() {
  require_termux
  local ldso pacman_conf patched=false
  ldso="$(find_ldso || true)"
  if [ -n "$ldso" ]; then
    log "glibc linker sudah ada: $ldso"
    return 0
  fi

  log "install glibc-runner via pacman"
  command -v pacman >/dev/null 2>&1 || pkg install -y pacman

  pacman_conf="$PREFIX/etc/pacman.conf"
  if [ -f "$pacman_conf" ] && ! grep -q '^SigLevel = Never' "$pacman_conf"; then
    cp "$pacman_conf" "$pacman_conf.$APP_NAME.bak" 2>/dev/null || true
    sed -i 's/^SigLevel[[:space:]]*=.*/SigLevel = Never/' "$pacman_conf" || true
    patched=true
    warn "pacman SigLevel = Never sementara, workaround GPGME Termux"
  fi

  pacman-key --init 2>/dev/null || true
  pacman-key --populate 2>/dev/null || true

  if ! pacman -Sy glibc-runner --noconfirm --assume-installed bash,patchelf,resolv-conf; then
    if [ "$patched" = true ] && [ -f "$pacman_conf.$APP_NAME.bak" ]; then
      mv "$pacman_conf.$APP_NAME.bak" "$pacman_conf" 2>/dev/null || true
    fi
    fail "install glibc-runner gagal"
  fi

  if [ "$patched" = true ] && [ -f "$pacman_conf.$APP_NAME.bak" ]; then
    mv "$pacman_conf.$APP_NAME.bak" "$pacman_conf" 2>/dev/null || true
  fi

  mkdir -p "$PREFIX/glibc/etc"
  [ -f "$PREFIX/glibc/etc/hosts" ] || cat > "$PREFIX/glibc/etc/hosts" <<'HOSTS'
127.0.0.1 localhost localhost.localdomain
::1 localhost ip6-localhost ip6-loopback
HOSTS

  ldso="$(find_ldso || true)"
  [ -n "$ldso" ] || fail "glibc-runner terpasang, tapi ld.so tidak ditemukan"
  log "glibc linker terpasang: $ldso"
}

write_compat_js() {
  mkdir -p "$APP_DIR"
  cat > "$COMPAT_JS" <<'JS'
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

delete process.env.LD_PRELOAD;

const wrapper = process.env.GLIBC_NODE_WRAPPER;
try {
  if (wrapper && fs.existsSync(wrapper)) {
    Object.defineProperty(process, 'execPath', { value: wrapper, writable: true, configurable: true });
  }
} catch {}

const originalCpus = os.cpus;
os.cpus = function cpus() {
  const out = originalCpus.call(os);
  return out.length ? out : [{ model: 'unknown', speed: 0, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } }];
};

const originalNetworkInterfaces = os.networkInterfaces;
os.networkInterfaces = function networkInterfaces() {
  try { return originalNetworkInterfaces.call(os); }
  catch { return { lo: [{ address: '127.0.0.1', netmask: '255.0.0.0', family: 'IPv4', mac: '00:00:00:00:00:00', internal: true, cidr: '127.0.0.1/8' }] }; }
};

try {
  const cp = require('child_process');
  const termuxSh = (process.env.PREFIX || '/data/data/com.termux/files/usr') + '/bin/sh';
  const ldso = (process.env.PREFIX || '/data/data/com.termux/files/usr') + '/glibc/lib/ld-linux-aarch64.so.1';
  const libpath = (process.env.PREFIX || '/data/data/com.termux/files/usr') + '/glibc/lib';

  function resolveCmd(cmd, env) {
    if (cmd.includes('/')) return fs.existsSync(cmd) ? cmd : null;
    for (const dir of ((env && env.PATH) || process.env.PATH || '').split(':')) {
      const full = path.join(dir, cmd);
      try { fs.accessSync(full, fs.constants.X_OK); return full; } catch {}
    }
    return null;
  }

  function needsWrap(file) {
    try {
      const fd = fs.openSync(file, 'r');
      const buf = Buffer.alloc(4096);
      const n = fs.readSync(fd, buf, 0, buf.length, 0);
      fs.closeSync(fd);
      if (n < 4 || buf[0] !== 0x7f || buf[1] !== 0x45 || buf[2] !== 0x4c || buf[3] !== 0x46) return false;
      return buf.includes(Buffer.from('ld-linux'));
    } catch { return false; }
  }

  function readShebang(file) {
    try {
      const s = fs.readFileSync(file, 'utf8').slice(0, 256);
      if (!s.startsWith('#!')) return null;
      return s.split('\n')[0].slice(2).trim().split(/\s+/);
    } catch { return null; }
  }

  function wrap(file, args, opts) {
    const env = opts && opts.env ? opts.env : process.env;
    const resolved = resolveCmd(file, env);
    if (!resolved || resolved === ldso) return null;
    if (needsWrap(resolved) && fs.existsSync(ldso)) {
      const cleanEnv = Object.assign({}, env);
      delete cleanEnv.LD_PRELOAD;
      return { file: ldso, args: ['--library-path', libpath, resolved].concat(args || []), opts: Object.assign({}, opts, { env: cleanEnv, shell: false }) };
    }
    const sb = readShebang(resolved);
    if (sb && sb[0] === '/usr/bin/env' && sb[1]) {
      const interp = resolveCmd(sb[1], env);
      if (interp) return { file: interp, args: sb.slice(2).concat([resolved]).concat(args || []), opts };
    }
    return null;
  }

  if (fs.existsSync(termuxSh)) {
    const exec = cp.exec;
    cp.exec = function(command, options, callback) {
      if (typeof options === 'function') { callback = options; options = {}; }
      options = options || {};
      if (!options.shell) options.shell = termuxSh;
      return exec.call(cp, command, options, callback);
    };
  }

  const spawn = cp.spawn;
  cp.spawn = function(command, args, opts) {
    if (args && !Array.isArray(args)) { opts = args; args = []; }
    const w = wrap(command, args || [], opts);
    return w ? spawn.call(cp, w.file, w.args, w.opts) : spawn.call(cp, command, args, opts);
  };

  const spawnSync = cp.spawnSync;
  cp.spawnSync = function(command, args, opts) {
    if (args && !Array.isArray(args)) { opts = args; args = []; }
    const w = wrap(command, args || [], opts);
    return w ? spawnSync.call(cp, w.file, w.args, w.opts) : spawnSync.call(cp, command, args, opts);
  };
} catch {}
JS
}

install_node() {
  require_termux
  install_glibc_runner
  write_compat_js

  local ldso real_node tarball url tmp npm_cli npx_cli
  ldso="$(find_ldso)"
  if [ -x "$BIN_DIR/node" ] && "$BIN_DIR/node" --version >/dev/null 2>&1; then
    log "Node.js sudah ada: $($BIN_DIR/node --version)"
    return 0
  fi

  install_base_deps
  tarball="node-v${NODE_VERSION}-linux-arm64.tar.xz"
  url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
  tmp="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/glibc-node.XXXXXX")"
  trap 'rm -rf "${tmp:-}"' RETURN

  log "download Node.js v${NODE_VERSION} linux-arm64"
  curl -fL --max-time 300 "$url" -o "$tmp/$tarball"

  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR" "$BIN_DIR"
  tar -xJf "$tmp/$tarball" -C "$NODE_DIR" --strip-components=1

  real_node="$NODE_DIR/bin/node.real"
  mv "$NODE_DIR/bin/node" "$real_node"
  chmod +x "$real_node"

  cat > "$BIN_DIR/node" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -e
unset LD_PRELOAD
export TMPDIR="\${TMPDIR:-$PREFIX/tmp}"
export TMP="\$TMPDIR"
export TEMP="\$TMPDIR"
export GLIBC_NODE_WRAPPER="$BIN_DIR/node"
if [ -f "$COMPAT_JS" ]; then
  case "\${NODE_OPTIONS:-}" in *"$COMPAT_JS"*) ;; *) export NODE_OPTIONS="\${NODE_OPTIONS:+\$NODE_OPTIONS }-r $COMPAT_JS" ;; esac
fi
exec "$ldso" --library-path "$(dirname "$ldso")" "$real_node" "\$@"
EOF
  chmod +x "$BIN_DIR/node"

  npm_cli="$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
  npx_cli="$NODE_DIR/lib/node_modules/npm/bin/npx-cli.js"
  cat > "$BIN_DIR/npm" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec "$BIN_DIR/node" "$npm_cli" "\$@"
EOF
  chmod +x "$BIN_DIR/npm"
  cat > "$BIN_DIR/npx" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec "$BIN_DIR/node" "$npx_cli" "\$@"
EOF
  chmod +x "$BIN_DIR/npx"

  PATH="$BIN_DIR:$PATH" "$BIN_DIR/npm" config set prefix "$PREFIX" >/dev/null 2>&1 || true
  PATH="$BIN_DIR:$PATH" "$BIN_DIR/npm" config set script-shell "$PREFIX/bin/sh" >/dev/null 2>&1 || true

  log "Node.js terpasang: $($BIN_DIR/node --version)"
  log "npm terpasang: $($BIN_DIR/npm --version)"
}

write_shell_env() {
  local start end block rc
  start="# >>> glibc-installer-android >>>"
  end="# <<< glibc-installer-android <<<"
  block="$start
export PATH=\"$BIN_DIR:\$HOME/bin:\$PATH\"
export TMPDIR=\"\${TMPDIR:-\$PREFIX/tmp}\"
export TMP=\"\$TMPDIR\"
export TEMP=\"\$TMPDIR\"
$end"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    touch "$rc"
    grep -qF "$start" "$rc" && sed -i "/$start/,/$end/d" "$rc"
    printf '\n%s\n' "$block" >> "$rc"
  done
  export PATH="$BIN_DIR:$HOME/bin:$PATH"
}

npm_install_global() {
  local spec="$1"
  install_node
  write_shell_env
  log "npm install -g $spec"
  PATH="$BIN_DIR:$PATH" "$BIN_DIR/npm" install -g "$spec"
}

npm_root_global() {
  PATH="$BIN_DIR:$PATH" "$BIN_DIR/npm" root -g 2>/dev/null || printf '%s/lib/node_modules\n' "$PREFIX"
}

find_claude_bin() {
  local root pkg p
  root="$(npm_root_global)"
  pkg="$root/$CLAUDE_PKG"
  for p in \
    "$pkg/bin/claude.exe" \
    "$pkg/node_modules/@anthropic-ai/claude-code-linux-arm64/claude" \
    "$pkg/node_modules/@anthropic-ai/claude-code-linux-arm64/claude.exe"; do
    [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

write_native_wrapper() {
  local name="$1" bin="$2" ldso libpath target
  ldso="$(find_ldso)"
  libpath="$(dirname "$ldso")"
  target="$PREFIX/bin/$name"
  chmod +x "$bin" 2>/dev/null || true
  rm -f "$target"
  cat > "$target" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -e
unset LD_PRELOAD
export TMPDIR="\${TMPDIR:-$PREFIX/tmp}"
export TMP="\$TMPDIR"
export TEMP="\$TMPDIR"
exec "$ldso" --library-path "$libpath" "$bin" "\$@"
EOF
  chmod +x "$target"
  log "wrapper $name -> $bin"
}

write_node_cli_wrapper() {
  local name="$1" script="$2" target="$PREFIX/bin/$name"
  rm -f "$target"
  cat > "$target" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec "$BIN_DIR/node" "$script" "\$@"
EOF
  chmod +x "$target"
  log "wrapper $name -> $script"
}

repair_claude() {
  install_glibc_runner
  local bin
  bin="$(find_claude_bin || true)"
  [ -n "$bin" ] || fail "Claude Code binary tidak ditemukan. Jalankan: bash glibc-installer.sh install --claude"
  write_native_wrapper claude "$bin"
  "$PREFIX/bin/claude" --version || true
}

repair_opencode() {
  install_node
  local root pkg script
  root="$(npm_root_global)"
  pkg="$root/$OPENCODE_PKG"
  script=""
  for p in "$pkg/bin/opencode" "$pkg/bin/opencode.js" "$pkg/dist/index.js" "$pkg/index.js"; do
    [ -f "$p" ] && { script="$p"; break; }
  done
  [ -n "$script" ] || fail "OpenCode tidak ditemukan. Jalankan: bash glibc-installer.sh install --opencode"
  write_node_cli_wrapper opencode "$script"
  "$PREFIX/bin/opencode" --version || true
}

repair_codex() {
  install_node
  local root pkg script native p
  root="$(npm_root_global)"
  pkg="$root/$CODEX_PKG"
  script=""
  native=""
  for p in "$pkg/bin/codex" "$pkg/bin/codex.js" "$pkg/dist/cli.js" "$pkg/index.js"; do
    [ -f "$p" ] && { script="$p"; break; }
  done
  for p in "$pkg"/bin/*.bin "$pkg"/vendor/*/codex "$pkg"/node_modules/*/codex; do
    [ -f "$p" ] && { native="$p"; break; }
  done
  if [ -n "$native" ]; then
    write_native_wrapper codex "$native"
  elif [ -n "$script" ]; then
    write_node_cli_wrapper codex "$script"
  else
    fail "Codex tidak ditemukan. Jalankan: bash glibc-installer.sh install --codex"
  fi
  "$PREFIX/bin/codex" --version || true
}

repair_openclaw() {
  install_node
  local root pkg script p
  root="$(npm_root_global)"
  pkg="$root/$OPENCLAW_PKG"
  script=""
  for p in "$pkg/openclaw.mjs" "$pkg/bin/openclaw" "$pkg/bin/openclaw.js" "$pkg/dist/index.js" "$pkg/index.js"; do
    [ -f "$p" ] && { script="$p"; break; }
  done
  [ -n "$script" ] || fail "OpenClaw tidak ditemukan. Jalankan menu Install OpenClaw."
  write_node_cli_wrapper openclaw "$script"
  "$PREFIX/bin/openclaw" --version || true
}

cli_pkg_name() {
  case "$1" in
    claude) printf '%s\n' "$CLAUDE_PKG" ;;
    opencode) printf '%s\n' "$OPENCODE_PKG" ;;
    codex) printf '%s\n' "$CODEX_PKG" ;;
    openclaw) printf '%s\n' "$OPENCLAW_PKG" ;;
  esac
}

cli_label() {
  case "$1" in
    claude) printf '%s\n' "Claude Code" ;;
    opencode) printf '%s\n' "OpenCode" ;;
    codex) printf '%s\n' "Codex" ;;
    openclaw) printf '%s\n' "OpenClaw" ;;
  esac
}

cli_installed() {
  local root pkg
  root="$(npm_root_global 2>/dev/null || printf '%s/lib/node_modules\n' "$PREFIX")"
  pkg="$(cli_pkg_name "$1")"
  [ -d "$root/$pkg" ]
}

cli_wrapper_exists() {
  local name="$1" target="$PREFIX/bin/$1"
  [ -f "$target" ] || return 1
  grep -qE 'glibc-installer-android|ld-linux|\.glibc-installer-android/bin/node' "$target" 2>/dev/null
}

cli_works() {
  local name="$1"
  [ -x "$PREFIX/bin/$name" ] || return 1
  "$PREFIX/bin/$name" --version >/dev/null 2>&1
}

cli_status() {
  local name="$1"
  if ! cli_installed "$name"; then
    printf '%s\n' missing
  elif ! cli_wrapper_exists "$name"; then
    printf '%s\n' no_linker
  elif ! cli_works "$name"; then
    printf '%s\n' broken
  else
    printf '%s\n' ok
  fi
}

install_one_cli() {
  case "$1" in
    claude) npm_install_global "$CLAUDE_PKG@latest"; repair_claude ;;
    opencode) npm_install_global "$OPENCODE_PKG@latest"; repair_opencode ;;
    codex) npm_install_global "$CODEX_PKG@latest"; repair_codex ;;
    openclaw) npm_install_global "$OPENCLAW_PKG@latest"; repair_openclaw ;;
  esac
  fix_global_shebangs
}

repair_one_cli() {
  case "$1" in
    claude) repair_claude ;;
    opencode) repair_opencode ;;
    codex) repair_codex ;;
    openclaw) repair_openclaw ;;
  esac
  fix_global_shebangs
}

uninstall_one_cli() {
  local name="$1" pkg root label
  pkg="$(cli_pkg_name "$name")"
  label="$(cli_label "$name")"
  install_node
  root="$(npm_root_global)"
  log "uninstall $label"
  PATH="$BIN_DIR:$PATH" "$BIN_DIR/npm" uninstall -g "$pkg" || true
  rm -f "$PREFIX/bin/$name"
}

fix_global_shebangs() {
  local f
  for f in "$PREFIX/lib/node_modules"/*/bin/* "$PREFIX/lib/node_modules"/@*/*/bin/*; do
    [ -f "$f" ] || continue
    head -1 "$f" 2>/dev/null | grep -q '^#!/usr/bin/env node$' || continue
    sed -i "1s|#!/usr/bin/env node|#!$BIN_DIR/node|" "$f"
  done
}

install_selected_tools() {
  local do_claude=false do_opencode=false do_codex=false do_openclaw=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --claude) do_claude=true ;;
      --opencode) do_opencode=true ;;
      --codex) do_codex=true ;;
      --openclaw) do_openclaw=true ;;
      --all) do_claude=true; do_opencode=true; do_codex=true; do_openclaw=true ;;
      *) ;;
    esac
    shift
  done

  $do_claude && { npm_install_global "$CLAUDE_PKG@latest"; repair_claude; }
  $do_opencode && { npm_install_global "$OPENCODE_PKG@latest"; repair_opencode; }
  $do_codex && { npm_install_global "$CODEX_PKG@latest"; repair_codex; }
  $do_openclaw && { npm_install_global "$OPENCLAW_PKG@latest"; repair_openclaw; }
  fix_global_shebangs
}

repair_selected_tools() {
  local do_claude=false do_opencode=false do_codex=false do_openclaw=false saw=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --claude) do_claude=true; saw=true ;;
      --opencode) do_opencode=true; saw=true ;;
      --codex) do_codex=true; saw=true ;;
      --openclaw) do_openclaw=true; saw=true ;;
      --all) do_claude=true; do_opencode=true; do_codex=true; do_openclaw=true; saw=true ;;
      *) ;;
    esac
    shift
  done
  if [ "$saw" = false ]; then
    do_claude=true; do_opencode=true; do_codex=true; do_openclaw=true
  fi

  install_node
  write_shell_env
  fix_global_shebangs
  $do_claude && repair_claude || true
  $do_opencode && repair_opencode || true
  $do_codex && repair_codex || true
  $do_openclaw && repair_openclaw || true
}

install_main() {
  install_base_deps
  install_node
  write_shell_env
  install_selected_tools "$@"
  log "selesai. Jalankan: source ~/.bashrc"
}

uninstall_main() {
  local keep_node=false rc start end
  while [ $# -gt 0 ]; do
    case "$1" in --keep-node) keep_node=true ;; esac
    shift
  done

  rm -f "$PREFIX/bin/claude" "$PREFIX/bin/opencode" "$PREFIX/bin/codex"
  start="# >>> glibc-installer-android >>>"
  end="# <<< glibc-installer-android <<<"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] && sed -i "/$start/,/$end/d" "$rc" || true
  done
  if [ "$keep_node" = false ]; then
    rm -rf "$APP_DIR"
  fi
  log "uninstall selesai. glibc-runner tidak dihapus; mungkin dipakai aplikasi lain."
}

status_main() {
  echo "APP_DIR=$APP_DIR"
  echo "LDSO=$(find_ldso || echo missing)"
  echo "NODE=$([ -x "$BIN_DIR/node" ] && "$BIN_DIR/node" --version || echo missing)"
  echo "NPM=$([ -x "$BIN_DIR/npm" ] && "$BIN_DIR/npm" --version || echo missing)"
  for c in claude codex opencode openclaw; do
    printf '%s=' "$c"
    cli_status "$c" 2>/dev/null || echo missing
  done
}

pause_menu() {
  printf '\nTekan Enter untuk lanjut...'
  read -r _ || true
}

menu_header() {
  clear 2>/dev/null || true
  printf '%s\n' "==== glibc-installer-android ===="
  printf 'Linker: %s\n' "$(find_ldso || echo missing)"
  printf 'Node: %s\n' "$([ -x "$BIN_DIR/node" ] && "$BIN_DIR/node" --version 2>/dev/null || echo missing)"
  printf '\n'
}

linker_menu() {
  while true; do
    menu_header
    cat <<'MENU'
Glibc Linker
1. Check Linker
2. Install Linker
3. Repair Linker
4. Uninstall Linker
0. Back
MENU
    printf 'Pilih: '
    read -r choice || return 0
    case "$choice" in
      1) status_main; pause_menu ;;
      2) install_base_deps; install_node; write_shell_env; pause_menu ;;
      3) install_glibc_runner; install_node; write_shell_env; pause_menu ;;
      4)
        warn "glibc-runner bisa dipakai tool lain. Ini hapus runtime terkelola dan wrapper CLI, bukan paket pacman glibc-runner."
        printf 'Lanjut uninstall runtime/wrapper? [y/N]: '
        read -r yes || true
        case "$yes" in y|Y|yes|YES) uninstall_main ;; *) log "batal" ;; esac
        pause_menu
        ;;
      0) return 0 ;;
      *) warn "pilihan tidak valid"; pause_menu ;;
    esac
  done
}

cli_action_label() {
  local status="$1" label="$2"
  case "$status" in
    missing) printf 'Install %s\n' "$label" ;;
    no_linker) printf 'Install Linker to %s\n' "$label" ;;
    broken) printf 'Repair %s\n' "$label" ;;
    ok) printf 'Update %s\n' "$label" ;;
    *) printf 'Install %s\n' "$label" ;;
  esac
}

cli_detail_menu() {
  local name="$1" label status action
  label="$(cli_label "$name")"
  while true; do
    status="$(cli_status "$name" 2>/dev/null || echo missing)"
    action="$(cli_action_label "$status" "$label")"
    menu_header
    printf '%s\n' "$label"
    printf 'Status: %s\n\n' "$status"
    cat <<MENU
1. Check Linker
2. $action
3. Uninstall $label
0. Back
MENU
    printf 'Pilih: '
    read -r choice || return 0
    case "$choice" in
      1)
        printf '%s status: %s\n' "$label" "$status"
        if [ -x "$PREFIX/bin/$name" ]; then "$PREFIX/bin/$name" --version || true; fi
        pause_menu
        ;;
      2)
        case "$status" in
          missing) install_one_cli "$name" ;;
          no_linker|broken) repair_one_cli "$name" ;;
          ok) install_one_cli "$name" ;;
          *) install_one_cli "$name" ;;
        esac
        pause_menu
        ;;
      3)
        printf 'Uninstall %s? [y/N]: ' "$label"
        read -r yes || true
        case "$yes" in y|Y|yes|YES) uninstall_one_cli "$name" ;; *) log "batal" ;; esac
        pause_menu
        ;;
      0) return 0 ;;
      *) warn "pilihan tidak valid"; pause_menu ;;
    esac
  done
}

cli_menu() {
  while true; do
    menu_header
    cat <<'MENU'
CLI Installer
1. Claude Code
2. Codex
3. OpenCode
4. OpenClaw
0. Back
MENU
    printf 'Pilih: '
    read -r choice || return 0
    case "$choice" in
      1) cli_detail_menu claude ;;
      2) cli_detail_menu codex ;;
      3) cli_detail_menu opencode ;;
      4) cli_detail_menu openclaw ;;
      0) return 0 ;;
      *) warn "pilihan tidak valid"; pause_menu ;;
    esac
  done
}

interactive_menu() {
  require_termux
  while true; do
    menu_header
    cat <<'MENU'
Menu Awal
1. glibc linker
2. CLI installer
3. Help
0. Exit
MENU
    printf 'Pilih: '
    read -r choice || return 0
    case "$choice" in
      1) linker_menu ;;
      2) cli_menu ;;
      3) usage; pause_menu ;;
      0) return 0 ;;
      *) warn "pilihan tidak valid"; pause_menu ;;
    esac
  done
}

main() {
  local cmd="${1:-menu}"
  [ $# -gt 0 ] && shift || true
  case "$cmd" in
    menu) interactive_menu ;;
    install) install_main "$@" ;;
    repair) repair_selected_tools "$@" ;;
    uninstall) uninstall_main "$@" ;;
    status) status_main ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
