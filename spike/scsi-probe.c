// scsi-probe.c — 用 SCSITaskLib 向 USB 存储设备发裸 SCSI 命令 (INQUIRY)
// 验证 macOS 用户态能否绕过 smartctl 缺失, 直发任意 CDB (为 SMART 功能探路)
// 编译: cc -O2 -o scsi-probe scsi-probe.c -framework IOKit -framework CoreFoundation
#include <stdio.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <IOKit/scsi/SCSITask.h>
#include <CoreFoundation/CoreFoundation.h>

static int do_inquiry(SCSITaskDeviceInterface **devIf) {
    SCSITaskInterface **task = (*devIf)->CreateSCSITask(devIf);
    if (!task) { printf("  CreateSCSITask failed\n"); return -1; }

    UInt8 cdb[16] = {0};
    cdb[0] = 0x12;          // INQUIRY
    cdb[4] = 96;            // alloc len
    UInt8 buf[96];
    memset(buf, 0, sizeof buf);

    SCSITaskSGElement sge = { .address = (mach_vm_address_t)buf, .length = 96 };
    (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    (*task)->SetTaskAttribute(task, kSCSITask_SIMPLE);
    (*task)->SetScatterGatherEntries(task, &sge, 1, 96, kSCSIDataTransfer_FromTargetToInitiator);

    SCSI_Sense_Data sense;
    memset(&sense, 0, sizeof sense);
    SCSITaskStatus status = 0;
    UInt64 got = 0;
    IOReturn r = (*task)->ExecuteTaskSync(task, &sense, &status, &got);
    SCSIServiceResponse resp = 0;
    (*task)->GetSCSIServiceResponse(task, &resp);
    printf("  ExecuteTaskSync: kr=0x%x resp=%d status=%d bytes=%llu\n", r, resp, status, got);
    if (r == kIOReturnSuccess && got >= 36) {
        printf("  INQUIRY OK -> Vendor: %.8s Product: %.16s Rev: %.4s\n",
               buf + 8, buf + 16, buf + 32);
    } else {
        printf("  INQUIRY 失败\n");
    }
    (*task)->Release(task);
    return (r == kIOReturnSuccess && got >= 36) ? 0 : -1;
}

int main(void) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                            IOServiceMatching("IOSCSIPeripheralDeviceNub"), &iter);
    if (kr != kIOReturnSuccess) { printf("IOServiceGetMatchingServices: 0x%x\n", kr); return 1; }

    io_service_t dev;
    int found = 0, ok = 0;
    while ((dev = IOIteratorNext(iter))) {
        io_name_t name;
        IORegistryEntryGetName(dev, name);
        printf("发现 SCSI nub: %s\n", name);
        found++;

        IOCFPlugInInterface **plugIn = NULL;
        SInt32 score = 0;
        kr = IOCreatePlugInInterfaceForService(dev, kIOSCSITaskDeviceInterfaceID,
                                               kIOCFPlugInInterfaceID, &plugIn, &score);
        if (kr != kIOReturnSuccess || !plugIn) {
            printf("  无法创建 plugin: kr=0x%x (跳过)\n", kr);
            IOObjectRelease(dev);
            continue;
        }
        SCSITaskDeviceInterface **devIf = NULL;
        HRESULT hr = (*plugIn)->QueryInterface(plugIn,
                        CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&devIf);
        if (hr != S_OK || !devIf) {
            printf("  QueryInterface 失败: 0x%lx\n", (long)hr);
            (*plugIn)->Release(plugIn);
            IOObjectRelease(dev);
            continue;
        }
        if (do_inquiry(devIf) == 0) ok++;
        (*devIf)->Release(devIf);
        (*plugIn)->Release(plugIn);
        IOObjectRelease(dev);
    }
    IOObjectRelease(iter);
    printf("== 汇总: 发现 %d 个 SCSI nub, INQUIRY 成功 %d 个 ==\n", found, ok);
    return ok > 0 ? 0 : 1;
}
