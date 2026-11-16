#!/usr/bin/env bash
# halogen-replicate.sh - reproduce the frame (Strix Halo) host setup for halogen-flash-server.
#
# Copies the setup of the reference host "frame" (2026-11-16, Halogen 0.20.0), and installs the current :latest image:
#   * kernel boot parameters  amd_iommu=pt|off amdgpu.gttsize=131072 ttm.pages_limit=32505856
#                             ttm.page_pool_size=32505856 zswap.enabled=0
#   * the fabric clock (FCLK) hold: /usr/local/sbin/halogen-fabric-clock + halogen-fabric-clock.service
#   * unlimited memlock for all users (limits.d)
#   * memory guard: systemd-oomd policy, zram0 (zram-generator default) plus a 16 GiB fallback swapfile
#   * packages: Docker, AMD firmware, rocminfo, zram and oomd; the amdxdna DKMS driver only when the
#     kernel has none; host XRT only with --host-xrt (the image carries its own XRT since 0.19.1)
#     (Arch Linux and derivatives, Ubuntu 24.04+ / Debian, Fedora; see "Distribution notes" below)
#   * host checks from the upstream docs: kernel KFD gfx1151 fixes and SVM, GPU MEC firmware >= 0x24,
#     BIOS UMA carve-out at its minimum, the ACPI platform profile (set to performance, as on frame)
#   * the user in the docker group, plus lingering for user units
#   * the user unit halogen.service with the exact frame container settings and the current :latest
#     image (pinned to its digest in the unit),
#     installed but NOT enabled and NOT started (frame also keeps it boot-disabled)
#   * the froggeric v22.5 chat-template override (downloaded, SHA-256 checked)
#   * optional: an API key (--api-key-file) and a LAN forwarder socket (--lan-ip)
#   * optional: the companion dashboard (--dashboard), built from github.com/Quat3rnion/halogen-dashboard
#   * optional: the exact model files frame serves (--fetch-models, about 165 GB); otherwise the
#     script prints where each file comes from
#
# Default mode is a DRY RUN: it prints what it would change. Use --apply to change the system.
#
#   sudo ./halogen-replicate.sh [--apply] [options]
#     --apply              make the changes (otherwise dry run)
#     --iommu MODE         pt:  amd_iommu=pt. The NPU works (it needs the IOMMU): Halogen runs the NPU
#                               helpers (embeddings, decider, LFM3, image, speech). This is frame's setting.
#                          off: amd_iommu=off. No NPU: faster prompt reading (prefill) on the GPU, and the
#                               unit runs without NPU helpers, /dev/accel, XRT mounts or the fabric clock hold.
#                          Without --iommu the script asks (default pt); without a terminal it uses pt.
#                          Run the script again with the other mode to switch, then reboot.
#     --user NAME          user that runs Halogen (default: $SUDO_USER)
#     --models-dir DIR     peonist base assets (tokenizer, vision tower)  default /opt/models/peonist-ai/halogen-qwen3.8-flash-next
#     --v2-dir DIR         checkpoint + ngram table                       default ~USER/models/halogen-v2
#     --npu-dir DIR        NPU helper models (writable)                   default ~USER/models/halogen-npu
#     --cache-dir DIR      prompt cache (writable, mode 0700)             default ~USER/models/halogen-prompt-cache
#     --checkpoint FILE    checkpoint file name in --v2-dir               default qwen38-flash-next-v2-abliterated-r2.hgn
#     --npu-models LIST    HALOGEN_NPU_MODELS value                       default: frame's seven helpers
#     --lan-ip ADDR        also install a socket forwarder ADDR:8731 -> 127.0.0.1:8731
#                          (without --api-key-file anyone on that network can use the API)
#     --api-key-file PATH  require an API key: HALOGEN_API_KEY_FILE, mounted read-only. The file is
#                          created (random key, mode 0600, owned by --user) when it does not exist.
#                          /health stays open. Clients send "Authorization: Bearer <key>".
#     --image REF          container image (default ghcr.io/peonist-ai/halogen-flash-server:latest). The
#                          script pulls it and writes the resolved @sha256 digest into the unit, so a restart
#                          never changes the version by surprise; re-run the script to move to a newer :latest.
#                          --fetch-models reads the NPU file pins from this image. Frame ran 0.20.0
#                          (@sha256:2d2c55a1...) when this script was written.
#     --shared-host        the machine also runs other large programs: set vm.compact_unevictable_allowed=0
#                          (upstream pairs it with HALOGEN_WEIGHTS_LOCK=1 on a shared host; frame keeps 1)
#     --conflicts "UNITS"  user units that must not run beside Halogen (systemd Conflicts=, both ways for
#                          units started by the same manager), for example "ollama.service llama-server.service"
#     --dashboard          also build and run the companion dashboard, github.com/Quat3rnion/halogen-dashboard
#                          (Collector + web page; the only reader of Halogen's /metrics). No published image
#                          exists, so it is built from a pinned commit (needs git and a few minutes of CPU).
#     --dashboard-bind A   address for the dashboard (default 127.0.0.1; 0.0.0.0 opens it on the LAN)
#     --dashboard-port N   port for the dashboard (default 8790)
#     --dashboard-ref REF  dashboard git commit, tag or branch (default: the pinned commit below)
#     --fetch-models       download the model files (as --user, with the Hugging Face CLI) at the exact
#                          revisions frame runs; the NPU revisions come from the image's own pin list
#     --host-xrt           mount the host's XRT over the image's (upstream: "you rarely need this"; only
#                          when the server says the NPU driver refused the image's XRT). Needs XRT >= 2.20.
#     --no-power-profile   do not change the ACPI platform profile
#     --no-cmdline         do not touch the kernel command line
#     --bootloader LIST    boot loader(s) to configure instead of auto-detection, space separated:
#                          systemd-boot, uki, grub, refind, limine, extlinux, efistub, none
#     --entries MODE       default (default): only the default boot entry; all: every entry except
#                          fallback/rescue/recovery ones (frame changed only its default entry)
#     --no-swap            do not create swap/zram/oomd settings
#     --no-packages        do not install packages
#     --cmdline-only       only run the hardware check and the kernel command-line step
#     --no-ppa             Ubuntu before 26.04: do not add ppa:lemonade-team/stable for XRT
#     --scale-memory       scale gttsize/ttm limits to this machine's RAM instead of frame's 128 GB values
#     -h, --help
#
# Things a script cannot set; check them yourself:
#   * BIOS: UMA frame buffer / "dedicated VRAM" = 512 MB (frame reads mem_info_vram_total = 536870912).
#     The large pool comes from GTT (system RAM), not from the BIOS carve-out.
#   * 128 GB RAM. Frame's container limit is 108 GiB; on a smaller machine the 4-slot KV pool and
#     seven NPU helpers will not fit.
#   * Reboot after the kernel command-line change.
#
# Boot loaders (any distribution; auto-detected from the EFI loader variables, /proc/cmdline and
# the files in the ESP and /boot; every detected one is configured):
#   * systemd-boot  options line of loader/entries/*.conf; also /etc/kernel/cmdline when kernel-install
#                   manages the entries (Fedora, Ubuntu), so new kernels keep the parameters
#   * uki           /etc/kernel/cmdline (or /etc/cmdline.d/ for mkinitcpio), then the images are rebuilt
#                   (mkinitcpio -P, dracut --regenerate-all, or kernel-install add)
#   * grub          BLS + grubby (Fedora/RHEL); /etc/default/grub.d/90-halogen.cfg (Debian/Ubuntu);
#                   otherwise GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub; then update-grub or
#                   grub-mkconfig / grub2-mkconfig
#   * refind        refind_linux.conf next to the kernel (manual refind.conf stanzas: by hand)
#   * limine        /etc/default/limine + limine-update (limine-entry-tool), or cmdline: in limine.conf
#   * extlinux      APPEND lines in extlinux.conf / syslinux.cfg
#   * efistub       firmware boot entry: the script prints the efibootmgr command; you run it
#
# Distribution notes:
#   * Arch:   docker, AMD firmware; xrt + xrt-plugin-amdxdna only with --host-xrt. Frame is Arch.
#   * Ubuntu: docker.io. The in-tree amdxdna driver needs kernel 6.14+ (24.04: linux-generic-hwe-24.04);
#             without it, 24.04 and 25.10 get amdxdna-dkms from ppa:lemonade-team/stable. With
#             --host-xrt: 26.04 libxrt2 / libxrt-npu2 from universe, older releases from that PPA.
#   * Fedora: docker from moby-engine. With --host-xrt: xrt, packaged only in Rawhide and EPEL 10 when
#             this was written; otherwise build it from https://github.com/amd/xdna-driver.
#             With SELinux enabled, the unit adds --security-opt label=disable (frame has no SELinux)
#             instead of relabelling model folders and host libraries. user@.service gets
#             LimitMEMLOCK=infinity, as AMD's xdna-driver README asks for on Fedora.
set -Eeuo pipefail
shopt -s lastpipe   # put_file at the end of a pipeline runs in this shell (PUT_CHANGED)
PUT_CHANGED=0

# ---------------- frame reference values ----------------
IMAGE='ghcr.io/peonist-ai/halogen-flash-server:latest'
FRAME_IMAGE='ghcr.io/peonist-ai/halogen-flash-server@sha256:2d2c55a17e71f1aaf812b4e4cf0783dc5a8258461f8b3d9d7d84a9697fcfe637'   # 0.20.0
DASH_REPO=https://github.com/Quat3rnion/halogen-dashboard.git
DASH_REF_DEFAULT=7f52ec2f864d148c96a5f87a01ad55309e920b63
CMDLINE_PARAMS=(amd_iommu=pt amdgpu.gttsize=131072 ttm.pages_limit=32505856 ttm.page_pool_size=32505856 zswap.enabled=0)
NPU_MODELS_DEFAULT='decider-0.8b,/models/npu/LFM3-1.7B,qwen3-embedding-0.6b,flux2-klein-4b,qwen3-asr-1.7b,qwen3-tts-1.7b-customvoice,qwen3guard-gen-0.6b'
TEMPLATE_URL='https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates/resolve/855bffc49448e299789730ff92c9b8d834d6cc14/chat_template.jinja'
TEMPLATE_SHA='e57684bae4156211a55473c5a63be976a405a37ab5be5ae0e5abf1df5349c4b2'
SWAPFILE=/swap/halogen-memory-guard.swap
SWAP_GIB=16
# Model files frame serves (repository@revision, file, SHA-256 where known).
HF_BASE_REPO=peonist-ai/halogen-qwen3.8-flash-next
HF_BASE_REV=e053f488b120b99ed2525e6ac99f68c51b3b6179        # tokenizer/ and the vision tower, as on frame
HF_NGRAM_REV=e3b33d6422216419d46434c2d9a64d82a9654d08       # qwen38-flash-next-ngram.hgn (added after e053f488)
NGRAM_SHA=3450acada94e19aabad88bd49b45eb70304820949c2240fc178067b20ae5dffe
HF_CKPT_REPO=Quat3rnion/halogen-qwen3.8-flash-next-v2-abliterated
HF_CKPT_REV=e7783c5822dfda2785a0f5b435abf54df89fe8ee        # the "r2" checkpoint frame serves (later commits replaced it)
HF_CKPT_FILE=qwen38-flash-next-v2-abliterated.hgn
CKPT_SHA=7bbac319851b500639462133085156b4f998dec562f511e65ca1c14d7af5163e
# Versions that frame ran when the 0.20.0 setup passed acceptance (for the report only).
REF_VERSIONS='kernel 7.2.9-arch1, linux-firmware 20261019, MEC firmware 0x24, NPU firmware 1.1.2.65, image XRT (no host mount), docker 29.9'

# ---------------- options ----------------
APPLY=0; RUN_USER="${SUDO_USER:-}"; MODELS_DIR=/opt/models/peonist-ai/halogen-qwen3.8-flash-next
V2_DIR=""; NPU_DIR=""; CACHE_DIR=""; CHECKPOINT=qwen38-flash-next-v2-abliterated-r2.hgn
NPU_MODELS="$NPU_MODELS_DEFAULT"; LAN_IP=""; DO_CMDLINE=1; DO_SWAP=1; DO_PKG=1; SCALE=0; USE_PPA=1; BOOTLOADER=""; ENTRIES=default; CMDLINE_ONLY=0; IOMMU=""; NPU_MODELS_SET=0; API_KEY_FILE=""; FETCH=0; HOST_XRT=0; DO_POWER=1; SHARED=0; CONFLICTS=""; DASH=0; DASH_BIND=127.0.0.1; DASH_PORT=8790; DASH_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --user) RUN_USER="$2"; shift ;;
    --models-dir) MODELS_DIR="$2"; shift ;;
    --v2-dir) V2_DIR="$2"; shift ;;
    --npu-dir) NPU_DIR="$2"; shift ;;
    --cache-dir) CACHE_DIR="$2"; shift ;;
    --checkpoint) CHECKPOINT="$2"; shift ;;
    --npu-models) NPU_MODELS="$2"; NPU_MODELS_SET=1; shift ;;
    --iommu) IOMMU="$2"; shift ;;
    --lan-ip) LAN_IP="$2"; shift ;;
    --api-key-file) API_KEY_FILE="$2"; shift ;;
    --image) IMAGE="$2"; shift ;;
    --fetch-models) FETCH=1 ;;
    --host-xrt) HOST_XRT=1 ;;
    --no-power-profile) DO_POWER=0 ;;
    --shared-host) SHARED=1 ;;
    --conflicts) CONFLICTS="$2"; shift ;;
    --dashboard) DASH=1 ;;
    --dashboard-bind) DASH_BIND="$2"; shift ;;
    --dashboard-port) DASH_PORT="$2"; shift ;;
    --dashboard-ref) DASH_REF="$2"; shift ;;
    --no-cmdline) DO_CMDLINE=0 ;;
    --bootloader) BOOTLOADER="$2"; shift ;;
    --entries) ENTRIES="$2"; shift; case "$ENTRIES" in default|all) ;; *) echo "--entries default|all" >&2; exit 2 ;; esac ;;
    --no-swap) DO_SWAP=0 ;;
    --no-packages) DO_PKG=0 ;;
    --cmdline-only) CMDLINE_ONLY=1 ;;
    --no-ppa) USE_PPA=0 ;;
    --scale-memory) SCALE=1 ;;
    -h|--help) awk 'NR > 1 && /^set -Eeuo/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (use --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------------- IOMMU mode: pt (NPU) or off (faster prefill, no NPU) ----------------
