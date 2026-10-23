# hardened-php

Scripts to move a CWP account's PHP 7.3 / 7.4 sites from CWP's own PHP-FPM
builds to the **Hardened PHP** packages (Imunify360 / TuxCare Extended
Lifecycle Support), and to revert that change.

## Why

PHP 7.3 and 7.4 are end-of-life upstream. This server has two sets of builds
for them:

| | CWP builds (default) | Hardened PHP (TuxCare ELS) |
|---|---|---|
| Path | `/opt/alt/php-fpm73`, `/opt/alt/php-fpm74` | `/opt/alt/php73`, `/opt/alt/php74` |
| Service | `php-fpm73`, `php-fpm74` | `alt-php73-fpm`, `alt-php74-fpm` |
| Packaged | no (compiled by CWP, last built Sep 2025) | yes, `alt-php7x-*` RPMs (rebuilt Oct 2026) |
| Security fixes | none since upstream EOL | backported by TuxCare |

Hardened PHP was installed (`imunify360-agent features status hardened-php`)
but no site used it: every vhost points at the CWP builds.

These scripts should be a stop-gap until sites are migrated to a supported PHP
(8.3+). They do not replace that migration.

## Scope

- **Changes:** the web server PHP of **one account**: its 7.3 or 7.4 PHP-FPM
  pool. This covers **all of the account's domains and subdomains set to that
  version** in CWP, because they share one pool per version. Sites set to other
  versions are not touched.
- **Changes (7.4 only):** the account's cron jobs that call `/usr/local/bin/php`
  (CWP's 7.4 CLI) are pointed at `/opt/alt/php74/usr/bin/php`.
- **Does not change:** CWP's own PHP (`/usr/local/cwp/php71`, PHP 7.2.30),
  which runs the CWP panels, Roundcube webmail and phpMyAdmin.
- **Does not change:** Apache vhost files. The hardened pool takes over the
  same socket path (`/opt/alt/php-fpm7x/usr/var/sockets/<user>.sock`), so CWP
  vhost rebuilds keep working.

The 7.3 and 7.4 scripts are independent: separate services, config, sockets
and backups. They can be run and reverted in any order.

## Usage

Run as root.

```bash
# PHP 7.4 pool of an account (optional URL is checked after the switch)
./enable-hardened-php74.sh username https://www.username.pt/
./revert-hardened-php74.sh username

# PHP 7.3 pool of an account
./enable-hardened-php73.sh username https://example.como/
./revert-hardened-php73.sh username

# Also undo the global changes (only when no other account uses the hardened pool)
./revert-hardened-php74.sh username --all
```

The user defaults to `username`. The check URL defaults to `https://www.example.com/` (7.4)
or `https:/example.com/` (7.3) for `username`, and is skipped for others
unless given.

Expect a few seconds of interruption for that account's sites, and one logout
for logged-in users (session storage moves to `/home/<user>/tmp`).

## What `enable-hardened-php7x.sh` does

1. **Pre-flight:** root, user exists, hardened PHP-FPM package installed, user
   not already switched. *(7.3)* Installs `alt-php73-sodium` if missing.
2. **Global hardened PHP config** (shared by all accounts; idempotent):
   - backs up `/opt/alt/php7x/etc/php.d` to `/root/hardened-php7x-backup/php.d.orig` (first run only)
   - enables the same extensions CWP's build loads (symlinks from `php.d.all`;
     mysqlnd variants of mysqli/pdo_mysql)
   - writes `zz-cwp-compat.ini` with CWP's php.ini defaults (`enable_dl=Off`,
     `error_reporting`, limits, `mail.log`, timezone; `expose_php=Off`)
   - disables the default `[www]` pool (it runs as `nobody` and isn't needed)
   - **aborts** if any extension CWP's build loads is missing from the hardened one
3. **Pool:** copies the account's CWP pool file unchanged (same socket,
   `pm.*` limits, env), adds `session.save_path`, and runs `php-fpm -t`.
4. **Cutover:** removes the pool from CWP's `php-fpm7x` and reloads it, waits
   for the socket to close, then starts or reloads `alt-php7x-fpm`. It checks
   that the socket is served by `/opt/alt/php7x/usr/sbin/php-fpm` and, if a URL
   is given, that it answers with a code below 500.
   **If any cutover step fails, it rolls back to CWP's pool automatically.**
5. *(7.4 only)* **Cron:** rewrites `/usr/local/bin/php` to the hardened CLI
   in the account's crontab.

## What `revert-hardened-php7x.sh` does

1. Removes the account's hardened pool. It reloads `alt-php7x-fpm`, or stops it
   if no pools are left.
2. Restores the CWP pool file, reloads `php-fpm7x` and checks the socket is
   served again.
3. *(7.4 only)* Changes `/opt/alt/php74/usr/bin/php` back to `/usr/local/bin/php`
   in the crontab, only if the enable script made that change. Other crontab
   edits are kept.
4. With `--all`, and only if no other account pools remain on the hardened
   service: removes the extension links and the compat ini it added, restores
   the `[www]` pool, and stops and disables `alt-php7x-fpm`.

## Backups and state

```
/root/hardened-php7x-backup/
├── php.d.orig/          original hardened php.d (before first enable)
├── alt-www.conf         default [www] pool that was disabled
└── <user>/
    ├── cwp-pool.conf    the account's original CWP pool file
    ├── enabled-at       present = account currently switched
    ├── crontab.orig     (7.4) crontab before the change
    └── crontab-modified (7.4) marker: enable changed the crontab
```

## Verifying

```bash
# Which binary serves the account's socket (expect /opt/alt/php7x/usr/sbin/php-fpm)
S=/opt/alt/php-fpm74/usr/var/sockets/username.sock
readlink /proc/$(ss -xlp | grep -F " $S " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)/exe

# The CWP pool must be gone (otherwise both pools fight for the socket)
ls /opt/alt/php-fpm74/usr/etc/php-fpm.d/users/username.conf   # expect: No such file

systemctl status alt-php74-fpm
tail -f /var/log/alt-php74-error.log
crontab -l -u username | grep php
```

`X-Powered-By` shows `PHP/7.4.33` on both builds, so it can't tell them apart.

## Caveats

- **CWP can recreate its pool.** Changing the account's PHP-FPM settings in
  the CWP panel can put back `/opt/alt/php-fpm7x/usr/etc/php-fpm.d/users/<user>.conf`.
  Both pools then compete for the socket, and whichever starts second fails.
  After panel changes, check with the commands above. To fix, delete the
  recreated CWP file and reload `php-fpm7x`, or run the revert script.
- **No per-site choice.** All of the account's sites on that version switch
  together.

