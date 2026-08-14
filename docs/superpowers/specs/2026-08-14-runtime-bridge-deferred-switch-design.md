# Runtime Bridge Deferred Interface Switch Design

**Date:** 2026-08-14  
**Status:** Approved for implementation planning

## 1. Purpose

Allow an application to request a runtime bridge interface switch before the
target MOAL STA interface is operational, without interrupting the currently
working bridge. The existing `bridge_iface` write remains the only control
operation. With `bridge_runtime_deferred=1`, a request for a disconnected or
administratively down target becomes a pending request and is applied
automatically when that target is ready; default-off mode retains rejection.

This feature does not change association policy, connect a WLAN, or validate
end-to-end traffic over the selected AP. The separately observed mlan1
data-plane failure after successful kernel transmit remains outside this scope.

## 2. Compatibility and Configuration

Add a global boolean parameter:

```text
bridge_runtime_deferred=0
```

- `0` is the default and preserves the current synchronous contract. A target
  that is down, disconnected, or has no carrier is rejected.
- `1` enables deferred requests. It is accepted as an `insmod` argument and as
  a `mod_para` configuration key. As with `bridge_runtime_switch`, per-card
  configuration uses enable-only global aggregation: any successfully parsed
  block containing `1` enables it, while a block containing `0` cannot disable
  an enable selected by another block.
- Only exact, single-character `0` and `1` values after the exact key delimiter
  are accepted. Empty/sign-only/extended values on the exact key fail parsing
  with a diagnostic; a prefix-extended different key cannot select the policy.

`bridge_runtime_switch=1` remains required. Enabling deferred mode does not
enable runtime switching by itself.

## 3. User Interface

Applications continue to write only the existing parameter:

```sh
echo mlan0 > /sys/module/moal/parameters/bridge_iface
```

The driver resolves the request as follows:

1. If the target is operational, perform the existing synchronous switch; a
   successful return is strict ready completion.
2. If the target is structurally valid but down, disconnected, or has no
   carrier, retain the current bridge and record the target as pending. This
   successful return is deferred acceptance, not switch completion.
3. If the target is absent, is not a MOAL STA, is unregistering, or belongs to
   an unavailable/resetting handle, reject the write without changing either
   active or pending state.

The existing `bridge_iface` getter continues to report the actual active bridge
owner. Add the read-only module parameter:

```text
/sys/module/moal/parameters/bridge_pending_iface
```

It reports the pending interface name followed by a newline, or an empty line
when no request is pending. Bridge stats also expose:

```text
iface=mlan1 pending_iface=mlan0 pending_state=waiting
```

Stats state becomes `none` after completion or cancellation and uses
`pending_iface=none pending_state=none`; the parameter getter's no-request wire
value remains an empty line. The getter never reports a pending target as active.

## 4. State Machine

The states are:

- **Active only:** an active bridge exists and there is no pending request.
- **Waiting:** the active bridge remains unchanged and one structurally valid
  target name is pending.
- **Switching:** a worker has observed the pending target as operational and is
  attempting the existing transactional switch.

Transitions:

```text
active=mlan1, pending=none
    -- write mlan0 while mlan0 is down -->
active=mlan1, pending=mlan0 (waiting)
    -- mlan0 becomes operational -->
active=mlan0, pending=none
```

Rules:

- Writing a new structurally valid, link-not-ready target replaces the prior
  pending request. A ready target instead runs the immediate transaction and
  consumes the old pending request on successful completion.
- Writing the current active interface cancels an actually existing pending
  request and is a successful no-op even through transient readiness. With no
  pending request, the same-target no-op still requires the legacy target and
  peer readiness/identity checks.
- A successful immediate switch clears a pending request.
- A failed immediate switch leaves the previously committed pending request
  unchanged.
- A pending request has no timeout. It remains until it completes, is replaced,
  is explicitly cancelled by writing the active interface, or the target is
  unregistered.
- An init_net target unregister cancels the exact matching pending name. A
  rename cancels only if the pending old name has disappeared from init_net
  under notifier-held RTNL; unrelated and cross-netns events are ignored. A
  later interface reusing the same name does not inherit the cancelled request.

## 5. Readiness and Safety Boundaries

Deferred mode relaxes only operational link predicates:

- `netif_running(target)`
- `priv->media_connected`
- `netif_carrier_ok(target)`

It does not relax structural or lifetime predicates. A request still requires:

