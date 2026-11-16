#!/usr/bin/env bash
# halogen-diag.sh - collect a read-only diagnostic bundle for a halogen-flash-server setup
# (AMD Strix Halo: Radeon 8060S iGPU + XDNA NPU, Docker container, optional systemd unit).
#
# Usage:
#   ./halogen-diag.sh [options]
#     -o DIR        output parent directory (default: current directory)
#     -c NAME       container name to inspect (default: every container whose name or image contains "halogen")
#     -p PORT       Halogen API port to probe on 127.0.0.1 (default: 8731)
#     -u URL        full base URL to probe instead (for example http://192.168.1.10:8731)
#     -k KEY        API key to send as "Authorization: Bearer KEY" (it is never written to the bundle)
#     -m            also read the server's /metrics endpoint (off by default)
#     -H            also SHA-256 the model files mounted into the container (slow on 100+ GB files)
#     -n LINES      log lines to keep per container/unit (default: 3000)
#     -h            help
#
# The script changes nothing. It runs as a normal user; run it with sudo (or have passwordless
# `sudo -n`) to also get dmesg, dmidecode, debugfs firmware versions and the full kernel journal.
# Secrets (tokens, keys, passwords in environment variables and logs) are masked, but please
# read the bundle before you share it: it contains hostnames, paths and local IP addresses.
set -u
export LC_ALL=C

OUT_PARENT="."
CONTAINER=""
PORT=8731
BASE_URL=""
API_KEY=""
READ_METRICS=0
HASH_MODELS=0
LOG_LINES=3000

while getopts ":o:c:p:u:k:mHn:h" opt; do
  case "$opt" in
    o) OUT_PARENT="$OPTARG" ;;
    c) CONTAINER="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    u) BASE_URL="${OPTARG%/}" ;;
    k) API_KEY="$OPTARG" ;;
    m) READ_METRICS=1 ;;
    H) HASH_MODELS=1 ;;
    n) LOG_LINES="$OPTARG" ;;
    h) awk 'NR > 1 && /^set -u/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "$0"; exit 0 ;;
    :) echo "option -$OPTARG needs a value" >&2; exit 2 ;;
    *) echo "unknown option -$OPTARG (use -h)" >&2; exit 2 ;;
  esac
done
[ -n "$BASE_URL" ] || BASE_URL="http://127.0.0.1:${PORT}"

TS=$(date -u +%Y%m%dT%H%M%SZ)
HOST=$(hostname 2>/dev/null || echo host)
OUT="${OUT_PARENT%/}/halogen-diag-${HOST}-${TS}"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 1; }

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif have sudo && sudo -n true 2>/dev/null; then SUDO="sudo -n"
fi
IS_ROOT=0; { [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; } && IS_ROOT=1

TO=""; have timeout && TO="timeout 60"

# Mask anything that looks like a credential.
redact() {
  sed -E \
    -e 's/(hf_)[A-Za-z0-9]{8,}/\1***REDACTED***/g' \
    -e 's/(sk-)[A-Za-z0-9_-]{8,}/\1***REDACTED***/g' \
    -e 's/(gh[pousr]_)[A-Za-z0-9]{8,}/\1***REDACTED***/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1***REDACTED***/g' \
    -e 's/\b([A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIALS?))(["]?[[:space:]]*[=:][[:space:]]*["]?)[^"[:space:],}]+/\1\3***REDACTED***/Ig' \
    -e 's#(://[^:/@[:space:]]+:)[^@/[:space:]]+@#\1***REDACTED***@#g'
}

LOGF="$OUT/_collector.log"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOGF" >&2; }

# run FILE CMD...   append "$ CMD" + output (stdout+stderr, redacted) to OUT/FILE
run() {
  local f="$OUT/$1"; shift
  {
    printf '\n$ %s\n' "$*"
    # shellcheck disable=SC2086
    $TO bash -c "$*" 2>&1 | redact
    printf '[exit %s]\n' "${PIPESTATUS[0]}"
  } >>"$f"
}
# runs FILE CMD...  same as run, but through sudo when available
runs() { local f="$1"; shift; if [ -n "$SUDO" ]; then run "$f" "$SUDO bash -c $(printf '%q' "$*")"; else run "$f" "$*"; fi; }

# dumpdir FILE DIR [maxdepth]  print every readable regular file in DIR as "path: value" (small files only)
dumpdir() {
  local f="$OUT/$1" d="$2" depth="${3:-1}"
  [ -d "$d" ] || { echo "# $d: missing" >>"$f"; return; }
  {
    echo "### $d"
    find -L "$d" -maxdepth "$depth" -type f -readable -size -64k 2>/dev/null | sort | while read -r p; do
      case "$p" in *uevent|*/power/*|*/subsystem/*|*/driver/*|*/firmware_node/*|*/msi_irqs/*) continue ;; esac
      case "${p##*/}" in config|rom|vpd|resource*|remove|rescan|reset*|new_id|remove_id|bind|unbind) continue ;; esac
      grep -Iq . "$p" 2>/dev/null || continue   # skip binary and empty files
      v=$(head -c 4096 "$p" 2>/dev/null)
      if [ "$(printf '%s' "$v" | wc -l)" -gt 0 ]; then printf -- '--- %s\n%s\n' "$p" "$v"; else printf '%s: %s\n' "$p" "$v"; fi
    done
  } 2>/dev/null | redact >>"$f"
}

