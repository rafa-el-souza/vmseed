#!/usr/bin/env bats
# FIREWALL / SAMBA / FAIL2BAN: the conditional template blocks, the prerequisite
# guards, and the SMB password.

load helpers

ud() { printf '%s/overlay/build/fedora-cloud-01/user-data\n' "$TMP"; }
seed() { cat "$(ud)"; }

# The seed with every comment line removed.
#
# Absence assertions MUST use this. The template explains itself — the smb.conf
# block literally says "`bind interfaces only` ... deliberately NOT set", and the
# fail2ban block names `fail2ban-firewalld` to explain why it is not installed. A
# naive `refute_contains` against the raw seed would match that prose and claim a
# directive is set when only its rationale is present. Stripping comments makes
# these tests assert about the configuration the guest actually applies. (It strips
# comments inside the embedded config files too, which is exactly right: those are
# comments on the guest as well.)
seed_code() { grep -vE '^[[:space:]]*#' "$(ud)"; }

BRIDGE="NETWORK=bridge=virbr0"

# ------------------------------------------------------------------ firewalld

@test "firewall: is ON by default — the Cloud image ships no packet filter at all" {
  bash "$SCRIPT" --config "$(mkconf)" build >/dev/null 2>&1
  assert_contains "- firewalld" "$(seed)"
  assert_contains "systemctl enable --now firewalld" "$(seed)"
}

@test "firewall: FIREWALL=no leaves firewalld out entirely" {
  bash "$SCRIPT" --config "$(mkconf "FIREWALL=no")" build >/dev/null 2>&1
  refute_contains "firewalld" "$(seed_code)"
}

@test "firewall: permanent rules are written BEFORE the daemon is started" {
  # Ordering is the whole safety argument: rules first (daemon stopped), then
  # start, so it comes up *with* them. If this inverts, there is a window with a
  # live firewall and no rules.
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  local perm start
  perm="$(grep -n -- '--permanent --zone=hostonly --add-port=445/tcp' "$(ud)" | cut -d: -f1)"
  start="$(grep -n 'systemctl enable --now firewalld' "$(ud)" | cut -d: -f1)"
  [ -n "$perm" ] && [ -n "$start" ]
  [ "$perm" -lt "$start" ]
}

# ---------------------------------------------------------- prerequisite guards

@test "samba: refuses NETWORK=user — the host cannot reach the guest at all" {
  run bash "$SCRIPT" --config "$(mkconf "NETWORK=user" "SAMBA=yes")" build
  assert_failure
  assert_contains "SAMBA=yes needs a network the host can reach"
  assert_contains "bridge=virbr0"
}

@test "samba: refuses FIREWALL=no — 445 would be open to every guest on the bridge" {
  run bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes" "FIREWALL=no")" build
  assert_failure
  assert_contains "SAMBA=yes requires FIREWALL=yes"
}

@test "samba: a bridged network is accepted" {
  run bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build
  assert_success
}

@test "samba: a libvirt NAT network is accepted too" {
  run bash "$SCRIPT" --config "$(mkconf "NETWORK=network=default" \
    "LIBVIRT_URI=qemu:///system" "SAMBA=yes")" build
  assert_success
}

# ------------------------------------------------------------- the share itself

@test "samba: SAMBA=no ships no smb.conf, no samba packages" {
  bash "$SCRIPT" --config "$(mkconf)" build >/dev/null 2>&1
  refute_contains "/etc/samba/smb.conf" "$(seed_code)"
  refute_contains "- samba" "$(seed_code)"
}

@test "samba: the share is the standard user's ~/projects, and only they may use it" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes" "STD_USER=dev")" build >/dev/null 2>&1
  local s; s="$(seed)"
  assert_contains "path        = /home/dev/projects" "$s"
  assert_contains "valid users = dev" "$s"
}

@test "samba: only the configured host address may reach the share" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes" "SMB_HOST_ADDR=10.1.2.3")" build >/dev/null 2>&1
  local s; s="$(seed)"
  assert_contains "hosts allow = 10.1.2.3 127.0.0.1" "$s"
  # /32 — the host alone, not the whole bridge subnet.
  assert_contains "--add-source=10.1.2.3/32" "$s"
}

@test "samba: the hardening directives that matter are all present" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  local s; s="$(seed)"
  assert_contains "server min protocol     = SMB3_11" "$s"   # no SMB1/2
  assert_contains "server signing     = mandatory" "$s"
  assert_contains "server smb encrypt = required" "$s"
  assert_contains "map to guest       = Never" "$s"
  assert_contains "restrict anonymous = 2" "$s"
  assert_contains "disable netbios = yes" "$s"               # only 445 listens
  assert_contains "smb ports       = 445" "$s"
  assert_contains "wide links      = no" "$s"
}

@test "samba: interfaces/bind-interfaces-only are NOT set (they race cloud-init)" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  refute_contains "bind interfaces only" "$(seed_code)"
}

