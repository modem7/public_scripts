# Ubuntu Cloud Template

Scripts for building Ubuntu cloud-init VM templates on a Proxmox host.

## Files

- `create-ubuntu-cloud-template.sh`: the generic builder. Downloads an Ubuntu
  cloud image, customises it and turns it into a Proxmox template. Driven by a
  profile (`--config`). See `profile.conf.example` for every option.
- `profile.conf.example`: example profile for the script above.
- `build-templates.sh`: a wrapper around the generic script that builds three
  ready-made templates (base, extras, desktop) with Postfix, an Ansible user,
  unattended upgrades, a journald cap and dotfiles. It generates the profiles
  and payload scripts, then calls `create-ubuntu-cloud-template.sh`.
- `build-templates.conf.example`: settings for `build-templates.sh`.
- `verify-template.sh`: run inside a clone to check everything was applied.

## Templates built by `build-templates.sh`

- `base`: server.
- `extras`: server plus admin tools.
- `desktop`: GNOME plus RDP.

## Usage

Run as root on the Proxmox host.

```bash
cp build-templates.conf.example build-templates.conf
chmod 600 build-templates.conf
nano build-templates.conf
./build-templates.sh extras
```

Other forms:

```bash
./build-templates.sh base|extras|desktop|all
./build-templates.sh --generate-only
./build-templates.sh extras -- --unattended --vmid 52000 --auto-vmid --template
./build-templates.sh --help
```

`--help` (also `-h` or `help`) prints the full help and works without root
or a config file.

`--generate-only` writes the profiles and payloads without building anything.
The default arguments passed to the generic script are
`--unattended --vmid 52000 --auto-vmid --template`.

`build-templates.conf` holds the Gmail app password and SSH keys. It is
git-ignored (`*.conf`). Never commit it.

The wrapper downloads the latest `create-ubuntu-cloud-template.sh` from this
repo on every run (falling back to the existing copy).

## Mail on clones

Each clone relays mail through `[smtp.gmail.com]:587` using the Gmail app
password from the config.

- The brackets stop MX lookups.
- IPv4 only, TLS required, and queued mail expires after one day, so a failure
  defers and drops instead of looping.
- A per-boot script sets `/etc/mailname` and `myhostname` from the clone's own
  hostname plus `MAIL_DOMAIN`, so clones never keep the template's name.
- Mail is sent as the natural `user@hostname.domain`. There is no sender or
  `From:` rewrite.
- `root` mail is aliased to `GMAIL_USER`.
- `/etc/crontab` sets `MAILTO=""`. Users' own crontabs are not changed, so add
  `MAILTO=""` to those if you do not want cron mail.

## Verifying a clone

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
time zone and so on) at the top. Edit them to match your
`build-templates.conf`.

## Manual steps

On the first clone of each template:

- Check the test mail arrived, and `journalctl -u postfix` shows
  `status=sent`.
- Desktop only: log in on the console once, log out, then RDP in with the login
  from `/root/rdp-credentials.txt`.
