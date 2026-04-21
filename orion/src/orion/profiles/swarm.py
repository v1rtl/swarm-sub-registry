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
TOKEN_CAP = 10**12 * 10**16  # 10^12 BZZ at 16-decimal precision

SWARM = Constellation(
    name="swarm",
    contracts=[
        ContractSpec(
            name="Token",
            artifact="TestToken",  # NB: testnet, not mainnet Token
            args=["BZZ", "BZZ", 16, TOKEN_CAP],
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