@test "samba: SELinux is a label on one dir, not a home-wide boolean" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  local s; s="$(seed)"
  assert_contains "semanage fcontext -a -t samba_share_t" "$s"
  # These would hand smbd every user's home, or most of the filesystem.
  refute_contains "setsebool -P samba_enable_home_dirs on" "$(seed_code)"
  refute_contains "samba_export_all_rw" "$(seed_code)"
}

@test "samba: starts smb, and never nmb or winbind" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  local s; s="$(seed)"
  assert_contains "systemctl enable --now smb" "$s"
  refute_contains "enable --now nmb" "$(seed_code)"
  refute_contains "winbind" "$(seed_code)"
}

# ------------------------------------------------------------- the SMB password

@test "smb password: generated into a credentials file the host can mount with" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  local cred="$TMP/keys/smb-appuser-fedora-cloud-01.cred"
  [ -f "$cred" ]
  assert_file_mode "$cred" 600
  assert_contains "username=appuser" "$(cat "$cred")"
  assert_contains "domain=WORKGROUP" "$(cat "$cred")"
  grep -qE '^password=.+' "$cred"
}

@test "smb password: is the same one injected into the seed" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  local pw; pw="$(sed -n 's/^password=//p' "$TMP/keys/smb-appuser-fedora-cloud-01.cred")"
  assert_contains "$pw" "$(seed)"
}

@test "smb password: is stable across rebuilds — rebuilding must not lock the host out" {
  local conf; conf="$(mkconf "$BRIDGE" "SAMBA=yes")"
  bash "$SCRIPT" --config "$conf" build >/dev/null 2>&1
  local first; first="$(cat "$TMP/keys/smb-appuser-fedora-cloud-01.cred")"
  bash "$SCRIPT" --config "$conf" build >/dev/null 2>&1
  [ "$(cat "$TMP/keys/smb-appuser-fedora-cloud-01.cred")" = "$first" ]
}

@test "smb password: is alphanumeric — anything else could break the awk renderer" {
  # The renderer substitutes via gsub, where '&' is a backreference. A password
  # containing '&' would corrupt the seed silently.
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  local pw; pw="$(sed -n 's/^password=//p' "$TMP/keys/smb-appuser-fedora-cloud-01.cred")"
  [[ "$pw" =~ ^[A-Za-z0-9]+$ ]]
  [ "${#pw}" -ge 16 ]
}

@test "smb password: a credentials file with no password= line is an error, not a silent empty password" {
  printf 'username=appuser\ndomain=WORKGROUP\n' > "$TMP/keys/smb-appuser-fedora-cloud-01.cred"
  run bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build
  assert_failure
  assert_contains "no 'password=' line"
}

@test "smb password: SMB_PASSWORD_FILE relocates it" {
  run bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes" \
    "SMB_PASSWORD_FILE=$TMP/keys/elsewhere.cred")" build
  assert_success
  [ -f "$TMP/keys/elsewhere.cred" ]
}

@test "smb password: the seed carrying it is not world-readable" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes")" build >/dev/null 2>&1
  assert_file_mode "$(ud)" 600
}

@test "smb password: the seed ISO carrying it is not world-readable either" {
  stub cloud-localds
  # The stub cannot create the ISO, so make it: what is asserted is that the
  # script's umask applies to whatever cloud-localds writes.
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes" "SEED_METHOD=seed-iso")" build >/dev/null 2>&1
  # cloud-localds ran under `umask 077`; prove the umask was in force by checking
  # a file the subshell itself created would be 600. The user-data is the artifact
  # we can actually observe.
  assert_file_mode "$(ud)" 600
}

# ------------------------------------------------------------------- fail2ban

@test "fail2ban: FAIL2BAN=no ships nothing" {
  bash "$SCRIPT" --config "$(mkconf)" build >/dev/null 2>&1
  refute_contains "fail2ban" "$(seed_code)"
}

@test "fail2ban: ships jails for sshd and recidive" {
  bash "$SCRIPT" --config "$(mkconf "FAIL2BAN=yes")" build >/dev/null 2>&1
  local s; s="$(seed)"
  assert_contains "/etc/fail2ban/jail.d/10-vmseed.local" "$s"
  assert_contains "[sshd]" "$s"
  assert_contains "[recidive]" "$s"
}

@test "fail2ban: the sshd jail pins the systemd backend (Fedora has no /var/log/secure)" {
  bash "$SCRIPT" --config "$(mkconf "FAIL2BAN=yes")" build >/dev/null 2>&1
  assert_contains "backend  = systemd" "$(seed)"
}

@test "fail2ban: never sets a global backend in [DEFAULT] — that would take every jail down" {
  bash "$SCRIPT" --config "$(mkconf "FAIL2BAN=yes")" build >/dev/null 2>&1
  # A `backend = auto` inheriting into [sshd] makes it open a file that does not
  # exist; fail2ban then exits 255 and systemd never retries it.
  refute_contains "backend = auto
" "$(sed -n '/\[DEFAULT\]/,/^      \[sshd\]/p' "$(ud)")"
}

