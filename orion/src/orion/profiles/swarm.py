"""Reference profile — the Swarm Constellation.

Encodes ../kabashira-docs/SWARM_CONSTELLATION.md as data: 5 contracts,
constructor dependencies, 4 role grants. The reference orion consumer
(alectryon-harness) reads this exact shape.

Note: ``Token`` uses the **testnet** TestToken artifact, not the mainnet
one — the mainnet artifact is a bridged-token reference and does not
contain deployable bytecode. See ISSUES.md:artifact-prefix.
"""

from orion.constellation import Constellation, ContractSpec, Ref, RoleGrant


NETWORK_ID = 1

# TestToken constructor is (name, symbol, initialSupply). Decimals are
# hardcoded to 16 in TestToken.sol via an override; there is no cap
# argument — the deployer holds MINTER_ROLE and mints on demand. Initial
# supply is 0 because participant provisioning does explicit mints
# per label.
SWARM = Constellation(
    name="swarm",
    contracts=[
        ContractSpec(
            name="Token",
            artifact="TestToken",  # NB: testnet, not mainnet Token
            args=["BZZ", "BZZ", 0],
        ),
        ContractSpec(
            name="PostageStamp",
            artifact="PostageStamp",
            args=[Ref("Token"), 16],  # minBucketDepth
        ),
        ContractSpec(
            name="PriceOracle",
            artifact="PriceOracle",
            args=[Ref("PostageStamp")],
        ),
        ContractSpec(
            name="StakeRegistry",
            artifact="StakeRegistry",
            args=[Ref("Token"), NETWORK_ID, Ref("PriceOracle")],
        ),
        ContractSpec(
            name="Redistribution",
            artifact="Redistribution",
            args=[Ref("StakeRegistry"), Ref("PostageStamp"), Ref("PriceOracle")],
        ),
    ],
    role_grants=[
        RoleGrant("PostageStamp",  "REDISTRIBUTOR_ROLE", "Redistribution"),
        RoleGrant("PostageStamp",  "PRICE_ORACLE_ROLE",  "PriceOracle"),
        RoleGrant("StakeRegistry", "REDISTRIBUTOR_ROLE", "Redistribution"),
        RoleGrant("PriceOracle",   "PRICE_UPDATER_ROLE", "Redistribution"),
    ],
)
