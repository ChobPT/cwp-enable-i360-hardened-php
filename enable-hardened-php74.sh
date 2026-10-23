#!/bin/bash
# Move a CWP account's PHP 7.4 pool from CWP's own php-fpm74 build to the
# TuxCare/Imunify Hardened PHP (alt-php74-fpm). The pool keeps the same socket
# path, so Apache vhosts (and CWP vhost rebuilds) need no changes.
#
# Usage: enable-hardened-php74.sh [user] [url-to-check]
#   enable-hardened-php74.sh spq https://www.spq.pt/
#
# Undo with revert-hardened-php74.sh [user]
set -euo pipefail

U=${1:-spq}
CHECK_URL=${2:-}
[ "$U" = spq ] && [ -z "$CHECK_URL" ] && CHECK_URL=https://www.spq.pt/

CWP=/opt/alt/php-fpm74/usr
ALT=/opt/alt/php74
CWP_POOL=$CWP/etc/php-fpm.d/users/$U.conf
ALT_POOL=$ALT/etc/php-fpm.d/$U.conf
SOCK=$CWP/var/sockets/$U.sock
BK=/root/hardened-php74-backup
UBK=$BK/$U

# Extensions loaded by CWP's php-fpm74 build that are modules in alt-php74
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

rollback() {
    echo "!! Cutover failed, restoring CWP php-fpm74 pool for $U" >&2
    rm -f "$ALT_POOL"
    systemctl reload alt-php74-fpm 2>/dev/null || true
    wait_socket down || true
    [ -z "$(listener_pid)" ] && rm -f "$SOCK"
    cp -a "$UBK/cwp-pool.conf" "$CWP_POOL"
    systemctl reload php-fpm74
    wait_socket up && echo "!! Rolled back: $U is on CWP php-fpm74 again" >&2
    exit 1
}

# --- Pre-flight -------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root"
id "$U" >/dev/null 2>&1 || die "user $U does not exist"
[ -x $ALT/usr/sbin/php-fpm ] || die "alt-php74-php-fpm is not installed"
[ -f "$ALT_POOL" ] && die "$ALT_POOL already exists ($U already switched?)"
[ -f "$CWP_POOL" ] || die "CWP pool $CWP_POOL not found"
mkdir -p "$UBK"

# --- 1. Global alt-php74 configuration (idempotent) -------------------------
if [ ! -d $BK/php.d.orig ]; then
    cp -a $ALT/etc/php.d $BK/php.d.orig
    log "Backed up $ALT/etc/php.d to $BK/php.d.orig"
fi
cd $ALT/etc/php.d
[ -L mysqli.ini ] && rm -f mysqli.ini   # non-mysqlnd mysqli, replaced by nd_mysqli
for e in $EXTENSIONS; do
    [ -f ../php.d.all/$e.ini ] || die "missing $ALT/etc/php.d.all/$e.ini"
    ln -sfn ../php.d.all/$e.ini $e.ini
done
cat > zz-cwp-compat.ini <<'EOF'
; Match CWP php-fpm74 php.ini defaults (written by enable-hardened-php74.sh)
enable_dl = Off
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
display_errors = Off
expose_php = Off
memory_limit = 128M
max_execution_time = 30
max_input_time = 60
cgi.fix_pathinfo = 1
default_charset = "UTF-8"
date.timezone = Europe/Lisbon
mail.add_x_header = On
mail.log = /usr/local/apache/logs/phpmail.log
EOF
cd - >/dev/null

# Default [www] pool runs as nobody and isn't needed
if [ -f $ALT/etc/php-fpm.d/www.conf ]; then
    mv $ALT/etc/php-fpm.d/www.conf $BK/alt-www.conf
    log "Disabled default alt-php74 [www] pool (saved to $BK/alt-www.conf)"
fi

modules() { "$1" -m 2>/dev/null | grep -vE '^\[|^$|^the ionCube' | tr 'A-Z' 'a-z' | sort -u; }
MISSING=$(comm -23 <(modules $CWP/bin/php) <(modules $ALT/usr/bin/php) | grep -vx snuffleupagus || true)
[ -z "$MISSING" ] || die "extensions missing in hardened PHP: $(echo $MISSING)"
log "Extensions OK (hardened PHP has everything CWP's build loads)"

# --- 2. Pool definition (copy of CWP's pool, same socket) -------------------
cp -a "$CWP_POOL" "$UBK/cwp-pool.conf"
install -d -o "$U" -g "$U" -m 700 "/home/$U/tmp" 2>/dev/null || true
{
    grep -v 'session.save_path' "$CWP_POOL"
    echo "php_admin_value[session.save_path] = /home/$U/tmp"
} > "$ALT_POOL"
if ! TEST=$($ALT/usr/sbin/php-fpm -t -y $ALT/etc/php-fpm.conf 2>&1); then
    rm -f "$ALT_POOL"
    die "alt-php74-fpm config test failed: $TEST"
fi
log "Config test: $(echo "$TEST" | tail -1)"

# --- 3. Cutover ---------------------------------------------------------------
log "Cutover: removing $U pool from CWP php-fpm74"
trap rollback ERR
rm -f "$CWP_POOL"
systemctl reload php-fpm74
wait_socket down || { echo "socket still held by CWP php-fpm74" >&2; false; }
rm -f "$SOCK"

log "Starting $U pool on alt-php74-fpm"
if systemctl is-active -q alt-php74-fpm; then
    systemctl reload alt-php74-fpm
else
    systemctl enable -q --now alt-php74-fpm
fi
wait_socket up || { echo "alt-php74-fpm did not open $SOCK" >&2; false; }

PID=$(listener_pid)
EXE=$(readlink /proc/"$PID"/exe)
[ "$EXE" = "$ALT/usr/sbin/php-fpm" ] || { echo "socket served by $EXE" >&2; false; }
log "Socket $SOCK is served by $EXE (pid $PID)"

if [ -n "$CHECK_URL" ]; then
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$CHECK_URL" || echo 000)
    log "HTTP check $CHECK_URL -> $CODE"
    [ "$CODE" -ge 200 ] && [ "$CODE" -lt 500 ] || { echo "HTTP check failed" >&2; false; }
    WEXE=$(for p in $(pgrep -f "php-fpm: pool $U\$"); do readlink /proc/$p/exe; done | sort -u)
    log "Worker binary: ${WEXE:-none spawned}"
fi
trap - ERR

# --- 4. Cron jobs: CWP CLI 7.4 -> hardened CLI 7.4 ---------------------------
if crontab -l -u "$U" > "$UBK/crontab.orig" 2>/dev/null; then
    if grep -q '/usr/local/bin/php[[:space:]]' "$UBK/crontab.orig"; then
        sed 's#/usr/local/bin/php\([[:space:]]\)#/opt/alt/php74/usr/bin/php\1#g' "$UBK/crontab.orig" | crontab -u "$U" -
        touch "$UBK/crontab-modified"
        log "Crontab of $U now uses /opt/alt/php74/usr/bin/php (original in $UBK/crontab.orig)"
    fi
else
    rm -f "$UBK/crontab.orig"
fi

date '+%F %T' > "$UBK/enabled-at"
log "Done. $U now runs on Hardened PHP 7.4. Watch /var/log/alt-php74-error.log"
log "NOTE: if CWP recreates $CWP_POOL (panel PHP-FPM changes), both pools will fight for the socket."
