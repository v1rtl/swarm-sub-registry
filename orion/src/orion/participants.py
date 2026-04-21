"""Layer 3 — funded participant provisioning.

Ports the five-step pattern
(derive → fund → mint → approve → role-bind) from
``../../alectryon-harness/python/src/alectryon_harness/participants.py``
into orion's consumer-facing surface.

Role binding is Swarm-only for now (``role_binding="swarm"`` ⇒
StakeRegistry.manageStake + PostageStamp.createBatch). Future protocols
will be added as separate callable adapters behind the same
``role_binding`` switch.

Collision protection: provisioning the same label twice *on the same
chain* would silently accumulate stake under Swarm (see
``ISSUES.md`` §Role-binding semantics). orion refuses a re-provision
with a clear error unless :meth:`Participant.wipe` has been called.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from eth_account import Account
from eth_hash.auto import keccak
from eth_keys import keys as eth_keys
from web3 import Web3

from orion import artifacts as _artifacts
from orion import state as _state
from orion.chain import Chain
from orion.constellation import _resolve_artifacts_dir  # shared helper

DEFAULT_KEY_PREFIX = b"orion:participant:"
_PARTICIPANTS_STATE_FILENAME = "participants.json"

# Swarm constants. Hoisted here because the reference role-binding adapter
# is Swarm-specific and these are the values it needs.
_SWARM_MIN_STAKE_WEI = 10**17  # 10 BZZ at 16-decimal precision (Staking.sol:45)
_SWARM_DEFAULT_HEIGHT = 0
_SWARM_DEFAULT_BATCH_DEPTH = 22  # 4.2M chunks — realistic-enough for priming
_SWARM_DEFAULT_BUCKET_DEPTH = 16
_SWARM_DEFAULT_BALANCE_PER_CHUNK = 1000  # wei; priming bumps this if lastPrice > 0
_SWARM_BZZ_MINT_BUFFER = 1000 * 10**16  # 1000 BZZ headroom per participant


# ─── Derivation ─────────────────────────────────────────────────────


def derive_signing_key(label: str, *, prefix: bytes = DEFAULT_KEY_PREFIX) -> bytes:
    """Deterministic signing key: ``keccak256(prefix + label)``.

    Same label ⇒ same 32-byte private key ⇒ same Ethereum address across
    runs. Changing ``prefix`` partitions the keyspace (useful when two
    harnesses share a chain — see ``ISSUES.md`` §Label collisions).
    """
    return keccak(prefix + label.encode())


def derive_overlay(owner_addr: str, nonce: bytes, network_id: int) -> bytes:
    """overlay = ``keccak256(owner_addr || reverse(networkId, 8-byte BE) || nonce)``.

    ``Staking.sol:124`` computes this as
    ``keccak256(abi.encodePacked(msg.sender, reverse(NetworkId), _setNonce))``
    where ``reverse()`` byte-swaps a uint64 (Staking.sol:343) — equivalent
    to encoding ``NetworkId`` as little-endian.
    """
    addr_bytes = bytes.fromhex(owner_addr.removeprefix("0x"))
    assert len(addr_bytes) == 20, f"expected 20-byte address, got {len(addr_bytes)}"
    assert len(nonce) == 32, f"expected 32-byte nonce, got {len(nonce)}"
    nid = network_id.to_bytes(8, "little")
    return keccak(addr_bytes + nid + nonce)


# ─── Participant record ─────────────────────────────────────────────


@dataclass
class Participant:
    label: str
    address: str
    signing_key: bytes
    overlays: list[dict[str, Any]] = field(default_factory=list)
    batches: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "label": self.label,
            "address": self.address,
            "signing_key": self.signing_key.hex(),
            "overlays": self.overlays,
            "batches": self.batches,
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Participant":
        return cls(
            label=d["label"],
            address=d["address"],
            signing_key=bytes.fromhex(d["signing_key"]),
            overlays=list(d.get("overlays", [])),
            batches=list(d.get("batches", [])),
        )


# ─── Provisioning (top-level) ───────────────────────────────────────


def provision(
    chain: Chain,
    deployment: dict[str, Any],
    *,
    label: str,
    overlays: int = 1,
    stake_wei: int = _SWARM_MIN_STAKE_WEI,
    batch_depth: int = _SWARM_DEFAULT_BATCH_DEPTH,
    bucket_depth: int = _SWARM_DEFAULT_BUCKET_DEPTH,
    balance_per_chunk: Optional[int] = None,
    role_binding: str = "swarm",
    artifacts_dir: Optional[Path] = None,
) -> Participant:
    """Run the five-step pattern: derive → fund → mint → approve → role-bind.

    - ``overlays`` — number of staked overlays to register under this one
      signing key. All overlays share the address; nonces differ.
    - ``stake_wei`` — stake per overlay in wei (BZZ has 16 decimals).
    - ``batch_depth`` / ``bucket_depth`` / ``balance_per_chunk`` — shape of
      the single postage batch created for this participant.
      ``balance_per_chunk=None`` auto-picks a value that beats the current
      ``minimumValidityBlocks × lastPrice``.
    - ``role_binding`` — protocol adapter; only ``"swarm"`` is implemented.

    Raises if this label has already been provisioned on this chain
    (would silently accumulate stake; see ``ISSUES.md``).
    """
    if role_binding != "swarm":
        raise NotImplementedError(
            f"role_binding={role_binding!r} not implemented; only 'swarm' is wired"
        )

    existing = _load_all(chain.state_dir)
    if label in existing:
        raise RuntimeError(
            f"label {label!r} already provisioned on this chain. "
            f"Call wipe() first, or use a distinct label."
        )

    art_dir = _resolve_artifacts_dir(artifacts_dir)
    abis = _load_swarm_abis(art_dir)

    signing_key = derive_signing_key(label)
    owner_addr = eth_keys.PrivateKey(signing_key).public_key.to_checksum_address()
    participant = Participant(label=label, address=owner_addr, signing_key=signing_key)

    # Step 2: fund native so the participant can pay gas.
    _fund_native(chain, owner_addr, amount_wei=10**18)

    # Step 3: mint BZZ. Cover stakes + batch + buffer.
    bpc = balance_per_chunk if balance_per_chunk is not None else _auto_balance_per_chunk(
        chain, deployment, abis,
    )
    batch_cost = bpc * (1 << batch_depth)
    mint_amount = overlays * stake_wei + batch_cost + max(_SWARM_BZZ_MINT_BUFFER, 2 * stake_wei)
    _mint_bzz(chain, deployment, abis, owner_addr, mint_amount)

    # Step 4+5: approve + role-bind. Per-overlay stake registration, then
    # a single postage batch per participant.
    for i in range(overlays):
        nonce = keccak(f"{label}:overlay:{i}".encode())
        rec = _register_overlay_swarm(
            chain, deployment, abis, signing_key, nonce, stake_wei, height=_SWARM_DEFAULT_HEIGHT,
        )
        participant.overlays.append(rec)

    batch_salt = keccak(f"{label}:batch".encode())
    participant.batches.append(_create_batch_swarm(
        chain, deployment, abis, signing_key,
        depth=batch_depth, bucket_depth=bucket_depth,
        balance_per_chunk=bpc, salt=batch_salt,
    ))

    _save_one(chain.state_dir, participant)
    return participant


def load(chain_state_dir: Path, label: str) -> Optional[Participant]:
    """Return the :class:`Participant` record for ``label``, or None."""
    all_ = _load_all(chain_state_dir)
    d = all_.get(label)
    return Participant.from_dict(d) if d else None


def load_all(chain_state_dir: Path) -> dict[str, Participant]:
    """Return a dict of all provisioned participants keyed by label."""
    return {k: Participant.from_dict(v) for k, v in _load_all(chain_state_dir).items()}


def wipe(chain_state_dir: Path) -> None:
    """Remove ``participants.json``. Does NOT un-stake on-chain."""
    path = chain_state_dir / _PARTICIPANTS_STATE_FILENAME
    if path.exists():
        path.unlink()


# ─── Internals: state file ──────────────────────────────────────────


def _load_all(state_dir: Path) -> dict[str, dict[str, Any]]:
    path = state_dir / _PARTICIPANTS_STATE_FILENAME
    if not path.exists():
        return {}
    with path.open() as f:
        return json.load(f).get("participants", {})


def _save_one(state_dir: Path, p: Participant) -> None:
    all_ = _load_all(state_dir)
    all_[p.label] = p.to_dict()
    _state.write(state_dir / _PARTICIPANTS_STATE_FILENAME, {"participants": all_})


# ─── Internals: tx helpers ──────────────────────────────────────────


def _send_tx(chain: Chain, signer_key: bytes, tx: dict) -> dict:
    """Sign + submit + await receipt. Uses legacy gas fields."""
    w3 = chain.w3
    acct = Account.from_key(signer_key)
    tx.setdefault("from", acct.address)
    tx.setdefault("nonce", w3.eth.get_transaction_count(acct.address))
    tx.setdefault("chainId", w3.eth.chain_id)
    tx.setdefault("gas", 3_000_000)
    tx.pop("maxFeePerGas", None)
    tx.pop("maxPriorityFeePerGas", None)
    tx.setdefault("gasPrice", w3.eth.gas_price)
    signed = acct.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    if receipt["status"] != 1:
        raise RuntimeError(f"tx reverted: {dict(receipt)}")
    return dict(receipt)


def _fund_native(chain: Chain, target: str, *, amount_wei: int) -> None:
    """Send native currency from the deployer to ``target``."""
    _send_tx(
        chain,
        chain.deployer_key,
        {
            "to": target,
            "value": amount_wei,
            "gas": 21_000,
        },
    )


def _mint_bzz(
    chain: Chain,
    deployment: dict[str, Any],
    abis: dict[str, list],
    to: str,
    amount_wei: int,
) -> None:
    """Deployer mints BZZ to ``to`` (TestToken: MINTER_ROLE held by deployer)."""
    w3 = chain.w3
    token_addr = deployment["contracts"]["Token"]
    token = w3.eth.contract(address=token_addr, abi=abis["Token"])
    tx = token.functions.mint(to, amount_wei).build_transaction(
        {"from": chain.deployer_addr}
    )
    _send_tx(chain, chain.deployer_key, tx)


# ─── Internals: Swarm role-binding adapter ──────────────────────────


def _register_overlay_swarm(
    chain: Chain,
    deployment: dict[str, Any],
    abis: dict[str, list],
    signing_key: bytes,
    nonce: bytes,
    stake_wei: int,
    height: int,
) -> dict[str, Any]:
    """Approve StakeRegistry + manageStake. Returns overlay record dict."""
    w3 = chain.w3
    acct = Account.from_key(signing_key)
    token_addr = deployment["contracts"]["Token"]
    stake_addr = deployment["contracts"]["StakeRegistry"]

    token = w3.eth.contract(address=token_addr, abi=abis["Token"])
    stake = w3.eth.contract(address=stake_addr, abi=abis["StakeRegistry"])

    tx = token.functions.approve(stake_addr, stake_wei).build_transaction({"from": acct.address})
    _send_tx(chain, signing_key, tx)

    tx = stake.functions.manageStake(nonce, stake_wei, height).build_transaction({"from": acct.address})
    _send_tx(chain, signing_key, tx)

    network_id = 1  # Swarm mainnet
    overlay = derive_overlay(acct.address, nonce, network_id)
    return {
        "nonce": "0x" + nonce.hex(),
        "overlay": "0x" + overlay.hex(),
        "stake_wei": stake_wei,
        "height": height,
    }


def _create_batch_swarm(
    chain: Chain,
    deployment: dict[str, Any],
    abis: dict[str, list],
    signing_key: bytes,
    *,
    depth: int,
    bucket_depth: int,
    balance_per_chunk: int,
    salt: bytes,
    immutable: bool = False,
) -> dict[str, Any]:
    """Approve PostageStamp + createBatch. Returns batch record dict."""
    w3 = chain.w3
    acct = Account.from_key(signing_key)
    token_addr = deployment["contracts"]["Token"]
    postage_addr = deployment["contracts"]["PostageStamp"]
    total = balance_per_chunk * (1 << depth)

    token = w3.eth.contract(address=token_addr, abi=abis["Token"])
    postage = w3.eth.contract(address=postage_addr, abi=abis["PostageStamp"])

    tx = token.functions.approve(postage_addr, total).build_transaction({"from": acct.address})
    _send_tx(chain, signing_key, tx)

    tx = postage.functions.createBatch(
        acct.address, balance_per_chunk, depth, bucket_depth, salt, immutable,
    ).build_transaction({"from": acct.address})
    _send_tx(chain, signing_key, tx)

    # batch_id = keccak256(abi.encode(msg.sender, nonce)) per PostageStamp.sol:206.
    # abi.encode (not encodePacked) left-pads address to 32 bytes.
    addr_bytes = bytes.fromhex(acct.address.removeprefix("0x"))
    batch_id = keccak(b"\x00" * 12 + addr_bytes + salt)
    return {
        "batch_id": "0x" + batch_id.hex(),
        "depth": depth,
        "bucket_depth": bucket_depth,
        "balance_per_chunk": balance_per_chunk,
    }


def _auto_balance_per_chunk(
    chain: Chain,
    deployment: dict[str, Any],
    abis: dict[str, list],
) -> int:
    """Pick a balance-per-chunk that beats 2× the chain's current minimum.

    PostageStamp enforces ``minimumValidityBlocks × lastPrice`` as a floor
    per chunk. On a fresh deploy ``lastPrice=0`` so the floor is zero and
    any positive value passes, but priming may raise ``lastPrice`` between
    deploy and provision — overshooting by 2× absorbs small drift.
    """
    postage = chain.w3.eth.contract(
        address=deployment["contracts"]["PostageStamp"], abi=abis["PostageStamp"],
    )
    last_price = postage.functions.lastPrice().call()
    min_validity = postage.functions.minimumValidityBlocks().call()
    return max(_SWARM_DEFAULT_BALANCE_PER_CHUNK, 2 * max(last_price, 1) * max(min_validity, 1))


# ─── Internals: ABI loader ──────────────────────────────────────────


def _load_swarm_abis(art_dir: Path) -> dict[str, list]:
    """Load the four ABIs that the Swarm role-binding adapter touches."""
    return {
        "Token":         _artifacts.load("TestToken",    artifacts_dir=art_dir).abi,
        "PostageStamp":  _artifacts.load("PostageStamp", artifacts_dir=art_dir).abi,
        "StakeRegistry": _artifacts.load("StakeRegistry", artifacts_dir=art_dir).abi,
    }
