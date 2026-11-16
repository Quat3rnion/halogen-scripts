#!/usr/bin/env bash
# test-bootloaders.sh - fixture tests for halogen-replicate.sh's kernel command-line step.
# Each case builds a fake boot setup inside a throwaway container, runs
#   halogen-replicate.sh --apply --cmdline-only
# twice (the second run must change nothing) and checks the result.
# Usage: ./test-bootloaders.sh            (needs docker; pulls ubuntu:26.04 and fedora:44)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
P='amd_iommu=pt amdgpu.gttsize=131072 ttm.pages_limit=32505856 ttm.page_pool_size=32505856 zswap.enabled=0'
pass=0; fail=0

# run_case NAME IMAGE SETUP CHECK [EXTRA_ARGS]
run_case() {
  local name="$1" image="$2" setup="$3" check="$4" extra="${5:-}"
  local out
  out=$(docker run --rm -i -e P="$P" -v "$root/halogen-replicate.sh:/r.sh:ro" -v "$here/stubs:/test-stubs:ro" "$image" bash -s <<EOF 2>&1
set -e
useradd -m tester >/dev/null 2>&1 || true
mkdir -p /fake-efivars /stubs
export PATH=/stubs:\$PATH HALOGEN_REP_EFIVARS=/fake-efivars HALOGEN_REP_CMDLINE=/fake-cmdline SUDO_USER=tester TMPDIR=/var/tmp
echo 'root=/dev/sda2 rw quiet' > /fake-cmdline
stub() { printf '#!/bin/sh\necho "\$(basename \$0) \$*" >> /stub.log\n' > /stubs/\$1; chmod +x /stubs/\$1; }
efivar() { f=/fake-efivars/\$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f; printf '\006\000\000\000' > \$f; s="\$2"; for ((i=0;i<\${#s};i++)); do printf '%s\0' "\${s:i:1}"; done >> \$f; }
$setup
bash /r.sh --apply --cmdline-only $extra > /run1.log 2>&1 || { echo "RUN1 FAILED"; cat /run1.log; exit 1; }
: > /stub.log.2; [ -f /stub.log ] && cp /stub.log /stub.log.1 || : > /stub.log.1; : > /stub.log
bash /r.sh --apply --cmdline-only $extra > /run2.log 2>&1 || { echo "RUN2 FAILED"; cat /run2.log; exit 1; }
if grep -q 'wrote:' /run2.log || [ -s /stub.log ]; then echo "SECOND RUN CHANGED SOMETHING"; cat /run2.log; cat /stub.log; exit 1; fi
$check
echo CASE-OK
EOF
)
  if printf '%s' "$out" | grep -q CASE-OK; then echo "PASS  $name"; pass=$((pass+1))
  else echo "FAIL  $name"; printf '%s\n' "$out" | sed 's/^/      /' | tail -40; fail=$((fail+1)); fi
}

# 1. Debian/Ubuntu GRUB with a cloud-image drop-in
run_case "grub (debian, grub.d drop-in)" ubuntu:26.04 '
mkdir -p /etc/default/grub.d /boot/grub
printf "GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"\n" > /etc/default/grub
printf "GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0 amd_iommu=off\"\nGRUB_CMDLINE_LINUX=\"zswap.enabled=1\"\n" > /etc/default/grub.d/50-cloudimg-settings.cfg
: > /boot/grub/grub.cfg; echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2 ro quiet" > /fake-cmdline; stub update-grub' '
grep -q "^update-grub" /stub.log.1
. /etc/default/grub; for f in /etc/default/grub.d/*.cfg; do . "$f"; done
echo "D=[$GRUB_CMDLINE_LINUX_DEFAULT] L=[$GRUB_CMDLINE_LINUX]"
[ "$GRUB_CMDLINE_LINUX_DEFAULT" = "console=ttyS0 $P" ] && [ -z "$GRUB_CMDLINE_LINUX" ]'

# 2. Fedora GRUB with BLS entries and grubby
run_case "grub (fedora, BLS + grubby)" fedora:44 '
mkdir -p /boot/loader/entries /boot/grub2; : > /boot/grub2/grub.cfg; : > /boot/loader/entries/abc-6.20.conf
cp /test-stubs/grubby /stubs/grubby
echo "BOOT_IMAGE=(hd0,gpt2)/vmlinuz ro" > /fake-cmdline' '
grep -q -- "--update-kernel=DEFAULT --remove-args=amd_iommu amdgpu.gttsize ttm.pages_limit ttm.page_pool_size zswap.enabled --args=$P" /stub.log.1'

# 3. GRUB without grub.d (Arch style): edit /etc/default/grub in place
run_case "grub (plain /etc/default/grub)" fedora:44 '
mkdir -p /boot/grub; : > /boot/grub/grub.cfg
printf "GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet amd_iommu=off\"\nGRUB_CMDLINE_LINUX=\"\"\n" > /etc/default/grub
echo "BOOT_IMAGE=/vmlinuz-linux root=/dev/sda2" > /fake-cmdline; stub grub-mkconfig' '
grep -qx "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet $P\"" /etc/default/grub
grep -q "^grub-mkconfig -o /boot/grub/grub.cfg" /stub.log.1'

# 4. systemd-boot with kernel-install entries (Fedora/Ubuntu style): entry + /etc/kernel/cmdline
run_case "systemd-boot (kernel-install)" fedora:44 '
echo 0123456789abcdef0123456789abcdef > /etc/machine-id
mkdir -p /efi/EFI/systemd /efi/loader/entries
printf "title Fedora\nversion 6.20\noptions root=UUID=1 rw rhgb\nlinux /vmlinuz\n" > /efi/loader/entries/0123456789abcdef0123456789abcdef-6.20.conf
printf "title Fedora rescue\noptions root=UUID=1 rw\nlinux /vmlinuz-rescue\n" > /efi/loader/entries/0123456789abcdef0123456789abcdef-0-rescue.conf
efivar LoaderInfo "systemd-boot 259"' '
grep -qx "options root=UUID=1 rw rhgb $P" /efi/loader/entries/0123456789abcdef0123456789abcdef-6.20.conf
grep -qx "options root=UUID=1 rw" /efi/loader/entries/0123456789abcdef0123456789abcdef-0-rescue.conf
grep -qx "root=UUID=1 rw rhgb $P" /etc/kernel/cmdline'

# 5. systemd-boot, --entries all skips the fallback entry
run_case "systemd-boot (--entries all)" fedora:44 '
mkdir -p /boot/EFI/systemd /boot/loader/entries
printf "title Arch\noptions root=X rw\n" > /boot/loader/entries/arch.conf
printf "title Arch LTS\noptions root=X rw amd_iommu=off\n" > /boot/loader/entries/arch-lts.conf
printf "title Arch fallback\noptions root=X rw\n" > /boot/loader/entries/arch-fallback.conf
efivar LoaderInfo "systemd-boot 261"' '
grep -qx "options root=X rw $P" /boot/loader/entries/arch.conf
grep -qx "options root=X rw $P" /boot/loader/entries/arch-lts.conf
grep -qx "options root=X rw" /boot/loader/entries/arch-fallback.conf
[ ! -f /etc/kernel/cmdline ]' '--entries all'

# 6. UKI built by mkinitcpio with /etc/cmdline.d
run_case "uki (mkinitcpio /etc/cmdline.d)" fedora:44 '
mkdir -p /etc/cmdline.d; echo "root=X rw" > /etc/cmdline.d/root.conf
efivar StubInfo "systemd-stub 261"; stub mkinitcpio' '
grep -qx "$P" /etc/cmdline.d/90-halogen.conf
grep -q "^mkinitcpio -P" /stub.log.1'

# 7. UKI with /etc/kernel/cmdline and dracut
run_case "uki (/etc/kernel/cmdline + dracut)" fedora:44 '
mkdir -p /etc/kernel; echo "root=X rw quiet" > /etc/kernel/cmdline
efivar StubInfo "systemd-stub 259"; stub dracut' '
grep -qx "root=X rw quiet $P" /etc/kernel/cmdline
grep -q "^dracut --regenerate-all --force" /stub.log.1'

# 8. rEFInd refind_linux.conf (default = first line)
run_case "refind (refind_linux.conf)" fedora:44 '
mkdir -p /boot/EFI/refind
printf "\"Boot with standard options\"  \"root=UUID=1 rw quiet\"\n\"Boot to single-user mode\"    \"root=UUID=1 rw single\"\n" > /boot/refind_linux.conf' '
grep -qx "\"Boot with standard options\"  \"root=UUID=1 rw quiet $P\"" /boot/refind_linux.conf
grep -qx "\"Boot to single-user mode\"    \"root=UUID=1 rw single\"" /boot/refind_linux.conf'

# 9. Limine limine.conf (no limine-entry-tool), default_entry 2
run_case "limine (limine.conf)" fedora:44 '
mkdir -p /boot/EFI/BOOT
printf "timeout: 3\ndefault_entry: 2\n\n/Arch Linux (linux-lts)\n    protocol: linux\n    path: boot():/vmlinuz-linux-lts\n    cmdline: root=X rw\n\n/Arch Linux (linux)\n    protocol: linux\n    path: boot():/vmlinuz-linux\n    cmdline: root=X rw quiet\n\n/Arch Linux (linux-fallback)\n    protocol: linux\n    cmdline: root=X rw\n" > /boot/EFI/BOOT/limine.conf' '
grep -qx "    cmdline: root=X rw quiet $P" /boot/EFI/BOOT/limine.conf
[ "$(grep -c "cmdline: root=X rw\$" /boot/EFI/BOOT/limine.conf)" = 2 ]'

# 10. Limine with limine-entry-tool (CachyOS)
run_case "limine (/etc/default/limine)" fedora:44 '
printf "ESP_PATH=/boot\nKERNEL_CMDLINE[default]=\"root=X rw quiet\"\n" > /etc/default/limine; stub limine-update' '
grep -qx "KERNEL_CMDLINE\[default\]=\"root=X rw quiet $P\"" /etc/default/limine
grep -q "^limine-update" /stub.log.1'

# 11. extlinux.conf
run_case "extlinux (extlinux.conf)" fedora:44 '
mkdir -p /boot/extlinux
printf "DEFAULT linux\nLABEL linux\n  LINUX /vmlinuz\n  APPEND root=X rw\nLABEL rescue\n  LINUX /vmlinuz\n  APPEND root=X rw single\n" > /boot/extlinux/extlinux.conf' '
grep -qx "  APPEND root=X rw $P" /boot/extlinux/extlinux.conf
grep -qx "  APPEND root=X rw single" /boot/extlinux/extlinux.conf'

# 12. EFISTUB: nothing to edit, instructions only
run_case "efistub (instructions only)" fedora:44 '
rm -rf /boot/loader /boot/grub /boot/grub2; : ' '
grep -q "EFISTUB" /run1.log; grep -q "efibootmgr --create" /run1.log'

# 13. --bootloader override wins over detection
run_case "--bootloader extlinux override" fedora:44 '
mkdir -p /boot/extlinux /boot/grub; : > /boot/grub/grub.cfg
printf "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\n" > /etc/default/grub
printf "LABEL a\n  APPEND root=X\n" > /boot/extlinux/extlinux.conf' '
grep -qx "  APPEND root=X $P" /boot/extlinux/extlinux.conf
grep -qx "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"" /etc/default/grub' '--bootloader extlinux'

# 14. switch pt -> off on systemd-boot (the old amd_iommu value must go, not pile up)
run_case "systemd-boot (--iommu off switch)" fedora:44 '
mkdir -p /boot/EFI/systemd /boot/loader/entries
printf "title Arch\noptions root=X rw amd_iommu=pt amdgpu.gttsize=131072 ttm.pages_limit=32505856 ttm.page_pool_size=32505856 zswap.enabled=0\n" > /boot/loader/entries/arch.conf
efivar LoaderInfo "systemd-boot 261"' '
grep -qx "options root=X rw amdgpu.gttsize=131072 ttm.pages_limit=32505856 ttm.page_pool_size=32505856 zswap.enabled=0 amd_iommu=off" /boot/loader/entries/arch.conf' '--iommu off'

# 15. --iommu off through the Debian GRUB drop-in, with amd_iommu=pt in a cloud drop-in
run_case "grub (debian, --iommu off)" ubuntu:26.04 '
mkdir -p /etc/default/grub.d /boot/grub; : > /boot/grub/grub.cfg
printf "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet amd_iommu=pt\"\n" > /etc/default/grub
echo "BOOT_IMAGE=/vmlinuz root=/dev/sda2" > /fake-cmdline; stub update-grub' '
. /etc/default/grub; for f in /etc/default/grub.d/*.cfg; do . "$f"; done
[ "$GRUB_CMDLINE_LINUX_DEFAULT" = "quiet amd_iommu=off amdgpu.gttsize=131072 ttm.pages_limit=32505856 ttm.page_pool_size=32505856 zswap.enabled=0" ]' '--iommu off'

echo; echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
