# GhostOperator — Adversarial Audit
**Method:** Full line-by-line review of `GhostOperator.huff` against all README, MANIFESTO, EIP712_GUIDE, and prior audit-report claims.  
**Auditor:** Independent (Claude, claude-sonnet-4-6)  
**Date:** 2026-06-15  
**Verdict summary:** The EIP-712 authorization layer is correctly implemented. The execution layer, permissions enforcement, reputation system, and bounty system are either not implemented or broken in production.

---

## Typehash Verification (independently recomputed)

All four precomputed constants are cryptographically correct:

| Constant | Claimed | Verified |
|---|---|---|
| `DOMAIN_TYPEHASH` | `0x8b73c3c6...` | ✅ |
| `AGENT_PERMIT_TYPEHASH` | `0x35ca65fc...` | ✅ |
| `NAME_HASH` (keccak256("GhostOperator")) | `0x4d0c6bc1...` | ✅ |
| `VERSION_HASH` (keccak256("1")) | `0xc89efdaa...` | ✅ |

---

## What Is Correct (confirmed, with stack traces)

### 1. EIP-712 struct hash construction

The struct hash is built in `mem[0x00..0xdf]`:

```
mem[0x00] = AGENT_PERMIT_TYPEHASH
mem[0x20] = agent         (calldataload 0x04)
mem[0x40] = permissions   (calldataload 0x24)
mem[0x60] = expiry        (calldataload 0x44)
mem[0x80] = nonce         (from storage, swap1 0x80 mstore)
mem[0xa0] = maxCalls      (calldataload 0x64)
mem[0xc0] = bounty        (calldataload 0x84)
keccak256(mem[0x00..0xdf])  →  structHash
```

Field ordering matches the typehash string exactly. No field is swapped or omitted. ✅

### 2. EIP-712 digest construction

```
mem[0x100..0x101] = "\x19\x01"   (0x1901 << 0xf0)
mem[0x102..0x121] = domainSep    (32 bytes, no overlap)
mem[0x122..0x141] = structHash   (32 bytes)
keccak256(mem[0x100..0x142])   →  digest  (0x42 = 66 bytes)
```

The 30 bytes of trailing zeros from the first `mstore` are immediately overwritten by `domainSep`. No corruption. ✅

### 3. ecrecover layout

The precompile (0x01) receives:

| Offset | Field | Calldata source |
|---|---|---|
| 0x100 | hash (digest) | stack |
| 0x120 | v | calldataload 0xe4 |
| 0x140 | r | calldataload 0xa4 |
| 0x160 | s | calldataload 0xc4 |

`staticcall(gas, 0x01, 0x100, 0x80, 0x100, 0x20)` — 128 bytes in, 32 bytes out at 0x100. Order is `[hash, v, r, s]` which is exactly what the ecrecover precompile requires. ✅

Calldata parameter order in the ABI:  
`authorize(address agent, bytes32 permissions, uint256 expiry, uint256 maxCalls, uint256 bounty, bytes32 r, bytes32 s, uint8 v)`  
Maps correctly to offsets 0xa4 (r), 0xc4 (s), 0xe4 (v). ✅

### 4. Auth slot consistency

All five functions that touch the auth struct compute the slot identically:

- `authorize`: `keccak256(caller || agent)` (inline, mem[0x00]=caller, mem[0x20]=agent)
- `execute`: `keccak256(principal || caller)` (principal from calldata, caller=agent) ✅ same result
- `revoke`, `isAuthorized`, `getAuth`: identical layout ✅

### 5. Nonce slot consistency

