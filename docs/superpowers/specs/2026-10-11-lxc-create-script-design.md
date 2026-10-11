# Proxmox LXC creator: design

Date: 2026-10-11
Script: `Bash/Proxmox Scripts/LXC Template/create-lxc.sh`

## Goal

One script, run as root on a Proxmox VE host, that builds an Ubuntu or Debian
container and either leaves it running or converts it to a template. It
replaces the manual in-container notes (apt, locale, user, dotfiles) and
follows the conventions of `create-ubuntu-cloud-template.sh`.

## Decisions

| Question | Decision |
|---|---|
| Output | Both: a running container, or a template with `--template` |
| Distros | Ubuntu and Debian "standard" templates from `pveam` |
| Structure | Single self-contained file plus `profile.conf.example` |
| Optional features | Profile toggles, all off by default |
| App installs (e.g. OliveTin) | Hook scripts, not built in |
| Secrets | Profile only (git-ignored `*.conf`); none in the script |

## Structure

The host part creates the container with `pct create` and starts it. Every
`guest_*` function in the script is then copied, with the settings it needs
(`declare -p` / `declare -f`), into one generated script. That script is
pushed into the container with `pct push` and run with `pct exec` in three
modes: `provision`, `finish` (container) or `seal` (template).

Nothing is fetched from the repo at run time. `--print-guest-script` prints
the generated script without creating anything.

Helpers shared with the VM script (output, prompts, ID handling, overwrite
safety) are copied, not sourced, so each script stays a standalone file.

## Interface

Same shape as the VM script: interactive prompts, `--config`, `--unattended`,
`--name`, `--ctid` / `--auto-ctid` (`--vmid` aliases), `--template` /
`--no-template`, `--force-overwrite` (templates only) with
`--i-know-what-i-am-doing`. Added: `--keep-on-failure`,
`--print-guest-script`.

As in the VM script, the answers can be saved as a profile at the summary,
before any work starts. Every setting is written, including optional
features carried over from a loaded profile, except `POSTFIX_PASS` and the
container ID. The hostname is saved only if it was chosen by hand.

## Build steps

1. Checks: Proxmox host, feature values, OS choice, storage, ID, network,
   time zone, free space (warning only). Nothing is changed before the summary.
2. `pveam download` (checksum verified by Proxmox; skipped if cached).
3. `pct create`: unprivileged, `nesting=1`, optional `keyctl=1`, DHCP or
   static IP, VLAN, tags, time zone, description, optional root SSH key.
4. Fix `/` owned by `nobody` (some Debian templates) from the host with
   `pct mount`, before the first start.
5. `UPLOAD_FILES`, then `provision`: wait for network, apt retries, disable
   `systemd-networkd-wait-online`, optional upgrade, packages, locale, the
   optional features, in a fixed order (zsh before users so `/etc/skel` is
   ready).
6. `PROVISION_SCRIPTS`.
7. `finish`: apt cleanup, container left running, IP printed. Or `seal`:
   also remove SSH host keys, empty `machine-id`, clear logs and caches, shut
   down, `pct template`.

## Optional features

`ROOT_SSH_KEY`, `ANSIBLE_USER`, `ADMIN_USER` (key-only, locked passwords,
passwordless sudo), `ZSH_DOTFILES`, `POSTFIX_RELAY`, `UNATTENDED_UPGRADES`
(`51unattended-upgrades` adds to the distro defaults), `REMOVE_SNAPD`,
`DISABLE_IPV6`, `PIP_BREAK_SYSTEM_PACKAGES`, `SUDO_COREDUMP_FIX`, `KEYCTL`.

## Clones

`pct clone` does not regenerate SSH host keys. `ct-identity.service`
(installed in every container) runs at boot: it creates host keys if there
are none and rewrites the Postfix sender maps for the current hostname.

## Changes from the old notes

- `mlocate` becomes `plocate`; `resolvconf` is dropped (Proxmox manages
  `resolv.conf` in containers).
- No user password; SSH keys only.
- `/etc/pip.conf` instead of deleting `EXTERNALLY-MANAGED`.
- Postfix: port 587, TLS required, system CA bundle.
- VM-only steps dropped: qemu-guest-agent, cloud-init, GRUB, zswap, tuned,
  fstrim.

## From community-scripts

Adopted: host/guest split, `pveam` lookup with storage checked by content
type, `nesting=1` default, network wait, Debian `/` ownership fix (done from
the host, where it works for unprivileged containers),
`networkd-wait-online` fix, forced `confold` upgrades, time zone validation.

Not adopted: whiptail menus, telemetry, code fetched from `main` at run
time, root console auto-login, apt mirror switching, MOTD banner, GPU /
proxy / host-CA passthrough.

## Failure handling

A trap removes the half-built container (unless `--keep-on-failure`) and the
host temp directory, which lives in `/run` so the generated script and any
mail password never reach disk. The copy inside the container is deleted at
the end of the build and on failure.

## Verification

- `bash -n` and `shellcheck` on the script.
- The generated guest script run end to end (`provision` then `seal`) in
  `debian:13` and `ubuntu:24.04` Docker containers with every feature on.
- Not verified here: the host side (`pct`, `pveam`, `pvesm`), which needs a
  Proxmox VE node.
