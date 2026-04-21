# Architecture

`orion` composes a local EVM test environment from three independently
reversible layers. Each layer has a narrow job and writes a state file
that the next layer consumes.

```
  ┌─────────────────────────────────────────────────────────┐
  │  Layer 3: participants                                  │
  │    one signing key per identity, staked + funded        │
  │    state: state/participants.json                       │
  ├─────────────────────────────────────────────────────────┤
  │  Layer 2: constellation                                 │
  │    N contracts, deterministic order, roles wired        │
  │    state: state/deployment.json                         │
  ├─────────────────────────────────────────────────────────┤
  │  Layer 1: chain                                         │
  │    anvil on :8545, dev mnemonic, 32 prefunded accounts  │
  │    state: state/chain.json  (rpc url, chain id, pid)    │
  └─────────────────────────────────────────────────────────┘
```

Invariants:

- **Every layer supports spawn-or-attach.** You can start fresh, or
  re-attach to an earlier bring-up via its state file.
- **Every layer is independently wipeable.** `rm state/participants.json`
  wipes only layer 3; the chain and deployment continue to work.
- **Nothing downstream hard-codes addresses.** Consumers always read
  `state/deployment.json` and `state/participants.json` at startup.
- **State files are written atomically** (`*.tmp` → `rename`). Partial
  writes would break re-attachment.

## Layer 1: chain

Wraps an anvil process. Exposes `Chain.up(...)` which either spawns a
new anvil (spawn-and-own or spawn-and-detach) or attaches to one
already running at `--rpc`.

Key services:
- `w3` — a `Web3` instance bound to the RPC endpoint.
- `deployer` — a canonical key (anvil account 0) with admin power over
  everything the harness deploys. Holds `DEFAULT_ADMIN_ROLE` on every
  contract, and thus grants all downstream roles.
- RPC helpers — mine blocks, snapshot/revert, impersonate, set interval
  mining. These expose the anvil-specific extensions (`anvil_*`,
  `evm_*`) the harness relies on.

Lifecycle patterns (pick one per driver):
- **Spawn-and-own** — chain dies with the driver. Simplest; loses
  state on restart.
- **Spawn-and-detach** — `chain.up(keep_running=True)` leaves anvil
  running and returns its PID. The driver (or another driver) can
  re-attach from `state/chain.json`.
- **Attach-only** — `chain.attach(rpc=...)` assumes anvil is running
  externally (e.g. under a test runner that owns chain lifecycle).

## Layer 2: constellation

A "constellation" is a small, fixed set of contracts deployed together,
typically with strict topological order and post-deploy role grants.
Orion models a constellation declaratively:

```python
# src/orion/profiles/swarm.py (shape — not the final API)
SWARM = Constellation(
    name="swarm",
    contracts=[
        ContractSpec("Token",        artifact="TestToken",   args=["BZZ", "BZZ", 16, 10**28]),
        ContractSpec("PostageStamp", artifact="PostageStamp", args=[Ref("Token"), 16]),
        ContractSpec("PriceOracle",  artifact="PriceOracle",  args=[Ref("PostageStamp")]),
        ContractSpec("StakeRegistry",artifact="StakeRegistry",args=[Ref("Token"), 1, Ref("PriceOracle")]),
        ContractSpec("Redistribution", artifact="Redistribution",
                     args=[Ref("StakeRegistry"), Ref("PostageStamp"), Ref("PriceOracle")]),
    ],
    role_grants=[
        RoleGrant("PostageStamp",  "REDISTRIBUTOR_ROLE", "Redistribution"),
        RoleGrant("PostageStamp",  "PRICE_ORACLE_ROLE",  "PriceOracle"),
        RoleGrant("StakeRegistry", "REDISTRIBUTOR_ROLE", "Redistribution"),
        RoleGrant("PriceOracle",   "PRICE_UPDATER_ROLE", "Redistribution"),
    ],
)
```

The deployer:
1. Resolves the constructor dependency graph and deploys in topological
   order. Circular dependencies are expressed via `setter=...` and
   applied post-deploy.
2. Sanity-checks each artifact's bytecode prefix (`0x608060...`)
   before submitting — the only reliable way to catch bridged-token
   artifacts masquerading as contracts. See `ISSUES.md:artifact-prefix`.
3. `cast code`-equivalent post-checks — if the deployed bytecode is
   empty, the constructor returned `0x` and something is wrong.
4. Applies role grants and logs each `(contract, role, grantee, tx_hash)`
   tuple to `state/deployment.json`.

### Artifacts

Orion reads Hardhat-style deploy artifacts (`{bytecode,
deployedBytecode, abi}`). No `forge build`, no `hardhat compile`, no
solc.

Artifacts for the built-in Swarm profile ship as a pinned git
submodule at `vendor/storage-incentives/` (populate with `git
submodule update --init vendor/storage-incentives`). Pinning to a
specific commit of `ethersphere/storage-incentives` makes the
bytecode under test byte-identical across developers and across
mainnet itself — bumping the pin is a deliberate act recorded in
the parent repo's history. To test against a different source tree,
override with `--artifacts` or `$ORION_ARTIFACTS`.

## Layer 3: participants

