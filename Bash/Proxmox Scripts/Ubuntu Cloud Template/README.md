# Ubuntu Cloud Template

Scripts for building Ubuntu cloud-init VM templates on a Proxmox host.

## Quick start

Run as root on the Proxmox host. It needs `git` and internet access (the Ubuntu
cloud image and a few scripts are downloaded on each build).

1. Get the scripts:

   ```bash
   git clone --depth 1 https://github.com/modem7/public_scripts.git
   cd "public_scripts/Bash/Proxmox Scripts/Ubuntu Cloud Template"
   ```

2. Create your config. This makes `~/.config/ubuntu-templates/` (outside the
   clone, so a `git pull` or a stray `git add` can never touch your secrets)
   with `shared.conf` and a profile per template, all readable by you only:

   ```bash
   ./build-templates.sh --init
   ```

3. Edit `~/.config/ubuntu-templates/shared.conf`. At least:
   - `ANSIBLE_SSH_PUBKEY`: the public key for the `ansible` user.
   - `MAIL_DOMAIN` and the mail settings. `MAIL_RELAY` is `gmail`, `custom`
     (your own SMTP server) or `none` (no mail leaves the VM). See
     [Mail on clones](#mail-on-clones).
   - Go through the rest of the file too: set or blank `CI_SSH_KEY`,
     `DOTFILES_RAW` and `WAKATIME_CFG` (they hold example values), and adjust
     the VM sizes in `profiles/*.conf` if you like.

   The builder refuses to run while the Ansible key, the mail domain or the
   mail addresses are still the examples.

4. Build a template and check it:

   ```bash
   ./build-templates.sh extras --verify --send-test-mail you@example.com
   ```

   This builds the `extras` template, then clones it, boots the clone, runs the
   checks inside it, prints the result and removes the clone. The test mail is
   optional and not sent with `MAIL_RELAY=none`. Use `base`, `desktop` or `all`
   instead of `extras`, and add `--keep` to leave the clone for a look around.

5. Clone the template in Proxmox as usual, set the user, password and SSH key
   on the Cloud-Init tab, and start it.

To update, run `git pull` in the clone, then `./build-templates.sh --init`
to add any new settings to your config (appended, commented out), and build
again. `./build-templates.sh --help` lists every option and setting.

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

`./build-templates.sh --init` makes a config folder outside the git clone,
so your secrets can't be committed by mistake and a `git pull` never
touches them. The folder is `CONFIG_DIR`, default
`~/.config/ubuntu-templates` (`/root/.config/ubuntu-templates` for root, or
under `XDG_CONFIG_HOME` if set). `--init` copies `shared.conf.example` to
`shared.conf` and each `profiles/*.conf.example` to `profiles/*.conf` in it.
Folders are mode 700, files 600. A file that already exists is kept, never
overwritten, so it is safe to run again. The only change it makes to one is
to append settings that are new in the `.example` file (missing from yours,
even as a comment), commented out under a dated heading, for you to enable
if you need them. A setting whose value spans several lines (such as
`WAKATIME_CFG`) is not appended; `--init` names it so you can copy it over
by hand. It needs no root, but the builder
runs as root and reads root's folder, so run it as root (or set
`CONFIG_DIR`).

The old layout still works: `shared.conf` and `profiles/*.conf` next to the
script, where they are git-ignored (`*.conf`). Only the `.example` copies
are committed.

Two kinds of file:

- `profiles/<template>.conf`: the VM side of one template. Name, tags,
  packages, snapd, IPv6, tuned, unattended upgrades and, for the desktop,
  GNOME, RDP, RAM and disk size. It is a plain profile for
  `create-ubuntu-cloud-template.sh --config` (see `profile.conf.example`).
  No secrets.
- `shared.conf`: the opinionated side, the same for every template. Ansible
  key, mail relay, unattended upgrades mail, dotfiles, WakaTime, login
  shell, needrestart, Pro adverts and the journald cap. Also a block of host
  defaults (`DISTRO_VER`, `DISK_STOR`, `NET_BRIDGE`, `VLAN`, `CI_USER`,
  `CI_SSH_KEY`, `CI_PASSWORD`) used by every template unless its profile sets them.
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
`shared.conf` next to the script, then the old `build-templates.conf` next
to the script with a warning, then `CONFIG_DIR/shared.conf`. The first one
found is used, and the build says which. Profiles are read from
`PROFILES_DIR`, default the `profiles/` folder next to that `shared.conf`.
Each template you build needs its profile. With none found, the builder
lists where it looked and points at `--init`.

## Usage

Run as root on the Proxmox host.

```bash
./build-templates.sh --init
nano /root/.config/ubuntu-templates/shared.conf
./build-templates.sh extras --verify
```

Other forms:

```bash
./build-templates.sh --init
./build-templates.sh base|extras|desktop|all
./build-templates.sh --generate-only
./build-templates.sh extras -- --unattended --vmid 52000 --auto-vmid --template
./build-templates.sh all --verify --send-test-mail you@example.com
./build-templates.sh --help
```