log "writing to $OUT (root=$IS_ROOT)"

# ---------- 00 summary ----------
{
  echo "halogen-diag  generated $(date -u '+%F %T UTC')"
  echo "host: $HOST   user: $(id -un) ($(id))"
  echo "privileged collection: $IS_ROOT"
  echo "API probe base URL: $BASE_URL"
  echo "kernel: $(uname -r)"
  . /etc/os-release 2>/dev/null && echo "os: ${PRETTY_NAME:-?}"
  echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  echo "mem: $(awk '/MemTotal|MemAvailable|SwapTotal|SwapFree/{printf "%s %.1f GiB  ", $1, $2/1048576}' /proc/meminfo)"
  echo "cmdline: $(cat /proc/cmdline)"
  echo "tainted: $(cat /proc/sys/kernel/tainted)"
  echo
  echo "== quick checks (upstream docs/troubleshooting.md, docs/NPU.md)"
  for d in /sys/class/drm/card*/device; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x1002 ] || continue
    mec=$(cat "$d/fw_version/mec_fw_version" 2>/dev/null || echo "")
    [ -n "$mec" ] && { [ $((mec)) -ge $((0x24)) ] && echo "OK    MEC firmware $mec (>= 0x24)" || echo "FAIL  MEC firmware $mec < 0x24: long prompts fail (update linux-firmware)"; }
    uma=$(( $(cat "$d/mem_info_vram_total" 2>/dev/null || echo 0) / 1048576 ))
    [ "$uma" -le 2048 ] && echo "OK    BIOS UMA carve-out $uma MiB" || echo "WARN  BIOS UMA carve-out $uma MiB: set it to the minimum, not Auto"
    gtt=$(( $(cat "$d/mem_info_gtt_used" 2>/dev/null || echo 0) / 1073741824 ))
    gtt_total=$(( $(cat "$d/mem_info_gtt_total" 2>/dev/null || echo 0) / 1073741824 ))
    echo "INFO  GTT used $gtt GiB of $gtt_total GiB"
    if [ "$gtt" -ge 10 ] && ! pgrep -f flash_serve >/dev/null 2>&1; then
      echo "WARN  $gtt GiB GTT in use with no flash_serve process: leaked after an unclean exit? (upstream: reboot)"
    fi
    echo "INFO  performance level $(cat "$d/power_dpm_force_performance_level" 2>/dev/null); fclk: $(grep '\*' "$d/pp_dpm_fclk" 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
  done
  found=0
  for n in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    awk '$1=="gfx_target_version"{exit !($2==110501)}' "$n" 2>/dev/null || continue
    found=1
    cap=$(awk '$1=="capability"{print $2}' "$n"); simd=$(awk '$1=="simd_count"{print $2}' "$n")
    cwsr=$(awk '$1=="cwsr_size"{print $2}' "$n"); ctl=$(awk '$1=="ctl_stack_size"{print $2}' "$n")
    [ $(( cap & 0x08000000 )) -ne 0 ] && echo "OK    KFD SVM (CONFIG_HSA_AMD_SVM) on" || echo "FAIL  KFD SVM off: read-only checkpoint registration fails"
    if [ -n "$cwsr" ] && [ "$cwsr" = $(( ctl + simd / 2 * 479232 )) ]; then echo "OK    KFD gfx1151 fixes present (cwsr_size $cwsr)"
    else echo "FAIL  KFD gfx1151 fixes missing (cwsr_size '${cwsr:-absent}'): needs Linux 6.18.4+ / Ubuntu HWE 6.17.0-19.19~24.04.2+ / OEM 6.14.0-1018+"; fi
  done
  [ "$found" = 1 ] || echo "FAIL  no KFD node with gfx_target_version 110501"
  case " $(cat /proc/cmdline) " in
    *" amd_iommu=off "*) echo "INFO  amd_iommu=off: GPU prefill faster, NPU unavailable" ;;
    *) echo "INFO  IOMMU on ($(tr ' ' '\n' </proc/cmdline | grep -E '^(amd_)?iommu=' | tr '\n' ' ')): the NPU can work" ;;
  esac
  [ -e /dev/accel/accel0 ] && echo "OK    /dev/accel/accel0 present" || echo "INFO  no /dev/accel/accel0 (no NPU, or amd_iommu=off)"
  [ -r /sys/firmware/acpi/platform_profile ] && echo "INFO  ACPI platform profile $(cat /sys/firmware/acpi/platform_profile) (upstream measured performance faster)"
  echo "INFO  vm.compact_unevictable_allowed=$(cat /proc/sys/vm/compact_unevictable_allowed 2>/dev/null) (upstream: 0 with HALOGEN_WEIGHTS_LOCK=1 on a shared host)"
} >"$OUT/00-summary.txt"

