# Why Python, not just Foundry

The reasonable default assumption when you see this repo is: *"Isn't
Foundry enough? Why all the Python?"*

Short answer: **Foundry is right for most harnesses. It's not right
for this one — because this isn't a test, it's a driver.**

## What Foundry is good at

Foundry is a first-class toolchain for Solidity development:

- `forge build` — compile contracts.
- `forge test` — run Solidity-native unit tests, including fuzzing and
  invariant tests, with cheat codes for time/block manipulation.
- `forge script` — one-shot deploy and state-setup scripts, in Solidity.
- `anvil` — local EVM node.
- `cast` — ad-hoc RPC calls from the shell.

For the common case — "I wrote a contract, I want to test that it
behaves right" — Foundry alone is the right answer, and adding Python
is weight without benefit. Most harnesses should be `forge test`.

## Why this harness is different

This harness is not testing a contract in isolation. It drives a
multi-invocation interaction against mainnet-deployed bytecode. The
load-bearing reasons for Python split cleanly from the auxiliary
tools we happen to integrate.

### Load-bearing — things the harness structurally needs

These are the capabilities orion's substrate provides, and they are
the reason the harness can't collapse into a `forge script`:

1. **Deploy mainnet bytecode verbatim.** The contracts under test
   must be byte-identical to what's live on Gnosis Chain. `forge
   build` recompiles from source → different compiler version,
   different bytecode, no longer mainnet-identical. We read the
   Hardhat deploy artifacts shipped in
   `vendor/storage-incentives/deployments/mainnet/*.json` and submit
   their `bytecode` field as raw transactions.

2. **Spawn-or-attach chain lifecycle.** Every layer of the harness
   supports both patterns — spawn a fresh anvil we own, or attach to
   one an external driver already started. `forge script` is
   one-shot: run, broadcast, exit. We need the anvil to outlive any
   single invocation.

3. **State files across invocations.** `state/chain.json`,
   `state/deployment.json`, `state/participants.json` — each written
   atomically (tmp → rename), each re-readable by a different process.
   Lets you deploy once, then run many analyses against the same
   deployment; also lets state survive a crash.

4. **Priming via anvil impersonation.** A fresh mainnet-bytecode
   deployment has zero state — prices, oracle feeds, cumulative pools
   all start at 0. To make accrual realistic we impersonate the
   role-holder contract (e.g. `PriceOracle`) and call its privileged
   setter (`setPrice`) directly, without modifying the deployed role
   table. Expressed as a context manager:

   ```python
   with chain.impersonate(oracle_addr):
       postage.functions.setPrice(44_445).transact({"from": oracle_addr})
   ```

5. **Declarative multi-contract deploys with role wiring.** Our
   "constellation" is five contracts with strict topological order and
   four AccessControl role grants. Orion models this as a dataclass
   (`ContractSpec`, `RoleGrant`, `Ref`) so each profile is ~40 lines
   of declaration; the deployer walks that structure in any language.
   `forge script` can do this imperatively but the shape of "deploy a
   set of contracts as data" isn't well-served.

Each of those five points is a *chain-side* capability. Python isn't
special — Go, Rust, or TypeScript could host the same substrate. The
point is that Foundry alone doesn't.

### Auxiliary — tools we integrate, consumers can drop

These live in the *downstream consumer* (currently
`alectryon-harness/`), not in orion itself. Orion knows nothing about
them. A different consumer of orion could skip them entirely:

- **Shell-out to a Rust binary.** For the Alectryon Technique the
  harness shells out to `kabashira/target/release/alectryon` to
  fabricate BMT-hashed samples and inclusion proofs. Convenient in
  Python (`subprocess.run` + JSON parse), but it's an Alectryon-
  specific integration, not a reason orion uses Python.

- **Off-chain cryptographic signing.** Alectryon claims include
  three postage-stamp ECDSA signatures over
  `keccak256(chunk_addr ‖ batch_id ‖ index ‖ ts)`. Python has
  `eth_keys.sign_msg_hash(h)`. Same story: protocol-specific, lives
  in the consumer.

- **Phase-gated round loop.** The Redistribution contract has a
  152-block commit-reveal-claim cycle. Looping through many rounds
  with phase-sensitive work is a natural Python `while` loop, but
  again — this is the Alectryon driver, not orion. Orion doesn't know
  what a "round" is.

- **Statistical aggregation.** The election test runs 300 rounds,
  tallies outcomes, computes χ². This runs *against* orion's substrate
  but isn't part of it. Another consumer could write the same analysis
  in R or a notebook.

The distinction matters because it answers "what happens if I don't
care about Alectryon?" You keep orion's substrate; you throw away the
auxiliary layer. Orion's load-bearing reason for Python is the five
chain-side capabilities above — not the specific tools a particular
downstream happens to integrate.

## The architecture, in one picture

```
┌──────────────────────────────────────────────────────────────┐
│  Consumer driver (Python — alectryon-harness today)          │
│   AUXILIARY — specific to the protocol under test:           │
│    - phase-gated round loops                                 │
│    - Rust-binary shell-out                                   │
│    - protocol-specific signatures                            │
│    - statistical aggregation                                 │
├──────────────────────────────────────────────────────────────┤
│  Harness substrate (orion — this repo)                       │
│   LOAD-BEARING — what the harness structurally needs:        │
│    - Layer 1 (chain):          spawn/attach anvil, RPC       │
│    - Layer 2 (constellation):  deploy declared contracts     │
│    - Layer 3 (participants):   derive→fund→mint→approve→bind │
│    - priming:                  impersonation-based seeding   │
│    - state files across invocations                          │
├──────────────────────────────────────────────────────────────┤
│  Chain (anvil — Foundry subprocess)                          │
│   - runs mainnet bytecode on ephemeral state                 │
└──────────────────────────────────────────────────────────────┘
```

Each layer writes a state file the next layer consumes and is
independently wipeable. This isn't a Python design; it's what you'd
want in any language. Python just has the ecosystem (`web3.py`,
`eth-account`, `click`, `rich`, `dataclasses`) that makes each layer
short.

## When NOT to use Python

Drop to pure Foundry when any of:

- You're unit-testing contract logic in isolation.
- Your "test" is a deploy + a handful of state assertions.
- You compile from source and don't need mainnet-identical bytecode.
- You don't need state to persist across invocations.
- No privileged-impersonation priming is required.

If your harness looks like that, `forge test` + a deploy script is the
right answer. Adding Python is weight without benefit.

## When Python is the right answer

All of these pushed orion into Python for the substrate:

- Deploying bytecode you don't compile (mainnet-identical clones).
- Priming state that requires privileged impersonation sequences.
- State files that persist across invocations.
- Multi-contract deploys expressed as data (topological spec + role
  grants).

And any of these (if your consumer needs them) reinforce the choice:

- Coordinating the chain with an off-chain daemon or binary.
- Producing off-chain cryptographic artifacts.
- Multi-round drivers with statistical aggregation.

## The one-line summary

**The harness is Python because orion drives a distributed bring-up,
not because it tests a contract.** Foundry is used underneath for the
chain; orion is the chain-side substrate; a consumer on top adds
protocol-specific logic (rounds, signatures, analyses) that happens to
also be Python but doesn't have to be.

## Related reading

- `ARCHITECTURE.md` — the three-layer model in detail.
- `ISSUES.md` — pitfalls (role-binding append-vs-replace, artifact
  bytecode prefixes, fresh-deploy zero-state) that motivated specific
  orion features.
- `../alectryon-harness/SKILLS.md` — the generic playbook this repo
  extracts. Layer taxonomy and priming came from there.
- `../alectryon-harness/docs/FUNDED_PARTICIPANTS.md` — the five-step
  participant pattern, with the `manageStake` accumulation pitfall
  documented.
