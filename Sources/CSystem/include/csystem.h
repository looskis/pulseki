#ifndef PULSEKI_CSYSTEM_H
#define PULSEKI_CSYSTEM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --------------------------------------------------------------------------
 * AppleSMC client
 *
 * All functions return 0 on success. A non-zero return is either the raw
 * kern_return_t from IOKit (large, usually negative when cast to int) or
 * 0x10000 + the SMC result byte when the SMC itself rejected the request.
 * ------------------------------------------------------------------------ */

typedef struct {
    uint32_t type;       /* four-char code, e.g. 'flt ', 'ui16', 'sp78' */
    uint32_t size;       /* payload size in bytes, at most 32 */
    uint8_t  attributes;
} psk_smc_key_info_t;

int  psk_smc_open(uint32_t *connection);
void psk_smc_close(uint32_t connection);
int  psk_smc_key_count(uint32_t connection, uint32_t *count);
int  psk_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t *key);
int  psk_smc_key_info(uint32_t connection, uint32_t key, psk_smc_key_info_t *info);
int  psk_smc_read_key(uint32_t connection, uint32_t key, uint32_t size, uint8_t out[32]);

/* --------------------------------------------------------------------------
 * Network interface counters (64-bit, via NET_RT_IFLIST2)
 * ------------------------------------------------------------------------ */

#define PSK_IFNAMSIZ 16

typedef struct {
    char     name[PSK_IFNAMSIZ];
    uint16_t index;
    uint8_t  type;        /* IFT_* */
    uint32_t flags;       /* IFF_* */
    uint32_t mtu;
    uint64_t baudrate;    /* bits per second, 0 if unknown */
    uint64_t ipackets, ierrors, opackets, oerrors, collisions;
    uint64_t ibytes, obytes, imcasts, omcasts, iqdrops, noproto;
    int32_t  snd_drops;
} psk_netif_t;

/* Fills up to `max` entries. Returns the number of interfaces present, which
 * may be larger than `max` (call again with a bigger buffer), or -1 with
 * errno set. */
int psk_netif_list(psk_netif_t *out, int max);

#ifdef __cplusplus
}
#endif

#endif /* PULSEKI_CSYSTEM_H */