# ---------- 01 OS / kernel ----------
log "os and kernel"
run 01-os-kernel.txt "cat /etc/os-release"
run 01-os-kernel.txt "uname -a"
run 01-os-kernel.txt "cat /proc/cmdline"
run 01-os-kernel.txt "cat /proc/version"
run 01-os-kernel.txt "uptime; cat /proc/loadavg"
run 01-os-kernel.txt "cat /proc/sys/kernel/tainted"
run 01-os-kernel.txt "ls /boot /efi /boot/efi 2>/dev/null"
run 01-os-kernel.txt "cat /etc/kernel/cmdline /etc/default/grub 2>/dev/null"
run 01-os-kernel.txt "grep -rH . /etc/modprobe.d/ /usr/lib/modprobe.d/ 2>/dev/null | grep -Ei 'amdgpu|amdxdna|ttm|kfd|iommu|drm'"
run 01-os-kernel.txt "grep -rH . /etc/modules-load.d/ 2>/dev/null"
run 01-os-kernel.txt "lsmod | grep -Ei 'amdgpu|amdxdna|ttm|drm|iommu|kfd|gpu_sched|xdna'"
run 01-os-kernel.txt "modinfo amdgpu 2>&1 | grep -Ev '^(alias|parm):'"
run 01-os-kernel.txt "modinfo amdxdna 2>&1"
run 01-os-kernel.txt "sysctl vm kernel.numa_balancing kernel.panic kernel.hung_task_timeout_secs 2>/dev/null | grep -Ev 'vm.stat_|lowmem_reserve'"
run 01-os-kernel.txt "cat /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; grep -i huge /proc/meminfo"
run 01-os-kernel.txt "cat /sys/module/zswap/parameters/enabled 2>/dev/null; zramctl 2>/dev/null; swapon --show"
dumpdir 01-module-params.txt /sys/module/amdgpu/parameters
dumpdir 01-module-params.txt /sys/module/ttm/parameters
dumpdir 01-module-params.txt /sys/module/amdxdna/parameters
dumpdir 01-module-params.txt /sys/module/amd_iommu/parameters
dumpdir 01-module-params.txt /sys/module/iommu/parameters

