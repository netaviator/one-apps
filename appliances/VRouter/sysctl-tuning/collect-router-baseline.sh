#!/bin/sh
# collect-router-baseline.sh - read-only baseline capture for a VRouter.
#
# Collects kernel/sysctl/NIC/conntrack/IPVS/memory state into ONE report file
# (plain text with "### section" markers, or JSON with -j).
#
# What it touches: it only reads. It never writes to /proc, /sys, sysctl, iptables,
# ip, tc or ethtool state and never runs `sysctl -w`. The only things it creates are
# a private temp directory (mode 700) next to the report, removed on exit, and the
# report itself (mode 600). It refuses to write the report through a symlink.
#
# Kernel modules: it never loads modules on purpose. Tools that make the kernel
# autoload a module as a side effect (ipvsadm -> ip_vs, iptables-save -> ip_tables /
# nf_tables, nft -> nf_tables, conntrack -> nf_conntrack_netlink) only run when the
# module is ALREADY loaded (checked in /proc/modules, /proc/net); otherwise the
# section says "(module X not loaded, not loading it)". Everything else it runs
# (ip, tc, ethtool, sysctl -a, lsmod, reads of /proc and /sys) does not autoload.
#
# Secrets: it does not read the environment, /proc/<pid>/cmdline, /proc/<pid>/environ,
# or any context/token file. Only /proc/cmdline (the kernel's), sysctl.d files and the
# system state listed above. Note that iptables/nft output can contain rule comments,
# so read a report before sharing it.
#
# POSIX sh; written for Alpine/busybox. Missing tools are reported as
# "(not installed)" and skipped, never fatal. Run as root for full data
# (/proc/slabinfo, conntrack -S, ethtool -S and iptables need it).
#
# JSON (-j): section name -> text. Output is ASCII only: CR is removed, every other
# control char, DEL and every byte >= 0x80 (valid UTF-8 included) becomes "?". No awk.
# Text mode keeps content as is; a "### " line inside content (for example from a
# sysctl.d file) is only unambiguous in the JSON form.
#
# Usage: collect-router-baseline.sh [-j] [-o FILE] [-l LABEL]
#   -j        write JSON (section name -> raw text) instead of text
#   -o FILE   report path (default: ./router-baseline-<host>-<label>-<UTC>.txt|json)
#   -l LABEL  free-text tag, e.g. "baseline" or "after-conntrack-max-65536"
#
# STATUS: first version ran with rc=0 on the stock VRouter image (Alpine 3.21.8,
# linux-virt 6.12.111, busybox 1.37, 1 vCPU / 512 MB, 2026-10-20); that run loaded
# ip_vs itself through ipvsadm, which the guards above now prevent. This hardened
# version was tested only in a privileged alpine:3.21 container; it has NOT been
# re-run on a router VM.

set -u
umask 077

die() { echo "collect-router-baseline: $*" >&2; exit 1; }
usage() { echo "Usage: $0 [-j] [-o FILE] [-l LABEL]" >&2; exit 2; }

JSON=0
OUT=""
LABEL="baseline"

while getopts "jo:l:h" opt; do
    case "$opt" in
        j) JSON=1 ;;
        o) OUT=$OPTARG ;;
        l) LABEL=$OPTARG ;;
        *) usage ;;
    esac
done

