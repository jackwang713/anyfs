#!/bin/bash
# cliff-test.sh — SLC悬崖测试: 连续写N个1GB, 逐个报速
# 用法: ./cliff-test.sh <挂载点> <GB数> <标签>
set -u
VOL="${1:?usage: cliff-test.sh <vol> <GB> <label>}"
N="${2:-40}"
LABEL="${3:-run}"
OUT=~/cliff-${LABEL}.csv
F="$VOL/cliff.bin"
rm -f "$F"
echo "# cliff-test $LABEL $(date)" > "$OUT"
for i in $(seq 1 "$N"); do
  t=$( { /usr/bin/time -p sh -c "dd if=/dev/urandom bs=1m count=1024 2>/dev/null >> $F; sync"; } 2>&1 | awk '/^real/{print $2}')
  [ -z "$t" ] && { echo "GB $i: WRITE-FAILED"; echo "$i,0" >> "$OUT"; continue; }
  v=$(echo "scale=1; 1024/$t" | bc)
  echo "$i,$v" >> "$OUT"
  echo "GB $i: $v MB/s"
done
rm -f "$F"; sync
echo "CLIFF-DONE -> $OUT"
