#!/bin/bash
# check-trim.sh — 查看各直通盘的 TRIM(UNMAP) 计数, 辅助判断养护流量是否到桥
# 用法: sudo ./check-trim.sh
# 判读: failed>0 → 设备拒绝; ops>0 → 有流量但受理≠执行 (吞 TRIM 的桥也计 ops,
#       物理判决唯 guest-deep-trim/native-deep-trim 读回可定); ops=0 → 未触发
set -e
QMP=/tmp/anyfsd.qmp
[ -S "$QMP" ] || { echo "FAIL: $QMP 不存在 (daemon/VM 未运行?)"; exit 1; }

JSON=$( ( echo '{"execute":"qmp_capabilities"}'; sleep 0.3; echo '{"execute":"query-blockstats"}'; sleep 0.5 ) \
  | nc -U "$QMP" | tail -1 )
export JSON

python3 - <<'PYEOF'
import json, os
rows = [d for d in json.loads(os.environ["JSON"])["return"] if d["device"].startswith("usbdisk")]
if not rows:
    print("无活动直通盘")
for d in rows:
    s = d["stats"]
    name = d["device"]
    ops, failed = s["unmap_operations"], s["failed_unmap_operations"]
    mb = s["unmap_bytes"] // 1048576
    if failed > 0:
        verdict = "TRIM 被拒绝 — 该设备不支持"
    elif ops > 0:
        # 教训 (2026-11-11 三星 U盘): ops>0 failed=0 只证明命令流到了 QEMU,
        # 吞 TRIM 的桥 (PROBE UNMAP=no) 也满足 — 物理生效与否唯深度检测读回可判
        verdict = "有 TRIM 流量 (受理≠执行, 物理判决跑 guest-deep-trim/native-deep-trim)"
    else:
        verdict = "未触发/不支持 (fstrim 空跑)"
    print(f"{name}: unmap_ops={ops} unmap={mb}MB failed={failed}  → {verdict}")
PYEOF