CUR_IOMMU=$(tr ' ' '\n' </proc/cmdline | sed -n 's/^amd_iommu=//p' | tail -1 || true)
if [ -z "$IOMMU" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    cat <<EOF
amd_iommu decides whether the NPU can be used (currently booted with: amd_iommu=${CUR_IOMMU:-<not set>}):
  pt   the NPU works: Halogen also runs its NPU helpers (embeddings, decider, LFM3, image, speech).
       This is frame's setting.
  off  no NPU: faster prompt reading (prefill) on the GPU; the NPU helpers are turned off.
EOF
    while :; do
      read -r -p "amd_iommu mode [pt/off] (default pt): " IOMMU
      IOMMU=${IOMMU:-pt}
      case "$IOMMU" in pt|off) break ;; *) echo "please answer pt or off" ;; esac
    done
  else
    IOMMU=pt
    echo "(no terminal: using --iommu pt; pass --iommu off for the no-NPU, faster-prefill setup)"
  fi
fi
case "$IOMMU" in pt|off) ;; *) echo "--iommu must be pt or off" >&2; exit 2 ;; esac
CMDLINE_PARAMS[0]="amd_iommu=$IOMMU"
if [ "$IOMMU" = off ]; then
  [ "$NPU_MODELS_SET" = 1 ] && [ -n "$NPU_MODELS" ] && echo "note: --iommu off: ignoring --npu-models (the NPU is not available without the IOMMU)"
  NPU_MODELS=""
fi

if [ "$(id -u)" -ne 0 ]; then
  [ "$APPLY" = 1 ] && { echo "--apply needs sudo" >&2; exit 1; }
  echo "(dry run without root: some checks are incomplete)"
  : "${RUN_USER:=$(id -un)}"
fi
[ -n "$RUN_USER" ] && id "$RUN_USER" >/dev/null 2>&1 || { echo "set --user NAME (the account that runs Halogen)" >&2; exit 1; }
[ "$RUN_USER" != root ] || { echo "Halogen runs as a normal user's systemd unit; pick a non-root --user" >&2; exit 1; }
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
RUN_UID=$(id -u "$RUN_USER")
: "${V2_DIR:=$RUN_HOME/models/halogen-v2}"
: "${NPU_DIR:=$RUN_HOME/models/halogen-npu}"
: "${CACHE_DIR:=$RUN_HOME/models/halogen-prompt-cache}"
TS=$(date +%Y%m%d%H%M%S)
BK=".pre-halogen-$TS"

# ---------------- helpers: output, progress, log ----------------
# Colours and spinners only on a terminal; NO_COLOR (https://no-color.org) turns colours off.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  C_B=$'\e[1m'; C_D=$'\e[2m'; C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else C_B=""; C_D=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_0=""; fi
TTY=0; [ -t 1 ] && TTY=1
# Full command output goes to a log; the screen shows one line a command.
LOG_DIR=/var/log; [ -w "$LOG_DIR" ] || LOG_DIR="${TMPDIR:-/var/tmp}"
LOG="$LOG_DIR/halogen-replicate-$TS.log"
: >"$LOG" 2>/dev/null || { LOG=/dev/null; }
STEP_N=0; STEP_TOTAL=12; WARNINGS=(); CHANGES=(); T_START=$SECONDS
log() { printf '%s %s\n' "$(date '+%T')" "$*" >>"$LOG"; }
step() {
  local t; t=$(printf '%s' "$*" | sed -E 's/^[0-9]+[a-z]?\. //'); STEP_N=$((STEP_N + 1))
  printf '\n%s[%d/%d] %s%s\n' "$C_B$C_C" "$STEP_N" "$STEP_TOTAL" "$t" "$C_0"; log "== $t"
}
note() { printf '  %s•%s %s\n' "$C_D" "$C_0" "$*"; log "  $*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; log "  ok: $*"; }
warn() { printf '  %s! %s%s\n' "$C_Y" "$*" "$C_0"; log "  WARNING: $*"; WARNINGS+=("$*"); }
fail() { printf '  %s✗ %s%s\n' "$C_R" "$*" "$C_0" >&2; log "  ERROR: $*"; }
plan() { printf '  %s→ would %s%s\n' "$C_D" "$*" "$C_0"; log "  would $*"; }
fmt_t() { local t=$1; [ "$t" -ge 60 ] && printf '%dm%02ds' $((t / 60)) $((t % 60)) || printf '%ds' "$t"; }
# run LABEL CMD...: run CMD with its output in the log. On a terminal a spinner shows the elapsed
# time; on failure the last lines of the output are shown and the script stops.
run() {
  local label="$1"; shift
  if [ "$APPLY" = 0 ]; then plan "run: $*"; return 0; fi
  log "+ $*"
  local t0=$SECONDS rc=0 pid i=0 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' nf=10
  case "$(locale charmap 2>/dev/null)" in UTF-8|utf8) ;; *) frames='|/-\\'; nf=4 ;; esac
  "$@" >>"$LOG" 2>&1 </dev/null & pid=$!
  if [ "$TTY" = 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s %s(%s)%s\e[K' "$C_C" "${frames:i++%nf:1}" "$C_0" "$label" "$C_D" "$(fmt_t $((SECONDS - t0)))" "$C_0"
      sleep 0.1
    done
    printf '\r\e[K'
  fi
  wait "$pid" || rc=$?
  if [ "$rc" = 0 ]; then ok "$label $C_D($(fmt_t $((SECONDS - t0))))$C_0"; CHANGES+=("$label"); return 0; fi
  fail "$label failed (exit $rc). Last lines of $LOG:"
  tail -n 15 "$LOG" | sed 's/^/      /' >&2
  [ "${RUN_SOFT:-0}" = 1 ] && return "$rc"
  exit "$rc"
}
# run_live LABEL CMD...: for commands with their own progress bar (downloads): output on screen and in the log.
run_live() {
  local label="$1"; shift
  if [ "$APPLY" = 0 ]; then plan "run: $*"; return 0; fi
  log "+ $*"; printf '  %s↓%s %s\n' "$C_C" "$C_0" "$label"
  local t0=$SECONDS
  if "$@" 2>&1 | tee -a "$LOG"; then ok "$label $C_D($(fmt_t $((SECONDS - t0))))$C_0"; CHANGES+=("$label")
  else fail "$label failed; see $LOG"; exit 1; fi
}
# doit CMD...: a short command (kept for the many one-line actions)
doit() { run "$*" "$@"; }
backup() { [ -e "$1" ] && [ "$APPLY" = 1 ] && cp -a -- "$1" "$1$BK" && printf '  %s  backup: %s%s\n' "$C_D" "$1$BK" "$C_0" && log "  backup: $1$BK"; return 0; }
# sha_check FILE SHA: SHA-256 with a progress bar (pv when installed, otherwise a spinner)
sha_check() {
  local f="$1" want="$2" got t0=$SECONDS size
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "$TTY" = 1 ] && command -v pv >/dev/null; then
    printf '  %s#%s checking %s (%s GiB)\n' "$C_C" "$C_0" "${f##*/}" $((size / 1073741824))
    got=$(pv -pterb -w 72 "$f" | sha256sum | cut -d' ' -f1)
  else
    RUN_SOFT=1 run "SHA-256 of ${f##*/} ($((size / 1073741824)) GiB)" sh -c "sha256sum '$f' > '$f.sha256.tmp'" || true
    got=$(cut -d' ' -f1 "$f.sha256.tmp" 2>/dev/null || true); rm -f "$f.sha256.tmp"
  fi
  if [ "$got" = "$want" ]; then ok "${f##*/}: SHA-256 matches ($(fmt_t $((SECONDS - t0))))"
  else fail "${f##*/}: SHA-256 ${got:-?} does not match $want"; WARNINGS+=("SHA-256 mismatch: $f"); fi
}
# user_dir [-m MODE] DIR: create DIR owned by the user. Below $RUN_HOME every missing level is created
# as the user, and a level that an earlier root run left owned by root is given back (a root-owned
# ~/.config breaks the user's own programs and systemctl --user).
user_dir() {
  local mode="" d rel acc
  [ "$1" = -m ] && { mode=$2; shift 2; }
  d=$1
  if [ "$APPLY" = 0 ]; then [ -d "$d" ] || plan "create folder $d (owner $RUN_USER)"; return 0; fi
  case "$d" in
    "$RUN_HOME"/*)
      rel=${d#"$RUN_HOME"/}; acc=$RUN_HOME
      local IFS=/
      for part in $rel; do
        acc="$acc/$part"
        if [ ! -d "$acc" ]; then mkdir "$acc"; chown "$RUN_USER:$(id -gn "$RUN_USER")" "$acc"; log "  mkdir $acc"
        elif [ "$(stat -c %u "$acc")" = 0 ]; then chown "$RUN_USER:$(id -gn "$RUN_USER")" "$acc"; log "  chown $acc (was root)"; fi
      done ;;
    *) [ -d "$d" ] || install -d -o "$RUN_USER" -g "$(id -gn "$RUN_USER")" "$d" ;;
  esac
  if [ -n "$mode" ]; then chmod "$mode" "$d"; fi
  return 0
}
# same_file A B: byte-identical (cmp is not on minimal images; cksum is in coreutils)
same_file() { [ "$(cksum <"$1")" = "$(cksum <"$2")" ]; }
# put_file PATH MODE OWNER  (content on stdin); only writes when the content differs
put_file() {
  local path="$1" mode="$2" owner="$3" tmp
  tmp=$(mktemp "${TMPDIR:-/var/tmp}/halogen-rep.XXXXXX")
  cat >"$tmp"
  if [ -f "$path" ] && same_file "$tmp" "$path"; then printf '  %s= unchanged: %s%s\n' "$C_D" "$path" "$C_0"; log "  unchanged: $path"; rm -f "$tmp"; return 0; fi
  PUT_CHANGED=1
  if [ "$APPLY" = 1 ]; then
    backup "$path"
    [ "${owner%%:*}" = root ] || user_dir "$(dirname "$path")"
    install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
    ok "wrote: $path"; CHANGES+=("wrote $path")
  else
    plan "write: $path ($mode $owner)"
    if [ -f "$path" ] && command -v diff >/dev/null; then diff -u "$path" "$tmp" | sed 's/^/      /' | head -40 || true
    else sed 's/^/      | /' "$tmp" | head -120; fi
  fi
  rm -f "$tmp"
}
as_user() { sudo -u "$RUN_USER" XDG_RUNTIME_DIR="/run/user/$RUN_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$RUN_UID/bus" "$@"; }

printf '%shalogen-replicate%s  user %s  ·  amd_iommu=%s  ·  %s\n' "$C_B" "$C_0" "$RUN_USER" "$IOMMU" "$( [ "$APPLY" = 1 ] && echo "${C_Y}APPLY: the system will change${C_0}" || echo "${C_G}dry run: nothing changes${C_0} (add --apply)")"
printf '%slog: %s%s\n' "$C_D" "$LOG" "$C_0"

# ---------------- 0. hardware check ----------------
step "0. hardware check"
GPU=$(lspci -Dn 2>/dev/null | awk '$3 ~ /^1002:1586/ {print $1}' | head -1 || true)
NPU=$(lspci -Dn 2>/dev/null | awk '$3 ~ /^1022:(17f0|1502)/ {print $1}' | head -1 || true)
[ -n "$GPU" ] && ok "GPU 1002:1586 (Radeon 8060S) at $GPU" || warn "no Strix Halo GPU (1002:1586) found; frame's settings target that chip"
if [ -n "$NPU" ]; then ok "NPU (XDNA) at $NPU"
elif [ "$IOMMU" = pt ]; then warn "no XDNA NPU found; NPU helpers will not work (consider --iommu off)"
fi
MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
note "RAM: $((MEM_KB/1048576)) GiB (frame: 125 GiB visible with 512 MB UMA)"
[ "$MEM_KB" -ge 120000000 ] || warn "less than ~120 GiB RAM: frame's 108 GiB container and 4-slot KV pool will not fit; frame's gttsize/ttm values exceed this RAM: use --scale-memory"
for f in /sys/class/drm/card*/device/mem_info_vram_total; do
  [ -r "$f" ] && [ "$(cat "${f%/*}/vendor")" = 0x1002 ] || continue
  UMA_MIB=$(( $(cat "$f") / 1048576 ))
  if [ "$UMA_MIB" -gt 2048 ]; then
    warn "BIOS UMA carve-out is $UMA_MIB MiB: set the UMA frame buffer to its minimum, not Auto (frame: 512 MiB; some boards stop at 2 GiB). Halogen wants system RAM (GTT), not dedicated VRAM."
  else ok "BIOS UMA carve-out: $UMA_MIB MiB (frame: 512 MiB)"; fi
  # GPU compute firmware: MEC older than 0x24 fails long prompts (INVALID_DISPATCH_PARAMETERS, upstream #128)
  mec=$(cat "${f%/*}/fw_version/mec_fw_version" 2>/dev/null || true)
  if [ -n "$mec" ]; then
    if [ $((mec)) -lt $((0x24)) ]; then warn "GPU MEC firmware $mec is older than 0x24: update linux-firmware (2026 releases)"
    else ok "GPU MEC firmware $mec (needs >= 0x24)"; fi
  fi
  gtt_used=$(cat "${f%/*}/mem_info_gtt_used" 2>/dev/null || echo 0)
  if [ "$gtt_used" -gt $((10 * 1073741824)) ] && ! pgrep -f flash_serve >/dev/null 2>&1; then
    warn "$((gtt_used / 1073741824)) GiB of GTT is in use with no Halogen engine running: after an unclean exit the driver can keep it; reboot before starting Halogen"
  fi
done
# KFD: AMD's two gfx1151 fixes and CONFIG_HSA_AMD_SVM (upstream troubleshooting: kernel floor
# 6.18.4, Ubuntu 24.04 HWE 6.17.0-19.19~24.04.2, OEM 6.14.0-1018; Fedora 6.18.6-200.fc43 lacked SVM)
KFD_OK=""
for n in /sys/class/kfd/kfd/topology/nodes/*/properties; do
  [ -r "$n" ] || continue
  awk '$1=="gfx_target_version"{exit !($2==110501)}' "$n" || continue
  cap=$(awk '$1=="capability"{print $2}' "$n"); simd=$(awk '$1=="simd_count"{print $2}' "$n")
  cwsr=$(awk '$1=="cwsr_size"{print $2}' "$n"); ctl=$(awk '$1=="ctl_stack_size"{print $2}' "$n")
  KFD_OK=1
  if [ $(( cap & 0x08000000 )) -eq 0 ]; then warn "KFD has no SVM support (CONFIG_HSA_AMD_SVM): Halogen cannot register its read-only checkpoint; use another kernel"; KFD_OK=0; fi
  if [ -z "$cwsr" ] || [ "$cwsr" != $(( ctl + simd / 2 * 479232 )) ]; then warn "KFD lacks AMD's gfx1151 fixes (cwsr_size): needs Linux 6.18.4+, Ubuntu 24.04 HWE 6.17.0-19.19~24.04.2+ or OEM 6.14.0-1018+"; KFD_OK=0; fi
  [ "$KFD_OK" = 1 ] && ok "kernel: KFD shared virtual memory on, gfx1151 fixes present"
done
[ -n "$KFD_OK" ] || warn "no KFD node with gfx_target_version 110501 (amdgpu not loaded, or not a Strix Halo GPU): cannot check the kernel"
if [ -r /sys/firmware/acpi/platform_profile ]; then
  PROFILE=$(cat /sys/firmware/acpi/platform_profile)
  note "ACPI platform profile: $PROFILE (choices: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null); frame: performance)"
fi
. /etc/os-release 2>/dev/null || true
case " ${ID:-} ${ID_LIKE:-} " in
  *" arch "*) DISTRO=arch ;;
  *" fedora "*) DISTRO=fedora ;;
  *" ubuntu "*|*" debian "*) DISTRO=debian ;;
  *) DISTRO=other ;;
