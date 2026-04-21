---
name: safe-propose
description: Propose transactions to a Gnosis Safe multisig via the Safe Transaction Service API using cast and curl. Covers building Safe transaction hashes, signing with proposer keys, submitting proposals, and querying pending transactions. Works on any EVM chain supported by the Safe Transaction Service.
license: Apache-2.0
metadata:
  author: opencode
  version: "1.0"
  category: Multisig
---

# Safe Transaction Proposals with cast + curl

Propose multisig transactions to the Safe Transaction Service without `safe-cli` or any SDK. Uses only `cast` (Foundry) for on-chain reads and signing, and `curl` for HTTP calls to the Safe Transaction Service API.

## What You Probably Got Wrong

> LLMs have stale training data. These are the most common mistakes.

- **Proposers must be owners** → Wrong. The Safe TX Service accepts proposals from _delegates_ (proposers) who are not owners. They just need to sign the Safe transaction hash. Owners still need to confirm separately.
- **You need an API key** → The Safe Transaction Service API is permissionless. No API key is required to propose transactions. `safe-cli` v1.9+ prints a warning about an API key, but the underlying REST API does not require one.
- **`cast wallet sign` hashes the message** → By default `cast wallet sign` applies EIP-191 prefix hashing. Use `--no-hash` when signing a Safe transaction hash, since the hash is already computed.
- **`cast send` for reading data** → Use `cast call` for view/pure functions (free, no gas). `cast send` submits a transaction.
- **Safe nonce = EOA nonce** → They are different. The Safe maintains its own internal nonce. Always read it from the contract: `cast call <SAFE> "nonce()(uint256)"`.
- **One proposal covers approve + action** → Each Safe transaction is a single call. If you need an ERC-20 `approve` before calling a contract function, that's two separate proposals with sequential nonces.
- **Address provided instead of private key** → If the user provides two values like `0xPrivateKey 0xAddress`, the first is the private key. Use `cast wallet address --private-key <key>` to verify.
- **Shell misinterprets hex values** → When passing hex strings (especially bytes32 zeros) to `cast calldata`, always wrap in double quotes: `"0x0000000000000000000000000000000000000000000000000000000000000000"`.

## Prerequisites

- **cast** (Foundry) installed — `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- **curl** available
- The Safe address, chain RPC URL, and the Safe Transaction Service base URL
- A private key belonging to either a Safe owner or a registered delegate/proposer

## Safe Transaction Service URLs

| Network | Base URL |
|---------|----------|
| Ethereum Mainnet | `https://api.safe.global/tx-service/eth` |
| Gnosis Chain | `https://api.safe.global/tx-service/gno` |
| Sepolia | `https://api.safe.global/tx-service/sep` |
| Polygon | `https://api.safe.global/tx-service/matic` |
| Arbitrum | `https://api.safe.global/tx-service/arb` |
| Optimism | `https://api.safe.global/tx-service/oeth` |
| Base | `https://api.safe.global/tx-service/base` |
| BNB Chain | `https://api.safe.global/tx-service/bnb` |

Full list: `https://api.safe.global/tx-service/about/`

## Step-by-Step: Propose a Transaction

### 1. Gather Safe Info

```bash
SAFE=0xYourSafeAddress
RPC=https://your-rpc-url

# Get current Safe nonce
cast call "$SAFE" "nonce()(uint256)" --rpc-url "$RPC"

# Get owners
cast call "$SAFE" "getOwners()(address[])" --rpc-url "$RPC"

# Get threshold
cast call "$SAFE" "getThreshold()(uint256)" --rpc-url "$RPC"
```

### 2. Encode the Transaction Calldata

Use `cast calldata` to ABI-encode the function call you want the Safe to execute.

```bash
# Example: ERC-20 approve
DATA=$(cast calldata "approve(address,uint256)" "0xSpenderAddress" 1000000000000000)

# Example: arbitrary contract call with bytes32 zero - must quote
DATA=$(cast calldata "someFunction(uint256,address,bytes32)" 42 "0xRecipient" "0x0000000000000000000000000000000000000000000000000000000000000000")
```

### 3. Compute the Safe Transaction Hash

Call `getTransactionHash` on the Safe contract. All gas-related parameters are typically 0 for proposals (gas is paid by the executor at execution time).

```bash
SAFE_TX_HASH=$(cast call $SAFE \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$TO" \
  "$VALUE" \
  "$DATA" \
  0 \
  0 \
  0 \
  0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  "$NONCE" \
  --rpc-url "$RPC")
```

**Parameters explained:**