- `authorize`: `keccak256(caller || NONCE_SLOT)` (inline)
- `nonces()`: `HASH_PAIR()` with [principal, NONCE_SLOT] → `keccak256(principal || NONCE_SLOT)` ✅
- `revokeAll`: `HASH_PAIR()` with [caller, NONCE_SLOT]` → `keccak256(caller || NONCE_SLOT)` ✅

All three compute the same mapping. No drift.

### 6. Six-slot auth struct storage

Written correctly in sequence: permissions(+0), expiry(+1), maxCalls(+2), bounty(+3), usedCalls=0(+4), revoked=0(+5). On re-authorize, `usedCalls` is reset to zero and `revoked` is cleared. ✅

### 7. Selector dispatch

Uses `dup1` to load selector once, then compares via `__FUNC_SIG()` computed at compile time. All 8 selectors covered. No hardcoded hex. ✅

### 8. Expiry checks (authorize and execute)

`authorize`: `dup1 timestamp gt auth_fail jumpi` — reverts when `timestamp > expiry`. ✅  
`execute`: `dup1 timestamp gt expired_fail jumpi` — same logic. ✅  
Both directions are correct (not inverted).

### 9. Event emission

All three events (`AgentAuthorized`, `AgentRevoked`, `AgentExecuted`) are emitted with correct indexed topics and data layouts. Stack traces confirm the field order matches the event signatures. ✅

---

## Bugs and False Claims

### CRITICAL-1 — `execute()` doesn't actually execute anything

**README claims:**
> "Every time Bob does a swap, the contract checks... If all checks pass: ALLOWED. Bob does the trade."
> "Give Bob exactly what he needs... Instantly"

**Reality:**

```
execute(address principal)
```

The function signature takes only a `principal` address. It validates the authorization and increments `usedCalls`, then emits `AgentExecuted` and returns `true`. **It never makes an external call to any target contract.** There is no `target` address, no `bytes calldata data`, no selector forwarding, no Uniswap call. Nothing is "executed" except a permission check.

The comment in the code admits this explicitly:

```
// execute(address principal, address target, bytes calldata data)
// Simplified: execute(address principal)
// For testability, we'll use: execute(address principal)
```

GhostOperator v1.0 is an **authorization oracle**, not a delegation execution engine. The entire narrative of "agents doing swaps on your behalf" is fiction relative to this code.

**Impact:** Core product claim is unimplemented.

---

### CRITICAL-2 — Permissions bitmap is never enforced

**README claims:**
> "permissions (bytes32) — bitmap of allowed selectors"
> "Swap tokens (only)"
> "gives BobTheRobot permission to do exactly 3 swaps on Uniswap"

**Reality:**

The `permissions` field is stored in `authSlot+0` and emitted in `AgentAuthorized`. It is **never read back inside `execute()`**. There is no bitmap check, no selector check, no comparison against any allowed operation. An authorized agent can call `execute()` as many times as `maxCalls` allows, regardless of what the permissions bitmap contains.

Permissions = a storage-occupying decoration with no enforcement.

**Impact:** The primary security guarantee ("scoped permissions") is not implemented.

---

### CRITICAL-3 — ERC-8004 reputation hook does not exist

**README claims:**
> "GhostOperator can feed data into ERC-8004 reputation registries. This means other protocols can track which agents are 'good' based on their behavior."

**MANIFESTO claims:**
> "ERC-8004 reputation hooks"

**Reality:**

There is zero code related to ERC-8004 anywhere in the repository. No interface, no external call, no registry address, no hook. This feature was announced but not built.

**Impact:** A named feature in the README and MANIFESTO is vaporware.

---

### CRITICAL-4 — Bounty system cannot work in production

**README claims:**
> "Contract sends Bob his ETH reward"
> "No manual transfers. No delays."

**Reality:**

Two compounding problems:

**Problem A — Contract cannot receive ETH.** The `MAIN()` dispatcher starts with:
```
0x04 calldatasize lt no_data jumpi
```
If `calldatasize < 4` (which includes a plain ETH send with no calldata), it immediately reverts. There is no `receive()` equivalent, no `fallback()`, no payable function. The contract cannot accumulate ETH for bounties.

**Problem B — Transfer failures are silently swallowed.**

```huff
0x00 0x00 0x00 0x00 dup5 caller gas call
pop    // ← drop call success flag
```

The return value of the ETH transfer `CALL` is immediately `pop`-ped. If the transfer fails (contract has 0 ETH, which it always will in production), `execute()` still returns `true`, still emits `AgentExecuted` with `gasRefundClaimed=bounty`, and the agent gets nothing. Silent failure.

In tests this works only because Foundry's `vm.deal()` forcibly injects ETH into the contract, bypassing the lack of a payable fallback.

**Impact:** The bounty system is completely non-functional in any real deployment.

---

### MEDIUM-1 — `isAuthorized()` does not check `usedCalls` vs `maxCalls`

```huff
do_is_authorized:
    // Checks: revoked (slot+5), expiry (slot+1)
    // Does NOT check: usedCalls (slot+4) vs maxCalls (slot+2)
```

An agent who has consumed all their `maxCalls` will have `isAuthorized()` return `true`, but `execute()` will revert with `MaxCallsReached`. Any external caller (a frontend, another contract) relying on `isAuthorized()` as a pre-flight check gets an incorrect answer.

**Impact:** Off-chain and on-chain callers will be misled about whether an agent can actually execute.

---

### MEDIUM-2 — `revokeAll()` does not stop already-authorized agents

**README claims:**
> "At ANY TIME, you can revoke Bob's permissions. Even if Bob is in the middle of something. You just say 'NOPE' and he stops working immediately."

**Reality:**

`revokeAll()` only increments the caller's nonce:

```huff
do_revoke_all:
    // Increment nonce for caller (invalidates all existing signatures)
    caller [NONCE_SLOT] swap1 HASH_PAIR()
    dup1 sload
    0x01 add
    swap1 sstore