esac
note "OS: ${PRETTY_NAME:-unknown} (family: $DISTRO); kernel $(uname -r). Frame reference: $REF_VERSIONS"
KVER=$(uname -r | awk -F'[.-]' '{printf "%d%03d", $1, $2}')
[ "$KVER" -ge 6014 ] || warn "kernel older than 6.14 has no in-tree amdxdna driver (Ubuntu 24.04: install linux-generic-hwe-24.04, or amdxdna-dkms)"
SELINUX=0
if command -v getenforce >/dev/null && [ "$(getenforce 2>/dev/null)" != Disabled ]; then SELINUX=1; fi
[ "$SELINUX" = 1 ] && note "SELinux is $(getenforce): the unit will use --security-opt label=disable"

# ---------------- 1. packages ----------------
step "1. packages"
[ "$CMDLINE_ONLY" = 1 ] && DO_PKG=0
APT_UPDATED=0
# pkg_install [--optional] PKG...   install with the native package manager
pkg_install() {
  local opt=0 cmd
  [ "${1:-}" = --optional ] && { opt=1; shift; }
  case "$DISTRO" in
    arch)   cmd=(pacman -S --needed --noconfirm "$@") ;;
    debian) if [ "$APT_UPDATED" = 0 ]; then run "refresh package lists" apt-get update; APT_UPDATED=1; fi
            cmd=(env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@") ;;
    fedora) cmd=(dnf install -y "$@") ;;
    *) warn "unknown distribution: install by hand: $*"; return 0 ;;
  esac
  if [ "$opt" = 1 ]; then
    RUN_SOFT=1 run "install $*" "${cmd[@]}" || warn "could not install: $* (continuing)"
  else run "install $*" "${cmd[@]}"; fi
}
NEED_DKMS=0
# loaded now, or available for the running kernel (after a kernel upgrade without a reboot the
# running kernel's modules can be gone, so check /sys/module first)
if [ "$IOMMU" = pt ] && [ ! -d /sys/module/amdxdna ] && ! modinfo amdxdna >/dev/null 2>&1; then NEED_DKMS=1; fi
[ "$IOMMU" = pt ] && [ "$NEED_DKMS" = 0 ] && note "the kernel has the amdxdna NPU driver; no DKMS driver needed"
if [ "$DO_PKG" = 0 ]; then note "skipped (--no-packages)"
else
  case "$DISTRO" in
    arch)
      pkg_install docker linux-firmware-amdgpu linux-firmware-amd rocminfo curl
      [ "$HOST_XRT" = 1 ] && pkg_install xrt xrt-plugin-amdxdna
      [ "$NEED_DKMS" = 1 ] && warn "this kernel has no amdxdna: use a kernel with it (linux, linux-lts >= 6.14) or the AUR amdxdna-dkms" ;;
    debian)
      pkg_install docker.io linux-firmware curl
      pkg_install --optional rocminfo
      UBU_VER=$(printf '%s' "${VERSION_ID:-0}" | tr -d .)
      if [ "${ID:-}" = ubuntu ] && [ "${UBU_VER:-0}" -lt 2604 ] && { [ "$NEED_DKMS" = 1 ] || [ "$HOST_XRT" = 1 ]; }; then
        if [ "$USE_PPA" = 1 ]; then
          pkg_install software-properties-common
          doit add-apt-repository -y ppa:lemonade-team/stable
          APT_UPDATED=0
          # AMD's DKMS 2.23 with XRT 2.23 is a known bad pair (NPU stalls); the PPA carries 2.25.
          [ "$NEED_DKMS" = 1 ] && pkg_install amdxdna-dkms
          [ "$HOST_XRT" = 1 ] && pkg_install libxrt-npu2 && pkg_install --optional libxrt-utils-npu
        else warn "Ubuntu ${VERSION_ID:-?} with --no-ppa: install the amdxdna driver (and XRT for --host-xrt) by hand"; fi
      elif [ "$HOST_XRT" = 1 ]; then
        pkg_install libxrt2 libxrt-npu2
        pkg_install --optional libxrt-utils-npu
      elif [ "$NEED_DKMS" = 1 ]; then
        warn "this kernel has no amdxdna: install the HWE kernel (linux-generic-hwe-24.04) or amdxdna-dkms"
      fi ;;
    fedora)
      pkg_install moby-engine curl linux-firmware amd-gpu-firmware
      pkg_install --optional rocminfo
      if [ "$HOST_XRT" = 1 ]; then
        pkg_install --optional xrt
        rpm -q xrt >/dev/null 2>&1 || warn "no Fedora xrt package (only Rawhide/EPEL 10 had one): build it from https://github.com/amd/xdna-driver"
      fi
      [ "$NEED_DKMS" = 1 ] && warn "this kernel has no amdxdna: update the kernel" ;;
    *) warn "unknown distribution: install Docker, current linux-firmware and curl yourself (and the amdxdna driver if the kernel lacks it)" ;;
  esac
  [ "$FETCH" = 1 ] && [ "$DISTRO" = debian ] && pkg_install --optional python3-venv
  [ "$DASH" = 1 ] && ! command -v git >/dev/null && pkg_install git
  # the dashboard's Dockerfile uses RUN --mount, which needs BuildKit (the buildx plugin)
  [ "$DASH" = 1 ] && ! docker buildx version >/dev/null 2>&1 && pkg_install docker-buildx
fi
if [ "$CMDLINE_ONLY" = 0 ]; then
  getent group docker >/dev/null || doit groupadd docker
  doit systemctl enable --now docker.service
fi

# ---------------- 2. kernel command line ----------------
step "2. kernel command line: ${CMDLINE_PARAMS[*]}"
if [ "$SCALE" = 1 ]; then
  # Upstream's table (docs/troubleshooting.md): gttsize in MiB = pages / 256. Frame keeps 131072
  # (slightly above upstream's 126976 for 128 GB) without --scale-memory.
  MEM_GIB=$(( MEM_KB / 1048576 ))
  if   [ "$MEM_GIB" -ge 110 ]; then TTM_PAGES=32505856
  elif [ "$MEM_GIB" -ge 80 ];  then TTM_PAGES=24379392
  elif [ "$MEM_GIB" -ge 50 ];  then TTM_PAGES=16252928
  else TTM_PAGES=$(( MEM_KB * 993 / 1000 / 4 )); fi
  GTT_MIB=$(( TTM_PAGES / 256 ))
  CMDLINE_PARAMS=("amd_iommu=$IOMMU" "amdgpu.gttsize=$GTT_MIB" "ttm.pages_limit=$TTM_PAGES" "ttm.page_pool_size=$TTM_PAGES" zswap.enabled=0)
  note "scaled to this RAM: ${CMDLINE_PARAMS[*]}"
fi
add_params() {  # add_params "<existing options>": keep existing order, set frame's values, append missing ones
  local opts=" $1 " p k
  for p in "${CMDLINE_PARAMS[@]}"; do
    case "$opts" in *" $p "*) continue ;; esac
    k="${p%%=*}"
    opts=$(printf '%s' "$opts" | sed -E "s/[[:space:]]${k//./\\.}=[^[:space:]]*/ /g")
    opts="$opts $p "
  done
  printf '%s' "$opts" | tr -s ' ' | sed -E 's/^ //; s/ $//'
}
CMDLINE_CHANGED=0
# Test hooks only: HALOGEN_REP_EFIVARS and HALOGEN_REP_CMDLINE replace the EFI variable folder and /proc/cmdline.
EFIVARS=${HALOGEN_REP_EFIVARS:-/sys/firmware/efi/efivars}
PROC_CMDLINE=${HALOGEN_REP_CMDLINE:-/proc/cmdline}
EFIGUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
efivar_str() {  # efivar_str NAME: print a systemd loader-interface EFI variable as text
  local f="$EFIVARS/$1-$EFIGUID"
  [ -r "$f" ] && tail -c +5 "$f" 2>/dev/null | tr -d '\0'
  return 0
}
# opts_in_line_set OLD -> 0 when OLD already has every frame parameter
has_all_params() { local p; for p in "${CMDLINE_PARAMS[@]}"; do case " $1 " in *" $p "*) ;; *) return 1 ;; esac; done; return 0; }
is_fallback() { case "$1" in *[Ff]allback*|*[Rr]escue*|*[Rr]ecovery*) return 0 ;; esac; return 1; }

# Candidate folders that can hold boot files (ESP, XBOOTLDR, /boot).
boot_dirs() {
  { bootctl --print-esp-path 2>/dev/null; bootctl --print-boot-path 2>/dev/null
    for d in /boot /boot/efi /efi; do [ -d "$d" ] && echo "$d"; done; } | awk 'NF && !seen[$0]++'
}

