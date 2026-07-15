#!/usr/bin/env bash
# vmseed guest diagnostics — READ-ONLY, changes nothing.
#
# Run ON THE GUEST as:   bash guest-diagnostics.sh    (it re-execs under sudo)
# Output goes to the terminal AND to /tmp/vmseed-diag.txt on the guest.
# Bring that file back into tools/diagnostics-results/ on the host (that folder
# is gitignored — the outputs are run artifacts, not source).
#
# Re-execs under sudo so the root-only logs (cloud-init*.log, audit.log) and the
# firewalld/pdbedit D-Bus calls actually work — running it unprivileged hides
# cloud-init-output.log and makes firewall-cmd fail with a polkit error.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

set +e
OUT=/tmp/vmseed-diag.txt
exec > >(tee "$OUT") 2>&1

sec() { printf '\n\n========== %s ==========\n' "$*"; }
# Each probe is a fixed command string containing pipes/redirections, so it needs
# shell evaluation (a bare "$@" would treat "cmd | tail" as one literal command).
# bash -c runs it in an isolated subshell — no eval, and a stray cd/set in one
# probe can't leak into the next. The strings are all hardcoded here, never input.
run() { printf '\n$ %s\n' "$*"; bash -c "$*" 2>&1; printf '  [exit %s]\n' "$?"; }

# STD_USER is 'appuser' unless the build overrode it; detect the share owner.
SHARE_DIR="$(ls -d /home/*/projects 2>/dev/null | head -1)"
STD_USER="$(basename "$(dirname "${SHARE_DIR:-/home/appuser/projects}")")"

sec "HOST / KERNEL / DATE / VIRT"
run "date -u"
run "uname -r"
run "grep -E '^(NAME|VERSION)=' /etc/os-release"
run "systemd-detect-virt"
run "echo share_dir=${SHARE_DIR:-<none>} std_user=$STD_USER"

sec "SYSTEMD FAILED UNITS"
run "systemctl --failed --no-pager"

# ---- cloud-init overview ----
sec "CLOUD-INIT STATUS (long)"
run "cloud-init status --long"
run "cloud-init status --format json"
sec "CLOUD-INIT TIMELINE (which module ran/failed)"
run "cloud-init analyze show | tail -60"
run "cloud-init analyze blame | head -20"

# ---- every failed unit, dynamically: status + journal ----
mapfile -t FAILED < <(systemctl --failed --no-legend --plain | awk '{print $1}')
# Always include the usual suspects even if they later self-clear.
for u in cloud-init-main.service cloud-config.service cloud-final.service \
         smb.service fail2ban.service firewalld.service systemd-tpm2-setup.service; do
  case " ${FAILED[*]} " in *" $u "*) : ;; *) FAILED+=("$u") ;; esac
done
for u in "${FAILED[@]}"; do
  [ -n "$u" ] || continue
  sec "UNIT: $u — status"
  run "systemctl status $u --no-pager -l"
  sec "UNIT: $u — journal (this boot, tail)"
  run "journalctl -u $u -b --no-pager | tail -80"
done

# ---- cloud-init logs: the real culprit for a runcmd/scripts_user failure ----
sec "CLOUD-INIT LOG — errors & tracebacks"
run "grep -nE 'WARNING|ERROR|Traceback|CRITICAL|non-zero|Failed to run' /var/log/cloud-init.log | tail -60"
sec "CLOUD-INIT-OUTPUT.LOG — runcmd stdout/stderr (READ THIS FIRST)"
run "tail -200 /var/log/cloud-init-output.log"

# ---- rendered seed, to correlate a failing command with the template ----
sec "RENDERED user-data (runcmd section)"
run "sed -n '/^runcmd:/,/^[a-z_]*:/p' /var/lib/cloud/instance/user-data.txt | head -140"
sec "RENDERED smb.conf as written to the guest"
run "testparm -s /etc/samba/smb.conf 2>&1 | head -80"

# ---- feature verification ----
sec "FIREWALL"
run "rpm -q firewalld"
run "systemctl is-active firewalld"
run "firewall-cmd --state"
run "firewall-cmd --get-active-zones"
run "firewall-cmd --list-all"                # default zone: the 445 (and any ssh) rich rules

sec "SAMBA"
run "rpm -q samba"
run "systemctl is-active smb"
run "testparm -s"
run "pdbedit -L"
run "smbstatus -b"
run "ls -ldZ ${SHARE_DIR:-/home/$STD_USER/projects}"
run "ls -l /run/smb-init.pass"          # expect: absent (consumed then shredded)
run "head -3 /var/log/samba/auth_audit.log"

sec "FAIL2BAN"
run "rpm -q fail2ban-server"
run "systemctl is-active fail2ban"
run "fail2ban-client status"
run "fail2ban-client status samba-auth"
run "fail2ban-regex /var/log/samba/auth_audit.log /etc/fail2ban/filter.d/samba-auth.conf | tail -20"
run "grep -c 'no valid date' /var/log/fail2ban.log"

sec "SELINUX — recent AVC denials"
run "ausearch -m AVC -ts recent"        # '<no matches>' is good

sec "TPM (for systemd-tpm2-setup.service)"
run "ls -l /dev/tpm0 /dev/tpmrm0"
run "ls -l /boot/efi/loader/credentials/ 2>&1 | head"   # where the failing write targets

printf '\n\n========== DONE — collected in %s (copy into tools/diagnostics-results/) ==========\n' "$OUT"
