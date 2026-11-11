#!/usr/bin/env python3
# qmp-stats.py — query-blockstats 探针: 打印每个块设备的 unmap/wr/rd 计数
# 用法: sudo python3 qmp-stats.py [--watch 秒]
# 诊断价值: nc 抓全行 + 贪婪 sed 会错拿最后一个设备的计数器 (多设备顺序不保证),
#           本探针按设备名分列, 杜绝张冠李戴
import socket, json, sys, time

SOCK = '/tmp/anyfsd.qmp'

def query(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(SOCK)
    f = s.makefile('rw')
    f.readline()                                  # QMP greeting
    f.write('{"execute":"qmp_capabilities"}\n'); f.flush()
    f.readline()
    f.write('{"execute":"%s"}\n' % cmd); f.flush()
    line = f.readline()
    s.close()
    return json.loads(line)

def show():
    j = query('query-blockstats')
    rows = []
    for e in j.get('return', []):
        st = e.get('stats', {})
        rows.append((e.get('device') or e.get('qdev') or '?',
                     st.get('unmap_operations', -1),
                     st.get('wr_operations', -1),
                     st.get('rd_operations', -1)))
    return rows

if '--watch' in sys.argv:
    step = float(sys.argv[sys.argv.index('--watch') + 1]) if len(sys.argv) > sys.argv.index('--watch') + 1 else 2
    base = None
    t0 = time.time()
    while True:
        rows = show()
        if base is None:
            base = [r[1] for r in rows]
        line = 'T+%4.0fs | ' % (time.time() - t0)
        line += '  '.join('%s unmap=+%d (tot %d)' % (r[0], r[1] - b, r[1]) for r, b in zip(rows, base))
        print(line, flush=True)
        time.sleep(step)
else:
    print('%-28s %12s %12s %12s' % ('device', 'unmap_ops', 'wr_ops', 'rd_ops'))
    for r in show():
        print('%-28s %12d %12d %12d' % r)