```

This invalidates any **unsubmitted** signed permits (off-chain signatures that haven't been submitted to `authorize()` yet). It does **not** touch any auth struct in storage. Any agent that was already authorized via `authorize()` has their auth struct intact and can still call `execute()` successfully after `revokeAll()`.

The test suite even acknowledges this:
```solidity
// Note: revokeAll increments nonce but doesn't actually clear auth struct
// The old auth is still "valid" in storage.
```

To actually stop an already-authorized agent, you must call `revoke(agent)` per-agent. `revokeAll()` is not a kill switch for active authorizations.

**Impact:** The "instant emergency stop" narrative is misleading. The correct per-agent `revoke()` works fine; the `revokeAll()` description in the README overclaims what it does.

---

### LOW-1 — Storage slot collision at precompile addresses (edge case)

The nonce mapping slot for a principal is `keccak256(principal || NONCE_SLOT)` where `NONCE_SLOT = 0x01`.

The auth struct base slot for `(principal, agent)` is `keccak256(principal || agent)`.

If `agent = address(0x0000000000000000000000000000000000000001)` (the ecrecover precompile), then:
```
auth_slot(principal, address(1)) == nonce_slot(principal)
```

The two slots are the same. In `authorize()`, the nonce is incremented first (to 1), then the auth struct is written. Auth struct field +0 (permissions) is stored at the nonce slot, overwriting the nonce with the permissions value. If permissions is `0`, the nonce resets to 0, re-enabling replay of the same signature.

In practice, address(1) will never call `execute()` (it's a precompile), but any principal who authorizes address(1) as an agent has inadvertently corrupted their own nonce counter. The zero-agent check (`iszero auth_fail jumpi`) blocks address(0) but not address(1).

**Impact:** Low exploitability in practice. Authorizing any address in the range `address(0x01)..address(0xFF)` where the address equals `NONCE_SLOT` (currently only `0x01`) would corrupt nonce storage.

---

### LOW-2 — `AUTH_SLOT()` macro is dead code

```huff
#define macro AUTH_SLOT() = takes(2) returns(1) {
    0x00 mstore
    0x20 mstore
    0x40 0x00 sha3
}
```

This macro is defined but never invoked. All auth slot computations are inlined directly. No functional impact, but it will generate a compiler warning and is misleading to readers.

---

## Claim-by-Claim Scorecard

| README / MANIFESTO Claim | Verdict | Notes |
|---|---|---|
| EIP-712 signature verification | ✅ CORRECT | End-to-end verified |
| "Can't be forged" | ✅ CORRECT | ecrecover + nonce replay protection works |
| "Can't be changed" | ✅ CORRECT | Blockchain immutability |
| Per-agent `revoke()` is instant | ✅ CORRECT | Sets `revoked=1`, checked first in execute |
| Nonce replay protection | ✅ CORRECT | Monotonically incremented per-principal |
| Gas dispatch (single selector load) | ✅ CORRECT | `dup1` pattern, no repeated calldataload |
| All typehashes precomputed correctly | ✅ CORRECT | Independently verified |
| `revokeAll()` stops all active agents instantly | ❌ FALSE | Only invalidates unsubmitted signatures |
| Permission bitmaps enforce allowed selectors | ❌ FALSE | Stored but never checked in execute() |
| Agents execute actions on-chain (trades, swaps) | ❌ FALSE | execute() does no call forwarding |
| ERC-8004 reputation hook | ❌ FALSE | Zero code exists |
| Bounty payment system | ❌ FALSE | Contract can't hold ETH; failures silently ignored |
| `isAuthorized()` accurately reflects executability | ⚠️ INCOMPLETE | Misses maxCalls exhaustion check |
| "Audited thoroughly" | ⚠️ SELF-AUDIT | The prior audit is by the same author, not independent |

---

## What GhostOperator Actually Is

Stripping the narrative: GhostOperator v1.0 is a correct, gas-efficient **EIP-712 permit registry** with:

- Per-`(principal, agent)` authorization structs stored in a collision-free mapping
- Time-bounded, call-counted permits with instant per-agent revocation
- Full EIP-712 typed signature verification (correctly implemented, all constants verified)
- Nonce-based replay protection

It is **not** an execution engine. It is not connected to any protocol. The `permissions` field has no enforcement. The bounty system does not work. The reputation hook does not exist.

The authorization layer is production-quality. The execution layer is absent.

---

## Recommendations

**Must-fix before any deployment claim:**

1. Implement `execute(address principal, address target, bytes4 selector, bytes calldata data)` with actual call forwarding and a permissions bitmap check against `selector`.
2. Add a `receive()` function or fund the contract from `authorize()` calls (principal deposits ETH on authorization) to make bounties viable.
3. Fix bounty failure handling — either revert on failed transfer or use a pull-payment pattern.
4. Fix `isAuthorized()` to also check `usedCalls < maxCalls`.
5. Clarify `revokeAll()` semantics in docs — it is not an active-agent kill switch.

**Nice to fix:**

6. Block `agent == address(1)` in `authorize()` to prevent nonce slot collision.
7. Remove the unused `AUTH_SLOT()` macro.
8. Either implement ERC-8004 integration or remove all mentions of it.

---

*The EIP-712 permit layer and the Huff implementation craft are genuine. The execution machinery it was supposed to drive has not been built yet. Ship the permit layer for what it is; don't claim the rest until the code exists.*
