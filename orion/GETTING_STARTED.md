# Getting Started

End-to-end walkthrough: from zero to a locally-running Swarm
constellation with a funded participant, ready for round driving.

This doc assumes you're on Linux or macOS.

## 1. Prerequisites

| Tool | Minimum | Install |
|---|---|---|
| Foundry (`anvil`, `cast`) | 0.2+ | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Python | 3.11+ | system package manager |
| `uv` | 0.4+ | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Hardhat deploy artifacts | — | see below |

### Getting contract artifacts

Orion deploys pre-compiled Hardhat artifacts verbatim. The Swarm
profile's artifacts live in a pinned git submodule at
`vendor/storage-incentives/` — initialise it once after cloning
orion:

```bash
git submodule update --init vendor/storage-incentives
```

The submodule is pinned to a specific commit of
`github.com/ethersphere/storage-incentives` so the bytecode under
test is reproducible across developers. To bump the pin, enter the
submodule, check out a new tag/commit, and commit the updated
pointer in the parent repo:

```bash
git -C vendor/storage-incentives fetch --tags
git -C vendor/storage-incentives checkout v0.9.4   # example
git add vendor/storage-incentives && git commit -m "vendor: bump storage-incentives to v0.9.4"
```

Orion's Swarm profile defaults to reading from
`vendor/storage-incentives/deployments/`. Mainnet artifacts live in
`deployments/mainnet/`; the deployable TestToken lives in
`deployments/testnet/` (the mainnet `Token.json` is a bridged-token
shim and not deployable — see `ISSUES.md:artifact-prefix`). You can
override the search root with `--artifacts` or `$ORION_ARTIFACTS` if
pointing at a different source.

An artifact is the right shape when its top-level JSON has
`bytecode`, `abi`, and (usually) `deployedBytecode`. See
`ISSUES.md:artifact-prefix` for the byte-one sanity check.

## 2. Install orion

```bash
cd orion
uv sync
```

This creates `.venv/` and installs `web3`, `eth-account`,
`eth-hash`, `click` per `pyproject.toml`. The `orion` command is
placed on `$PATH` for the venv.

```bash
orion --help
```

## 3. Bring up the stack

Three ways to do this; pick the one that matches your working style.

### Option A — one-shot

```bash
orion up --profile swarm
```

Spawns anvil, deploys the 5-contract Swarm constellation, wires 4
role grants, writes `state/chain.json` and `state/deployment.json`.
Anvil detaches and keeps running — its PID is in `state/chain.json`
and echoed to stdout. This is usually what you want.

### Option B — one layer at a time

```bash
# Layer 1: chain
orion chain up --port 8545 --keep-running

# Layer 2: constellation (reads state/chain.json)
orion deploy --profile swarm

# Layer 3: participant
orion participants provision --label op-0 --overlays 1
```

Each step is idempotent and can be re-invoked after wiping only its
layer's state file.

### Option C — external anvil

```bash
# You're running anvil yourself (or under a test runner)
anvil --port 8545 --accounts 32 --balance 10000 --silent &

orion chain attach --rpc http://127.0.0.1:8545
orion deploy --profile swarm
```

## 4. Provision participants

```bash
# one operator with one staked overlay + one postage batch
orion participants provision --label op-0 --overlays 1

# a fleet of 256 overlays under a single signing key
orion participants provision --label fleet --overlays 256

# inspect
orion participants list
```

The operator's signing key is `keccak256("orion:op-0")` —
deterministic, so the address is stable across runs. Change the
label if you want a different identity; see
`ISSUES.md:stake-accumulation` for the gotcha when re-using labels.

## 5. Prime the economy (optional)

A freshly-deployed constellation has `PostageStamp.lastPrice = 0`, so
the redistribution pot is empty. If your driver needs non-zero
earnings, prime the price before round-driving:

```bash
# seed lastPrice to mainnet round 301042's value (44,445 wei/chunkblock)
orion prime set-postage-price --wei-per-chunkblock 44445
```

Under the hood this uses `anvil_impersonateAccount` on the
`PriceOracle` contract address (holder of `PRICE_ORACLE_ROLE`) to
call `PostageStamp.setPrice`, then releases the impersonation. No
role-table modifications; the deployment remains mainnet-identical.

## 6. Drive the protocol

Round-driving, event handlers, and any protocol-specific logic are
out of orion's scope. Orion hands you `state/chain.json` +
`state/deployment.json` + `state/participants.json`; a downstream
driver consumes those and does whatever the protocol needs. Read the
state from a driver with:

```python
from orion import Chain
from pathlib import Path
import json

chain = Chain.load()                                       # reads state/chain.json
deployment = json.loads(Path("state/deployment.json").read_text())
# your driver code here — round loops, event listeners, metrics, …
```

For ad-hoc chain inspection from the shell, `cast` talks to the same
RPC:

```bash
RPC=$(jq -r .rpc state/chain.json)
ADDR=$(jq -r '.contracts.Redistribution' state/deployment.json)
cast call $ADDR "currentRound()(uint64)" --rpc-url $RPC
```

## 7. Tear down / re-run

```bash
# stop the anvil started by orion
orion chain down

# or just wipe state and start fresh
rm -rf state/ && orion up --profile swarm
```

Deterministic key derivation means a re-run produces the same
addresses and thus the same overlays and batches — useful for
debugging across sessions. It also means two concurrent `orion` runs
with the same label will collide on-chain; use a run-id suffix to
partition.

## Next steps

- `ARCHITECTURE.md` — the three-layer model and extension points.
- `ISSUES.md` — known pitfalls and limitations; read before debugging.
- `WHY_PYTHON.md` — rationale for Python, scope of load-bearing
  features vs auxiliary tools.

## Troubleshooting quick hits

| Symptom | First check |
|---|---|
| `connection refused` on port 8545 | anvil died; `ls state/chain.json` and restart |
| tx reverts with empty revert data | missing role grant or approval — check `state/deployment.json:role_grants` and pre-call approvals |
| `contract does not have any code` | wrong anvil (stale PID) or bad artifact prefix — see `ISSUES.md` |
| second run's stakes are bigger than the first | role-binding call appends, not replaces — see `ISSUES.md:stake-accumulation` |

More pitfall detail in `ISSUES.md`.
