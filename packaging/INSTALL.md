# anyFS 安装说明（macOS 13+，Intel）

anyFS 让 macOS 读写 NTFS / exFAT / ext4 移动硬盘，并自动养护 SSD（TRIM）。

## 安装

双击 `AnyFS-0.1.pkg` 安装。因为安装包未使用 Apple 付费证书签名，系统会有一次安全提示，按你的 macOS 版本操作：

- **macOS 13 / 14**：如果双击被拦，右键点安装包 → 打开 → 再点"打开"
- **macOS 15 及更新**：双击被拦后，去 **系统设置 → 隐私与安全性**，滚到最下面点"**仍要打开**"
- 或者终端一行命令（任意版本通用）：
  ```
  xattr -d com.apple.quarantine ~/Downloads/AnyFS-0.1.pkg
  ```

安装会自动完成：App 装入 `/Applications`，后台服务注册到系统（按需启动，不占资源）。

## 首次使用：授权"完全磁盘访问"（必做，一次性）

anyFS 需要直接读写磁盘，首次接管分区时系统需要授权：

1. 打开 **系统设置 → 隐私与安全性 → 完全磁盘访问权限**
2. 点 `+`，按 `Cmd+Shift+G` 输入 `/Library/PrivilegedHelperTools/anyfsd`，打开
3. 确保开关打开

（Paragon NTFS 等同类软件也需要同样步骤。）

## 使用

1. 插入移动硬盘，点击菜单栏的 anyFS 图标
2. 把要用的分区**开关打开**（约 15 秒），Finder 会自动弹出可读写的分区
3. 没勾选的分区不受影响，继续由 macOS 原生使用
4. 用完**先关闭开关**再拔盘；退出 App 会自动安全关闭一切

养护提示：NTFS 分区实时自动养护（在线 TRIM）；exFAT/ext4 分区点分区旁边的 🍃 按钮手动养护。

## 卸载

```
sudo launchctl bootout system/com.anyfs.daemon
sudo rm /Library/LaunchDaemons/com.anyfs.daemon.plist \
        /Library/PrivilegedHelperTools/anyfsd \
        /usr/local/etc/anyfsd.conf
sudo rm -rf /Applications/AnyFS.app
```