# ---- detection ----
detect_bootloaders() {
  local info stub d found=""
  info=$(efivar_str LoaderInfo); stub=$(efivar_str StubInfo)
  [ -n "$stub" ] && found="$found uki"
  case "$info" in
    *systemd-boot*) found="$found systemd-boot" ;;
    *GRUB*|*grub*)  found="$found grub" ;;
    *[Ll]imine*)    found="$found limine" ;;
    *rEFInd*|*refind*) found="$found refind" ;;
  esac
  grep -q 'BOOT_IMAGE=' "$PROC_CMDLINE" && found="$found grub"
  for d in $(boot_dirs); do
    [ -f "$d/limine.conf" ] || [ -f "$d/limine/limine.conf" ] || [ -f "$d/EFI/BOOT/limine.conf" ] || [ -f "$d/EFI/limine/limine.conf" ] && found="$found limine"
    ls "$d"/loader/entries/*.conf >/dev/null 2>&1 && [ -d "$d/EFI/systemd" ] && found="$found systemd-boot"
    [ -f "$d/refind_linux.conf" ] || [ -d "$d/EFI/refind" ] && found="$found refind"
    [ -f "$d/extlinux/extlinux.conf" ] || [ -f "$d/syslinux/syslinux.cfg" ] || [ -f "$d/syslinux.cfg" ] && found="$found extlinux"
  done
  [ -f /etc/default/limine ] && found="$found limine"
  { [ -f /boot/grub/grub.cfg ] || [ -f /boot/grub2/grub.cfg ]; } && [ -f /etc/default/grub ] && found="$found grub"
  [ -z "$found" ] && [ -d "$EFIVARS" ] && found="efistub"
  printf '%s\n' $found | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

# ---- systemd-boot (Boot Loader Specification type #1 entries) ----
cmdline_systemd_boot() {
  local entries=() e def="" mid old new
  for d in $(boot_dirs); do for e in "$d"/loader/entries/*.conf; do [ -f "$e" ] && entries+=("$e"); done; done
  [ ${#entries[@]} -gt 0 ] || { warn "systemd-boot: no loader/entries/*.conf found"; return; }
  def=$(bootctl list --json=short 2>/dev/null | python3 -c 'import json,sys; print(next((e.get("path","") for e in json.load(sys.stdin) if e.get("isDefault")),""))' 2>/dev/null || true)
  if [ -z "$def" ]; then
    for e in "${entries[@]}"; do is_fallback "$e" || { def="$e"; break; }; done
  fi
  case "$def" in *.efi) note "systemd-boot: the default entry is a UKI ($def): its command line is inside the image"; cmdline_uki; return ;; esac
  for e in "${entries[@]}"; do
    if [ "$ENTRIES" = default ] && [ "$e" != "$def" ]; then note "left alone (not the default entry): $e"; continue; fi
    if [ "$ENTRIES" = all ] && is_fallback "$e"; then note "left alone (fallback/rescue entry): $e"; continue; fi
    old=$(sed -n 's/^options[[:space:]]\+//p' "$e" | head -1)
    if ! grep -q '^options[[:space:]]' "$e"; then warn "systemd-boot: $e has no options line; add one by hand"; continue; fi
    new=$(add_params "$old")
    if [ "$old" = "$new" ]; then note "unchanged: $e"; continue; fi
    awk -v n="$new" '!done && /^options[[:space:]]/ {print "options " n; done=1; next} {print}' "$e" | put_file "$e" 0644 root:root
  done
  # kernel-install (Fedora, Ubuntu, ...) writes new entries from /etc/kernel/cmdline: keep it in step.
  mid=$(cat /etc/machine-id 2>/dev/null || true)
  if [ -f /etc/kernel/cmdline ] || { [ -n "$mid" ] && printf '%s\n' "${entries[@]}" | grep -q "/$mid-"; }; then
    kernel_cmdline_file "$(sed -n 's/^options[[:space:]]\+//p' "$def" 2>/dev/null | head -1)"
  fi
  return 0
}

# /etc/kernel/cmdline (kernel-install, UKI generators). Seed it from SEED or /proc/cmdline when missing.
kernel_cmdline_file() {
  local seed="${1:-}" old new
  if [ -f /etc/kernel/cmdline ]; then old=$(tr '\n' ' ' </etc/kernel/cmdline | sed 's/ *$//')
  else
    [ -n "$seed" ] || seed=$(tr ' ' '\n' <"$PROC_CMDLINE" | grep -Ev '^(BOOT_IMAGE|initrd)=' | tr '\n' ' ')
    old="$seed"; note "/etc/kernel/cmdline is missing; seeding it from the current command line"
  fi
  new=$(add_params "$old")
  if [ -f /etc/kernel/cmdline ] && [ "$old" = "$new" ]; then note "unchanged: /etc/kernel/cmdline"; return 0; fi
  printf '%s\n' "$new" | put_file /etc/kernel/cmdline 0644 root:root
  return 0
}

# ---- unified kernel images: the command line is built into the .efi ----
cmdline_uki() {
  local changed=0
  if [ -d /etc/cmdline.d ] && [ ! -f /etc/kernel/cmdline ]; then      # mkinitcpio drop-in folder
    printf '%s\n' "${CMDLINE_PARAMS[*]}" | put_file /etc/cmdline.d/90-halogen.conf 0644 root:root
    [ "$PUT_CHANGED" = 1 ] && changed=1
  else
    PUT_CHANGED=0; kernel_cmdline_file ""; [ "$PUT_CHANGED" = 1 ] && changed=1
  fi
  [ "$changed" = 1 ] || { note "UKI command-line source already has the parameters"; return; }
  if command -v mkinitcpio >/dev/null; then doit mkinitcpio -P
  elif command -v dracut >/dev/null; then doit dracut --regenerate-all --force
  elif command -v kernel-install >/dev/null; then
    local k img
    for k in /usr/lib/modules/*; do
      k=${k##*/}; img=/usr/lib/modules/$k/vmlinuz; [ -f "$img" ] || img=/boot/vmlinuz-$k
      [ -f "$img" ] && doit kernel-install add "$k" "$img"
    done
  else warn "rebuild your unified kernel images so they pick up the new command line"; fi
  return 0
}

# ---- GRUB ----
cmdline_grub() {
  local cfg="" old new d
  for d in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do [ -f "$d" ] && { cfg="$d"; break; }; done
  if command -v grubby >/dev/null && ls /boot/loader/entries/*.conf >/dev/null 2>&1; then
    # Fedora/RHEL style: GRUB reads BLS entries; grubby edits them (and GRUB_CMDLINE_LINUX).
    old=$(grubby --info=DEFAULT 2>/dev/null | sed -n 's/^args="\(.*\)"$/\1/p' || true)
    if has_all_params "$old"; then note "GRUB/BLS default kernel already has the parameters"; return; fi
    local missing="" p
    for p in "${CMDLINE_PARAMS[@]}"; do case " $old " in *" $p "*) ;; *) missing="$missing $p" ;; esac; done
    local which=DEFAULT keys="" m; [ "$ENTRIES" = all ] && which=ALL
    for m in $missing; do keys="$keys ${m%%=*}"; done
    # remove old values of the same keys first (amd_iommu flags add up rather than replace)
    doit grubby --update-kernel="$which" --remove-args="${keys# }" --args="${missing# }"
    [ -f /etc/kernel/cmdline ] && kernel_cmdline_file ""
    CMDLINE_CHANGED=1
    return
  fi
  [ -f /etc/default/grub ] || { warn "GRUB: /etc/default/grub not found"; return; }
  # Debian/Ubuntu's grub-mkconfig reads /etc/default/grub.d/*.cfg after /etc/default/grub, even when
  # the folder is missing on a given install. Use a drop-in whenever this grub-mkconfig reads one.
  local grubd=0 m
  if [ -d /etc/default/grub.d ]; then grubd=1
  else
    for m in /usr/sbin/grub-mkconfig /sbin/grub-mkconfig /usr/sbin/grub2-mkconfig /usr/bin/grub-mkconfig; do
      if [ -f "$m" ] && grep -q 'default/grub\.d' "$m"; then grubd=1; break; fi
    done
  fi
  if [ "$grubd" = 1 ]; then
    if [ ! -d /etc/default/grub.d ]; then doit mkdir -p /etc/default/grub.d; fi
    # Debian/Ubuntu: a drop-in sourced after /etc/default/grub (and after cloud-image drop-ins).
    # It first strips other values of the same keys: amd_iommu flags add up (amd_iommu=off would stay
    # in force next to amd_iommu=pt), so appending alone is not enough.
    local keys k
    keys=$(for k in "${CMDLINE_PARAMS[@]}"; do printf '%s|' "${k%%=*}"; done | sed 's/|$//; s/\./\\./g')
    {
      echo '# halogen-replicate.sh: frame kernel parameters for Halogen (sourced by update-grub)'
      echo "_halogen_strip() { printf ' %s ' \"\$1\" | sed -E 's/ ($keys)=[^ ]*/ /g; s/  +/ /g; s/^ //; s/ \$//'; }"
      echo 'GRUB_CMDLINE_LINUX="$(_halogen_strip "${GRUB_CMDLINE_LINUX:-}")"'
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$(_halogen_strip \"\${GRUB_CMDLINE_LINUX_DEFAULT:-}\") ${CMDLINE_PARAMS[*]}\""
    } \
      | put_file /etc/default/grub.d/90-halogen.cfg 0644 root:root
  else
    old=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT=["'\'']\?\(.*\)["'\'']\?$/\1/p' /etc/default/grub | tail -1 | sed 's/["'\'']$//')
    new=$(add_params "$old")
    # GRUB_CMDLINE_LINUX goes on every entry before the default options: remove the same keys there,
    # or an amd_iommu=off in it would stay in force next to amd_iommu=pt.
    local oldl newl k
    oldl=$(sed -n 's/^GRUB_CMDLINE_LINUX=["'\'']\?\(.*\)["'\'']\?$/\1/p' /etc/default/grub | tail -1 | sed 's/["'\'']$//')
    newl=" $oldl "
    for k in "${CMDLINE_PARAMS[@]}"; do newl=$(printf '%s' "$newl" | sed -E "s/[[:space:]]${k%%=*}=[^[:space:]]*/ /g"); done
    newl=$(printf '%s' "$newl" | tr -s ' ' | sed -E 's/^ //; s/ $//')
    if [ "$old" = "$new" ] && [ "$oldl" = "$newl" ] && grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then note "unchanged: /etc/default/grub"; return; fi
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
      sed "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" /etc/default/grub
    else
      cat /etc/default/grub; printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$new"
    fi | if [ "$oldl" != "$newl" ]; then sed "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$newl\"|"; else cat; fi \
      | put_file /etc/default/grub 0644 root:root
  fi
  [ "$PUT_CHANGED" = 1 ] || return 0
  if command -v update-grub >/dev/null; then doit update-grub
  elif [ -n "$cfg" ] && command -v grub-mkconfig >/dev/null; then doit grub-mkconfig -o "$cfg"
  elif [ -n "$cfg" ] && command -v grub2-mkconfig >/dev/null; then doit grub2-mkconfig -o "$cfg"
  else warn "GRUB: regenerate grub.cfg by hand"; fi
  return 0
}

# ---- rEFInd: refind_linux.conf next to the kernel ("title" "options" per line) ----
cmdline_refind() {
  local f out line re first n=0 found=0
  re='^([[:space:]]*"[^"]*"[[:space:]]+")([^"]*)(".*)$'
  for f in $(for d in $(boot_dirs); do find "$d" -maxdepth 3 -name refind_linux.conf 2>/dev/null; done | sort -u); do
    found=1; out=""; first=1
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ $re ]] && { [ "$ENTRIES" = all ] && ! is_fallback "$line" || [ $first = 1 ]; }; then
        line="${BASH_REMATCH[1]}$(add_params "${BASH_REMATCH[2]}")${BASH_REMATCH[3]}"; first=0; n=$((n+1))
      elif [[ $line =~ $re ]]; then first=0
      fi
      out+="$line"$'\n'
    done <"$f"
    printf '%s' "$out" | put_file "$f" 0644 root:root
  done
  [ $found = 1 ] || warn "rEFInd: no refind_linux.conf found; manual stanzas in refind.conf need 'options' edited by hand"
  grep -qs '^[[:space:]]*options' "$(for d in $(boot_dirs); do ls "$d"/EFI/refind/refind.conf 2>/dev/null; done | head -1)" \
    && note "rEFInd: refind.conf also has manual 'options' lines; check them by hand"
  return 0
}

# ---- Limine ----
cmdline_limine() {
  local f out line title="" re idx=0 def=1 picked=0 old
  if [ -f /etc/default/limine ]; then
    # limine-entry-tool (Arch, CachyOS): KERNEL_CMDLINE[default]="..." then limine-update
    old=$(sed -n 's/^KERNEL_CMDLINE\[default\]+\?=["'\'']\?\(.*\)["'\'']$/\1/p' /etc/default/limine | tail -1)
    [ -n "$old" ] || old=$(tr ' ' '\n' <"$PROC_CMDLINE" | grep -Ev '^(BOOT_IMAGE|initrd)=' | tr '\n' ' ')
    if grep -q '^KERNEL_CMDLINE\[default\]' /etc/default/limine; then
      awk -v n="$(add_params "$old")" '/^KERNEL_CMDLINE\[default\]/ && !d {print "KERNEL_CMDLINE[default]=\"" n "\""; d=1; next} {print}' /etc/default/limine
    else cat /etc/default/limine; printf 'KERNEL_CMDLINE[default]="%s"\n' "$(add_params "$old")"; fi | put_file /etc/default/limine 0644 root:root
    if [ "$PUT_CHANGED" = 1 ]; then
      if command -v limine-update >/dev/null; then doit limine-update
      elif command -v limine-mkinitcpio >/dev/null; then doit limine-mkinitcpio
      else warn "Limine: run limine-entry-tool's update command by hand"; fi
    fi
    return
  fi
  re='^([[:space:]]*(kernel_)?cmdline:[[:space:]]*)(.*)$'
  for f in $(for d in $(boot_dirs); do ls "$d"/limine.conf "$d"/limine/limine.conf "$d"/EFI/BOOT/limine.conf "$d"/EFI/limine/limine.conf 2>/dev/null; done | sort -u); do
    def=$(sed -n 's/^[[:space:]]*default_entry:[[:space:]]*\([0-9]\+\).*/\1/p' "$f" | head -1); def=${def:-1}
    out=""; idx=0; picked=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ ^[[:space:]]*/ ]]; then title=$line; idx=$((idx+1)); fi
      if [[ $line =~ $re ]]; then
        if { [ "$ENTRIES" = all ] && ! is_fallback "$title"; } || { [ "$ENTRIES" = default ] && [ $picked = 0 ] && [ $idx -ge "$def" ] && ! is_fallback "$title"; }; then
          line="${BASH_REMATCH[1]}$(add_params "${BASH_REMATCH[3]}")"; picked=1
        fi
      fi
      out+="$line"$'\n'
    done <"$f"
    printf '%s' "$out" | put_file "$f" 0644 root:root
  done
  return 0
}

