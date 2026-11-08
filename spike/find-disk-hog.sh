#!/bin/bash
# find-disk-hog.sh — 定位磁盘空间去向 (需 sudo + 终端需 FDA 完全磁盘访问权限)
echo "=== 1/3 TCC 盲区点名 (上次被挡的目录) ==="
du -sh /System/Volumes/Data/.TemporaryItems \
       /System/Volumes/Data/.DocumentRevisions-V100 \
       /System/Volumes/Data/.Spotlight-V100 \
       /System/Volumes/Data/private/var/containers \
       /Users/jack/.Trash \
       /Users/jack/Library/Mail \
       /Users/jack/Library/Messages 2>&1 | sort -rh

echo "=== 2/3 卷级全景 ==="
du -xsh /System/Volumes/Data/* /System/Volumes/Data/.[!.]* 2>/dev/null | sort -rh | head -12

echo "=== 3/3 若仍对不上: df vs du 差额 ==="
df -h /System/Volumes/Data | tail -1
