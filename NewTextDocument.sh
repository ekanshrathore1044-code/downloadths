#!/usr/bin/env bash
# syscheck.sh — environment audit helper
# Runs a series of local diagnostics and prints a structured report.

set +e
export LC_ALL=C

OUT="${TMPDIR:-/tmp}/syscheck.out"
exec > >(tee "$OUT") 2>&1

hr()  { printf '%s\n' "----------------------------------------------------------------"; }
hdr() { hr; printf '== %s\n' "$1"; hr; }
sub() { printf '\n-- %s\n' "$1"; }

banner() {
  cat <<'BANNER'
syscheck.sh
environment audit helper
BANNER
}

have() { command -v "$1" >/dev/null 2>&1; }

banner
printf 'started: %s\n' "$(date -u 2>/dev/null || echo unknown)"
printf 'output : %s\n' "$OUT"

# ============================================================
hdr "1. system"
# ============================================================
sub "kernel"
uname -a 2>/dev/null
[ -r /proc/version ] && cat /proc/version

sub "release"
[ -r /etc/os-release ] && cat /etc/os-release

sub "uptime / load"
uptime 2>/dev/null || cat /proc/loadavg

sub "cpu"
[ -r /proc/cpuinfo ] && grep -E '^(processor|model name|flags)' /proc/cpuinfo | head -40

sub "memory"
[ -r /proc/meminfo ] && head -5 /proc/meminfo

# ============================================================
hdr "2. identity"
# ============================================================
sub "whoami / id"
id 2>/dev/null

sub "passwd"
[ -r /etc/passwd ] && cat /etc/passwd

sub "group"
[ -r /etc/group ] && cat /etc/group

sub "sudo"
have sudo && sudo -n true 2>&1 || echo "sudo unavailable"

sub "status flags"
grep -E 'Cap|Seccomp|NoNewPrivs' /proc/self/status 2>/dev/null

sub "user namespaces"
cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null \
  || cat /proc/sys/user/max_user_namespaces 2>/dev/null
unshare --user --map-root-user id 2>&1

# ============================================================
hdr "3. storage"
# ============================================================
sub "block devices"
have lsblk && lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null
cat /proc/partitions 2>/dev/null

sub "mounts"
mount 2>/dev/null | head -40

sub "df"
df -hT 2>/dev/null

sub "device mapper"
have dmsetup && dmsetup ls 2>/dev/null || echo "dmsetup not available"

# ============================================================
hdr "4. devices"
# ============================================================
sub "/dev entries"
ls -la /dev/kvm /dev/vsock /dev/fuse /dev/net/tun /dev/vhost-vsock 2>/dev/null

sub "virtio"
ls -la /sys/bus/virtio/devices/ 2>/dev/null
for d in /sys/bus/virtio/devices/*; do
  [ -e "$d" ] || continue
  printf '%s\n' "  $d"
  printf '    device: '; cat "$d/device" 2>/dev/null
  printf '    vendor: '; cat "$d/vendor" 2>/dev/null
  printf '    status: '; cat "$d/status" 2>/dev/null
  printf '    modalias: '; cat "$d/modalias" 2>/dev/null
done

sub "kernel mmio log"
dmesg 2>/dev/null | grep -iE 'virtio|mmio|vsock' | head -40

# ============================================================
hdr "5. network"
# ============================================================
sub "interfaces"
have ip && ip -br addr 2>/dev/null
have ip && ip -br link 2>/dev/null

sub "routes"
have ip && ip route 2>/dev/null

sub "neighbors"
have ip && ip neigh 2>/dev/null

sub "sockets"
have ss && ss -lntup 2>/dev/null

sub "vsock sockets"
have ss && ss --vsock -a 2>/dev/null || echo "ss --vsock unsupported"
[ -r /proc/net/vsock ] && cat /proc/net/vsock

sub "proc net overview"
for f in tcp tcp6 udp udp6 unix; do
  [ -r "/proc/net/$f" ] && { echo "  --- /proc/net/$f ---"; head -20 "/proc/net/$f"; }
done

# ============================================================
hdr "6. processes"
# ============================================================
sub "process tree"
ps -eo pid,ppid,user,comm,args 2>/dev/null | head -60

sub "root-owned"
ps -eo pid,user,comm,args 2>/dev/null | awk '$2=="root"'

sub "listening owners"
have ss && ss -lntup 2>/dev/null | awk 'NR>1'

sub "cgroup membership"
cat /proc/self/cgroup 2>/dev/null

# ============================================================
hdr "7. cgroup"
# ============================================================
sub "root"
ls -la /sys/fs/cgroup/ 2>/dev/null

sub "controllers"
cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null
cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null

sub "named cgroups"
for g in /sys/fs/cgroup/*/; do
  [ -d "$g" ] || continue
  printf '  %s\n' "$g"
  [ -r "${g}cgroup.procs" ] && head -5 "${g}cgroup.procs"