# ---------- 02 hardware ----------
log "hardware"
run 02-hardware.txt "lscpu"
run 02-hardware.txt "cat /proc/meminfo"
run 02-hardware.txt "free -h"
run 02-hardware.txt "lspci -nnk"
run 02-hardware.txt "lspci -vvv -d 1002: 2>/dev/null; lspci -vvv -d 1022: 2>/dev/null | grep -A40 -Ei 'signal processing|npu|1502|17f0'"
runs 02-hardware.txt "dmidecode -t bios -t system -t baseboard -t processor -t memory"
run 02-hardware.txt "cat /sys/class/dmi/id/{sys_vendor,product_name,product_version,board_vendor,board_name,bios_vendor,bios_version,bios_date} 2>/dev/null"
run 02-hardware.txt "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,ROTA,TRAN"
run 02-hardware.txt "df -hT -x tmpfs -x devtmpfs -x overlay"
run 02-hardware.txt "findmnt -no SOURCE,FSTYPE,OPTIONS /; findmnt -no SOURCE,FSTYPE,OPTIONS /var/lib/docker 2>/dev/null"
run 02-hardware.txt "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference /sys/devices/system/cpu/amd_pstate/status 2>/dev/null"
run 02-hardware.txt "powerprofilesctl get 2>/dev/null; tuned-adm active 2>/dev/null; cat /sys/firmware/acpi/platform_profile 2>/dev/null"
run 02-hardware.txt "sensors 2>/dev/null"
run 02-hardware.txt "ls -la /dev/kfd /dev/dri /dev/dri/by-path /dev/accel 2>&1"
run 02-hardware.txt "getent group render video; id"
run 02-hardware.txt "ulimit -a"
run 02-hardware.txt "cat /proc/pressure/memory /proc/pressure/io /proc/pressure/cpu 2>/dev/null"

# ---------- 03 GPU (amdgpu / ROCm) ----------
log "gpu"
for card in /sys/class/drm/card*; do
  [ -e "$card/device/vendor" ] || continue
  [ "$(cat "$card/device/vendor")" = "0x1002" ] || continue
  d="$card/device"
  f="03-gpu-$(basename "$card").txt"
  run "$f" "readlink -f $d; cat $d/vendor $d/device $d/revision $d/subsystem_device 2>/dev/null"
  for n in power_dpm_force_performance_level power_dpm_state pp_power_profile_mode \
           pp_dpm_fclk pp_dpm_sclk pp_dpm_mclk pp_dpm_socclk pp_dpm_dcefclk pp_od_clk_voltage \
           mem_info_vram_total mem_info_vram_used mem_info_vis_vram_total mem_info_gtt_total mem_info_gtt_used \
           gpu_busy_percent mem_busy_percent current_link_speed current_link_width \
           vbios_version unique_id product_name serial_number thermal_throttling_logging apu_thermal_cap; do
    [ -r "$d/$n" ] && run "$f" "echo '== $n'; cat $d/$n"
  done
  dumpdir "$f" "$d/fw_version"
  for h in "$d"/hwmon/hwmon*; do dumpdir "$f" "$h"; done
  [ -r "$d/gpu_metrics" ] && run "$f" "od -An -tx1 -v $d/gpu_metrics | head -40"