TS=$(date -u +%Y%m%dT%H%M%SZ)
HOST=$(hostname 2>/dev/null) || HOST=unknown
# User-controlled text is never put into a shell command string: it is only passed
# through printf %s. Printable-ASCII copies keep the report structure intact.
printable() { printf '%s' "$1" | LC_ALL=C tr -c '\040-\176' '?'; }
HOST_P=$(printable "$HOST")
LABEL_P=$(printable "$LABEL")
SAFE_HOST=$(printf '%s' "$HOST" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
SAFE_LABEL=$(printf '%s' "$LABEL" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
EXT=txt
[ "$JSON" -eq 1 ] && EXT=json
[ -n "$OUT" ] || OUT="./router-baseline-$SAFE_HOST-$SAFE_LABEL-$TS.$EXT"

[ -L "$OUT" ] && die "refusing to write the report through a symlink: $OUT"
[ -d "$OUT" ] && die "report path is a directory: $OUT"
OUTDIR=$(dirname -- "$OUT")
if [ ! -d "$OUTDIR" ] || [ ! -w "$OUTDIR" ]; then die "cannot write into directory: $OUTDIR"; fi

TMPD=$(mktemp -d "$OUTDIR/.router-baseline.XXXXXX") || die "mktemp failed in $OUTDIR"
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

IDX="$TMPD/index"
: > "$IDX" || die "cannot write $IDX"
SEQ=0
CUR=""

# begin_sec NAME: start a new section (its own file, so content can never forge a marker).
begin_sec() {
    SEQ=$((SEQ + 1))
    CUR="$TMPD/s$SEQ"
    printf '%s\n' "$1" >> "$IDX"
    : > "$CUR"
}

# note NAME TEXT: a section holding one line.
note() { begin_sec "$1"; printf '%s\n' "$2" >> "$CUR"; }

# sec NAME CMD [ARGS...]: run CMD, record output under NAME.
sec() {
    begin_sec "$1"; shift
    if command -v "$1" >/dev/null 2>&1; then
        "$@" >> "$CUR" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || printf '(exit status %s)\n' "$rc" >> "$CUR"
    else
        printf '(not installed: %s)\n' "$1" >> "$CUR"
    fi
}

# secfile NAME FILE: record a file's content.
secfile() {
    begin_sec "$1"
    if [ -r "$2" ]; then cat "$2" >> "$CUR" 2>&1; else printf '(unreadable: %s)\n' "$2" >> "$CUR"; fi
}

# secsh NAME 'snippet' [ARG...]: small read-only pipelines; ARGs arrive as $1... (never
# spliced into the snippet text).
secsh() {
    begin_sec "$1"
    snippet=$2
    shift 2
    sh -c "$snippet" sh "$@" >> "$CUR" 2>&1 || printf '(exit status %s)\n' "$?" >> "$CUR"
}

modloaded() { grep -q "^$1 " /proc/modules 2>/dev/null; }

NICS=""
for d in /sys/class/net/*; do
    n=${d##*/}
    [ "$n" = "lo" ] && continue
    [ -e "$d" ] || continue
    case "$n" in
        *[!A-Za-z0-9._@:-]*) UNSAFE_NICS=1; continue ;;
    esac
    NICS="$NICS $n"
done
UNSAFE_NICS=${UNSAFE_NICS:-0}

# ---- meta ----
begin_sec meta.collector
{
    printf 'script=collect-router-baseline.sh\n'
    printf 'label=%s\n' "$LABEL_P"
    printf 'utc=%s\n' "$TS"
    printf 'host=%s\n' "$HOST_P"
    printf 'uid=%s\n' "$(id -u)"
    [ "$UNSAFE_NICS" -eq 0 ] || printf 'skipped interfaces with unsafe names (not A-Za-z0-9._@:-)\n'
} >> "$CUR"

sec meta.uname uname -a
secfile meta.os-release /etc/os-release
secfile meta.cmdline /proc/cmdline
sec meta.nproc nproc
secsh meta.cpu "grep -E '^(processor|model name|cpu MHz|flags)' /proc/cpuinfo"
secfile meta.loadavg /proc/loadavg
sec meta.uptime uptime
sec meta.lsmod lsmod
secsh meta.virt "ls /sys/class/dmi/id 2>/dev/null; cat /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor 2>/dev/null"

# ---- memory ----
sec mem.free free -m
secfile mem.meminfo /proc/meminfo
sec mem.slabtop slabtop -o -s c
secsh mem.slab-net "grep -E '^(nf_conntrack|nf_conncount|ip_vs|ip_vs_conn|nf_nat|fib|ip_fib|ip_dst|ip_mrt|neighbour|arp_cache|ndisc_cache|skbuff|kmalloc-(256|512|1k|2k)|xfrm)' /proc/slabinfo"
secfile mem.overcommit /proc/sys/vm/overcommit_memory

