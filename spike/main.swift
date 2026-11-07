import Foundation
import Virtualization

// NTFS Bridge Spike — 验证 VZ virtio-blk raw 盘直通
// 1. discard_max_bytes: VZ 是否向 guest 宣告 DISCARD 能力（TRIM 生死测试）
// 2. dd 顺序读: virtio-blk -> raw rdisk 的吞吐上限
// 全程只读，不对磁盘写入任何数据

let workDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let kernelURL = workDir.appendingPathComponent("alpine/vmlinuz-virt")
let initrdURL = workDir.appendingPathComponent("alpine/initramfs-virt")
let isoURL = workDir.appendingPathComponent("alpine/alpine-virt.iso")
let usbDiskPath = "/dev/disk2"

let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
bootLoader.initialRamdiskURL = initrdURL
bootLoader.commandLine = "console=hvc0"

let config = VZVirtualMachineConfiguration()
config.bootLoader = bootLoader
config.cpuCount = 2
config.memorySize = 512 * 1024 * 1024

let guestInput = Pipe()
let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
serial.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: guestInput.fileHandleForReading,
    fileHandleForWriting: FileHandle.standardOutput
)
config.serialPorts = [serial]

// USB 盘 -> /dev/vda
let diskAttachment = try VZDiskImageStorageDeviceAttachment(
    url: URL(fileURLWithPath: usbDiskPath),
    readOnly: false,
    cachingMode: .automatic,
    synchronizationMode: .full
)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

// Alpine ISO -> /dev/vdb，initramfs 需要找到 boot media 才能进 live 系统
let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
config.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: isoAttachment))

try config.validate()

let vm = VZVirtualMachine(configuration: config)

func send(_ s: String) {
    guestInput.fileHandleForWriting.write(s.data(using: .utf8)!)
}

DispatchQueue.global().async {
    Thread.sleep(forTimeInterval: 12)
    send("\nroot\n")
    Thread.sleep(forTimeInterval: 3)
    send("echo SPIKE-SECTORS=$(cat /sys/block/vda/size)\n")
    send("echo SPIKE-DISCARD=$(cat /sys/block/vda/queue/discard_max_bytes)\n")
    send("echo SPIKE-GRAN=$(cat /sys/block/vda/queue/discard_granularity)\n")
    send("fdisk -l /dev/vda | head -8\n")
    Thread.sleep(forTimeInterval: 1)
    send("dd if=/dev/vda of=/dev/null bs=1M count=4096\n")
    send("echo SPIKE-ALL-DONE\n")
    Thread.sleep(forTimeInterval: 120)
    fputs("SPIKE-TIMEOUT\n", stderr)
    exit(1)
}

vm.start { result in
    switch result {
    case .success:
        fputs("SPIKE-VM-STARTED\n", stderr)
    case .failure(let error):
        fputs("SPIKE-VM-FAILED: \(error)\n", stderr)
        exit(2)
    }
}

dispatchMain()