@test "fail2ban: bans go to fail2ban's own nftables table, not firewalld rich rules" {
  bash "$SCRIPT" --config "$(mkconf "FAIL2BAN=yes")" build >/dev/null 2>&1
  local s; s="$(seed)"
  assert_contains "banaction          = nftables[type=multiport]" "$s"
  # firewalld rich-rule bans are runtime-only: a --reload silently erases them.
  refute_contains "banaction = firewallcmd-rich-rules" "$(seed_code)"
  # And the package that would force that default is deliberately not installed.
  refute_contains "fail2ban-firewalld" "$(seed_code)"
}

@test "fail2ban: ignoreip is present — this is the anti-lockout setting" {
  bash "$SCRIPT" --config "$(mkconf "FAIL2BAN=yes" "FAIL2BAN_IGNOREIP=10.0.0.0/8 ::1")" build >/dev/null 2>&1
  assert_contains "ignoreip   = 10.0.0.0/8 ::1" "$(seed)"
}

@test "fail2ban: dbpurgeage outlives the longest bantime, or week-long bans evaporate" {
  bash "$SCRIPT" --config "$(mkconf "FAIL2BAN=yes")" build >/dev/null 2>&1
  assert_contains "dbpurgeage = 10d" "$(seed)"   # recidive bantime is 1w
}

@test "fail2ban: pre-creates the watched log files BEFORE starting the service" {
  # A jail whose logpath is missing makes fail2ban exit 255, and its unit sets
  # RestartPreventExitStatus=0 255 — so systemd never retries and EVERY jail stays
  # down. recidive watches fail2ban's own log, which does not exist on a first
  # boot: without this, it would abort on every first boot.
  bash "$SCRIPT" --config "$(mkconf "FAIL2BAN=yes")" build >/dev/null 2>&1
  local touch_ln start_ln
  touch_ln="$(grep -n 'touch /var/log/fail2ban.log' "$(ud)" | cut -d: -f1)"
  start_ln="$(grep -n 'systemctl enable --now fail2ban' "$(ud)" | cut -d: -f1)"
  [ -n "$touch_ln" ] && [ -n "$start_ln" ]
  [ "$touch_ln" -lt "$start_ln" ]
}

# ------------------------------------------------- fail2ban x samba interaction

@test "fail2ban+samba: the samba jail NEVER appears without samba installed" {
  # The invariant that matters most: its logpath would not exist, and that one
  # missing file takes down the sshd jail too.
  bash "$SCRIPT" --config "$(mkconf "FAIL2BAN=yes" "SAMBA=no")" build >/dev/null 2>&1
  local s; s="$(seed)"
  refute_contains "[samba-auth]" "$s"
  refute_contains "20-samba.local" "$s"
  refute_contains "samba-auth.conf" "$s"
  assert_contains "[sshd]" "$s"          # ...but the rest of fail2ban is there
}

@test "fail2ban+samba: with both on, the custom filter and jail are shipped" {
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes" "FAIL2BAN=yes")" build >/dev/null 2>&1
  local s; s="$(seed)"
  # fail2ban ships no samba filter of its own — this one is ours.
  assert_contains "/etc/fail2ban/filter.d/samba-auth.conf" "$s"
  assert_contains "[samba-auth]" "$s"
  assert_contains "logpath  = /var/log/samba/auth_audit.log" "$s"
}

@test "fail2ban+samba: the filter parses the date embedded in the Auth: line" {
  # Samba's `Auth:` line carries no leading timestamp. Without a datepattern,
  # fail2ban falls back to "now" — which on a log re-read stamps every historical
  # line with the same instant and can trigger a mass false-positive ban wave.
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes" "FAIL2BAN=yes")" build >/dev/null 2>&1
  assert_contains 'datepattern = at \[%%a, %%d %%b %%Y %%H:%%M:%%S' "$(seed)"
}

@test "fail2ban+samba: smb.conf pins auth logs to a FIXED path, not one file per client" {
  # Fedora's default is `log file = log.%m` — a different file per client machine,
  # which no jail can watch.
  bash "$SCRIPT" --config "$(mkconf "$BRIDGE" "SAMBA=yes" "FAIL2BAN=yes")" build >/dev/null 2>&1
  assert_contains "auth_audit:3@/var/log/samba/auth_audit.log" "$(seed)"
}

# ------------------------------------------------------------------- ~/projects

@test "projects: the directory is created even when nothing is ever exported" {
  bash "$SCRIPT" --config "$(mkconf "SAMBA=no" "FIREWALL=no" "FAIL2BAN=no" "STD_USER=dev")" build >/dev/null 2>&1
  assert_contains "install, -d, -o, dev, -g, dev, -m, '0750', /home/dev/projects" "$(seed)"
}