A funded participant is a signing identity with enough native currency
to pay gas, enough protocol token to interact, and a role binding
that makes them visible to the protocol. Orion implements the
canonical five-step pattern:

```
1. derive signing key             ← the identity
2. fund native currency           ← so they can pay gas
3. mint protocol token            ← so they can interact
4. approve(contract, amount)      ← so the contract can pull tokens
5. call role-binding function     ← stake, createBatch, deposit, etc.
```

Signing keys are deterministic: `private_key = keccak256(prefix + ":" +
label)`. Same label ⇒ same address across runs. Nonces within a label
are indexed (`label + ":" + str(i)`) so a single owner can hold many
overlays.

The role-binding call is *profile-specific*. For Swarm:
- `StakeRegistry.manageStake(nonce, stake_amount, height)` registers a
  staked overlay.
- `PostageStamp.createBatch(owner, balancePerChunk, depth, bucketDepth,
  nonce, immutable)` creates a stamp batch.

Other profiles plug in their own role-binding adapters. See
`ISSUES.md:role-binding-semantics` — many role-binding functions
*append* rather than *replace*, and the harness must model this or
stake accumulates silently across runs.

## Layer 0 (optional): priming

A fresh mainnet-bytecode deployment runs correct *code* against
zero *state*: prices, oracles, fee indices, cumulative pools are all
zero. To get realistic numbers (e.g. non-zero redistribution pot per
round), the driver seeds state variables before rounds start.

The generic pattern is **impersonate the role-holder and call the
privileged setter**. For Swarm:

```python
# PRICE_ORACLE_ROLE is held by the PriceOracle contract itself.
# Impersonate it to call PostageStamp.setPrice(...) directly.
chain.anvil_impersonate(oracle_addr)
postage_stamp.setPrice(44_445).send({"from": oracle_addr})
chain.anvil_stop_impersonating(oracle_addr)
```

This leaves the role table identical to mainnet — no extra grants, no
bytecode modifications. Priming helpers live in `src/orion/priming.py`.

## Extension points

### New protocol profiles

Copy `src/orion/profiles/swarm.py`, declare your constellation and
its role-binding adapter, drop it into `src/orion/profiles/`. The CLI
picks up profiles by module name: `orion deploy --profile myproto`.

### Custom priming

Add a function to `src/orion/priming.py` (or a protocol-specific
priming module inside the profile package). Priming isn't on the CLI
by default — consumers call it explicitly because what counts as
"realistic state" is protocol-dependent.

### Custom drivers

Orion gives you `Chain`, `deployment state`, and `participants`.
Anything above that — round loops, event watchers, metrics — is
downstream. Write your driver as a separate package/module that
imports `orion`.

## Consumption model

Downstream drivers compose orion's four public entry points —
`Chain`, `deploy_profile`, `provision`, `priming.*` — with their own
protocol-specific logic:

```python
from orion import Chain, deploy_profile, provision, priming

chain       = Chain.up(keep_running=True)
deployment  = deploy_profile(chain, profile="swarm")
priming.set_postage_price(chain, deployment, wei_per_chunkblock=44_445)
operator    = provision(chain, deployment, label="op-0", overlays=1)

# protocol-specific driver code from here on — round loop, event
# handlers, metrics, statistical tests, off-chain crypto, etc.
```

Orion's state files (`state/chain.json`, `state/deployment.json`,
`state/participants.json`) are the consumption contract. A driver
can either keep an in-memory `Chain` object or re-load from the state
files across invocations; both are first-class.

Migrating an existing harness onto orion is incremental: replace your
``deploy.py`` with ``from orion.constellation import deploy_profile``
first, then your ``participants.py`` with ``from orion.participants
import provision``, then your chain lifecycle. One module at a time,
no flag day — the state-file shapes match what a hand-rolled harness
typically already writes.

## Python package layout

```
orion/
├── pyproject.toml
├── src/orion/
│   ├── __init__.py         # public API re-exports: Chain, deploy_profile, provision, …
│   ├── __main__.py         # `python -m orion` entrypoint
│   ├── cli.py              # `orion` CLI (click)
│   ├── chain.py            # Layer 1: anvil lifecycle, RPC helpers
│   ├── constellation.py    # Layer 2: Constellation, ContractSpec, RoleGrant, deploy_profile
│   ├── participants.py     # Layer 3: derive_key, provision, the five-step pipeline
│   ├── priming.py          # impersonation-based state seeding
│   ├── artifacts.py        # Hardhat artifact loader + bytecode-prefix sanity check
│   ├── state.py            # atomic JSON read/write, state file schemas
│   └── profiles/
│       ├── __init__.py
│       └── swarm.py        # reference Swarm constellation + role-binding adapter
└── state/                  # gitignored; one directory per bring-up
```

## Out of scope

- Non-EVM chains (Solana, Cosmos, …). Add a `Chain` backend if needed;
  do not special-case in call sites.
- P2P networking, libp2p, pullsync, hive. `../kabashira/` covers that;
  orion operates purely chain-side.
- Real protocol-scale data stores (TB-scale reserves, off-chain state
  that a real node would maintain). Drivers that need such state
  provide their own — orion is chain-side only.
- Metrics and dashboards. Orion emits state and events; downstream
  consumers aggregate.
