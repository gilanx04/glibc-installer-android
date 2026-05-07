# glibc-installer-android

All-in-one installer glibc runner/wrapper/linker untuk Android Termux fresh.

Target:

- Termux dari F-Droid
- Android ARM64 / `aarch64`
- Tanpa `proot-distro`
- Node.js official `linux-arm64` lewat glibc dynamic linker
- Repair wrapper setelah update npm/nodejs/Claude Code/OpenCode/Codex

## Kenapa perlu ini

Binary Linux glibc biasanya punya interpreter:

```text
/lib/ld-linux-aarch64.so.1
```

Android/Termux tidak punya path itu. Efek umum:

```text
cannot execute: required file not found
```

Script ini memasang `glibc-runner`, lalu membuat wrapper yang menjalankan binary lewat:

```text
$PREFIX/glibc/lib/ld-linux-aarch64.so.1
```

Node.js juga dipasang sebagai runtime terkelola di:

```text
~/.glibc-installer-android/
```

## Fitur

- `install` — install base package, glibc-runner, Node.js glibc, npm/npx wrapper
- `repair` — bangun ulang wrapper setelah update npm/nodejs/CLI
- `uninstall` — hapus wrapper dan environment block
- optional installer:
  - Claude Code (`@anthropic-ai/claude-code`)
  - OpenCode (`opencode-ai`)
  - Codex (`@openai/codex`)
  - OpenClaw (`openclaw`)

## Menu interaktif

Jalankan tanpa argumen:

```bash
bash glibc-installer.sh
```

Menu awal:

```text
1. glibc linker
2. CLI installer
```

Submenu `glibc linker`:

```text
1. Check Linker
2. Install Linker
3. Repair Linker
4. Uninstall Linker
```

Submenu `CLI installer`:

```text
1. Claude Code
2. Codex
3. OpenCode
4. OpenClaw
```

Di tiap CLI, menu berubah sesuai kondisi:

- CLI belum ada → `Install [Nama CLI]`
- CLI ada tapi belum pakai linker → `Install Linker to [Nama CLI]`
- CLI ada tapi wrapper/linker rusak → `Repair [Nama CLI]`
- Semua OK → `Update [Nama CLI]`

## Install dari Termux fresh

```bash
pkg update -y && pkg install -y git bash curl
mkdir -p ~/glibc-installer-android
cd ~/glibc-installer-android
# taruh glibc-installer.sh di folder ini, lalu:
chmod +x glibc-installer.sh
bash glibc-installer.sh
```

Install runtime saja, tanpa CLI opsional dan tanpa menu:

```bash
bash glibc-installer.sh install
source ~/.bashrc
```

Install Claude Code saja:

```bash
bash glibc-installer.sh install --claude
source ~/.bashrc
claude --version
```

Install OpenCode saja:

```bash
bash glibc-installer.sh install --opencode
source ~/.bashrc
opencode --version
```

Install Codex saja:

```bash
bash glibc-installer.sh install --codex
source ~/.bashrc
codex --version
```

Install OpenClaw saja:

```bash
bash glibc-installer.sh install --openclaw
source ~/.bashrc
openclaw --version
```

## Versi Node.js

Default script memakai Node.js `22.22.2` karena Node 22 adalah LTS dan biasanya paling aman untuk npm CLI.

Versi Node.js tidak wajib `22.22.2`. Bisa pakai versi lebih baru selama tersedia di Node official untuk `linux-arm64`:

```text
https://nodejs.org/dist/v<VERSION>/node-v<VERSION>-linux-arm64.tar.xz
```

Cek versi tersedia:

```bash
curl -I https://nodejs.org/dist/v24.11.1/node-v24.11.1-linux-arm64.tar.xz
```

Jika output `HTTP/2 200` atau `HTTP/1.1 200`, versi bisa dipakai.

Install dengan versi Node lain:

```bash
NODE_VERSION=24.11.1 bash glibc-installer.sh install
source ~/.zshrc
node --version
```