done
for n in /sys/class/kfd/kfd/topology/nodes/*; do dumpdir 03-kfd-topology.txt "$n" 1; done
runs 03-kfd-topology.txt 'ls -la /sys/class/kfd/kfd/proc/ 2>/dev/null; for p in /sys/class/kfd/kfd/proc/*; do n=${p##*/}; echo "== pid $n $(cat /proc/$n/comm 2>/dev/null)"; ls "$p/queues" 2>/dev/null | head; done'
runs 03-gpu-users.txt "fuser -v /dev/kfd /dev/dri/* /dev/accel/* 2>&1"
runs 03-gpu-users.txt "lsof /dev/kfd /dev/accel/accel0 2>/dev/null | head -50"
run 03-gpu-tools.txt "halogen-fabric-clock status 2>/dev/null || /usr/local/sbin/halogen-fabric-clock status 2>/dev/null || echo 'halogen-fabric-clock not installed'"
run 03-gpu-tools.txt "systemctl status halogen-fabric-clock.service --no-pager 2>/dev/null"
run 03-gpu-tools.txt "ls -la /opt/rocm* 2>/dev/null | head; cat /opt/rocm/.info/version 2>/dev/null"
run 03-gpu-tools.txt "PATH=\$PATH:/opt/rocm/bin rocminfo"
run 03-gpu-tools.txt "PATH=\$PATH:/opt/rocm/bin rocm-smi --showall 2>/dev/null || true"
run 03-gpu-tools.txt "PATH=\$PATH:/opt/rocm/bin amd-smi static 2>/dev/null; PATH=\$PATH:/opt/rocm/bin amd-smi metric 2>/dev/null; true"
run 03-gpu-tools.txt "vulkaninfo --summary 2>/dev/null | head -60"
runs 03-gpu-tools.txt "for f in /sys/kernel/debug/dri/*/amdgpu_firmware_info; do echo \"== \$f\"; cat \"\$f\"; done"
runs 03-gpu-tools.txt "for f in /sys/kernel/debug/dri/*/amdgpu_pm_info; do echo \"== \$f\"; cat \"\$f\"; done"
run 03-gpu-tools.txt "ls -la /lib/firmware/amdgpu 2>/dev/null | grep -Ei 'gc_11_5|psp_14|sdma_6_1|vcn_4_0_5|dcn_3_5|smu_14' | head -40"
run 03-gpu-tools.txt "pacman -Q 2>/dev/null | grep -Ei 'linux-firmware|mesa|rocm|hip|xrt|xdna|docker|amdgpu' ; dpkg -l 2>/dev/null | grep -Ei 'linux-firmware|mesa|rocm|hip|xrt|xdna|docker|amdgpu' ; rpm -qa 2>/dev/null | grep -Ei 'linux-firmware|mesa|rocm|hip|xrt|xdna|docker|amdgpu'; true"

# ---------- 04 NPU (amdxdna / XRT) ----------
log "npu"
run 04-npu.txt "ls -la /dev/accel /sys/class/accel 2>&1"
for a in /sys/class/accel/accel*; do [ -e "$a/device" ] && dumpdir 04-npu.txt "$a/device"; done
run 04-npu.txt "ls -la /lib/firmware/amdnpu/* 2>/dev/null"
run 04-npu.txt "ls -la /opt/xilinx/xrt/lib /usr/lib/libxrt* /usr/lib64/libxrt* 2>/dev/null"
run 04-npu.txt "xrt-smi --version 2>/dev/null; xrt-smi examine 2>&1; xrt-smi examine -r all 2>&1 | head -200"
run 04-npu.txt "cat /proc/sys/vm/max_map_count; grep -i memlock /etc/security/limits.conf /etc/security/limits.d/* 2>/dev/null"

# ---------- 05 kernel log ----------
log "kernel log"
PAT='amdgpu|amdxdna|xdna|kfd|ttm|iommu|AMD-Vi|drm|gpu reset|ring .* timeout|page fault|Page not present|killed entity|svm_range|aie2_tdr|making progress|oom|Out of memory|hung_task|mce|watchdog|halogen|firmware|SMU|psp'
if [ "$IS_ROOT" = 1 ]; then
  runs 05-dmesg-full.txt "dmesg -T"
  runs 05-dmesg-filtered.txt "dmesg -T | grep -Ei '$PAT'"
else
  run 05-dmesg-filtered.txt "dmesg -T 2>/dev/null | grep -Ei '$PAT' || journalctl -k -b --no-pager 2>/dev/null | grep -Ei '$PAT'"
