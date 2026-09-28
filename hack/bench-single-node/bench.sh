#!/bin/bash
# Single-node kind bench: create time, idle CPU (total and per process), memory,
# apiserver request rate. Arms are interleaved so machine drift hits all of them.
set -u
cd "$(dirname "$0")"
KIND=${KIND:-kind}
REPS=${REPS:-3}
SETTLE=${SETTLE:-60}
WINDOW=${WINDOW:-120}
ARMS=${ARMS:-"base le dns1 all"}
OUT=${OUT:-results.csv}
NODE=bench-control-plane
PROCS="kube-apiserver etcd kube-controller kube-scheduler kubelet containerd coredns kindnetd kube-proxy local-path-prov"
[ -f "$OUT" ] || echo "host,rep,arm,create_s,ready_s,cpu_mcores,mem_mib,apiserver_req_per_s,$(echo $PROCS | tr ' ' ','),flags" > "$OUT"

now() { date +%s.%N; }
reqs() { kubectl get --raw /metrics 2>/dev/null | awk '/^apiserver_request_total\{/ {s+=$NF} END {printf "%d", s}'; }
cpu() { docker exec $NODE awk '/^usage_usec/ {print $2}' /sys/fs/cgroup/cpu.stat; }
# utime+stime ticks summed per process name (comm), one "name ticks" line each
proc_ticks() {
  docker exec $NODE bash -c 'for d in /proc/[0-9]*; do
    read -r c < $d/comm 2>/dev/null || continue
    s=$(cat $d/stat 2>/dev/null) || continue
    s=${s##*) }; set -- $s
    echo "$c $(( ${12} + ${13} ))"
  done' | awk '{t[$1]+=$2} END {for (k in t) print k, t[k]}'
}

for rep in $(seq 1 "$REPS"); do
  for arm in $ARMS; do
    $KIND delete cluster --name bench >/dev/null 2>&1
    t0=$(now)
    if ! $KIND create cluster --name bench --config "cfg/$arm.yaml" --wait 5m >"create-$arm-$rep.log" 2>&1; then
      echo "$(hostname),$rep,$arm,FAIL" >> "$OUT"; continue
    fi
    t1=$(now)
    kubectl -n kube-system wait --for=condition=Ready pod --all --timeout=300s >/dev/null 2>&1
    t2=$(now)
    if [ "$arm" = dns1 ] || [ "$arm" = all ]; then
      kubectl -n kube-system scale deploy coredns --replicas=1 >/dev/null
      kubectl -n kube-system rollout status deploy coredns --timeout=120s >/dev/null 2>&1
    fi
    flags=$(docker exec $NODE sh -c 'grep -ho "leader-elect=[a-z]*" /etc/kubernetes/manifests/*.yaml | sort | uniq -c | tr -s " " | tr "\n" ";"')
    flags="$flags coredns=$(kubectl -n kube-system get deploy coredns -o jsonpath='{.status.replicas}')"
    sleep "$SETTLE"
    c0=$(cpu); r0=$(reqs); p0=$(proc_ticks); s0=$(now)
    sleep "$WINDOW"
    c1=$(cpu); r1=$(reqs); p1=$(proc_ticks); s1=$(now)
    mem=$(docker exec $NODE cat /sys/fs/cgroup/memory.current)
    python3 - "$(hostname)" "$rep" "$arm" "$t0" "$t1" "$t2" "$c0" "$c1" "$s0" "$s1" "$r0" "$r1" "$mem" "$flags" "$PROCS" "$p0" "$p1" >> "$OUT" <<'PY'
import sys
host, rep, arm, t0, t1, t2, c0, c1, s0, s1, r0, r1, mem, flags, procs, p0, p1 = sys.argv[1:]
t0, t1, t2, s0, s1 = map(float, (t0, t1, t2, s0, s1))
el = s1 - s0
def parse(s):
    d = {}
    for line in s.splitlines():
        k, _, v = line.rpartition(" ")
        d[k] = int(v)
    return d
a, b = parse(p0), parse(p1)
per = [f"{(b.get(p, 0) - a.get(p, 0)) * 10 / el:.1f}" for p in procs.split()]  # 100 ticks/s -> millicores
print(",".join([host, rep, arm, f"{t1-t0:.1f}", f"{t2-t0:.1f}", f"{(int(c1)-int(c0))/1000/el:.0f}",
                f"{int(mem)/2**20:.0f}", f"{(int(r1)-int(r0))/el:.2f}", *per, flags]))
PY
    tail -1 "$OUT"
  done
done
$KIND delete cluster --name bench >/dev/null 2>&1
