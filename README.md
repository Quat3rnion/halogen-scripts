# halogen-scripts

Scripts to set up and examine a host for
[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) on
AMD Strix Halo (Ryzen AI Max+ 395, Radeon 8060S, XDNA NPU).

| Script | Purpose |
|---|---|
| `halogen-replicate.sh` | Sets up a host the same way as a reference host ("frame") that runs Halogen. It configures kernel parameters, the GPU fabric clock, memory, Docker and a systemd user unit. |
| `halogen-diag.sh` | Collects a diagnostic bundle for a Halogen host. It does not change the system. Use it to report a problem. |

The scripts support Arch Linux, Ubuntu 24.04 and later (and Debian), and Fedora.

## Requirements

- An AMD Strix Halo machine. 128 GB RAM is necessary for the reference
  configuration (four 262,144-position slots and seven NPU helper models).
- systemd, Docker (the script installs it), `curl`, and `sudo`.
- In the BIOS, set the UMA frame buffer ("dedicated VRAM") to its minimum.
  Do not use Auto. Halogen uses system RAM through GTT, not dedicated VRAM.

## Quick start

```bash
git clone https://github.com/Quat3rnion/halogen-scripts.git
cd halogen-scripts

# 1. Dry run. This shows all changes. It changes nothing.
sudo ./halogen-replicate.sh

# 2. Apply the changes.
sudo ./halogen-replicate.sh --apply

# 3. Reboot, so that the new kernel parameters and groups apply.
sudo reboot

# 4. Start Halogen by hand (the unit is not enabled at boot).
systemctl --user start halogen.service
journalctl --user -fu halogen.service
```