# ---- extlinux / syslinux: APPEND lines per LABEL ----
cmdline_extlinux() {
  local f out line label="" def re lre
  re='^([[:space:]]*[Aa][Pp][Pp][Ee][Nn][Dd][[:space:]]+)(.*)$'
  lre='^[[:space:]]*[Ll][Aa][Bb][Ee][Ll][[:space:]]+(.*)$'
  for f in $(for d in $(boot_dirs); do ls "$d"/extlinux/extlinux.conf "$d"/syslinux/syslinux.cfg "$d"/syslinux.cfg 2>/dev/null; done | sort -u); do
    def=$(sed -n 's/^[[:space:]]*[Dd][Ee][Ff][Aa][Uu][Ll][Tt][[:space:]]\+\(.*\)/\1/p' "$f" | head -1)
    out=""
    while IFS= read -r line || [ -n "$line" ]; do
      [[ $line =~ $lre ]] && { label=${BASH_REMATCH[1]}; [ -n "$def" ] || def=$label; }
      if [[ $line =~ $re ]] && { { [ "$ENTRIES" = all ] && ! is_fallback "$label"; } || [ "$label" = "$def" ]; }; then
        line="${BASH_REMATCH[1]}$(add_params "${BASH_REMATCH[2]}")"
      fi
      out+="$line"$'\n'
    done <"$f"
    printf '%s' "$out" | put_file "$f" 0644 root:root
  done
  return 0
}

cmdline_efistub() {
  warn "EFISTUB (firmware boots the kernel directly): the command line is stored in the firmware boot entry."
  note "recreate the entry with the extra parameters, for example:"
  note "  efibootmgr -v            # find the current entry (BootCurrent) and its unicode arguments"
  note "  efibootmgr --create --disk /dev/XXX --part N --label Linux --loader /vmlinuz-linux \\"
  note "    --unicode '<current arguments> ${CMDLINE_PARAMS[*]}'"
  return 0
}

if [ "$DO_CMDLINE" = 0 ]; then note "skipped (--no-cmdline)"
else
  DETECTED=$(detect_bootloaders)
  note "boot loader info: '$(efivar_str LoaderInfo)'; detected: ${DETECTED:-none}"
  if [ -n "$BOOTLOADER" ]; then BL_LIST="$BOOTLOADER"
  else
    # A UKI is configured where it is built; otherwise use the loader that booted this system first,
    # then the other installed ones (a machine can carry configuration for several).
    BL_LIST="$DETECTED"
  fi
  [ -n "$BL_LIST" ] || warn "no boot loader detected: add these by hand: ${CMDLINE_PARAMS[*]} (or use --bootloader)"
  for bl in $BL_LIST; do
    note "configuring: $bl"
    PUT_CHANGED=0
    case "$bl" in
      systemd-boot) cmdline_systemd_boot ;;
      uki)          cmdline_uki ;;
      grub)         cmdline_grub ;;
      refind)       cmdline_refind ;;
      limine)       cmdline_limine ;;
      extlinux|syslinux) cmdline_extlinux ;;
      efistub)      cmdline_efistub ;;
      none)         note "skipped (--bootloader none)" ;;
      *) warn "unknown --bootloader $bl (use systemd-boot, uki, grub, refind, limine, extlinux, efistub or none)" ;;
    esac
    [ "$PUT_CHANGED" = 1 ] && CMDLINE_CHANGED=1
  done
  for p in "${CMDLINE_PARAMS[@]}"; do grep -qw -- "$p" "$PROC_CMDLINE" || note "not active yet (needs reboot): $p"; done
fi

if [ "$CMDLINE_ONLY" = 1 ]; then
  echo; echo "--cmdline-only: stopping after the kernel command line (changed: $CMDLINE_CHANGED)."
  exit 0
fi

# ---------------- 3. fabric clock hold ----------------
step "3. fabric clock (FCLK) hold"
put_file /usr/local/sbin/halogen-fabric-clock 0755 root:root <<'EOF_FABRIC_CLOCK'
#!/bin/sh
# halogen-fabric-clock hold | release | status: the AMD GPU's fabric clock (FCLK), held at its top level.
#
# On Strix Halo the GPU and the NPU working at the same time can hang the machine, and corrupt the NPU's results,
# while the GPU's fabric clock changes speed; held at its top level, the two run together cleanly. halogen-flash-server
# with HALOGEN_NPU_MODELS refuses to start until the clock is held. This holds it: the performance level `manual` and
# only the top pp_dpm_fclk level, on every amdgpu device that has the control (the GPU and SoC clocks stay automatic).
# Cost: about 1 W at idle. Run as root; halogen-fabric-clock.service runs `hold` at every boot and after a resume.
#
#   hold     hold it (waits up to 60 s for the GPU driver to come up)
#   release  give it back to the driver (the performance level `auto`)
#   status   print each device's state; exit 0 when every device is held
set -u
SYS="${HALOGEN_SYSFS:-/sys}"

devices() {
  for d in "$SYS"/class/drm/card*/device; do
    [ -w "$d/pp_dpm_fclk" ] || [ -r "$d/pp_dpm_fclk" ] || continue
    [ -e "$d/power_dpm_force_performance_level" ] || continue
    echo "$d"
  done | sort -u
}

held() {   # held DEVICE_DIR: the performance level high, or manual with only the top fclk level selected
  perf=$(cat "$1/power_dpm_force_performance_level" 2>/dev/null)
  [ "$perf" = high ] && return 0
  [ "$perf" = manual ] || return 1
  top=$(grep . "$1/pp_dpm_fclk" | tail -n 1)
  [ "$(grep -c '\*' "$1/pp_dpm_fclk")" = 1 ] && [ "${top%\*}" != "$top" ]
}

cmd="${1:-status}"
case "$cmd" in
  hold)
    n=0
    while [ -z "$(devices)" ] && [ "$n" -lt 60 ]; do sleep 1; n=$((n + 1)); done
    [ -n "$(devices)" ] || { echo "halogen-fabric-clock: no amdgpu device with a fabric clock control (pp_dpm_fclk) under $SYS/class/drm" >&2; exit 1; }
    rc=0
    for d in $(devices); do
      lvl=$(grep . "$d/pp_dpm_fclk" | tail -n 1 | cut -d: -f1)
      # the driver applies the level several seconds after the write, so the read-back waits up to 30 s
      ok=0
      if echo manual > "$d/power_dpm_force_performance_level" && echo "$lvl" > "$d/pp_dpm_fclk"; then
        t=0; until held "$d" || [ "$t" -ge 300 ]; do sleep 0.1; t=$((t + 1)); done
        held "$d" && ok=1
      fi
      if [ "$ok" = 1 ]; then
        echo "halogen-fabric-clock: $d: held at level $lvl ($(grep . "$d/pp_dpm_fclk" | tail -n 1 | awk '{print $2}'))"
      else
        echo "halogen-fabric-clock: $d: could not hold it (level $lvl)" >&2; rc=1
      fi
    done
    exit "$rc" ;;
  release)
    for d in $(devices); do echo auto > "$d/power_dpm_force_performance_level" && echo "halogen-fabric-clock: $d: released (auto)"; done ;;
  status)
    [ -n "$(devices)" ] || { echo "halogen-fabric-clock: no amdgpu device with a fabric clock control"; exit 1; }
    rc=0
    for d in $(devices); do
      if held "$d"; then echo "$d: held ($(cat "$d/power_dpm_force_performance_level"))"
      else echo "$d: NOT held ($(cat "$d/power_dpm_force_performance_level"))"; rc=1; fi
    done
    exit "$rc" ;;
  *) echo "usage: halogen-fabric-clock hold | release | status" >&2; exit 2 ;;
esac
EOF_FABRIC_CLOCK
put_file /etc/systemd/system/halogen-fabric-clock.service 0644 root:root <<'EOF_FABRIC_UNIT'
# Holds the AMD GPU's fabric clock at its top level at boot and after every resume, for halogen-flash-server with
# the NPU (HALOGEN_NPU_MODELS): on Strix Halo the GPU and the NPU at once are safe only with that clock held.
# Install (as root), from this directory:
#   install -m 755 halogen-fabric-clock /usr/local/sbin/
#   install -m 644 halogen-fabric-clock.service /etc/systemd/system/
#   systemctl daemon-reload && systemctl enable --now halogen-fabric-clock.service
# Check: halogen-fabric-clock status. Undo: systemctl disable halogen-fabric-clock.service, then
#   halogen-fabric-clock release (or reboot). The unit runs once at boot and once after each resume (a resume can hand
#   the clock back to the driver); it holds nothing open, so it shows inactive between runs.
[Unit]
Description=Hold the AMD GPU fabric clock at its top level (GPU and NPU together)
After=systemd-modules-load.service suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/halogen-fabric-clock hold

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF_FABRIC_UNIT
doit systemctl daemon-reload
if [ "$IOMMU" = pt ]; then
  doit systemctl enable halogen-fabric-clock.service
  # Holding now is safe and reversible (halogen-fabric-clock release); it costs about 1 W at idle.
  if ls /sys/class/drm/card*/device/pp_dpm_fclk >/dev/null 2>&1; then
    doit systemctl start halogen-fabric-clock.service
  else
    warn "no amdgpu fabric clock control (pp_dpm_fclk) on this machine: the hold is installed but not started (Halogen's NPU mode will refuse to start)"
  fi
else
  # The hold protects GPU + NPU together; with amd_iommu=off there is no NPU. The files stay installed
  # so that --iommu pt can switch back.
  note "--iommu off: the fabric clock hold is not needed"
  if systemctl is-enabled --quiet halogen-fabric-clock.service 2>/dev/null; then doit systemctl disable halogen-fabric-clock.service; fi
  if /usr/local/sbin/halogen-fabric-clock status >/dev/null 2>&1; then doit /usr/local/sbin/halogen-fabric-clock release; fi
fi

# ---------------- 4. memlock, groups, linger ----------------
step "4. memlock, groups, lingering"
put_file /etc/security/limits.d/90-memlock.conf 0644 root:root <<'EOF'
# Unlimited locked memory (Halogen runs with --ulimit memlock=-1 and HALOGEN_WEIGHTS_LOCK=1)
*        soft memlock unlimited
*        hard memlock unlimited
root     soft memlock unlimited
root     hard memlock unlimited
EOF
if [ "$DISTRO" = fedora ]; then
  put_file /etc/systemd/system/user@.service.d/90-halogen-memlock.conf 0644 root:root <<'EOF'
[Service]
# Fedora: limits.d alone does not raise memlock for systemd --user sessions (amd/xdna-driver README)
LimitMEMLOCK=infinity
EOF
fi
# ACPI platform profile: upstream measured performance faster than balanced; frame runs performance.
if [ "$DO_POWER" = 1 ] && [ -n "${PROFILE:-}" ] && [ "$PROFILE" != performance ]; then
  if ! grep -qw performance /sys/firmware/acpi/platform_profile_choices 2>/dev/null; then
    note "platform profile: this machine offers no 'performance' choice"
  elif command -v powerprofilesctl >/dev/null && powerprofilesctl get >/dev/null 2>&1; then
    doit powerprofilesctl set performance      # power-profiles-daemon / tuned-ppd keep it across reboots
  else
    put_file /etc/systemd/system/halogen-platform-profile.service 0644 root:root <<'EOF'
[Unit]
Description=Set the ACPI platform profile to performance (Halogen; frame runs performance)
ConditionPathExists=/sys/firmware/acpi/platform_profile

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo performance > /sys/firmware/acpi/platform_profile'

[Install]
WantedBy=multi-user.target
EOF
    doit systemctl daemon-reload
    doit systemctl enable --now halogen-platform-profile.service
  fi
elif [ "$DO_POWER" = 0 ]; then note "platform profile: left alone (--no-power-profile)"
elif [ -n "${PROFILE:-}" ]; then note "platform profile already performance"
fi
# Frame's user is only in docker: the container gets video/render through --group-add.
for g in docker; do
  getent group "$g" >/dev/null || { warn "group $g does not exist"; continue; }
  id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx "$g" && note "$RUN_USER already in $g" || doit usermod -aG "$g" "$RUN_USER"
done
loginctl show-user "$RUN_USER" -p Linger 2>/dev/null | grep -q yes && note "linger already on" || doit loginctl enable-linger "$RUN_USER"

# ---------------- 5. memory guard ----------------
step "5. memory guard (oomd, zram, fallback swap, zswap off)"
if [ "$DO_SWAP" = 0 ]; then note "skipped (--no-swap)"
else
  put_file /etc/systemd/oomd.conf.d/10-halogen-memory-guard.conf 0644 root:root <<'EOF'