- a registered and present MOAL STA netdev;
- a live handle and matching `priv`/BSS identity;
- hardware ready and no surprise removal, firmware reset/reload, or terminal
  driver error;
- a live registered bridge peer and an existing active bridge owner.

The pending state stores an interface name and monotonically increasing request
generation, not a long-lived raw handle, `priv`, or netdev pointer. Every worker
attempt re-resolves the name and validates identities while holding
`AddRemoveCardSem`. The existing bridge lifecycle mutex serializes request
updates and actual owner changes.

## 6. Event and Worker Model

No periodic polling is introduced.

Netdev `UP`/`CHANGE`/carrier notification for a matching pending name schedules
a module-lifetime work item. The notifier does not perform a switch directly,
because switch teardown and initialization sleep and acquire RTNL and lifecycle
locks. The worker:

1. snapshots the pending name and generation;
2. acquires the existing card/lifecycle serialization;
3. re-resolves and fully validates the target;
4. leaves the request waiting on transient not-ready or reset/busy results;
5. invokes the existing transactional switch only when operational;
6. clears pending state only if the generation still matches.

The generation check prevents an old worker from clearing or applying a newer
application request. A notifier-admission boolean is protected by the same
pending-state spinlock: init enables admission before publishing runtime
control readiness, while teardown clears readiness, disables admission under
that lock, and only then cancels and drains the work item. This closes the
read-gate-then-queue race in which a notifier could otherwise enqueue work just
after `cancel_work_sync()` returned. Pending state is cleared before runtime
control data is destroyed.

Pending is retained only across reset paths that preserve netdev identity.
Before destructive interface recreation, the reset path synchronously
invalidates matching pending identity while old handle/priv/netdev names are
still pinned. Terminal reset/reload failure or other terminal no-owner teardown
clears all pending state; a same-name recreated netdev cannot inherit it.

## 7. Failure Semantics and Logging

- Registering a deferred request returns success because the request is durably
  accepted, not because forwarding has already moved.
- Until automatic completion, `bridge_iface` remains the old owner and its
  forwarding remains active.
- If the automatic transaction fails after becoming ready, the existing
  rollback contract keeps or restores the old owner. Transient failures retain
  the pending request for a later readiness event; permanent identity loss
  cancels it.
- No asynchronous error is returned to the original writer. Outcomes are
  observable through `bridge_pending_iface`, bridge stats/counters, and dmesg.

Required logs cover request registration, replacement, cancellation,
readiness-triggered attempt, completion, transient failure, and permanent
cancellation. They include target name, generation, and errno where applicable.

## 8. Validation

Host/static validation must prove:

- default-off compatibility and strict 0/1 parsing;
- no raw target pointer retained in pending state;
- notifier only schedules work and never executes lifecycle teardown;
- generation comparison before clearing pending state;
- worker cancellation/drain before runtime-control teardown;
- active getter and pending getter report distinct state;
- existing immediate switch and rollback checks remain intact.

Target validation must cover:

1. Deferred mode off: down/disconnected targets retain current rejection.
2. Deferred mode on: writing a down target succeeds, active owner and traffic
   remain on the old interface, and pending reports the target.
3. Bringing the target up and associating it produces exactly one automatic
   switch and clears pending state.
4. Replacement and active-name cancellation behave deterministically. True
   replacement requires a third registered, present, link-not-ready STA distinct
   from active and pending; a ready third target is an immediate completion.
   Two-STA hardware records replacement as NOT RUN/UNSUPPORTED.
5. Target unregister cancels pending without a stale switch after name reuse.
6. Unrelated init_net rename and cross-netns same-name events leave pending
   unchanged, while exact target identity loss cancels it before name reuse.
7. Destructive reset success invalidates a request for a recreated target and
   terminal destructive failure leaves no unfulfillable pending request;
   identity-preserving reset may retain it.
8. Concurrent writers, reset/reload, remove, and module unload do not produce
   stale work, UAF, lockdep reports, or an incorrect owner.
9. Existing synchronous successful switch and rollback fault cases still pass.

Builds are run only after code freeze: one i.MX93 build, followed by one final
i.MX8 build, matching the project validation policy.

## 9. Non-goals

- Selecting or associating an AP on behalf of userspace.
- Timing out pending requests.
- Multiple pending targets or priority selection.
- RSSI-based automatic target selection.
- Treating link readiness as proof of end-to-end data-plane reachability.
- Fixing the independently observed same-MAC/multi-BSSID mlan1 return-path
  failure.
