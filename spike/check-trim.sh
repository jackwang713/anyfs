#!/bin/bash
# check-trim.sh — 查看各直通盘的 TRIM(UNMAP) 计数, 验证养护是否真到硬件
# 用法: sudo ./check-trim.sh
# 判读: unmap_ops>0 且 failed=0 → TRIM 真被执行; =0 → 设备不支持/未触发; failed>0 → 被拒绝
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
        verdict = "TRIM 已执行 — 养护有效"
    else:
        verdict = "未触发/不支持 (fstrim 空跑)"
    print(f"{name}: unmap_ops={ops} unmap={mb}MB failed={failed}  → {verdict}")
PYEOF