| Position | Parameter | Typical Value | Description |
|----------|-----------|---------------|-------------|
| 1 | `to` | Contract address | Target of the transaction |
| 2 | `value` | `0` | ETH/native value to send |
| 3 | `data` | Encoded calldata | From step 2 |
| 4 | `operation` | `0` | 0 = CALL, 1 = DELEGATECALL |
| 5 | `safeTxGas` | `0` | Gas for the Safe transaction (0 = estimate at execution) |
| 6 | `baseGas` | `0` | Gas overhead |
| 7 | `gasPrice` | `0` | Gas price for refund (0 = no refund) |
| 8 | `gasToken` | `address(0)` | Token for gas refund (0 = ETH) |
| 9 | `refundReceiver` | `address(0)` | Refund recipient (0 = tx.origin) |
| 10 | `_nonce` | Safe nonce | Must match the Safe's current nonce for the next tx |

### 4. Sign the Hash

Sign the Safe transaction hash with the proposer's private key. Use `--no-hash` because the Safe transaction hash is already a final digest.

```bash
SIGNATURE=$(cast wallet sign --no-hash "$SAFE_TX_HASH" --private-key "$PRIVATE_KEY")
```

### 5. Submit to the Transaction Service

```bash
TX_SERVICE=https://api.safe.global/tx-service/sep  # Change per network
SENDER=0xProposerAddress  # Address corresponding to $PRIVATE_KEY

curl -s -X POST "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/" \
  -H "Content-Type: application/json" \
  -d "{
    \"to\": \"$TO\",
    \"value\": \"$VALUE\",
    \"data\": \"$DATA\",
    \"operation\": 0,
    \"safeTxGas\": \"0\",
    \"baseGas\": \"0\",
    \"gasPrice\": \"0\",
    \"gasToken\": \"0x0000000000000000000000000000000000000000\",
    \"refundReceiver\": \"0x0000000000000000000000000000000000000000\",
    \"nonce\": $NONCE,
    \"contractTransactionHash\": \"$SAFE_TX_HASH\",
    \"sender\": \"$SENDER\",
    \"signature\": \"$SIGNATURE\"
  }"
```

A successful response returns HTTP **201** with an empty body, or HTTP **200** with transaction details.

### 6. Verify the Proposal

```bash
# List pending transactions
curl -s "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/?limit=5&ordering=-nonce" | python3 -m json.tool

# Get a specific transaction by safeTxHash
curl -s "$TX_SERVICE/api/v1/multisig-transactions/$SAFE_TX_HASH/" | python3 -m json.tool
```

## Complete Example: ERC-20 Approve + Contract Call

This example proposes two transactions: first an ERC-20 `approve`, then a contract call that spends the approved tokens.

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
SAFE=0x1b5BB8C4Ea0E9B8a9BCd91Cc3B81513dB0bA8766
RPC=https://sepolia.drpc.org
TX_SERVICE=https://api.safe.global/tx-service/sep
PRIVATE_KEY=0xYourProposerPrivateKey
SENDER=$(cast wallet address --private-key $PRIVATE_KEY)

TOKEN=0x543dDb01Ba47acB11de34891cD86B675F04840db
SPENDER=0xcdfdC3752caaA826fE62531E0000C40546eC56A6
AMOUNT=10000000000000000  # 1 token (16 decimals)

# --- Read current Safe nonce ---
NONCE=$(cast call $SAFE "nonce()(uint256)" --rpc-url $RPC)
echo "Safe nonce: $NONCE"

# --- Transaction 1: approve ---
APPROVE_DATA=$(cast calldata "approve(address,uint256)" "$SPENDER" "$AMOUNT")

APPROVE_HASH=$(cast call $SAFE \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$TOKEN" 0 "$APPROVE_DATA" 0 0 0 0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  "$NONCE" --rpc-url "$RPC")

APPROVE_SIG=$(cast wallet sign --no-hash $APPROVE_HASH --private-key $PRIVATE_KEY)

echo "Proposing approve (nonce $NONCE)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/" \
  -H "Content-Type: application/json" \
  -d "{
    \"to\": \"$TOKEN\",
    \"value\": \"0\",
    \"data\": \"$APPROVE_DATA\",
    \"operation\": 0,
    \"safeTxGas\": \"0\",
    \"baseGas\": \"0\",
    \"gasPrice\": \"0\",
    \"gasToken\": \"0x0000000000000000000000000000000000000000\",
    \"refundReceiver\": \"0x0000000000000000000000000000000000000000\",
    \"nonce\": $NONCE,
    \"contractTransactionHash\": \"$APPROVE_HASH\",
    \"sender\": \"$SENDER\",
    \"signature\": \"$APPROVE_SIG\"
  }")
echo "Approve proposal: HTTP $HTTP_CODE"

# --- Transaction 2: contract call (next nonce) ---
NEXT_NONCE=$((NONCE + 1))
CALL_DATA=$(cast calldata "topUp(bytes32,uint256)" "0xYourBatchId" "$AMOUNT")