The script asks for the IOMMU mode (`pt` or `off`) if you do not give
`--iommu`. Refer to [IOMMU mode](#iommu-mode).

The script does not download model files unless you give `--fetch-models`.
Without it, step 10 of the output shows the source and the location of each
file.

## Examples

Set up the reference configuration, download all model files, and install the
dashboard:

```bash
sudo ./halogen-replicate.sh --apply --iommu pt --fetch-models --dashboard
```

Use the GPU only, for faster prompt processing (no NPU):

```bash
sudo ./halogen-replicate.sh --apply --iommu off
```

Make the API available on the LAN, with an API key:

```bash
sudo ./halogen-replicate.sh --apply --iommu pt \
  --api-key-file ~/.config/halogen/api-key \
  --lan-ip 192.168.1.50
# Clients send: Authorization: Bearer $(cat ~/.config/halogen/api-key)
```

Show the dashboard on the LAN, on port 8790:

```bash
sudo ./halogen-replicate.sh --apply --iommu pt --dashboard --dashboard-bind 0.0.0.0
```

Use a machine with less than 128 GB RAM. This sets the GTT size to the
upstream values for the installed RAM:

```bash
sudo ./halogen-replicate.sh --apply --iommu pt --scale-memory
```

Use a specific Halogen version instead of `:latest`:

```bash
sudo ./halogen-replicate.sh --apply --image ghcr.io/peonist-ai/halogen-flash-server:0.20.5
```

Change only the kernel command line:

```bash
sudo ./halogen-replicate.sh --apply --iommu off --cmdline-only
```

Change all boot entries, not only the default entry:

```bash
sudo ./halogen-replicate.sh --apply --entries all
```

Use a specified boot loader instead of the automatic detection:

```bash
sudo ./halogen-replicate.sh --apply --bootloader grub
```

Collect a diagnostic bundle (with `sudo`, the bundle also contains `dmesg`
and firmware versions):

```bash
sudo ./halogen-diag.sh
# The result is halogen-diag-<host>-<time>.tar.gz in the current folder.

# With an API key, and with a server on another address:
./halogen-diag.sh -u http://192.168.1.50:8731 -k "$(cat ~/.config/halogen/api-key)"
```

Read the bundle before you share it. The script hides tokens, keys and
passwords, but the bundle contains host names, paths and local IP addresses.

For all options, use `--help` (`-h` for `halogen-diag.sh`).

## What halogen-replicate.sh changes

The default mode is a dry run. With `--apply`, the script makes a backup of each
file before it changes it (`<file>.pre-halogen-<time>`). It writes a full log to
`/var/log/halogen-replicate-<time>.log`. You can run the script again. A second
run changes nothing when the system is already correct.

| Step | Change |
|---|---|
| Hardware check | Checks the GPU, NPU, RAM, BIOS UMA size, GPU MEC firmware (0x24 or later), the kernel KFD fixes and shared virtual memory, and the power profile. It changes nothing. |
| Packages | Docker, AMD firmware, `rocminfo`, zram and systemd-oomd. The NPU DKMS driver, only if the kernel does not have `amdxdna`. Host XRT, only with `--host-xrt`. |
| Kernel command line | `amd_iommu=pt` or `off`, `amdgpu.gttsize`, `ttm.pages_limit`, `ttm.page_pool_size`, `zswap.enabled=0`. |
| Fabric clock | Installs `halogen-fabric-clock` and its service. The service holds the GPU fabric clock at its top level. This is necessary when the GPU and the NPU operate at the same time. |
| Memory and user | Unlimited locked memory, the user in the `docker` group, lingering for user units, and the `performance` power profile. |
| Memory guard | A systemd-oomd policy, zram, and a 16 GiB fallback swap file with the lowest priority. |
| User unit | `~/.config/systemd/user/halogen.service`, with the reference container settings and the image digest of `:latest`. The unit is not enabled and not started. |
| Model files | Only with `--fetch-models`. The files are downloaded at the revisions of the reference host, and the script checks the SHA-256 of the large files. |
| Dashboard | Only with `--dashboard`. Refer to [Dashboard](#dashboard). |

### Boot loaders

The script finds the boot loader automatically and edits its configuration:

- systemd-boot (and `/etc/kernel/cmdline` when kernel-install manages the entries)
- unified kernel images (UKI), with `mkinitcpio`, `dracut` or `kernel-install`
- GRUB (with `grubby` on Fedora, a drop-in in `/etc/default/grub.d/` on Debian
  and Ubuntu, otherwise `/etc/default/grub`). On Debian and Ubuntu,
  `update-grub` reads this folder also when the install does not have it yet.
  The script then makes the folder.
- rEFInd, Limine and extlinux/syslinux
- EFISTUB: the script prints the `efibootmgr` command. You must run it yourself.

The script removes old values of the same parameters. This is important for
`amd_iommu`: a value of `off` before `pt` keeps the IOMMU off.

## IOMMU mode

| Mode | Result |
|---|---|
| `pt` | The NPU operates. Halogen runs its NPU helper models (embeddings, decider, LFM3, image, speech). This is the reference setting. |
| `off` | No NPU. Upstream measured 13 to 16 percent faster prompt processing (prefill) on the GPU. The unit runs without NPU models, `/dev/accel`, XRT and the fabric clock hold. |

To change the mode, run the script again with the other mode, then reboot.

## Dashboard

`--dashboard` builds and runs
[halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) as the user
unit `halogen-dashboard.service`. There is no published image. The script builds
the image from a pinned commit (`--dashboard-ref` selects another one). The
first build takes approximately 5 to 15 minutes.

- The default address is `http://127.0.0.1:8790`. Use `--dashboard-bind` and
  `--dashboard-port` to change it. The dashboard has no login.
- The dashboard Collector must be the only reader of Halogen's `/metrics`,
  because each read resets two gauges. Let Prometheus read the Collector's
  `/metrics`, not Halogen's.
- With `--api-key-file`, the key goes into `~/.config/halogen/dashboard.env`
  (mode 0600).

## Tests

`tests/test-bootloaders.sh` runs 17 boot-loader cases in Ubuntu 26.04 and
Fedora 44 containers. Each case runs the script two times and makes sure that
the second run changes nothing. Docker is necessary.

```bash
./tests/test-bootloaders.sh
```

The full `--apply` path was tested on Ubuntu 26.04, Fedora 44 and Arch Linux
virtual machines, with reboots. These machines had no Strix Halo hardware. Thus
the tests did not start Halogen, the NPU or the fabric clock hold.

## Limits

- The script does not set the BIOS. Check the UMA frame buffer yourself.
- `--fetch-models` downloads approximately 165 GB.
- `--host-xrt` is for rare cases only. Use it only when Halogen reports that the
  NPU driver refused the XRT in the image.
- The reference values (GTT size, memory limit of 108 GiB, four KV slots) are
  for 128 GB RAM.

## License

Licensed under either of [Apache License 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT), at your option.