fi
runs 05-journal-kernel.txt "journalctl -k -b --no-pager | grep -Ei '$PAT' | tail -n 3000"
runs 05-journal-kernel.txt "journalctl -k -b -1 --no-pager 2>/dev/null | grep -Ei '$PAT' | tail -n 1500"
runs 05-journal-kernel.txt "journalctl --list-boots --no-pager | tail -n 15"
runs 05-journal-oom.txt "journalctl -b --no-pager | grep -Ei 'out of memory|oom-kill|invoked oom-killer|oom_reaper|killed process|systemd-oomd\\[|memory pressure' | tail -n 500"
if command -v getenforce >/dev/null; then
  run 05-selinux.txt "getenforce; sestatus 2>/dev/null; getsebool container_use_devices 2>/dev/null"
  runs 05-selinux.txt "ausearch -m AVC,USER_AVC -ts boot 2>/dev/null | tail -n 200 || journalctl -b --no-pager | grep -i 'avc:' | tail -n 200"
fi
run 05-journal-oom.txt "oomctl 2>/dev/null; systemctl is-active systemd-oomd 2>/dev/null"

# ---------- 06 container runtime ----------
log "docker"
DOCKER=""
if have docker && docker info >/dev/null 2>&1; then DOCKER="docker"
elif have docker && [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then DOCKER="$SUDO docker"
elif have podman; then DOCKER="podman"
fi
echo "container CLI: ${DOCKER:-none}" >>"$OUT/00-summary.txt"
if [ -n "$DOCKER" ]; then
  run 06-docker.txt "$DOCKER version"
  run 06-docker.txt "$DOCKER info"
  run 06-docker.txt "$DOCKER ps -a --no-trunc --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
  run 06-docker.txt "$DOCKER images --digests | grep -Ei 'halogen|REPOSITORY'"
  run 06-docker.txt "$DOCKER stats --no-stream --no-trunc"
  run 06-docker.txt "$DOCKER system df"
  run 06-docker.txt "cat /etc/docker/daemon.json 2>/dev/null"
  if [ -n "$CONTAINER" ]; then NAMES="$CONTAINER"
  else NAMES=$($DOCKER ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -i halogen | awk '{print $1}')
  fi
  for img in $($DOCKER images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i halogen | grep -v '<none>'); do
    run 06-docker-images.txt "$DOCKER image inspect $img --format '{{.Id}} {{json .RepoDigests}} created={{.Created}} labels={{json .Config.Labels}}'"
  done
  for n in $NAMES; do
    f="06-container-$n.txt"
    log "container $n"
    run "$f" "$DOCKER inspect $n"
    run "$f" "$DOCKER inspect $n --format '{{range .Config.Env}}{{println .}}{{end}}' | sort"
    run "$f" "$DOCKER top $n -eo pid,ppid,rss,vsz,pcpu,etime,args 2>/dev/null"
    run "$f" "$DOCKER exec $n sh -c 'cat /proc/1/oom_score_adj; ulimit -a; nproc; cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events /sys/fs/cgroup/memory.pressure 2>/dev/null' 2>&1"
    run "$f" "$DOCKER exec $n sh -c 'ls -la /dev/kfd /dev/dri /dev/accel; ls -la /models /v2 /cache /models/npu 2>/dev/null | head -100; env | grep -E \"^(HALOGEN|HSA|HIP|ROCM|AMD|XRT|LD_)\" | sort' 2>&1"
    run "$f" "$DOCKER exec $n sh -c 'ls /opt/rocm*/.info 2>/dev/null; cat /opt/rocm*/.info/version 2>/dev/null; ls -la /opt/xilinx/xrt/lib 2>/dev/null' 2>&1"
    run "$f" "$DOCKER exec $n sh -c 'cat /etc/halogen* /app/VERSION /VERSION 2>/dev/null; true'"
    run "06-container-$n.log" "$DOCKER logs --timestamps --tail $LOG_LINES $n"
    if [ "$HASH_MODELS" = 1 ]; then
      $DOCKER inspect "$n" --format '{{range .Mounts}}{{println .Source}}{{end}}' 2>/dev/null | while read -r src; do
        [ -n "$src" ] && run 06-model-hashes.txt "find '$src' -maxdepth 2 -type f \\( -name '*.hgn' -o -name '*.gguf' -o -name '*.safetensors' -o -name '*.hnpw' -o -name '*.json' -o -name '*.jinja' \\) -exec sha256sum {} +"
      done
    fi
    $DOCKER inspect "$n" --format '{{range .Mounts}}{{println .Source}}{{end}}' 2>/dev/null | while read -r src; do
      [ -n "$src" ] && run 06-model-files.txt "ls -la '$src' 2>&1 | head -60; du -sh '$src' 2>/dev/null"
    done
  done
fi

# ---------- 07 systemd units ----------
log "systemd"
for scope in system user; do
  SC="systemctl"; JC="journalctl"
  [ "$scope" = user ] && SC="systemctl --user" && JC="journalctl --user"
  units=$($SC list-units --all --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -Ei 'halogen|fabric|oomd')
  units="$units $($SC list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'halogen|fabric')"
  for u in $(echo "$units" | tr ' ' '\n' | sort -u); do
    f="07-unit-$scope-$u.txt"
    run "$f" "$SC cat $u"
    run "$f" "$SC status $u --no-pager -l"
    run "$f" "$SC show $u -p ActiveState,SubState,Result,NRestarts,ExecMainStatus,ExecMainCode,MainPID,UnitFileState,MemoryCurrent,MemoryPeak,MemorySwapMax,OOMPolicy"
    run "$f" "$JC -u $u -b --no-pager -n $LOG_LINES"
  done
done
run 07-systemd.txt "systemctl --failed --no-pager; systemctl --user --failed --no-pager"
run 07-systemd.txt "loginctl show-user \$(id -un) -p Linger 2>/dev/null"

# ---------- 08 API probe ----------
log "api probe $BASE_URL"
if have curl; then
  AUTH=()
  [ -n "$API_KEY" ] && AUTH=(-H "Authorization: Bearer $API_KEY")
  probe() {
    local path="$1"
    { printf '\n$ curl %s%s\n' "$BASE_URL" "$path"
      curl -sS -m 20 -w '\n[http %{http_code} in %{time_total}s]\n' "${AUTH[@]}" "$BASE_URL$path" 2>&1 | head -c 200000 | redact
    } >>"$OUT/08-api.txt"
  }
  probe /health
  probe /healthz
  probe /v1/models
  probe /version
  [ "$READ_METRICS" = 1 ] && probe /metrics
  # tiny real request: proves the main model generates (2 tokens, no thinking)
  MODEL=$(curl -s -m 10 "${AUTH[@]}" "$BASE_URL/v1/models" 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$MODEL" ]; then
    { printf '\n$ POST %s/v1/chat/completions (model=%s, "Reply with OK")\n' "$BASE_URL" "$MODEL"
      curl -sS -m 120 -w '\n[http %{http_code} in %{time_total}s]\n' "${AUTH[@]}" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}],\"max_tokens\":16,\"chat_template_kwargs\":{\"enable_thinking\":false}}" \
        "$BASE_URL/v1/chat/completions" 2>&1 | redact
    } >>"$OUT/08-api.txt"
  fi
else
  echo "curl not installed" >"$OUT/08-api.txt"
fi
run 08-api.txt "ss -lntp 2>/dev/null | grep -E ':$PORT\\b|LISTEN' | head -40"

# ---------- 09 environment ----------
run 09-env.txt "env | grep -E '^(HALOGEN|HSA|HIP|ROCM|AMD|XRT|HF_|LD_LIBRARY|DOCKER)' | sort"

# ---------- package ----------
log "packaging"
find "$OUT" -type f -empty -delete
TAR="${OUT}.tar.gz"
tar -C "$(dirname "$OUT")" -czf "$TAR" "$(basename "$OUT")" && log "bundle: $TAR ($(du -h "$TAR" | cut -f1))"
echo
echo "Done. Review the files in $OUT before you share $TAR."
[ "$IS_ROOT" = 1 ] || echo "Tip: run with sudo to also collect dmesg, dmidecode and amdgpu firmware versions."
