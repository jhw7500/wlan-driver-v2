/** @file moal_bridge_loopguard.h
 *
 * @brief moal bridge loop guard (#117): per-direction duplicate suppression.
 *
 * Two bridge boards whose wired peers share one L2 segment and whose STAs join
 * the same ESS form a forwarding loop: the AP turns multicast into per-STA
 * unicast and both bridges forward it (w2p on one board, p2w on the other).
 * MAC-based rules cannot separate loop traffic from client traffic here: the
 * driver has no clone-mode flag and STA RX h_dest is always its own MAC.
 * Instead each direction remembers a hash of recently forwarded L2 unicast
 * frames (key: first 128 bytes plus frame length, hashed in moal_bridge.c;
 * bytes past 128 are not compared) and drops a frame whose key is seen
 * MOAL_BR_LOOP_K times within a fixed window that starts at the first
 * sighting. Group addresses are exempt, so broadcast/multicast forwarding is
 * untouched. A sustained stream of same-key frames passes MOAL_BR_LOOP_K-1
 * frames per window and loses the rest.
 *
 * This header holds only the slot logic so it can be unit-tested on the host
 * (scripts/tests/loopguard_host_test.sh); hashing the skb, reading jiffies and
 * bumping the stats counters live in moal_bridge.c.
 *
 * Lock-free: one slot is one u64 (tag:32 | tick:24 | cnt:8) accessed with
 * READ_ONCE/WRITE_ONCE from the w2p and p2w producers. A lost race between
 * the two directions cannot happen (they use separate tables); a lost race
 * between two frames of the same direction under-counts, it never drops a
 * frame that was not a repeat.
 *
 * Sweep: a slot keeps only 24 tick bits, so a slot left untouched for a whole
 * 2^24-tick period (4.66 h at HZ=1000) would alias back into its window and a
 * sparse same-key frame could be dropped. The table is therefore zeroed on the
 * first observation that comes MOAL_BR_LOOP_SWEEP_TICKS (half a period) or
 * more after the previous sweep; no slot is ever consulted when it is older
 * than that, so the masked elapsed time is always the true one. A loop that
 * straddles a sweep gets MOAL_BR_LOOP_K-1 extra frames through, once per sweep
 * interval.
 */

#ifndef _MOAL_BRIDGE_LOOPGUARD_H
#define _MOAL_BRIDGE_LOOPGUARD_H

#define MOAL_BR_LOOP_SLOTS 512 /* u64 slots per direction (4 KiB) */
#define MOAL_BR_LOOP_K 3 /* n-th identical frame within the window is dropped */
#define MOAL_BR_LOOP_TICK_MASK 0xffffffu
#define MOAL_BR_LOOP_CNT_MAX 0xffu
#define MOAL_BR_LOOP_SWEEP_TICKS (1u << 23) /* zero the table this often: half the tick period */

struct moal_bridge_loopguard {
	u64 slot[MOAL_BR_LOOP_SLOTS];
	u64 sweep_tick; /* full-width tick of the last sweep */
};

enum moal_br_loop_verdict {
	MOAL_BR_LOOP_PASS = 0, /* first sighting (or window expired / other tag) */
	MOAL_BR_LOOP_DUP = 1, /* second sighting within the window: count, forward */
	MOAL_BR_LOOP_DROP = 2, /* MOAL_BR_LOOP_K-th or later sighting: drop */
};

/**
 * moal_bridge_loopguard_sweep - forget every slot
 * @lg:  per-direction table
 * @now: current tick, full-width jiffies
 *
 * Lock-free like the slots: a producer writing concurrently may lose its slot,
 * which only under-counts.
 */
static inline void moal_bridge_loopguard_sweep(struct moal_bridge_loopguard *lg, u64 now)
{
	unsigned int i;

	WRITE_ONCE(lg->sweep_tick, now);
	for (i = 0; i < MOAL_BR_LOOP_SLOTS; i++)
		WRITE_ONCE(lg->slot[i], 0);
}

/**
 * moal_bridge_loopguard_observe - record one unicast frame and judge it
 * @lg:    per-direction table
 * @tag:   32-bit frame hash (identity of the frame bytes)
 * @idx:   slot index candidate; masked to the table size here
 * @now:   current tick, full-width jiffies; the slot keeps its low 24 bits and
 *         the sweep clock uses the full value
 * @win:   window length in ticks; the window is fixed from the first sighting
 *
 * The caller has already excluded group addresses and checked the runtime
 * switch, so this function only needs the hash and the clock.
 */
static inline enum moal_br_loop_verdict
moal_bridge_loopguard_observe(struct moal_bridge_loopguard *lg, u32 tag, u32 idx,
			      u64 now, u32 win)
{
	u64 *slot = &lg->slot[idx & (MOAL_BR_LOOP_SLOTS - 1)];
	u32 now24 = (u32)now & MOAL_BR_LOOP_TICK_MASK;
	u64 cur;
	u32 slot_tag, slot_tick, cnt;

	if (now - READ_ONCE(lg->sweep_tick) >= MOAL_BR_LOOP_SWEEP_TICKS)
		moal_bridge_loopguard_sweep(lg, now);
	cur = READ_ONCE(*slot);
	slot_tag = (u32)(cur >> 32);
	slot_tick = (u32)(cur >> 8) & MOAL_BR_LOOP_TICK_MASK;
	cnt = (u32)(cur & MOAL_BR_LOOP_CNT_MAX);
	if (cnt && slot_tag == tag &&
	    ((now24 - slot_tick) & MOAL_BR_LOOP_TICK_MASK) <= win) {
		if (cnt < MOAL_BR_LOOP_CNT_MAX)
			cnt++;
		WRITE_ONCE(*slot, ((u64)tag << 32) | ((u64)slot_tick << 8) | cnt);
		if (cnt >= MOAL_BR_LOOP_K)
			return MOAL_BR_LOOP_DROP;
		return MOAL_BR_LOOP_DUP;
	}
	WRITE_ONCE(*slot, ((u64)tag << 32) | ((u64)now24 << 8) | 1u);
	return MOAL_BR_LOOP_PASS;
}

#endif /* _MOAL_BRIDGE_LOOPGUARD_H */