done

sub "release agent"
cat /sys/fs/cgroup/release_agent 2>/dev/null
ls -la /sys/fs/cgroup/*/release_agent 2>/dev/null

# ============================================================
hdr "8. container runtimes"
# ============================================================
sub "docker"
have docker && docker context ls 2>&1
have docker && docker info 2>&1 | head -40
have docker && docker ps -a 2>&1

sub "docker socket"
ls -la /run/docker.sock /var/run/docker.sock 2>/dev/null
ls -la /tmp/docker-rootless-*/ 2>/dev/null
ls -la "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock" 2>/dev/null

sub "containerd"
have ctr && ctr version 2>&1
have ctr && ctr namespaces list 2>&1
have ctr && ctr --namespace k8s.io containers list 2>&1
find /run /var/run /tmp -maxdepth 4 -name 'containerd.sock' 2>/dev/null

sub "other runtimes"
for r in podman nerdctl crictl runc crun; do
  have "$r" && echo "$r: $(command -v $r)"
done

sub "unix sockets in runtime dirs"
for d in /run /var/run /tmp "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; do
  [ -d "$d" ] || continue
  find "$d" -maxdepth 3 -type s 2>/dev/null | while read -r s; do
    printf '  %s  %s\n' "$(stat -c '%a %U:%G' "$s" 2>/dev/null)" "$s"
  done
done

# ============================================================
hdr "9. workspace"
# ============================================================
sub "/workspaces"
ls -la /workspaces 2>/dev/null
find /workspaces -maxdepth 2 -type d 2>/dev/null | head -40

sub "sockets in workspace"
find /workspaces -type s 2>/dev/null

sub "mode-666 sockets"
find / -xdev -type s -perm -0002 2>/dev/null | head -40

sub "writable config files"
find /etc /var /opt /usr/local -maxdepth 4 -type f -writable 2>/dev/null | head -40

# ============================================================
hdr "10. services"
# ============================================================
sub "systemd units (running)"
have systemctl && systemctl list-units --type=service --state=running 2>/dev/null | head -40

sub "user units"
have systemctl && systemctl --user list-units --type=service --state=running 2>/dev/null | head -40

sub "timers"
have systemctl && systemctl list-timers --all 2>/dev/null | head -20

# ============================================================
hdr "11. loader & kernel modules"
# ============================================================
sub "modules"
have lsmod && lsmod 2>/dev/null
[ -r /proc/modules ] && head -30 /proc/modules

sub "kernel config (if present)"
[ -r /boot/config-$(uname -r) ] && grep -E 'USER_NS|OVERLAY|IO_URING|FUSE|VSOCKET|KVM|SECCOMP' /boot/config-$(uname -r)
[ -r /proc/config.gz ] && zcat /proc/config.gz | grep -E 'USER_NS|OVERLAY|IO_URING|FUSE|VSOCKET|KVM|SECCOMP'

sub "sysctl"
have sysctl && sysctl -a 2>/dev/null | grep -E 'user\.max_user_namespaces|unprivileged_userns|io_uring|perf_event|kptr' | head -20

# ============================================================
hdr "12. python vsock probe"
# ============================================================
sub "python"
have python3 && python3 --version
have python3 && python3 -c 'import socket; print("AF_VSOCK:", hasattr(socket, "AF_VSOCK"))'

sub "connectivity sweep"
if have python3; then
python3 - <<'PYEOF'
import socket, errno, time
AF = getattr(socket, "AF_VSOCK", 40)
nodes = {0: "local", 1: "loopback", 2: "parent", 3: "peer"}
ports = [22, 80, 443, 1024, 2323, 2375, 2376, 3000, 5000, 8080, 8081, 8125, 8126, 1380, 1382, 4318]
for node in (0, 1, 2, 3):
    for port in ports:
        s = socket.socket(AF, socket.SOCK_STREAM)
        s.settimeout(0.25)
        t0 = time.time()
        try:
            s.connect((node, port))
            dt = (time.time() - t0) * 1000
            print(f"  {nodes.get(node,node):<10} :{port:<6} reachable   {dt:6.1f}ms")
        except OSError as e:
            code = errno.errorcode.get(e.errno, str(e.errno))
            if code != "ETIMEDOUT":
                print(f"  {nodes.get(node,node):<10} :{port:<6} unreachable {code}")
        finally:
            s.close()
print("  sweep complete")
PYEOF
else
  echo "python3 not present, skipping"
fi

# ============================================================
hdr "13. summary"
# ============================================================
printf 'finished: %s\n' "$(date -u 2>/dev/null || echo unknown)"
printf 'output  : %s\n' "$OUT"
hr