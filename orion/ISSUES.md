# Issues — known pitfalls, scope limits, upstream gaps

Living list. Each entry names a class of bug we or a consumer has
already hit (or will); knowing about them up front saves half a day
of debugging. When a pitfall turns into a fix inside orion, move it
to a changelog entry and delete from here.

Entries are not in priority order — use the table of contents.

- [Pitfalls in consumer code](#pitfalls-in-consumer-code)
  - [Role-binding semantics: append vs. replace](#role-binding-semantics-append-vs-replace)
  - [Artifact bytecode prefix](#artifact-bytecode-prefix)
  - [Empty-data reverts](#empty-data-reverts)
  - [Fresh deploys have zero price state](#fresh-deploys-have-zero-price-state)
  - [Infinite approvals hide bugs](#infinite-approvals-hide-bugs)
  - [Label collisions across concurrent runs](#label-collisions-across-concurrent-runs)
  - [EIP-1559 vs. legacy gas fields](#eip-1559-vs-legacy-gas-fields)
  - [Stale anvil / wrong chain](#stale-anvil--wrong-chain)
- [Scope limits](#scope-limits)
- [Upstream gaps](#upstream-gaps)

## Pitfalls in consumer code

### Role-binding semantics: append vs. replace

Most role-binding calls (`stake`, `deposit`, `provide`, `add*`)
*append* to an existing position rather than creating a new one. The
function name rarely makes this clear; you have to read the storage
write.

**Canonical example — Swarm `StakeRegistry.manageStake`:**

```solidity
updatedPotentialStake = stakes[msg.sender].potentialStake + _addAmount;
stakes[msg.sender] = Stake({ ..., potentialStake: updatedPotentialStake });
```

There is exactly one `stakes[msg.sender]` slot. `_addAmount` is added
to whatever is already there. The `_setNonce` parameter rotates the
overlay hash (a staker can change neighbourhoods without unstaking)
but does *not* produce a second stake record.

**How this bites:** deterministic key derivation (`keccak256("orion:"
+ label)` → address) means re-runs use the *same* address.
`potentialStake` silently accumulates. After four runs at 10 BZZ each,
your "10 BZZ staker" is a 40 BZZ staker from the protocol's point of
view. Stake-weighted elections, economic simulations, anything
sensitive to per-run amounts will produce numbers matching accumulated
stake, not the per-run parameter you think you set.

**Remediation:**
- Include a run identifier in the label: `elect-0-r{block_number}`,
  so each run derives a fresh address.
- Or wipe the chain between runs (`rm -rf state/` + fresh
  `orion up`).
- Or `withdrawFromStake()` before re-provisioning (recovers only the
  surplus, not committed portion).

**Generalisation:** before wiring any new protocol into orion, for
each role-binding function, read the storage write and confirm
whether it appends or replaces. `set*` typically replaces; `manage*`
is ambiguous; everything else usually appends.

### Artifact bytecode prefix

Some Hardhat "artifacts" are not deployable contract bytecode — they
are bridge references or upgrade proxies masquerading as contracts.
Always inspect the first few bytes of `bytecode`:

- `0x608060...` — standard Solidity init bytecode. Deploy it.
- `0x000500...` or other non-`0x6080` prefix — not EVM init. Deploy
  will "succeed" (tx mined, address produced), but `cast code
  <address>` returns empty. Use a different artifact (e.g. the
  testnet `TestToken` instead of the mainnet `Token`).

Orion's artifact loader should refuse to submit non-`6080` bytecode
with a clear error. If you see "deployment succeeded but cast code is
0x", check the prefix.

### Empty-data reverts

Transactions that revert with zero revert data almost always mean a
`require()` without a custom error was hit. Top three causes, in
order:

1. Missing AccessControl role grant (the contract is reading
   `hasRole(ROLE, msg.sender)` and getting false).
2. Missing `approve()` before a `transferFrom` inside the call.
3. Insufficient balance (native or token) for what the call tries to
   transfer.

If the revert happens at `estimate_gas` (before submit), it's
usually one of those three. If it happens *after* submit, it's more
often a stateful check (e.g. "can't manageStake twice with the same
nonce in the same round").

### Fresh deploys have zero price state

Deploying mainnet bytecode gives you the right *code*, not the right
*state*. Prices, oracles, cumulative fees — all zero on a fresh
constellation. For Swarm specifically, `PostageStamp.lastPrice = 0`
means the redistribution pot is empty and every round pays zero.

Fix: prime. `orion prime set-postage-price --wei-per-chunkblock
44445` uses `anvil_impersonateAccount` on the `PriceOracle` address
(holder of `PRICE_ORACLE_ROLE`) to call `setPrice(...)` without
touching the deployed role table.

Other protocols need their own priming — think Compound's
`borrowRateMantissa`, Uniswap's factory fee, a vault's target APY.
The generic move is always: impersonate the role-holder, call the
privileged setter, release the impersonation.

### Infinite approvals hide bugs

In production code, `approve(spender, type(uint256).max)` is fine.
In test harnesses it masks bugs. If `manageStake` pulls more than it
should, an infinite approval lets the bug pass silently; an
exact-amount approval reverts and surfaces the problem.

Orion should always approve the exact amount needed and reset
allowances to zero after the bound call. Consumers that want
long-lived approvals can opt in explicitly.

### Label collisions across concurrent runs

Deterministic key derivation (`keccak256("orion:" + label)`) is the
feature that makes debugging possible across runs. It is also the
thing that makes two concurrent orion instances with the same label
fight over the same address on-chain. Consequences:

- Nonce races: both runs try to send from the same address with the
  same nonce; one succeeds, the other fails with `nonce too low`.
- State-shape skew: run A provisions `op-0` with 1 overlay, run B
  provisions `op-0` with 256, and then both read
  `participants.json` from their own local filesystem while the
  on-chain state reflects only the most recent call.

Fix: include a run-id in labels when running concurrent harnesses
(`--label-prefix run-42` on every invocation).

### EIP-1559 vs. legacy gas fields

`web3.py`'s `build_transaction` auto-populates EIP-1559 fields
(`maxFeePerGas`, `maxPriorityFeePerGas`). Mixing in a legacy
`gasPrice` triggers `TypeError: Unknown kwargs: ['gasPrice']`. Pick
a lane — if you want legacy, clear the 1559 fields first:

```python
tx = contract.functions.foo().build_transaction({"from": addr})
tx.pop("maxFeePerGas", None)
tx.pop("maxPriorityFeePerGas", None)
tx["gasPrice"] = w3.eth.gas_price
```

Usually easier to stay on EIP-1559 throughout.

### Stale anvil / wrong chain

"`contract does not have any code`" at an address you deployed to
usually means you're connected to a different anvil than the one
holding the state. Check:

- `state/chain.json:pid` — is that process still alive? (`ps -p
  $PID`)
- `state/chain.json:chain_id` — matches `w3.eth.chain_id`?
- `cast code <addr>` — if empty, either the deploy constructor
  returned `0x` (bad artifact; see above) or you're on the wrong
  chain.

Orion should reload `state/chain.json` on every invocation and fail
fast if the chain id or a known contract's code length doesn't
match.

## Scope limits

Things orion explicitly does *not* do, and probably never will:

- **Non-EVM chains.** The `Chain` abstraction is EVM-shaped (nonces,
  gas, OpenZeppelin AccessControl). Adding Solana / Cosmos /
  whatever would require a second backend and a different
  `constellation.py` — possible in principle, but scope creep.
- **libp2p / P2P networking.** See `../kabashira/` for retrieval,
  pullsync, hive. Orion is chain-side only.
- **Real honest-node reserves at TB scale.** Consumers that need
  such reserves build them — e.g. alectryon-harness uses synthetic
  in-memory reserves of a few thousand chunks.
- **Metrics / dashboards.** Orion emits state files and events;
  downstream consumers (alectryon-harness driver, future honest-node
  simulators) aggregate into JSONL/Prometheus/whatever.
- **Source-level contract instrumentation.** The pre-compiled
  bytecode approach means you can't edit contract source mid-harness.
  If a consumer needs instrumentation, it switches to `forge build`
  of the same commit — at the cost of losing the "byte-identical to
  mainnet" guarantee.
- **Cross-chain bridges, real price feeds, real gas markets.** The
  local anvil is a sandbox; anything cross-chain is a driver
  concern.

## Upstream gaps

Things *other* repos are missing that complicate orion's or its
consumers' lives. Tracked here so we can push fixes upstream when
the opportunity arises.

### kabashira: `bmt_merkle_path` missing

Kabashira exposes BMT hashing but not merkle-path construction. The
alectryon binary builds paths internally but doesn't emit them;
`alectryon-harness` currently ports the algorithm to Python
(`bmt.py`). Tracked in detail at
`../kabashira/ALECTRYON_HARNESS_GAPS.md`. Not orion's problem
directly — orion stops at the EVM boundary — but closing this gap is
what lets `alectryon-harness` delete `bmt.py` entirely and treat
kabashira as a black-box proof-emitter.

### kabashira: postage stamp signing

Kabashira's `SwarmSigner::sign` applies EIP-191 + keccak256, whereas
postage stamps need EIP-191 applied over a pre-hashed 32-byte
message. Also tracked at `../kabashira/ALECTRYON_HARNESS_GAPS.md`.
Same story: orion is unaffected, but a `sign_stamp` helper in
kabashira would let `alectryon-harness` delete `stamp.py`.

### `storage-incentives`: mainnet Token artifact is a bridge shim

The mainnet `Token.json` in
`vendor/storage-incentives/deployments/mainnet/` is a bridged-token
reference, not deployable Solidity. Use
`vendor/storage-incentives/deployments/testnet/TestToken.json`
instead. This is not a bug in anything we own; it's a fact of the
upstream repo layout. Orion's Swarm profile already defaults to
`TestToken` (see `src/orion/profiles/swarm.py`). If the artifact
loader is ever rewritten, preserve the "fall back to testnet/ for
TestToken" behaviour.

### Harness is mid-stage-3

`../alectryon-harness/README.md:35` has a status table: commit and
reveal land, claim reverts with empty logs. Suspect causes listed at
`README.md:272`. Once diagnosed, may surface another priming gap
(e.g. layer-3 transform salt requires a reveal phase that touches
`currentRevealRoundAnchor`). If the fix is protocol-generic, it
belongs in orion priming; if Technique-specific, in
alectryon-harness.
