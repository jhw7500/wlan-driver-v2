# NXP mwifiex 0396cfb Upstream Port Design

**Status:** Approved for execution by the user's repeated “둘다” direction.

## Objective

Port the NXP `mwifiex` upstream history after
`0396cfb38ad73a3d587cd0f8c139b47801e70891` through
`2e481212d262758cbd4d0fc7ea95a2ad5f704bc3` onto the local product tree,
while preserving intentional local behavior and removing duplicate or stale
conflict resolutions.

## Fixed inputs

- Local integration parent: `main` at `ce179fcc8a82f4ce41e70ffadc65c966a7a1565d`
- Upstream base: `0396cfb38ad73a3d587cd0f8c139b47801e70891`
- Upstream target: `upstream/lf-6.18.20_2.0.0` at
  `2e481212d262758cbd4d0fc7ea95a2ad5f704bc3`
- Upstream range size: 40 commits
- Clean integration branch: `port/upstream-61820-0396-clean`
- The earlier `port/upstream-61820-0396` branch is retained as forensic
  evidence. Its repeated cherry-pick history is not an integration source.

## Integration architecture

Use one non-fast-forward merge with `main` and the exact upstream target as
parents. This preserves both histories and prevents another replay of the same
release snapshots. Resolve conflicts by behavior, not by choosing an entire
side:

1. Accept upstream data structures, kernel compatibility updates, release
   identifiers, chipset support, and recovery fixes by default.
2. Retain local bridge runtime switching, bridge reset/suspend coordination,
   management-frame diagnostics, VHT/HE policy, and power-control fixes.
3. Remove duplicated functions and duplicated release blocks.
4. Keep mirrored MLAN ioctl headers byte-for-byte identical.
5. Do not claim hardware behavior from compile-only evidence.

## Explicit compatibility decisions

### Antenna configuration and NSS intent

Upstream uses the four-word `antcfg` response for Tx/Rx plus 6 GHz Tx/Rx.
The local tree used the same third word for `user_htstream`. Reusing the same
slot would silently corrupt one side.

The merged driver therefore keeps the upstream `antcfg` response unchanged
and adds a narrowly scoped private query, `antcfgnss`, returning only
`user_htstream`. The bundled `mlanutl` uses that query when displaying the
local NSS limit. The internal `mlan_ds_ant_cfg` carries both upstream 6 GHz
fields and the local NSS field.

### Management-frame metadata

The merged event prefix is four bytes:

- byte 0: upstream band configuration
- byte 1: upstream channel number
- byte 2: local RX SNR
- byte 3: local RX noise floor

The 802.11 management payload remains at offset four. This preserves the
upstream frequency calculation and the local management dump RSSI metadata.

### Runtime bridge

`moal_bridge.c` is a built object, not a parked source file. All local
init/deinit, RX/TX fast path, firmware reload, PCIe/SDIO reset, and suspend/
resume hooks must remain reachable after conflict resolution.

## Validation contract

The port is acceptable only when all of the following are evidenced:

- the exact upstream target is an ancestor of the merge result;
- no merge markers, duplicate function definitions, or diff whitespace errors;
- `mlan/mlan_ioctl.h` and `mlinux/mlan_ioctl.h` are identical;
- bridge static checks and runtime-switch shell QA pass;
- the out-of-tree driver builds with installed Linux 6.8 headers;
- `mapp/mlanutl` builds;
- final diff review classifies every remaining upstream divergence;
- hardware-only USB/PCIe/SDIO, suspend/resume, AP/STA, and firmware-recovery
  scenarios are listed as required target validation rather than reported as
  passed.