`--verify` runs `verify-clone.sh` on each template right after it is built
(see below). `--send-test-mail <address>` and `--keep` are passed on to it
and only work with `--verify`. All three may go anywhere before `--`,
mixed in with create-script args. Any other argument after the target is
passed, in order, to the create script. Everything after `--` is passed on
as it is, even `--verify`, `--keep` or `--send-test-mail`.

`--help` (also `-h` or `help`) prints the full help and works without root,
a config file or profiles. So does `--init`, which takes no other options.

`--generate-only` writes the profiles and payloads without building anything.
The default arguments passed to the generic script are
`--unattended --vmid 52000 --auto-vmid --template`.

`shared.conf` holds the mail password and SSH keys. Keep it mode 600 and
never commit it. The builder refuses the placeholder `ANSIBLE_SSH_PUBKEY`
from the example.

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
| `custom` | Your own relay: `MAIL_RELAY_HOST` and `MAIL_RELAY_PORT`. Port 587 uses STARTTLS (required), 465 uses TLS from the start, anything else (such as 25) requires TLS when there is a login and uses it if offered otherwise. A blank `MAIL_RELAY_USER` means no login, for an internal relay. |
| `none` | No relay. Mail stays on the clone, and anything addressed outside it bounces. |

Other settings: `MAIL_ROOT_TO` (where root's mail goes; defaults to
`MAIL_RELAY_USER` when that is an address), `MAIL_SENDER` (optional: rewrite
every sender to this address, which some relays require) and `MAIL_DOMAIN`.
Only the `gmail` relay has been tested; `custom` and `none` are checked by
reading the generated config, not by sending mail. The builder refuses the
placeholder values from `shared.conf.example`.

`GMAIL_USER` and `GMAIL_APP_PASSWORD` still work as the old names for
`MAIL_RELAY_USER` and `MAIL_RELAY_PASSWORD`, with a warning.

- The brackets stop MX lookups.
- IPv4 only, TLS (required on 587, 465 or with a login), and queued mail
  expires after one day, so a failure defers and drops instead of looping.
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
  seconds for Postfix to log `status=sent` for that address. With
  `MAIL_RELAY=none` it does not wait (mail stays on the clone).
- `--config <path>`: the `shared.conf` to read (see below).
- `--vmid <id>`: VMID for the clone. Default: the next free one. A VMID that
  already exists is refused.
- `--full [--storage <name>]`: full clone. Default is a linked clone, which
  needs storage that supports it.
- `--keep`: leave the clone running instead of destroying it.
- `--timeout <secs>` and `--verify-timeout <secs>`: waits for the agent and
  cloud-init (default 300), and for the verify run (default 600).

What to expect comes from `shared.conf`, found as `build-templates.sh` finds
it: `--config`, then `SHARED_CONF`, then `BUILD_CONF`, then `shared.conf` next
to the script. A file named by one of the first three must exist. The file is
read in a subshell, and only non-secret settings go to the guest, as
`VERIFY_*` variables: the mail relay, host, port and login name, `MAIL_ROOT_TO`,
`MAIL_SENDER`, `MAIL_DOMAIN`, `UU_MAIL`, the ansible key, `LOGIN_SHELL`,
`NEEDRESTART_MODE` and the journal cap. The relay password and the other
secrets are never read out or sent. With no `shared.conf` found, it says so and
`verify-template.sh` uses its built-in defaults.

The template needs `qemu-guest-agent` installed and the VM option `agent=1`.
The clone is destroyed on success, failure and Ctrl-C. Only a VM this run
created is ever stopped or destroyed. Exit codes: 0 passed, 1 a FAIL or a
clone/start error, 2 usage error, 3 agent timeout, 4 cloud-init error, 5 guest
command timeout.

`./build-templates.sh <target> --verify` does this for each template it
builds, with `--profile <target>` and `--config` set to the `shared.conf` it
used. It takes a few minutes per template. The new template's VMID is the one
VMID in `qm list` after the build that was not there before. If there is not
exactly one, that template is not verified and counts as a failure. A failed
verify does not stop the other targets. A summary is printed at the end, and
the exit code is 1 if any verify failed. A failed build still stops the run
with the create script's exit code. With `--keep`, each verify clone is left
running and the summary lists its VMID; remove each one by hand with
`qm destroy <id> --purge`. `verify-clone.sh` and `verify-template.sh`
must be next to `build-templates.sh` (or set `VERIFY_CLONE`); this is checked
before anything is built.

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

Run by hand, `verify-template.sh` uses the values at its top (mail relay,
domain, relay login, SSH key, time zone and so on). Edit them to match your
`shared.conf` and profiles, or use `verify-clone.sh`, which passes them from
`shared.conf`. Settings left blank in `shared.conf` (no relay login, no
`UU_MAIL`, no `LOGIN_SHELL` and so on) are shown as `SKIP` or checked as off.

## Manual steps

On the first clone of each template:

- Check the test mail arrived, and `journalctl -u postfix` shows
  `status=sent`.
- Desktop only: log in on the console once, log out, then RDP in with the login
  from `/root/rdp-credentials.txt`.
