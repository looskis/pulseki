#include "csystem.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_var.h>
#include <net/if_mib.h>

/* getifaddrs() exposes 32-bit if_data counters, and on current macOS the
 * routing socket's RTM_IFINFO2 records also carry byte counts that wrap at
 * 4 GB even though the field is 64 bits wide. The per-interface IFMIB sysctl
 * (net.link.generic.ifdata.<index>.general) is what netstat -ib reads and it
 * returns true 64-bit counters. */
int psk_netif_list(psk_netif_t *out, int max) {
    struct if_nameindex *names = if_nameindex();
    if (!names) return -1;

    int count = 0;
    for (struct if_nameindex *ni = names; ni->if_index != 0; ni++) {
        struct ifmibdata data;
        size_t len = sizeof data;
        int mib[6] = { CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)ni->if_index, IFDATA_GENERAL };
        if (sysctl(mib, 6, &data, &len, NULL, 0) < 0 || len < sizeof data) continue;

        if (count < max) {
            psk_netif_t *n = &out[count];
            memset(n, 0, sizeof(*n));
            strncpy(n->name, data.ifmd_name[0] ? data.ifmd_name : ni->if_name, PSK_IFNAMSIZ - 1);
            n->name[PSK_IFNAMSIZ - 1] = '\0';

            const struct if_data64 *d = &data.ifmd_data;
            n->index      = (uint16_t)ni->if_index;
            n->type       = d->ifi_type;
            n->flags      = data.ifmd_flags & 0xFFFF; /* upper bits are kernel-internal */
            n->mtu        = d->ifi_mtu;
            n->baudrate   = d->ifi_baudrate;
            n->ipackets   = d->ifi_ipackets;
            n->ierrors    = d->ifi_ierrors;
            n->opackets   = d->ifi_opackets;
            n->oerrors    = d->ifi_oerrors;
            n->collisions = d->ifi_collisions;
            n->ibytes     = d->ifi_ibytes;
            n->obytes     = d->ifi_obytes;
            n->imcasts    = d->ifi_imcasts;
            n->omcasts    = d->ifi_omcasts;
            n->iqdrops    = d->ifi_iqdrops;
            n->noproto    = d->ifi_noproto;
            n->snd_drops  = (int32_t)data.ifmd_snd_drops;
        }
        count++;
    }

    if_freenameindex(names);
    return count;
}
