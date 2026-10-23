#!/bin/bash
# Undo enable-hardened-php74.sh: put the account's pool back on CWP's php-fpm74.
#
# Usage: revert-hardened-php74.sh [user] [--all]
#   --all  also undo the global alt-php74 changes (extension links, compat ini,
#          default [www] pool) and, if no other account pools remain, stop and
#          disable alt-php74-fpm
set -euo pipefail

U=username
ALL=0
for a in "$@"; do
    case "$a" in
        --all) ALL=1 ;;
        *) U=$a ;;
    esac
done

CWP=/opt/alt/php-fpm74/usr
ALT=/opt/alt/php74
CWP_POOL=$CWP/etc/php-fpm.d/users/$U.conf
ALT_POOL=$ALT/etc/php-fpm.d/$U.conf
SOCK=$CWP/var/sockets/$U.sock
BK=/root/hardened-php74-backup
UBK=$BK/$U

# Must match enable-hardened-php74.sh
EXTENSIONS="nd_mysqli nd_pdo_mysql pdo_sqlite apcu bcmath dom fileinfo gd imagick imap intl
ioncube_loader json mbstring mcrypt opcache phar posix pspell soap sockets sodium ssh2
sysvmsg sysvsem sysvshm tidy xmlreader xmlrpc xmlwriter xsl zip"

log() { echo "[$(date +%T)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

listener_pid() {
    ss -xlp 2>/dev/null | grep -F " $SOCK " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

wait_socket() { # wait_socket up|down
    for _ in $(seq 1 20); do
        if [ "$1" = up ]; then [ -n "$(listener_pid)" ] && return 0
        else [ -z "$(listener_pid)" ] && return 0; fi
        sleep 0.5
    done
    return 1
}

other_alt_pools() {
    find $ALT/etc/php-fpm.d -maxdepth 1 -name '*.conf' ! -name www.conf 2>/dev/null
}

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$UBK/cwp-pool.conf" ] || [ -f "$CWP_POOL" ] || die "no CWP pool backup in $UBK and no $CWP_POOL"

# --- 1. Pool back to CWP php-fpm74 -------------------------------------------
if [ -f "$ALT_POOL" ]; then
    mv "$ALT_POOL" "$UBK/alt-pool.conf.reverted"
    log "Removed $U pool from alt-php74-fpm"
    if systemctl is-active -q alt-php74-fpm; then
        if [ -n "$(other_alt_pools)" ] || [ -f $ALT/etc/php-fpm.d/www.conf ]; then
            systemctl reload alt-php74-fpm
        else
            systemctl stop alt-php74-fpm   # php-fpm refuses to run with no pools
        fi
    fi
    wait_socket down || die "$SOCK still held by alt-php74-fpm"
    [ -S "$SOCK" ] && unlink "$SOCK"
fi

if [ ! -f "$CWP_POOL" ]; then
    cp -a "$UBK/cwp-pool.conf" "$CWP_POOL"
    log "Restored $CWP_POOL"
fi
systemctl reload php-fpm74
wait_socket up || die "CWP php-fpm74 did not open $SOCK - check: systemctl status php-fpm74"
log "Socket $SOCK is served by $(readlink /proc/"$(listener_pid)"/exe)"

# --- 2. Crontab ----------------------------------------------------------------
# Only undo our own path change, so later crontab edits are kept
if [ -f "$UBK/crontab-modified" ]; then
    crontab -l -u "$U" \
        | sed 's#/opt/alt/php74/usr/bin/php\([[:space:]]\)#/usr/local/bin/php\1#g' \
        | crontab -u "$U" -
    mv "$UBK/crontab-modified" "$UBK/crontab-modified.reverted"
    log "Crontab of $U back on /usr/local/bin/php (pre-enable copy: $UBK/crontab.orig)"
fi
[ -f "$UBK/enabled-at" ] && mv "$UBK/enabled-at" "$UBK/reverted-from-enabled-at"

# --- 3. Optional: global alt-php74 configuration -----------------------------
if [ "$ALL" = 1 ]; then
    if [ -n "$(other_alt_pools)" ]; then
        log "Other account pools still use alt-php74-fpm, global config left as is:"
        other_alt_pools
    else
        cd $ALT/etc/php.d
        for e in $EXTENSIONS; do
            # only remove links this script set up, and only if not in the original set
            [ -L $e.ini ] && [ ! -e $BK/php.d.orig/$e.ini ] && unlink $e.ini
        done
        [ -f zz-cwp-compat.ini ] && mv zz-cwp-compat.ini $BK/zz-cwp-compat.ini.reverted
        [ -L $BK/php.d.orig/mysqli.ini ] && [ ! -e mysqli.ini ] && ln -s "$(readlink $BK/php.d.orig/mysqli.ini)" mysqli.ini
        cd - >/dev/null
        log "Restored original extension set in $ALT/etc/php.d"

        if [ -f $BK/alt-www.conf ] && [ ! -f $ALT/etc/php-fpm.d/www.conf ]; then
            cp -a $BK/alt-www.conf $ALT/etc/php-fpm.d/www.conf
            log "Restored default [www] pool"
        fi
        systemctl disable -q --now alt-php74-fpm
        log "alt-php74-fpm stopped and disabled (as before)"
    fi
fi

log "Done. $U is back on CWP php-fpm74."