[OOM]
# Kill an opted-in, restartable workload before swap exhaustion causes thrashing.
SwapUsedLimit=80%
DefaultMemoryPressureLimit=60%
DefaultMemoryPressureDurationSec=30s
EOF
  if [ "$DO_PKG" = 1 ]; then
    case "$DISTRO" in
      arch)   pkg_install zram-generator ;;
      debian) pkg_install --optional systemd-zram-generator; pkg_install --optional systemd-oomd ;;
      fedora) pkg_install --optional zram-generator systemd-oomd-defaults ;;
    esac
  fi
  doit systemctl enable --now systemd-oomd.service
  if [ "$APPLY" = 1 ]; then systemctl reload systemd-oomd.service 2>/dev/null || true; fi
  [ -e /etc/systemd/zram-generator.conf ] && note "keeping existing /etc/systemd/zram-generator.conf" || \
    printf '[zram0]\n' | put_file /etc/systemd/zram-generator.conf 0644 root:root
  DISK_SWAP_B=$(swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null | awk '$1 !~ /zram/ {s+=$2} END {print s+0}')
  OLD_UNIT=$(systemd-escape -p --suffix=swap "$SWAPFILE")
  if [ "$DISK_SWAP_B" -ge $((SWAP_GIB * 1073741824)) ] && ! swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
    note "disk swap already $((DISK_SWAP_B / 1073741824)) GiB: $(swapon --show=NAME,SIZE --noheadings | grep -v zram | tr '\n' ' ')"
  else
    if [ ! -e "$SWAPFILE" ]; then
      FSTYPE=$(findmnt -no FSTYPE / || true)
      if [ "$FSTYPE" = btrfs ] && ! command -v btrfs >/dev/null; then pkg_install btrfs-progs; fi
      if [ "$FSTYPE" = btrfs ]; then
        [ -d /swap ] || doit btrfs subvolume create /swap
        doit btrfs filesystem mkswapfile --size "${SWAP_GIB}g" "$SWAPFILE"
      else
        doit mkdir -p /swap
        doit fallocate -l "${SWAP_GIB}G" "$SWAPFILE"
        doit chmod 600 "$SWAPFILE"
        doit mkswap "$SWAPFILE"
      fi
    fi
    # A service, not a .swap unit: a .swap unit tries once, and on btrfs swapon fails with EBUSY while
    # an exclusive operation runs (cloud images resize the root filesystem at boot). This one retries.
    if [ -e "/etc/systemd/system/$OLD_UNIT" ]; then
      doit systemctl disable "$OLD_UNIT"
      if [ "$APPLY" = 1 ]; then rm -f "/etc/systemd/system/$OLD_UNIT"; log "  removed /etc/systemd/system/$OLD_UNIT"; fi
    fi
    put_file /etc/systemd/system/halogen-swap.service 0644 root:root <<EOF
[Unit]
Description=Halogen memory guard fallback swap ($SWAPFILE, ${SWAP_GIB} GiB, lowest priority)
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'grep -q "^$SWAPFILE " /proc/swaps && exit 0; for i in \$\$(seq 24); do swapon -p -1 $SWAPFILE && exit 0; sleep 5; done; exit 1'
ExecStop=-/sbin/swapoff $SWAPFILE

[Install]
WantedBy=swap.target
EOF
    doit systemctl daemon-reload
    if systemctl is-enabled --quiet halogen-swap.service 2>/dev/null && swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
      ok "fallback swap $SWAPFILE active"
    else doit systemctl enable --now halogen-swap.service; fi
  fi
fi

if [ "$SHARED" = 1 ]; then
  printf '# halogen-replicate.sh --shared-host: let compaction move locked pages (HALOGEN_WEIGHTS_LOCK=1)\nvm.compact_unevictable_allowed = 0\n' \
    | put_file /etc/sysctl.d/90-halogen-shared-host.conf 0644 root:root
  [ "$PUT_CHANGED" = 1 ] && doit sysctl -p /etc/sysctl.d/90-halogen-shared-host.conf
else
  note "vm.compact_unevictable_allowed=$(cat /proc/sys/vm/compact_unevictable_allowed 2>/dev/null) (frame: 1; --shared-host sets 0)"
fi

# ---------------- 6. XRT ----------------
step "6. XRT"
XRT_MOUNTS=""
if [ "$IOMMU" = off ]; then
  note "--iommu off: no NPU, so no XRT"
elif [ "$HOST_XRT" = 0 ]; then
  note "the image carries its own XRT with the NPU plugin (since 0.19.1): no host mount (frame's earlier"
  note "host mounts are removed). Use --host-xrt only if the server says the NPU driver refused the image's XRT."
  command -v dkms >/dev/null && dkms status 2>/dev/null | grep -qi 'xdna.*2\.23' && warn "AMD's DKMS amdxdna 2.23 is a known bad pairing (NPU stalls); upstream recommends the kernel's driver or AMD's 2.25"
