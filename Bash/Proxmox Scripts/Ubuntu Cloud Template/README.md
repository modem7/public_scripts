# Ubuntu Cloud Template

Scripts for building Ubuntu cloud-init VM templates on a Proxmox host.

## Files

- `create-ubuntu-cloud-template.sh`: the generic builder. Downloads an Ubuntu
  cloud image, customises it and turns it into a Proxmox template. Driven by a
  profile (`--config`). See `profile.conf.example` for every option.
- `profile.conf.example`: example profile for the script above.
- `build-templates.sh`: a wrapper around the generic script that builds three
  ready-made templates (base, extras, desktop) with Postfix, an Ansible user,
  unattended upgrades, a journald cap and dotfiles. It assembles the profiles
  and writes the payload scripts, then calls `create-ubuntu-cloud-template.sh`.
- `shared.conf.example`: settings shared by every template built by
  `build-templates.sh` (mail, Ansible, dotfiles, tweaks, host defaults).
- `profiles/*.conf.example`: one VM profile per template.
- `verify-template.sh`: run inside a clone to check everything was applied.
- `verify-clone.sh`: run on the Proxmox host. Clones a template, boots the
  clone, runs `verify-template.sh` inside it and removes the clone.

## Templates built by `build-templates.sh`

- `base`: server.
- `extras`: server plus admin tools.
- `desktop`: GNOME plus RDP.

## Config for `build-templates.sh`

Two kinds of file, both git-ignored (`*.conf`). Only the `.example` copies
are committed.

- `profiles/<template>.conf`: the VM side of one template. Name, tags,
  packages, snapd, IPv6, tuned, unattended upgrades and, for the desktop,
  GNOME, RDP, RAM and disk size. It is a plain profile for
  `create-ubuntu-cloud-template.sh --config` (see `profile.conf.example`).
  No secrets.
- `shared.conf`: the opinionated side, the same for every template. Ansible
  key, mail relay, unattended upgrades mail, dotfiles, WakaTime, login
  shell, needrestart, Pro adverts and the journald cap. Also a block of host
  defaults (`DISTRO_VER`, `DISK_STOR`, `NET_BRIDGE`, `VLAN`, `CI_SSH_KEY`,
  `CLOUD_PASSWORD`) used by every template unless its profile sets them.
  It holds secrets.

`OUT_DIR` is the generated output (profiles and payloads, root-only). It
defaults to `template-build/` next to the script, which is git-ignored. Set
`OUT_DIR` in `shared.conf` or the environment to put it elsewhere. Before
this default it was `/root/template-build`.

Each generated `OUT_DIR/<template>.conf` is, in order:

1. The host defaults from `shared.conf` (`CI_SSH_KEY` becomes `SSH_KEY`).
2. `profiles/<template>.conf` as it is, so it can override step 1. To
   override the SSH key in a profile, set `SSH_KEY`.
3. The payloads, appended with `+=` (`UPLOAD_FILES`, `CUSTOMIZE_SCRIPTS`,
   `FIRSTBOOT_SCRIPTS`, `EXTRA_VC_ARGS`), plus any of `libsasl2-modules`,
   `unattended-upgrades` and `zsh` missing from `EXTRA_VIRT_PKGS`. The
   payloads need those, so editing a profile can't break them.

`shared.conf` is found by `SHARED_CONF`, then `BUILD_CONF` (old name), then
`shared.conf` next to the script, then the old `build-templates.conf` with a
warning. Profiles are read from `PROFILES_DIR` (default `profiles/` next to
the script). Each template you build needs its profile.

## Usage

Run as root on the Proxmox host.

```bash
cp shared.conf.example shared.conf
chmod 600 shared.conf
nano shared.conf
for t in base extras desktop; do cp "profiles/$t.conf.example" "profiles/$t.conf"; done
nano profiles/extras.conf
./build-templates.sh extras
```

Other forms:

```bash
./build-templates.sh base|extras|desktop|all
./build-templates.sh --generate-only
./build-templates.sh extras -- --unattended --vmid 52000 --auto-vmid --template
./build-templates.sh --help
```

`--help` (also `-h` or `help`) prints the full help and works without root,
a config file or profiles.

`--generate-only` writes the profiles and payloads without building anything.
The default arguments passed to the generic script are
`--unattended --vmid 52000 --auto-vmid --template`.

`shared.conf` holds the mail password and SSH keys. It is git-ignored
(`*.conf`). Never commit it.

### Moving from `build-templates.conf`

1. Rename `build-templates.conf` to `shared.conf`. Until you do, it is still
   read, with a warning.
2. Copy the three `profiles/*.conf.example` files to `profiles/*.conf`. They
   hold what the script used to hard-code.