# ---- sysctl (full dump; the tuning candidates are diffed against this) ----
secsh sysctl.all "if command -v sysctl >/dev/null 2>&1; then sysctl -a 2>/dev/null; else find /proc/sys -type f 2>/dev/null | while read -r f; do printf '%s = ' \"\$f\"; cat \"\$f\" 2>/dev/null | tr '\\n' ' '; echo; done; fi"
secsh sysctl.files "ls -l /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ 2>&1; for f in /etc/sysctl.conf /etc/sysctl.d/* /usr/lib/sysctl.d/*; do [ -f \"\$f\" ] && { echo \"--- \$f\"; cat \"\$f\"; }; done"

# ---- interfaces ----
sec net.ip-link ip -s link
sec net.ip-link-detail ip -d -s -s link
sec net.ip-addr ip addr
sec net.ip-route ip route show table all
sec net.ip-rule ip rule
sec net.ip-neigh-count sh -c 'ip neigh | wc -l'
sec net.ip-neigh-stat ip -s neigh
secfile net.proc-net-dev /proc/net/dev
secfile net.softnet_stat /proc/net/softnet_stat
secfile net.snmp /proc/net/snmp
secfile net.netstat /proc/net/netstat
secfile net.fib_triestat /proc/net/fib_triestat
secfile net.rt_cache_stat /proc/net/stat/rt_cache
secfile net.arp_cache_stat /proc/net/stat/arp_cache
secfile net.interrupts /proc/interrupts
secfile net.softirqs /proc/softirqs
secsh net.irq-affinity "for f in /proc/irq/*/smp_affinity_list; do echo \"\$f: \$(cat \$f 2>/dev/null)\"; done"
secsh net.default_smp_affinity "cat /proc/irq/default_smp_affinity"
sec net.tc-qdisc tc -s qdisc

for n in $NICS; do
    sec "nic.$n.ethtool-driver" ethtool -i "$n"
    sec "nic.$n.ethtool-link" ethtool "$n"
    sec "nic.$n.ethtool-k" ethtool -k "$n"
    sec "nic.$n.ethtool-l" ethtool -l "$n"
    sec "nic.$n.ethtool-g" ethtool -g "$n"
    sec "nic.$n.ethtool-c" ethtool -c "$n"
    sec "nic.$n.ethtool-S" ethtool -S "$n"
    # shellcheck disable=SC2016  # $1, $n, $f are for the inner sh, on purpose
    secsh "nic.$n.sysfs" 'n=$1; for f in mtu tx_queue_len speed duplex operstate; do printf "%s=" "$f"; cat "/sys/class/net/$n/$f" 2>&1; done; for q in /sys/class/net/"$n"/queues/*; do [ -d "$q" ] || continue; for f in rps_cpus xps_cpus rps_flow_cnt; do if [ -r "$q/$f" ]; then echo "$q/$f=$(cat "$q/$f")"; fi; done; done; true' "$n"
done

# ---- conntrack / NAT / firewall ----
secsh ct.proc "for f in count max buckets expect_max; do printf 'nf_conntrack_%s=' \$f; cat /proc/sys/net/netfilter/nf_conntrack_\$f 2>&1; done; printf 'hashsize='; cat /sys/module/nf_conntrack/parameters/hashsize 2>&1"
secsh ct.stat-proc "if [ -r /proc/net/stat/nf_conntrack ]; then cat /proc/net/stat/nf_conntrack; else echo '(this kernel has no /proc/net/stat/nf_conntrack; use conntrack -S from conntrack-tools)'; fi"
# conntrack-tools opens a NETLINK_NETFILTER socket, which autoloads nf_conntrack_netlink.
if modloaded nf_conntrack_netlink; then
    sec ct.conntrack-S conntrack -S
    sec ct.conntrack-C conntrack -C
else
    note ct.conntrack-S '(module nf_conntrack_netlink not loaded, not loading it)'
    note ct.conntrack-C '(module nf_conntrack_netlink not loaded, not loading it)'
fi
secsh ct.sysctl "sysctl -a 2>/dev/null | grep -E '^net\.(netfilter|nf_conntrack)'"
secsh ct.entries-by-proto "if [ -r /proc/net/nf_conntrack ]; then awk '{print \$3}' /proc/net/nf_conntrack | sort | uniq -c; else echo '(no /proc/net/nf_conntrack)'; fi"
# iptables-save / nft make the kernel autoload ip_tables / nf_tables (and iptable_nat ->
# nf_conntrack). Only run them when the xtables / nf_tables core is already there.
if modloaded nf_tables || [ -e /proc/net/ip_tables_names ]; then
    sec fw.iptables-save iptables-save -c