else
  # Upstream docs/NPU.md#host-xrt: all three libraries or none, XRT >= 2.20, loadable with the image's
  # glibc 2.41 / GLIBCXX_3.4.33. AMD's packages: mount /opt/xilinx/xrt as is. Distribution packages:
  # each file twice, at /opt/xilinx/xrt/lib/ and at its own path; Debian/Ubuntu XRT >= 2.25 at
  # /opt/xilinx/lib/x86_64-linux-gnu/ instead of its own path.
  verge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # verge A B: A >= B
  if [ -f /opt/xilinx/xrt/lib/libxrt_core.so.2 ] && case "$(readlink -f /opt/xilinx/xrt/lib/libxrt_core.so.2)" in /opt/xilinx/*) true ;; *) false ;; esac; then
    note "AMD XRT package in /opt/xilinx/xrt: mounted as is"
    XRT_MOUNTS="  -v /opt/xilinx/xrt:/opt/xilinx/xrt:ro \\"$'\n'
  else
    L=""
    # the real directory (Arch's /usr/lib64 is a link to /usr/lib; upstream mounts at /usr/lib there)
    for d in /usr/lib/x86_64-linux-gnu /usr/lib /usr/lib64; do [ -e "$d/libxrt_core.so.2" ] && { L=$(readlink -f "$d"); break; }; done
    if [ -z "$L" ]; then warn "--host-xrt: no host XRT found (libxrt_core.so.2); the image's XRT is used"
    else
      CORE=$(readlink -f "$L/libxrt_core.so.2"); UTIL=$(readlink -f "$L/libxrt_coreutil.so.2" 2>/dev/null || true); DRV=$(readlink -f "$L/libxrt_driver_xdna.so.2" 2>/dev/null || true)
      vcore=${CORE##*.so.}; vutil=${UTIL##*.so.}; vdrv=${DRV##*.so.}
      note "host XRT in $L: core $vcore, coreutil ${vutil:-missing}, xdna plugin ${vdrv:-missing}"
      if [ ! -f "$UTIL" ] || [ ! -f "$DRV" ]; then warn "--host-xrt: all three libraries are needed (mount all three or none); not mounting"
      elif ! verge "$vcore" 2.20; then warn "--host-xrt: XRT $vcore is older than 2.20 and cannot read the NPU programs; not mounting"
      else
        [ "$vcore" = "$vutil" ] && [ "$vcore" = "$vdrv" ] || warn "XRT core $vcore, coreutil $vutil and plugin $vdrv differ; a mismatch can break the NPU"
        second="$L"
        [ "$L" = /usr/lib/x86_64-linux-gnu ] && verge "$vcore" 2.25 && second=/opt/xilinx/lib/x86_64-linux-gnu
        for l in "$UTIL:libxrt_coreutil.so.2" "$CORE:libxrt_core.so.2" "$DRV:libxrt_driver_xdna.so.2"; do
          src=${l%%:*}; name=${l##*:}
          XRT_MOUNTS+="  -v $src:/opt/xilinx/xrt/lib/$name:ro \\"$'\n'"  -v $src:$second/$name:ro \\"$'\n'
        done
        note "the server checks at start that these load with the image's glibc 2.41 and names a library that does not"
      fi
    fi
  fi
fi

# ---------------- 7. directories and chat template ----------------
step "7. model and cache directories, chat template"
for d in "$V2_DIR" "$NPU_DIR"; do [ -d "$d" ] && note "exists: $d" || { user_dir -m 0755 "$d"; [ "$APPLY" = 1 ] && ok "created $d"; }; done
[ -d "$MODELS_DIR" ] && note "exists: $MODELS_DIR" || doit install -d -m 0755 "$MODELS_DIR"
[ -d "$CACHE_DIR" ] && note "exists: $CACHE_DIR" || { user_dir -m 0700 "$CACHE_DIR"; [ "$APPLY" = 1 ] && ok "created $CACHE_DIR"; }
[ "$APPLY" = 1 ] && chmod 0700 "$CACHE_DIR"
CHATTR=$(findmnt -no FSTYPE -T "$(dirname "$CACHE_DIR")" 2>/dev/null || true)
if [ "$CHATTR" = btrfs ]; then
  # frame's /home is mounted nodatacow,nodatasum; +C on the empty folder gives new cache files the same
  if lsattr -d "$CACHE_DIR" 2>/dev/null | awk '{exit !($1 ~ /C/)}'; then ok "cache folder is NOCOW (chattr +C)"
  elif [ -z "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then doit chattr +C "$CACHE_DIR"
  else note "cache folder is on btrfs and not empty: set 'chattr +C' only on an empty folder (frame: nodatacow mount)"; fi
fi
TPL_DIR="$RUN_HOME/.config/halogen/chat-templates/froggeric-855bffc49448"
TPL="$TPL_DIR/chat_template.jinja"
if [ -f "$TPL" ] && echo "$TEMPLATE_SHA  $TPL" | sha256sum -c --status; then ok "chat template present and verified"
elif [ "$APPLY" = 1 ]; then
  user_dir "$TPL_DIR"
  curl -fsSL "$TEMPLATE_URL" -o "$TPL.part"
  echo "$TEMPLATE_SHA  $TPL.part" | sha256sum -c --status || { rm -f "$TPL.part"; echo "template SHA-256 mismatch" >&2; exit 1; }
  mv "$TPL.part" "$TPL"; chown "$RUN_USER:" "$TPL"; chmod 0644 "$TPL"
  ok "downloaded and verified: $TPL (Apache-2.0, froggeric/Qwen-Fixed-Chat-Templates@855bffc4)"
else note "would download $TEMPLATE_URL -> $TPL and check SHA-256 $TEMPLATE_SHA"; fi

# ---------------- 8. Halogen user unit ----------------
step "8. Halogen user unit (installed, not enabled, not started)"
IMAGE_REF="$IMAGE"
case "$IMAGE" in
  *@sha256:*) note "image pinned by digest: $IMAGE" ;;
  *)
    run "pull $IMAGE" docker pull "$IMAGE"
    DIGEST=$(docker image inspect "$IMAGE" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null | grep "^${IMAGE%:*}@" | head -1 || true)
    if [ -n "$DIGEST" ]; then
      note "$IMAGE is $DIGEST (version $(docker image inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^HALOGEN_IMAGE_VERSION=//p'))"
      IMAGE="$DIGEST"
    elif [ "$APPLY" = 1 ]; then echo "could not resolve $IMAGE to a digest" >&2; exit 1
    else note "would pull $IMAGE and pin its digest in the unit"; fi ;;
esac
CONFLICTS_LINE=""
[ -n "$CONFLICTS" ] && CONFLICTS_LINE="Conflicts=$CONFLICTS"$'\n'
GID_VIDEO=$(getent group video | cut -d: -f3 || true); GID_RENDER=$(getent group render | cut -d: -f3 || true)
GROUPADD=""
[ -n "$GID_VIDEO$GID_RENDER" ] && GROUPADD="  ${GID_VIDEO:+--group-add $GID_VIDEO }${GID_RENDER:+--group-add $GID_RENDER }\\"$'\n'
[ -n "$GID_RENDER" ] || warn "no render group: /dev/kfd and /dev/dri/renderD* may not be usable in the container"
UNIT_DIR="$RUN_HOME/.config/systemd/user"
user_dir "$UNIT_DIR"
API_ENV=""
if [ -n "$API_KEY_FILE" ]; then
  case "$API_KEY_FILE" in /*) ;; *) API_KEY_FILE="$(pwd)/$API_KEY_FILE" ;; esac
  if [ -s "$API_KEY_FILE" ]; then note "API key file exists: $API_KEY_FILE (not shown)"
  elif [ "$APPLY" = 1 ]; then
    user_dir -m 0700 "$(dirname "$API_KEY_FILE")"
    ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$API_KEY_FILE"; echo >> "$API_KEY_FILE" )
    chown "$RUN_USER:" "$API_KEY_FILE"; chmod 0600 "$API_KEY_FILE"
    note "created a random API key in $API_KEY_FILE (mode 0600; read it with: cat $API_KEY_FILE)"
  else note "would create a random API key in $API_KEY_FILE (mode 0600)"; fi
  API_ENV="  -e HALOGEN_API_KEY_FILE=/run/secrets/halogen-api-key \\"$'\n'"  -v $API_KEY_FILE:/run/secrets/halogen-api-key:ro \\"$'\n'
elif [ -n "$LAN_IP" ]; then
  warn "--lan-ip without --api-key-file: anyone who can reach $LAN_IP:8731 can use the API"
fi
if [ "$IOMMU" = pt ]; then
  FCLK_PRE="# Fail before launch if the fabric clock is not held (GPU + NPU together need it)."$'\n'"ExecStartPre=/usr/local/sbin/halogen-fabric-clock status"$'\n'
  ACCEL_DEV=" --device /dev/accel/accel0"
  NPU_ENV="  -e HALOGEN_NPU_MODELS=$NPU_MODELS \\"$'\n'
  NPU_MOUNT="  -v $NPU_DIR:/models/npu \\"$'\n'
  MODE_NOTE="amd_iommu=pt: GPU + NPU helpers (frame's setting)"
else
  FCLK_PRE=""; ACCEL_DEV=""; NPU_ENV=""; NPU_MOUNT=""
  MODE_NOTE="amd_iommu=off: GPU only, no NPU helpers (faster prefill). Switch: re-run halogen-replicate.sh --iommu pt"
fi
SECOPT=""
[ "$SELINUX" = 1 ] && SECOPT="  --security-opt label=disable \\"$'\n'
PROXYD=/usr/lib/systemd/systemd-socket-proxyd
[ -x "$PROXYD" ] || [ ! -x /lib/systemd/systemd-socket-proxyd ] || PROXYD=/lib/systemd/systemd-socket-proxyd
put_file "$UNIT_DIR/halogen.service" 0644 "$RUN_USER:$(id -gn "$RUN_USER")" <<EOF
# Generated by halogen-replicate.sh. Mirrors frame's halogen-v2-abliterated.service.
# Keep it boot-disabled: start it by hand with  systemctl --user start halogen.service
# Mode: $MODE_NOTE
# Image: $IMAGE_REF, pinned to its digest; re-run halogen-replicate.sh to update.
[Unit]
Description=Halogen flash server (frame replica), OpenAI API on 127.0.0.1:8731
Documentation=https://github.com/peonist-ai/halogen-flash-server
After=network-online.target
${CONFLICTS_LINE}StartLimitIntervalSec=30min
StartLimitBurst=4

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'i=0; until /usr/bin/docker info >/dev/null 2>&1; do i=\$\$((i+1)); [ \$\$i -ge 90 ] && exit 1; sleep 2; done'
${FCLK_PRE}ExecStartPre=-/usr/bin/docker rm -f halogen
ExecStart=/usr/bin/docker run --rm --name halogen \\
  -p 127.0.0.1:8731:8731 \\
  --device /dev/kfd --device /dev/dri${ACCEL_DEV} \\
${GROUPADD}  --ipc=host --ulimit memlock=-1:-1 \\
  --memory=108g --memory-swap=108g \\
  --oom-score-adj=-1000 \\
${SECOPT}  -e HALOGEN_OOM_SCORE_ADJ=0 \\
  -e HALOGEN_WEIGHTS_LOCK=1 \\
  -e HALOGEN_KV_POOL_POSITIONS=1048576 \\
  -e HALOGEN_KV_SLOTS=4 \\
  -e HALOGEN_KV8=1 \\
  -e HALOGEN_CTX=262144 \\
  -e HALOGEN_SPEC_ADAPT=0 \\
  -e HALOGEN_SAMPLED_DEPTH=7 \\
  -e HALOGEN_SAMPLED_GATE=0.95,0.98 \\
  -e HALOGEN_MAX_TOK=8192 \\
  -e HALOGEN_CHECKPOINT=/v2/$CHECKPOINT \\
  -e HALOGEN_NGRAM_TABLE=/v2/qwen38-flash-next-ngram.hgn \\
  -e HALOGEN_TOKENIZER=/models/tokenizer \\
  -e HALOGEN_VISION_TOWER=/models/qwen38-flash-next-vision.hgn \\
  -e HALOGEN_MODEL_ID=halogen-v2-abliterated \\
  -e HALOGEN_TEMPERATURE=1.0 \\
  -e HALOGEN_TOP_P=0.95 \\
  -e HALOGEN_TOP_K=20 \\
  -e HALOGEN_MAX_THINKING_TOKENS=8192 \\
${NPU_ENV}  -e HALOGEN_CACHE_DIR=/cache \\
  -e HALOGEN_CACHE_DISK_GIB=64 \\
  -e HALOGEN_CACHE_PRUNE_OLD=0 \\
${API_ENV}  -v $MODELS_DIR:/models:ro \\
  -v $V2_DIR:/v2:ro \\
  -v $TPL:/models/tokenizer/chat_template.jinja:ro \\
${NPU_MOUNT}  -v $CACHE_DIR:/cache \\
$XRT_MOUNTS  $IMAGE
ExecStop=/usr/bin/docker stop -t 90 halogen
TimeoutStartSec=infinity
TimeoutStopSec=120
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
EOF
if [ -n "$LAN_IP" ]; then
  put_file "$UNIT_DIR/halogen-lan-proxy.socket" 0644 "$RUN_USER:$(id -gn "$RUN_USER")" <<EOF
# LAN forwarder: $LAN_IP:8731 -> 127.0.0.1:8731. $( [ -n "$API_KEY_FILE" ] && echo 'The API needs the key in '"$API_KEY_FILE"' (/health stays open).' || echo 'No API key is set: anyone who can reach this address can use the API.' )
[Unit]
Description=LAN forwarder for Halogen ($LAN_IP:8731 -> 127.0.0.1:8731)

[Socket]
ListenStream=$LAN_IP:8731
FreeBind=yes

[Install]
WantedBy=sockets.target
EOF
  put_file "$UNIT_DIR/halogen-lan-proxy.service" 0644 "$RUN_USER:$(id -gn "$RUN_USER")" <<EOF
[Unit]
Description=LAN forwarder for Halogen
Requires=halogen-lan-proxy.socket
After=halogen-lan-proxy.socket

[Service]
ExecStart=$PROXYD --exit-idle-time=10min 127.0.0.1:8731
EOF
fi
if [ "$APPLY" = 1 ] && [ -S "/run/user/$RUN_UID/bus" ]; then
  as_user systemctl --user daemon-reload
  if [ -n "$LAN_IP" ]; then run "enable halogen-lan-proxy.socket ($LAN_IP:8731)" as_user systemctl --user enable --now halogen-lan-proxy.socket; fi
  as_user systemd-analyze --user verify "$UNIT_DIR/halogen.service" 2>&1 | sed 's/^/   verify: /' || true
fi

# ---------------- 8b. model files ----------------
step "8b. model files"
# Main files: repo@revision, files, destination.
MODEL_PLAN=(
  "$HF_BASE_REPO|$HF_BASE_REV|tokenizer/*|$MODELS_DIR"
  "$HF_BASE_REPO|$HF_BASE_REV|qwen38-flash-next-vision.hgn|$MODELS_DIR"
  "$HF_BASE_REPO|$HF_NGRAM_REV|qwen38-flash-next-ngram.hgn|$V2_DIR"
  "$HF_CKPT_REPO|$HF_CKPT_REV|$HF_CKPT_FILE|$V2_DIR"
)
# NPU files: the revisions come from the image's own pin list (/opt/halogen/npu/models.txt).
NPU_PINS=""
if [ "$IOMMU" = pt ] && [ -n "$NPU_MODELS" ]; then
  if command -v docker >/dev/null && { docker image inspect "$IMAGE" >/dev/null 2>&1 || { [ "$FETCH" = 1 ] && [ "$APPLY" = 1 ] && docker pull -q "$IMAGE" >/dev/null; }; }; then
    NPU_PINS=$(docker run --rm --network none --entrypoint cat "$IMAGE" /opt/halogen/npu/models.txt 2>/dev/null | grep '^model ' || true)
  fi
  pin() { printf '%s\n' "$NPU_PINS" | awk -v id="$1" -v k="$2" '$2==id { for (i=3;i<=NF;i++) if (index($i, k"=")==1) print substr($i, length(k)+2) }'; }
  IFS=, read -r -a NPU_LIST <<<"$NPU_MODELS"
  for m in "${NPU_LIST[@]}"; do
    case "$m" in
      /models/npu/*)
        # a user checkpoint directory; frame's is LFM3-1.7B on the lfm3-1.7b NPU programs
        name=${m#/models/npu/}; fast=""; case "$name" in *:fast) name=${name%:fast}; fast=-fast ;; esac
        prog="lfm3-1.7b$fast"
        src=$(pin "$prog" source)
        case "$name" in
          LFM3-1.7B|lfm3-1.7b) if [ -n "$src" ]; then MODEL_PLAN+=("${src%@*}|${src#*@}|*|$NPU_DIR/$name"); elif [ -n "$NPU_PINS" ]; then warn "no pin for $prog in the image"; fi ;;
          *) warn "NPU entry $m is your own checkpoint: place its files in $NPU_DIR/$name yourself" ;;
        esac
        [ -n "$(pin "$prog" repo)" ] && MODEL_PLAN+=("$(pin "$prog" repo)|$(pin "$prog" revision)|devices/*|$NPU_DIR/$prog") ;;
      *)
        repo=$(pin "$m" repo); rev=$(pin "$m" revision); dev=$(pin "$m" devices)
        if [ -z "$NPU_PINS" ]; then
          if [ "${PIN_NOTE:-0}" = 0 ]; then
            if [ "$APPLY" = 1 ]; then warn "could not read the NPU pin list from $IMAGE: NPU files not planned"
            else note "NPU model revisions come from the image's pin list; this dry run has not pulled $IMAGE, so they are listed with --apply"; fi
            PIN_NOTE=1
          fi
          continue
        fi
        if [ -z "$repo" ] || [ -z "$rev" ]; then warn "the image has no downloadable pin for NPU model $m"; continue; fi
        MODEL_PLAN+=("$repo|$rev|*|$NPU_DIR/$m")
        if [ -n "$dev" ]; then
          e="$(pin "$dev" repo)|$(pin "$dev" revision)"
          # skip when the whole devices= model is already planned (it holds devices/)
          case " ${MODEL_PLAN[*]} " in *"$e|*|$NPU_DIR/$dev"*) ;; *) MODEL_PLAN+=("$e|devices/*|$NPU_DIR/$dev") ;; esac
        fi ;;
    esac
  done
fi
for e in "${MODEL_PLAN[@]}"; do IFS='|' read -r repo rev inc dest <<<"$e"; note "$repo@${rev:0:12}  $inc  ->  $dest"; done
note "checkpoint: $HF_CKPT_FILE (SHA-256 ${CKPT_SHA:0:16}...) is linked as $V2_DIR/$CHECKPOINT"
if [ "$FETCH" = 1 ]; then
  avail=$(df -B1G --output=avail "$(dirname "$V2_DIR")" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)
  [ "${avail:-0}" -ge 170 ] || warn "only ${avail:-?} GiB free under $(dirname "$V2_DIR"); the files need about 165 GB"
  HF=""
  for c in hf huggingface-cli; do HF=$(sudo -u "$RUN_USER" -H bash -lc "command -v $c" 2>/dev/null || true); [ -n "$HF" ] && break; done
  VENV="$RUN_HOME/.local/share/halogen-replicate/hf-venv"
  if [ -z "$HF" ]; then
    doit sudo -u "$RUN_USER" -H python3 -m venv "$VENV"
    doit sudo -u "$RUN_USER" -H "$VENV/bin/pip" install -q 'huggingface_hub[cli]'
    HF="$VENV/bin/hf"
  fi
  for e in "${MODEL_PLAN[@]}"; do
    IFS='|' read -r repo rev inc dest <<<"$e"
    user_dir "$dest"
    run_live "$repo@${rev:0:12} ($inc)" sudo -u "$RUN_USER" -H "$HF" download "$repo" --revision "$rev" --include "$inc" --local-dir "$dest"
  done
  if [ "$APPLY" = 1 ]; then
    if [ "$HF_CKPT_FILE" != "$CHECKPOINT" ] && [ ! -e "$V2_DIR/$CHECKPOINT" ]; then ln "$V2_DIR/$HF_CKPT_FILE" "$V2_DIR/$CHECKPOINT"; fi
    note "checking the checkpoint and the n-gram table (about 140 GB to read; install pv for a progress bar)"
    sha_check "$V2_DIR/$CHECKPOINT" "$CKPT_SHA"
    sha_check "$V2_DIR/qwen38-flash-next-ngram.hgn" "$NGRAM_SHA"
    note "the NPU files are checked against the image's pins by Halogen at every start"
  else
    note "would link $V2_DIR/$HF_CKPT_FILE as $V2_DIR/$CHECKPOINT and check both SHA-256 values"
  fi
else
  note "not downloaded (add --fetch-models). The paths above must exist before Halogen starts; the unit does not set HALOGEN_DOWNLOAD."
fi

# ---------------- 8c. companion dashboard ----------------
step "8c. dashboard (github.com/Quat3rnion/halogen-dashboard)"
if [ "$DASH" = 0 ]; then note "skipped (add --dashboard)"
else
  : "${DASH_REF:=$DASH_REF_DEFAULT}"
  DASH_SRC="$RUN_HOME/.local/share/halogen-replicate/halogen-dashboard"
  DASH_ENV="$RUN_HOME/.config/halogen/dashboard.env"
  if [ -d "$DASH_SRC/.git" ]; then doit sudo -u "$RUN_USER" -H git -C "$DASH_SRC" fetch -q origin
  else
    user_dir "$(dirname "$DASH_SRC")"
    doit sudo -u "$RUN_USER" -H git clone -q "$DASH_REPO" "$DASH_SRC"
  fi
  doit sudo -u "$RUN_USER" -H git -C "$DASH_SRC" -c advice.detachedHead=false checkout -q --force "$DASH_REF"
  # this checkout belongs to the script: drop an earlier run's patch so the fix applies cleanly again
  doit sudo -u "$RUN_USER" -H sh -c "git -C '$DASH_SRC' reset -q --hard && git -C '$DASH_SRC' clean -fdq"
  DASH_TAG="halogen-dashboard:${DASH_REF:0:12}"
  # Prometheus export fix (one "# TYPE" line per metric family without labels); not upstream yet.
  # Applied when it fits; a newer ref that already has it is left as is.
  cat > "${TMPDIR:-/var/tmp}/halogen-dash.patch" <<'EOF_DASH_PATCH'
diff --git a/crates/collector/src/collector.rs b/crates/collector/src/collector.rs
index 87acd65..b0b87cc 100644
--- a/crates/collector/src/collector.rs
+++ b/crates/collector/src/collector.rs
@@ -412,9 +412,16 @@ async fn metrics(State(app): State<App>) -> impl IntoResponse {
     for (n, v) in crate::rates::COUNTERS.iter().zip(i.tracker.adjusted) {
         text.push_str(&format!("# TYPE {n} counter\n{n} {v}\n"));
     }
+    let mut gauge_families = std::collections::BTreeSet::new();
     for (n, v) in &i.gauges {
         if !crate::rates::COUNTERS.contains(&n.as_str()) {
-            text.push_str(&format!("# TYPE {n} gauge\n{n} {v}\n"));
+            // TYPE identifies a metric family, not a labelled sample. Keep the
+            // full key on sample lines and declare each family only once.
+            let family = n.split_once('{').map_or(n.as_str(), |(name, _)| name);
+            if gauge_families.insert(family) {
+                text.push_str(&format!("# TYPE {family} gauge\n"));
+            }
+            text.push_str(&format!("{n} {v}\n"));
         }
     }
     let current = i

diff --git a/crates/collector/tests/prometheus_export.rs b/crates/collector/tests/prometheus_export.rs
new file mode 100644
index 0000000..b62b745
--- /dev/null
+++ b/crates/collector/tests/prometheus_export.rs
@@ -0,0 +1,63 @@
+use halogen_dashboard::{collector::App, types::now_ms};
+
+// This uses fixture data and an isolated in-memory collector. It never starts
+// the upstream polling tasks or accesses a production metrics endpoint.
+#[tokio::test]
+async fn labelled_samples_have_one_unlabelled_type_per_metric_family() {
+    let app = App::new(":memory:").unwrap();
+    let fixture = include_str!("../../../fixtures/halogen-0.18.1/metrics.txt");
+    let input = format!(
+        "{fixture}\ntest:temperature{{sensor=\"left\"}} 21\ntest:temperature{{sensor=\"right\"}} 22\n"
+    );
+    app.scrape_metrics(now_ms(), Some(&input)).unwrap();
+    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
+    let url = format!("http://{}/metrics", listener.local_addr().unwrap());
+    let router = app.router();
+    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
+    let response = reqwest::get(url).await.unwrap();
+    assert!(response.status().is_success());
+    assert!(
+        response.headers()["content-type"]
+            .to_str()
+            .unwrap()
+            .contains("version=0.0.4")
+    );
+    let text = response.text().await.unwrap();
+    server.abort();
+    let _ = server.await;
+
+    // TYPE takes a bare family name, never a labelled sample key.
+    for line in text.lines().filter(|line| line.starts_with("# TYPE ")) {
+        let fields: Vec<_> = line.split_whitespace().collect();
+        assert_eq!(fields.len(), 4, "malformed TYPE: {line}");
+        assert!(
+            !fields[2].contains(['{', '}', '=']),
+            "labelled TYPE: {line}"
+        );
+        assert!(
+            matches!(fields[3], "gauge" | "counter"),
+            "invalid type: {line}"
+        );
+    }
+    assert_eq!(
+        text.lines()
+            .filter(|l| *l == "# TYPE halogen:build_info gauge")
+            .count(),
+        1
+    );
+    assert_eq!(
+        text.lines()
+            .filter(|l| *l == "# TYPE test:temperature gauge")
+            .count(),
+        1
+    );
+    assert!(text.contains("test:temperature{sensor=\"left\"} 21\n"));
+    assert!(text.contains("test:temperature{sensor=\"right\"} 22\n"));
+    assert!(text.contains("halogen:build_info{version=\"0.18.1\",engine_version=\"0.18.1\",model=\"halogen-v2-abliterated\"} 1\n"));
+    assert!(text.contains("# TYPE halogen:requests_total counter\n"));
+    assert!(text.contains("# TYPE halogen:cache_bytes gauge\n"));
+
+    if let Ok(path) = std::env::var("EXPORT_TEST_OUTPUT") {
+        std::fs::write(path, text).unwrap();
+    }
+}

EOF_DASH_PATCH
  if [ "$APPLY" = 1 ]; then
    if sudo -u "$RUN_USER" -H git -C "$DASH_SRC" apply --check "${TMPDIR:-/var/tmp}/halogen-dash.patch" 2>/dev/null; then
      sudo -u "$RUN_USER" -H git -C "$DASH_SRC" apply "${TMPDIR:-/var/tmp}/halogen-dash.patch"
      note "applied the Prometheus TYPE-line fix"; DASH_TAG="$DASH_TAG-typefix"
    else note "TYPE-line fix does not apply to $DASH_REF (already included, or the code moved): building as is"; fi
  else note "would apply the Prometheus TYPE-line fix when it fits"; DASH_TAG="$DASH_TAG-typefix"; fi
  rm -f "${TMPDIR:-/var/tmp}/halogen-dash.patch"
  if [ "$APPLY" = 1 ] && docker image inspect "$DASH_TAG" >/dev/null 2>&1; then ok "image $DASH_TAG already built"
  else
    note "building $DASH_TAG (Rust + web page; about 5-15 minutes the first time)"
    run "docker build $DASH_TAG" docker buildx build --load -t "$DASH_TAG" "$DASH_SRC"
  fi
  PUT_CHANGED=0
  # HALOGEN_API_KEY goes in a 0600 env file, not in the unit
  KEYLINE="HALOGEN_API_KEY="
  if [ -n "$API_KEY_FILE" ] && [ -s "$API_KEY_FILE" ]; then KEYLINE="HALOGEN_API_KEY=$(head -n1 "$API_KEY_FILE")"
  elif [ -n "$API_KEY_FILE" ]; then KEYLINE="HALOGEN_API_KEY=<from $API_KEY_FILE>"; fi
  printf 'HALOGEN_URL=http://127.0.0.1:8731\n%s\nHALOGEN_DASHBOARD_LISTEN=%s:%s\nRUST_LOG=info\nTZ=%s\n' \
    "$KEYLINE" "$DASH_BIND" "$DASH_PORT" "$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)" \
    | if [ "$APPLY" = 1 ]; then put_file "$DASH_ENV" 0600 "$RUN_USER:$(id -gn "$RUN_USER")"; else sed 's/^HALOGEN_API_KEY=.\+/HALOGEN_API_KEY=<hidden>/' | put_file "$DASH_ENV" 0600 "$RUN_USER:$(id -gn "$RUN_USER")"; fi
  HC_HOST=$DASH_BIND; [ "$HC_HOST" = 0.0.0.0 ] && HC_HOST=127.0.0.1
  put_file "$UNIT_DIR/halogen-dashboard.service" 0644 "$RUN_USER:$(id -gn "$RUN_USER")" <<EOF
# Generated by halogen-replicate.sh. Companion dashboard for Halogen: $DASH_REPO @ $DASH_REF
# The Collector must be the ONLY reader of Halogen's /metrics (reading resets two gauges; dashboard
# ADR 0001). Point Prometheus at this Collector's /metrics, never at Halogen's.
[Unit]
Description=Halogen dashboard (Collector + web page) on $DASH_BIND:$DASH_PORT
Documentation=https://github.com/Quat3rnion/halogen-dashboard
After=network-online.target halogen.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f halogen-dashboard
# host network: Halogen publishes only on 127.0.0.1:8731
ExecStart=/usr/bin/docker run --rm --name halogen-dashboard \\
  --network host \\
  --env-file $DASH_ENV \\
  -v halogen-dashboard-data:/data \\
  --health-cmd "curl -fsS http://$HC_HOST:$DASH_PORT/healthz || exit 1" \\
${SECOPT}  $DASH_TAG
ExecStop=/usr/bin/docker stop -t 20 halogen-dashboard
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
  if [ "$APPLY" = 1 ] && [ -S "/run/user/$RUN_UID/bus" ]; then
    as_user systemctl --user daemon-reload
    # A user manager that started before the user joined the docker group cannot reach the Docker
    # socket until it restarts (next login or reboot). Restarting it here would stop the user's programs.
    UM_PID=$(systemctl show "user@$RUN_UID.service" -p MainPID --value 2>/dev/null || echo 0)
    DOCKER_GID=$(getent group docker | cut -d: -f3)
    if [ "${UM_PID:-0}" != 0 ] && awk -v g="$DOCKER_GID" '$1=="Groups:" {for (i=2;i<=NF;i++) if ($i==g) f=1} END {exit !f}' "/proc/$UM_PID/status" 2>/dev/null; then
      if [ "$PUT_CHANGED" = 1 ] && as_user systemctl --user is-active --quiet halogen-dashboard.service; then
        run "restart halogen-dashboard.service (new settings or image)" as_user systemctl --user restart halogen-dashboard.service
      fi
      run "enable and start halogen-dashboard.service" as_user systemctl --user enable --now halogen-dashboard.service
    else
      run "enable halogen-dashboard.service" as_user systemctl --user enable halogen-dashboard.service
      warn "the dashboard starts after $RUN_USER logs in again or after a reboot (the running user session is not yet in the docker group)"
    fi
    note "dashboard: http://$HC_HOST:$DASH_PORT (it shows Halogen as down until Halogen runs)"
  else note "would enable and start halogen-dashboard.service (http://$HC_HOST:$DASH_PORT)"; fi
  [ "$DASH_BIND" != 127.0.0.1 ] && warn "the dashboard has no login: anyone who can reach $DASH_BIND:$DASH_PORT can see it"
fi

# ---------------- 9. report ----------------
step "9. current state"
if [ -x /usr/local/sbin/halogen-fabric-clock ]; then
  if /usr/local/sbin/halogen-fabric-clock status >/dev/null 2>&1; then ok "fabric clock: $(/usr/local/sbin/halogen-fabric-clock status 2>&1 | tr '\n' ' ')"
  elif [ "$IOMMU" = pt ] && ls /sys/class/drm/card*/device/pp_dpm_fclk >/dev/null 2>&1; then warn "fabric clock: $(/usr/local/sbin/halogen-fabric-clock status 2>&1 | tr '\n' ' ')"
  elif [ "$IOMMU" = pt ]; then note "fabric clock: no amdgpu fabric clock control on this machine"
  else note "fabric clock: not held (not needed with amd_iommu=off)"; fi
