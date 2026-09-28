#include "csystem.h"

#include <string.h>
#include <IOKit/IOKitLib.h>

/* Wire format of the AppleSMC user client. The kernel rejects any call whose
 * struct size is not exactly 80 bytes, hence the static assert. */
typedef struct {
    uint8_t  major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData must be 80 bytes to match AppleSMC");

enum { kSMCHandleYPCEvent = 2 };
enum { kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static int smc_call(uint32_t conn, SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(*out);
    memset(out, 0, sizeof(*out));
    kern_return_t kr = IOConnectCallStructMethod((io_connect_t)conn, kSMCHandleYPCEvent,
                                                 in, sizeof(*in), out, &outSize);
    if (kr != KERN_SUCCESS) return (int)kr;
    if (out->result != 0) return 0x10000 + out->result;
    return 0;
}

int psk_smc_open(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return (int)kIOReturnNotFound;
    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return (int)kr;
    *connection = conn;
    return 0;
}

void psk_smc_close(uint32_t connection) {
    if (connection != IO_OBJECT_NULL) IOServiceClose((io_connect_t)connection);
}

int psk_smc_key_count(uint32_t connection, uint32_t *count) {
    uint8_t bytes[32];
    int rc = psk_smc_read_key(connection, 0x234B4559 /* '#KEY' */, 4, bytes);
    if (rc) return rc;
    *count = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
    return 0;
}

int psk_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t *key) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    int rc = smc_call(connection, &in, &out);
    if (rc) return rc;
    *key = out.key;
    return 0;
}

int psk_smc_key_info(uint32_t connection, uint32_t key, psk_smc_key_info_t *info) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    int rc = smc_call(connection, &in, &out);
    if (rc) return rc;
    info->type = out.keyInfo.dataType;
    info->size = out.keyInfo.dataSize;
    info->attributes = out.keyInfo.dataAttributes;
    return 0;
}

int psk_smc_read_key(uint32_t connection, uint32_t key, uint32_t size, uint8_t out_bytes[32]) {
    if (size > 32) return (int)kIOReturnBadArgument;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = kSMCReadKey;
    int rc = smc_call(connection, &in, &out);
    if (rc) return rc;
    memcpy(out_bytes, out.bytes, 32);
    return 0;
}
