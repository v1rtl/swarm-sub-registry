# How to Propose a Safe Transaction

This guide walks through proposing a multisig transaction using cast, curl, and the Safe Transaction Service API.

## Prerequisites

- Safe address
- RPC URL for the network
- Proposer private key (registered delegate or owner)
- Transaction Service URL for the network

| Network | Transaction Service URL |
|---------|------------------------|
| Ethereum Mainnet | `https://api.safe.global/tx-service/eth` |
| Sepolia | `https://api.safe.global/tx-service/sep` |
| Gnosis Chain | `https://api.safe.global/tx-service/gno` |

## Step-by-Step Commands

### 1. Get Your Address from Private Key

```bash
cast wallet address --private-key 0xYOUR_PRIVATE_KEY
```

Save this as your proposer address.

### 2. Get Current Safe Nonce

```bash
cast call 0xSAFE_ADDRESS "nonce()(uint256)" --rpc-url https://sepolia.drpc.org
```

Note: This is the Safe's internal nonce, not your EOA nonce.

### 3. Encode the Calldata

```bash
cast calldata "functionName(paramType,paramType)" arg1 arg2
```

Example for ERC-20 approve:
```bash
cast calldata "approve(address,uint256)" 0xSPENDER 1000000000000000
```

### 4. Compute the Safe Transaction Hash

```bash
cast call 0xSAFE_ADDRESS \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "0xTO_ADDRESS" \
  0 \
  "0xCALLDATA" \
  0 \
  0 \
  0 \
  0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  NONCE \
  --rpc-url https://sepolia.drpc.org
```

Parameters: `to`, `value`, `data`, `operation`, `safeTxGas`, `baseGas`, `gasPrice`, `gasToken`, `refundReceiver`, `nonce`

### 5. Sign the Hash

```bash
cast wallet sign --no-hash 0xSAFE_TX_HASH --private-key 0xYOUR_PRIVATE_KEY
```

The `--no-hash` flag is required because the Safe transaction hash is already a digest.

### 6. Submit the Proposal

```bash
curl -X POST "https://api.safe.global/tx-service/sep/api/v1/safes/0xSAFE_ADDRESS/multisig-transactions/" \
  -H "Content-Type: application/json" \
  -d '{
    "to": "0xTO_ADDRESS",
    "value": "0",
    "data": "0xCALLDATA",
    "operation": 0,
    "safeTxGas": "0",
    "baseGas": "0",
    "gasPrice": "0",
    "gasToken": "0x0000000000000000000000000000000000000000",
    "refundReceiver": "0x0000000000000000000000000000000000000000",
    "nonce": NONCE,
    "contractTransactionHash": "0xSAFE_TX_HASH",
    "sender": "0xPROPOSER_ADDRESS",
    "signature": "0xSIGNATURE"
  }'
```

### 7. Verify

```bash
curl "https://api.safe.global/tx-service/sep/api/v1/safes/0xSAFE_ADDRESS/multisig-transactions/?executed=false&ordering=-nonce&limit=5"
```

## Example: Create Batch on PostageStamp

### Configuration

```bash
SAFE=0x1b5BB8C4Ea0E9B8a9BCd91Cc3B81513dB0bA8766
RPC=https://sepolia.drpc.org
TX_SERVICE=https://api.safe.global/tx-service/sep
POSTAGE_STAMP=0xcdfdC3752caaA826fE62531E0000C40546eC56A6
PRIVATE_KEY=0xYOUR_PRIVATE_KEY
```

### Get nonce and sender

```bash
NONCE=$(cast call "$SAFE" "nonce()(uint256)" --rpc-url "$RPC")
SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Nonce: $NONCE, Sender: $SENDER"
```

### CreateBatch calldata

```bash
DATA=$(cast calldata "createBatch(address,uint256,uint8,uint8,bytes32,bool)" \
  0xf99AB3e044798AC422D11e747ffB7269901a55CC \
  766627200 \
  17 \
  16 \
  "0x0000000000000000000000000000000000000000000000000000000000000000" \
  false)
```

### Compute Safe transaction hash

```bash
SAFE_TX_HASH=$(cast call "$SAFE" \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$POSTAGE_STAMP" 0 "$DATA" 0 0 0 0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  "$NONCE" --rpc-url "$RPC")
```

### Sign

```bash
SIGNATURE=$(cast wallet sign --no-hash "$SAFE_TX_HASH" --private-key "$PRIVATE_KEY")
```

### Submit

```bash
curl -X POST "$TX_SERVICE/api/v1/safes/$SAFE/multisig-transactions/" \
  -H "Content-Type: application/json" \
  -d "{
    \"to\": \"$POSTAGE_STAMP\",
    \"value\": \"0\",
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

## Example: Two-Step (Approve + Action)

If you need ERC-20 approval first:

### Step 1: Approve

```bash
# Use nonce 4
APPROVE_DATA=$(cast calldata "approve(address,uint256)" "0xPOSTAGE_STAMP" 100000000000000)
APPROVE_HASH=$(cast call "$SAFE" \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "0xBZZ_TOKEN" 0 "$APPROVE_DATA" 0 0 0 0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  4 --rpc-url "$RPC")
APPROVE_SIG=$(cast wallet sign --no-hash "$APPROVE_HASH" --private-key "$PRIVATE_KEY")
# Submit with nonce 4
```

### Step 2: Action

```bash
# Use nonce 5
CALL_DATA=$(cast calldata "createBatch(...)" ...)
CALL_HASH=$(cast call "$SAFE" \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "0xPOSTAGE_STAMP" 0 "$CALL_DATA" 0 0 0 0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  5 --rpc-url "$RPC")
CALL_SIG=$(cast wallet sign --no-hash "$CALL_HASH" --private-key "$PRIVATE_KEY")
# Submit with nonce 5
```

## Troubleshooting

| Error | Fix |
|-------|-----|
| "insufficient allowance" | First propose approve transaction |
| "Contract transaction hash must be unique" | Use unique nonce or different calldata |
| Signature invalid | Check you used `--no-hash` flag |
| 422 error | Sender is not a valid proposer/delegate |

## Adding Confirmation

After proposal, an owner confirms:

```bash
OWNER_SIG=$(cast wallet sign --no-hash 0xSAFE_TX_HASH --private-key 0xOWNER_PRIVATE_KEY)

curl -X POST "https://api.safe.global/tx-service/sep/api/v1/multisig-transactions/0xSAFE_TX_HASH/confirmations/" \
  -H "Content-Type: application/json" \
  -d "{\"signature\": \"$OWNER_SIG\"}"
```