# Swarm volume registry

Goal: bring volume lifecycle semantics and a tiered ownership/management model to Swarm capacity quotas (postage stamp batches).

## Ownership model

The Swarm volume API breaks management duties into up to three roles:

* **Owner wallet.** Create, modify (TTL/size), delete, transfer ownership, designate payer, (add/remove signing keys not supported by Postage contract)
* **Funding wallet.** Hold tokens, authorize/revoke owner in registry
* **Chunk signer.** Must be a (keypair associated to an) EOA. Sign uploads. (In postage contract, this is also "owner" for the purpose of expanding batches.)

The main user profiles we wish to serve are:

* Owner = payer = signer. One key controlling everything. The default model that seems to be assumed by Swarm's postage contract.
* Owner = signer != payer. The account owner requisitions a budget from a vault that holds funds. 
  * Separate attack surface for token-holding account.
  * Unlock smart account payer which may bring cost management features such as spending limits.
  * Payer may even be a distinct entity, e.g. a DAO that assigns a budget for hosting to be managed by a contributor.

## API

*Owner API.*

* Create volume
* Modify volume
  * Update expiry
  * Expand (owner = chunk signer)
* Delete volume

*Payer API.*

* Authorize owner
* Revoke authorization

Components:

* **Paymaster.** Execute payments, track account info (owner/payer pairs, delegation options). Upkeep via gas boy.
* **Registry.** Maintain collection of volumes, management endpoints.

## Gas boy

Called "keeper" pattern by Chainlink. Gas boy must trigger the paymaster contract to execute payments.

* *Altruistic.* Free tier Cloudflare/AWS serverless trigger. Must maintain nominal xDAI balance for gas payments. (Gas sponsorship possible?) Needs global trigger() that iterates through all volumes.
* *Volume owner.* May maintain their own batch. Needs trigger() endpoint accepting a specific batch id.
* *App owner.* App builders may be incentivised to ensure upkeep of user batches. Needs batch id groups for trigger().

### Reliability layer

Gas boy may deposit assets into a contract with `keepalive()` trigger that extends a timelock as well as keeping alive the batch. If timelock expires, assets may be claimed by anyone. 

Etherscan offers an email alert service that triggers on token transfer on a watched address, so this also serves as an email alert on keepalive failures.

## Security

* *Owner compromise.* If separate, payer must revoke owner or adversary can drain funds by creating huge batches. 

* Revocation must occur on all batches with that owner/payer pair. => don't store payer information in the volume metadata, look up on a separate table.

* Ability to create or expand batches equals ability to drain funds from registered payer.

* Management feature: designate "operator" account with limited access to management functions (e.g. total batch size limit).

## Test cases

### Volume health guarantees

* *Survival.* The batch associated to an adequately funded, non-expiring volume must survive for longer than the grace period.
* *Removal.* After a volume is removed, no new topup payments associated with that volume can occur.
  * A volume can be removed because it is *deleted* or because it *expires*. 
  * A volume can also be cleaned up if payment fails repeatedly and the underlying batch expires, but this is not considered "removal."
  * If no other volumes exist with the same designated funding wallet, a keepalive() transaction cannot result in funds being transferred from that funding wallet.
  * If no other sources top up that batch, the batch will not be topped up.

### Funding source designation + auth flow

* *Funding wallet designation.* Owner must designate funding wallet. 
* *Implicit self-designation.* If no action is taken, system may assume owner and funding wallets are the same.
* *Auth transaction.* Funding wallet must create auth transaction but cannot designate itself as owner's registered fund source.
* *Owner-initiated auth flow.* Using Safe as funding wallet: owner may initiate by proposing auth transaction to funding wallet via Safe API

### Keepalive

* Keepalive is *idempotent* in the sense that if it is called twice consecutively (with no other code executing in between), the second call is a no-op. In particular, calling it "too frequently" cannot cause user funds to be drained more quickly.

  Keepalive should target a particular balance per chunk, calculated as what is required to keep the batch alive for the configured grace period at the current storage price.

### Payment failure

*As long as the underlying batch exists, the volume exists, even if it cannot be topped up.* 

*Once the underlying batch expires, even if it expires early due to a failure, the volume can be cleaned up.*

Failure modes:

* Payment call reverts (not enough funds, spending limit reached).
* Funding wallet has not completed auth flow or has revoked auth.