CALL_HASH=$(cast call $SAFE \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$SPENDER" 0 "$CALL_DATA" 0 0 0 0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  "$NEXT_NONCE" --rpc-url "$RPC")

CALL_SIG=$(cast wallet sign --no-hash $CALL_HASH --private-key $PRIVATE_KEY)

echo "Proposing contract call (nonce $NEXT_NONCE)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/" \
  -H "Content-Type: application/json" \
  -d "{
    \"to\": \"$SPENDER\",
    \"value\": \"0\",
    \"data\": \"$CALL_DATA\",
    \"operation\": 0,
    \"safeTxGas\": \"0\",
    \"baseGas\": \"0\",
    \"gasPrice\": \"0\",
    \"gasToken\": \"0x0000000000000000000000000000000000000000\",
    \"refundReceiver\": \"0x0000000000000000000000000000000000000000\",
    \"nonce\": $NEXT_NONCE,
    \"contractTransactionHash\": \"$CALL_HASH\",
    \"sender\": \"$SENDER\",
    \"signature\": \"$CALL_SIG\"
  }")
echo "Contract call proposal: HTTP $HTTP_CODE"
```

## Useful API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/safes/{address}/` | Safe info (owners, threshold, nonce, etc.) |
| GET | `/api/v1/safes/{address}/multisig-transactions/` | List all multisig transactions |
| POST | `/api/v1/safes/{address}/multisig-transactions/` | Propose a new transaction |
| GET | `/api/v1/multisig-transactions/{safeTxHash}/` | Get specific transaction by hash |
| GET | `/api/v1/safes/{address}/multisig-transactions/?executed=false` | List pending (unexecuted) transactions |
| POST | `/api/v1/multisig-transactions/{safeTxHash}/confirmations/` | Add an owner confirmation/signature |
| GET | `/api/v1/safes/{address}/balances/` | Token balances held by the Safe |
| GET | `/api/v1/owners/{address}/safes/` | List Safes where an address is owner |
| POST | `/api/v1/delegates/` | Register a delegate (proposer) for a Safe |
| DELETE | `/api/v1/delegates/{delegate_address}/` | Remove a delegate |

## Adding an Owner Confirmation

After a transaction is proposed, owners confirm by signing the same `safeTxHash`:

```bash
# Owner signs the safeTxHash
OWNER_SIG=$(cast wallet sign --no-hash "$SAFE_TX_HASH" --private-key "$OWNER_PRIVATE_KEY")
OWNER_ADDRESS=$(cast wallet address --private-key "$OWNER_PRIVATE_KEY")

# Submit confirmation
curl -s -X POST "$TX_SERVICE/api/v1/multisig-transactions/$SAFE_TX_HASH/confirmations/" \
  -H "Content-Type: application/json" \
  -d "{\"signature\": \"$OWNER_SIG\"}"
```

Once `confirmations >= threshold`, any account can execute the transaction on-chain.

## Sending ETH from the Safe

To propose sending native currency (ETH/xDAI/MATIC), set `value` and leave `data` as `"0x"`:

```bash
TO=0xRecipientAddress
VALUE=1000000000000000000  # 1 ETH in wei

SAFE_TX_HASH=$(cast call "$SAFE" \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$TO" "$VALUE" "0x" 0 0 0 0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  "$NONCE" --rpc-url "$RPC")

# Sign and submit as usual...
```

## Error Handling

| HTTP Code | Meaning | Fix |
|-----------|---------|-----|
| 201 | Proposal accepted | Success |
| 400 | Invalid data | Check calldata encoding, nonce, or safeTxHash mismatch |
| 422 | Validation error | Signature doesn't match sender, or sender is not owner/delegate |
| 404 | Safe not found | Safe not indexed by the TX service on this network |
| 429 | Rate limited | Back off and retry |

Common issues:

- **"Contract transaction hash must be unique"** → A transaction with this exact safeTxHash was already proposed.
- **Nonce mismatch** → Always read the nonce fresh from the contract before proposing. For queuing multiple proposals, increment the nonce manually (nonce, nonce+1, nonce+2, ...).
- **Signature invalid** → Ensure you used `--no-hash` with `cast wallet sign`. The Safe tx hash is already a digest.

## Security

- **Never hardcode private keys** in scripts. Use environment variables: `--private-key $PRIVATE_KEY`.
- **Verify calldata** before proposing. Decode with `cast 4byte-decode <calldata>` or `cast calldata-decode <sig> <calldata>`.
- **Check the Safe address** on a block explorer before proposing to confirm it's the correct multisig.
- **Review pending transactions** in the Safe UI before signing as an owner.

## References

- [Safe Transaction Service API Docs](https://docs.safe.global/core-api/transaction-service-overview)
- [Safe Smart Account Reference](https://docs.safe.global/advanced/smart-account-overview)
- [Foundry Book — cast](https://book.getfoundry.sh/reference/cast/)
