/* Host unit test for the moal bridge loop-guard slot logic (#117).
 * Compiles mlinux/moal_bridge_loopguard.h with a tiny userspace shim; the
 * kernel wrapper (hash from skb, jiffies, counters) is exercised on the board.
 * Run: bash scripts/tests/loopguard_host_test.sh */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef uint32_t u32;
typedef uint64_t u64;
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, v) ((x) = (v))
#include "../../mlinux/moal_bridge_loopguard.h"

static int fails;
#define EXPECT(cond, name) do { if (cond) printf("PASS loopguard: %s\n", name); \
	else { printf("FAIL loopguard: %s\n", name); fails++; } } while (0)

int main(void)
{
	struct moal_bridge_loopguard lg = { { 0 } };
	const u32 win = 50;	/* window in ticks */
	enum moal_br_loop_verdict v1, v2, v3, v4;

	/* 1. three identical frames inside the window: pass, dup, drop */
	v1 = moal_bridge_loopguard_observe(&lg, 0x11111111u, 7, 1000, win);
	v2 = moal_bridge_loopguard_observe(&lg, 0x11111111u, 7, 1004, win);
	v3 = moal_bridge_loopguard_observe(&lg, 0x11111111u, 7, 1008, win);
	EXPECT(v1 == MOAL_BR_LOOP_PASS && v2 == MOAL_BR_LOOP_DUP && v3 == MOAL_BR_LOOP_DROP,
	       "3 repeats within the window -> pass, dup, drop (K=3)");
	v4 = moal_bridge_loopguard_observe(&lg, 0x11111111u, 7, 1012, win);
	EXPECT(v4 == MOAL_BR_LOOP_DROP, "4th repeat still dropped");

	/* 2. a different frame colliding on the same slot starts over */
	v1 = moal_bridge_loopguard_observe(&lg, 0x22222222u, 7, 1013, win);
	v2 = moal_bridge_loopguard_observe(&lg, 0x22222222u, 7, 1014, win);
	EXPECT(v1 == MOAL_BR_LOOP_PASS && v2 == MOAL_BR_LOOP_DUP,
	       "slot collision with another tag restarts the count (no false drop)");

	/* 3. window is fixed from the first sighting: repeats after expiry pass */
	v1 = moal_bridge_loopguard_observe(&lg, 0x33333333u, 9, 2000, win);
	v2 = moal_bridge_loopguard_observe(&lg, 0x33333333u, 9, 2000 + win, win);
	v3 = moal_bridge_loopguard_observe(&lg, 0x33333333u, 9, 2000 + win + 1, win);
	EXPECT(v1 == MOAL_BR_LOOP_PASS && v2 == MOAL_BR_LOOP_DUP && v3 == MOAL_BR_LOOP_PASS,
	       "repeat at the window edge counts, repeat past the window restarts");

	/* 4. 24-bit tick wrap-around inside the window still matches */
	v1 = moal_bridge_loopguard_observe(&lg, 0x44444444u, 3, 0xfffffeu, win);
	v2 = moal_bridge_loopguard_observe(&lg, 0x44444444u, 3, 0x000001u, win);
	EXPECT(v1 == MOAL_BR_LOOP_PASS && v2 == MOAL_BR_LOOP_DUP, "tick wrap-around within window matches");

	/* 5. counter saturates without wrapping back to pass */
	{
		int i, all_drop = 1;
		for (i = 0; i < 300; i++)
			if (moal_bridge_loopguard_observe(&lg, 0x55555555u, 5, 5000 + (i % 10), win) == MOAL_BR_LOOP_PASS && i >= 2)
				all_drop = 0;
		EXPECT(all_drop, "300 repeats never wrap back to pass");
	}

	/* 6. slot index is masked to the table */
	v1 = moal_bridge_loopguard_observe(&lg, 0x66666666u, MOAL_BR_LOOP_SLOTS + 1, 6000, win);
	v2 = moal_bridge_loopguard_observe(&lg, 0x66666666u, 1, 6001, win);
	EXPECT(v1 == MOAL_BR_LOOP_PASS && v2 == MOAL_BR_LOOP_DUP, "index beyond the table wraps onto the same slot");

	printf("loopguard host test: %d failure(s)\n", fails);
	return fails ? 1 : 0;
}