else
    note fw.iptables-save '(modules nf_tables / ip_tables not loaded, not loading them)'
fi
if modloaded nf_tables; then
    sec fw.nft-ruleset nft list ruleset
else
    note fw.nft-ruleset '(module nf_tables not loaded, not loading it)'
fi

# ---- IPVS / LVS ----
# ipvsadm loads ip_vs on its first call, so it only runs when the module is already loaded
# (/proc/net/ip_vs exists). Otherwise the report would measure a changed system.
IPVS_GUARD="[ -e /proc/net/ip_vs ] || { echo '(ip_vs not loaded, not loading it)'; exit 0; }"
secsh ipvs.ipvsadm-ln "$IPVS_GUARD; ipvsadm -Ln 2>&1"
secsh ipvs.ipvsadm-stats "$IPVS_GUARD; ipvsadm -Ln --stats 2>&1"
secsh ipvs.ipvsadm-timeout "$IPVS_GUARD; ipvsadm -L --timeout 2>&1"
secsh ipvs.ipvsadm-daemon "$IPVS_GUARD; ipvsadm -L --daemon 2>&1"
secsh ipvs.sysctl "sysctl -a 2>/dev/null | grep -E '^net\.ipv4\.vs\.'"
secfile ipvs.proc-ip_vs_stats /proc/net/ip_vs_stats
secsh ipvs.conn-count "if [ -r /proc/net/ip_vs_conn ]; then wc -l < /proc/net/ip_vs_conn; else echo '(no /proc/net/ip_vs_conn)'; fi"

# ---- finalise ----
TAB=$(printf '\t')

# jesc FILE: JSON string body for the file's content, on stdout, no awk. Each stage goes
# through a temp file so a failing stage is detected (a pipe only reports the last one).
jesc() {
    LC_ALL=C tr -d '\015' < "$1" > "$TMPD/j1" || return 1
    LC_ALL=C tr -c '\011\012\040-\176' '?' < "$TMPD/j1" > "$TMPD/j2" || return 1
    LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$TAB/\\\\t/g" -e '$!s/$/\\n/' \
        "$TMPD/j2" > "$TMPD/j3" || return 1
    LC_ALL=C tr -d '\n' < "$TMPD/j3"
}

# jesc_str STRING: same for a single value.
jesc_str() {
    printf '%s' "$1" > "$TMPD/js" || return 1
    jesc "$TMPD/js"
}

assemble_txt() {
    i=0
    while IFS= read -r name; do
        i=$((i + 1))
        printf '### %s\n' "$name" || return 1
        cat "$TMPD/s$i" || return 1
        if [ -n "$(tail -c 1 "$TMPD/s$i")" ]; then printf '\n' || return 1; fi
    done < "$IDX"
}

assemble_json() {
    printf '{"host":"%s","label":"%s","utc":"%s","sections":{' \
        "$(jesc_str "$HOST_P")" "$(jesc_str "$LABEL_P")" "$TS" || return 1
    i=0
    first=1
    while IFS= read -r name; do
        i=$((i + 1))
        [ "$first" -eq 1 ] || printf ',' || return 1
        first=0
        printf '"%s":"' "$(jesc_str "$name")" || return 1
        jesc "$TMPD/s$i" || return 1
        printf '"' || return 1
    done < "$IDX"
    printf '}}\n'
}

FINAL="$TMPD/final"
if [ "$JSON" -eq 1 ]; then
    assemble_json > "$FINAL" || die "cannot build the JSON report"
else
    assemble_txt > "$FINAL" || die "cannot build the text report"
fi
[ -s "$FINAL" ] || die "report is empty"

[ -L "$OUT" ] && die "refusing to write the report through a symlink: $OUT"
[ -d "$OUT" ] && die "report path is a directory: $OUT"
mv -f "$FINAL" "$OUT" || die "cannot move the report to $OUT"
echo "wrote $OUT" >&2