Ganti Node.js setelah terlanjur install:

```bash
rm -rf ~/.glibc-installer-android/node \
       ~/.glibc-installer-android/bin/node \
       ~/.glibc-installer-android/bin/npm \
       ~/.glibc-installer-android/bin/npx

NODE_VERSION=24.11.1 bash ~/glibc-installer-android/glibc-installer.sh install
source ~/.zshrc
node --version
```

Rekomendasi:

```bash
# stabil / LTS
NODE_VERSION=22.22.2 bash glibc-installer.sh install

# lebih baru, jika mau coba
NODE_VERSION=24.11.1 bash glibc-installer.sh install
```

Catatan: Node 24 bisa jalan, tapi beberapa npm CLI/native dependency mungkin belum stabil. Jika CLI rusak setelah ganti Node, jalankan:

```bash
bash ~/glibc-installer-android/glibc-installer.sh repair --all
source ~/.zshrc
```

## Repair setelah update npm/nodejs/CLI

Jika pernah menjalankan:

```bash
npm install -g @anthropic-ai/claude-code@latest
npm install -g opencode-ai@latest
npm install -g @openai/codex@latest
```

lalu CLI rusak, jalankan:

```bash
bash ~/glibc-installer-android/glibc-installer.sh repair --all
source ~/.bashrc
```

Repair Claude Code saja:

```bash
bash ~/glibc-installer-android/glibc-installer.sh repair --claude
```

Repair OpenCode saja:

```bash
bash ~/glibc-installer-android/glibc-installer.sh repair --opencode
```

Repair Codex saja:

```bash
bash ~/glibc-installer-android/glibc-installer.sh repair --codex
```

Tanpa flag, repair mencoba semua CLI:

```bash
bash ~/glibc-installer-android/glibc-installer.sh repair
```

## Uninstall

Hapus wrapper dan environment block:

```bash
bash ~/glibc-installer-android/glibc-installer.sh uninstall
source ~/.bashrc
```

Simpan Node.js terkelola:

```bash
bash ~/glibc-installer-android/glibc-installer.sh uninstall --keep-node
```

Catatan: `glibc-runner` tidak dihapus otomatis karena mungkin dipakai tool lain.

## Status

```bash
bash ~/glibc-installer-android/glibc-installer.sh status
```

Output menampilkan:

- lokasi `ld.so`
- versi Node.js
- versi npm
- status `claude`, `opencode`, `codex`

## Path penting

```text
~/.glibc-installer-android/bin/node
~/.glibc-installer-android/bin/npm
~/.glibc-installer-android/bin/npx
~/.glibc-installer-android/node/
~/.glibc-installer-android/glibc-compat.js
$PREFIX/bin/claude
$PREFIX/bin/opencode
$PREFIX/bin/codex
```

## Cara kerja wrapper

Contoh wrapper native:

```bash
exec "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
  --library-path "$PREFIX/glibc/lib" \
  "/path/to/linux-arm64-binary" \
  "$@"
```

Wrapper juga:

- `unset LD_PRELOAD`
- set `TMPDIR`, `TMP`, `TEMP`
- pakai `$PREFIX/tmp`
- patch shebang `#!/usr/bin/env node` ke Node.js terkelola

## Troubleshooting

### `cannot execute: required file not found`

```bash
bash ~/glibc-installer-android/glibc-installer.sh repair --all
```

### `glibc linker missing`

```bash
bash ~/glibc-installer-android/glibc-installer.sh install
```

### `npm not found`

```bash
bash ~/glibc-installer-android/glibc-installer.sh install
source ~/.bashrc
```

### Setelah update Claude Code/OpenCode/Codex rusak

```bash
bash ~/glibc-installer-android/glibc-installer.sh repair --all
```

### Shell belum kenal command

```bash
source ~/.bashrc
```

Atau buka sesi Termux baru.

## Referensi

- https://github.com/AidanPark/openclaw-android
- https://github.com/gilanx04/Claude-Code-Android

## License

MIT