3. `PKGS_*` and `TAG_BASE` are no longer read. If you had changed them, put
   the packages in `EXTRA_VIRT_PKGS` and the tags in `TAG` in the profiles,
   then delete them from `shared.conf` (they are ignored with a warning).

The wrapper downloads the latest `create-ubuntu-cloud-template.sh` from this
repo on every run (falling back to the existing copy).

## Mail on clones

Each clone sends mail through the relay chosen by `MAIL_RELAY` in
`shared.conf`:

| `MAIL_RELAY` | What it does |
| --- | --- |
| `gmail` (default) | `[smtp.gmail.com]:587` with `MAIL_RELAY_USER` and a Gmail app password in `MAIL_RELAY_PASSWORD`. The only one tested. |
| `custom` | Your own relay: `MAIL_RELAY_HOST` and `MAIL_RELAY_PORT`. Port 587 uses STARTTLS (required), 465 uses TLS from the start, anything else (such as 25) uses TLS if offered. A blank `MAIL_RELAY_USER` means no login, for an internal relay. |
| `none` | No relay. Mail stays on the clone, and anything addressed outside it bounces. |

Other settings: `MAIL_ROOT_TO` (where root's mail goes; defaults to
`MAIL_RELAY_USER` when that is an address), `MAIL_SENDER` (optional: rewrite
every sender to this address, which some relays require) and `MAIL_DOMAIN`.
Only the `gmail` relay has been tested; `custom` and `none` are checked by
reading the generated config, not by sending mail. The builder refuses the
placeholder values from `shared.conf.example`.

`GMAIL_USER` and `GMAIL_APP_PASSWORD` still work as the old names for
`MAIL_RELAY_USER` and `MAIL_RELAY_PASSWORD`, with a warning.

`verify-template.sh` and `verify-clone.sh` still expect the Gmail relay, so
for `custom` or `none` expect FAILs in their mail section until they read
`shared.conf`.

- The brackets stop MX lookups.
- IPv4 only, TLS where the relay supports it, and queued mail expires after
  one day, so a failure defers and drops instead of looping.
- A per-boot script sets `/etc/mailname` and `myhostname` from the clone's own
  hostname plus `MAIL_DOMAIN`, so clones never keep the template's name.
- Mail is sent as the natural `user@hostname.domain`. There is no sender or
  `From:` rewrite unless `MAIL_SENDER` is set.
- `root` mail is aliased to `MAIL_ROOT_TO`.
- `/etc/crontab` sets `MAILTO=""`. Users' own crontabs are not changed, so add
  `MAILTO=""` to those if you do not want cron mail.

## Verifying a template from the host

`verify-clone.sh` does the whole check from the Proxmox host in one command. It
clones the template, starts the clone, waits for the guest agent and for
cloud-init, runs `verify-template.sh` inside the clone through the agent,
prints the output and returns its exit code, then destroys the clone.

```bash
./verify-clone.sh 9002
./verify-clone.sh 9002 --profile extras --send-test-mail you@example.com
./verify-clone.sh 9002 --keep
```

Options (see `--help` for all of them):

- `--profile` and `--send-test-mail <address>` are passed to
  `verify-template.sh`. With the mail option the script also waits up to 60
  seconds for Postfix to log `status=sent` for that address.
- `--vmid <id>`: VMID for the clone. Default: the next free one. A VMID that
  already exists is refused.
- `--full [--storage <name>]`: full clone. Default is a linked clone, which
  needs storage that supports it.
- `--keep`: leave the clone running instead of destroying it.
- `--timeout <secs>` and `--verify-timeout <secs>`: waits for the agent and
  cloud-init (default 300), and for the verify run (default 600).

The template needs `qemu-guest-agent` installed and the VM option `agent=1`.
The clone is destroyed on success, failure and Ctrl-C. Only a VM this run
created is ever stopped or destroyed. Exit codes: 0 passed, 1 a FAIL or a
clone/start error, 2 usage error, 3 agent timeout, 4 cloud-init error, 5 guest
command timeout.

## Verifying a clone by hand

After cloning a template and booting it, run inside the clone:

```bash
sudo ./verify-template.sh --send-test-mail you@example.com
```

Options:

- `--profile base|extras|desktop`: default is worked out from what is
  installed.
- `--send-test-mail <address>`: also sends a Postfix test email.

The exit code is 0 when there are no FAILs (warnings are fine).

`verify-template.sh` has the values it expects (domain, Gmail user, SSH key,
time zone and so on) at the top. Edit them to match your `shared.conf` and
profiles.

## Manual steps

On the first clone of each template:

- Check the test mail arrived, and `journalctl -u postfix` shows
  `status=sent`.
- Desktop only: log in on the console once, log out, then RDP in with the login
  from `/root/rdp-credentials.txt`.