else note "fabric clock tool not installed yet"; fi
note "/proc/cmdline: $(cat /proc/cmdline)"
[ "$(id -u)" -eq 0 ] && note "memlock (new logins): $(su - "$RUN_USER" -c 'ulimit -l' 2>/dev/null || echo ?)"
note "NPU firmware: $(cat /sys/class/accel/accel0/device/fw_version 2>/dev/null || echo 'no /dev/accel/accel0')"
swapon --show 2>/dev/null | sed 's/^/   /'
cat <<EOF

IOMMU mode: amd_iommu=$IOMMU$( [ "$IOMMU" = off ] && echo " (no NPU helpers: no embeddings/ASR/TTS/image endpoints on the NPU)" )
Model files: see "model files" above ($( if [ "$FETCH" = 0 ]; then echo "not downloaded; add --fetch-models, or copy them"; elif [ "$APPLY" = 1 ]; then echo "downloaded with --fetch-models"; else echo "--fetch-models would download them"; fi )).
Image: $IMAGE$( [ "$IMAGE" != "$IMAGE_REF" ] && echo " (from $IMAGE_REF)" ); frame ran 0.20.0 ($FRAME_IMAGE)
Dashboard: $( [ "$DASH" = 1 ] && echo "http://$DASH_BIND:$DASH_PORT (systemctl --user status halogen-dashboard.service)" || echo "not installed (--dashboard)" )
API key: $( [ -n "$API_KEY_FILE" ] && echo "$API_KEY_FILE (clients send Authorization: Bearer <key>)" || echo "none (loopback only$( [ -n "$LAN_IP" ] && echo ", AND open on $LAN_IP:8731" ))" )
Next steps:
  1. Reboot if the kernel command line changed (changed now: $CMDLINE_CHANGED).
  2. Log out and in (or reboot) so the new groups and memlock limit apply to $RUN_USER.
  3. Check: $( [ "$IOMMU" = pt ] && echo "halogen-fabric-clock status   (must say held)" || echo "grep -o 'amd_iommu=[a-z]*' /proc/cmdline   (must say amd_iommu=off)" )
  4. Start by hand: systemctl --user start halogen.service ; journalctl --user -fu halogen.service
  5. If the machine still hangs with GPU + NPU busy and the fabric clock held, update the BIOS
     (upstream reports such hosts; see ROCm/TheRock#8709).
EOF
printf '\n%sSummary%s  %s  ·  %d action(s)  ·  %d warning(s)\n' "$C_B" "$C_0" "$(fmt_t $((SECONDS - T_START)))" "${#CHANGES[@]}" "${#WARNINGS[@]}"
for w in "${WARNINGS[@]}"; do printf '  %s!%s %s\n' "$C_Y" "$C_0" "$w"; done
printf '  %sfull log: %s%s\n' "$C_D" "$LOG" "$C_0"
[ "$APPLY" = 1 ] || printf '  %sdry run finished: nothing changed. Run again with --apply.%s\n' "$C_G" "$C_0"
