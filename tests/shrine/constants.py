from decimal import Decimal

from tests.roles import ShrineRoles
from tests.utils import RAY_PERCENT, RAY_SCALE, WAD_SCALE

LIQUIDATION_THRESHOLD = 80 * RAY_PERCENT

YANG1_ADDRESS = 1234
YANG2_ADDRESS = 2345
YANG3_ADDRESS = 3456
FAUX_YANG_ADDRESS = 7890


# Shrine setup constants
YANGS = [
    {
        "id": 1,
        "address": YANG1_ADDRESS,
        "start_price": Decimal("2000"),
        "ceiling": 10_000 * WAD_SCALE,
        "threshold": LIQUIDATION_THRESHOLD,
    },
    {
        "id": 2,
        "address": YANG2_ADDRESS,
        "start_price": Decimal("500"),
        "ceiling": 100_000 * WAD_SCALE,
        "threshold": LIQUIDATION_THRESHOLD,
    },
    {
        "id": 3,
        "address": YANG3_ADDRESS,
        "start_price": Decimal("1.25"),
        "ceiling": 10_000_000 * WAD_SCALE,
        "threshold": LIQUIDATION_THRESHOLD,
    },
]

YANG_0_ADDRESS = YANGS[0]["address"]
YANG_0_CEILING = YANGS[0]["ceiling"]
YANG_0_THRESHOLD = YANGS[0]["threshold"]
YANG_0_ID = YANGS[0]["id"]

INITIAL_DEPOSIT = 10
INITIAL_DEPOSIT_WAD = 10 * WAD_SCALE

FEED_LEN = 10
MAX_PRICE_CHANGE = 0.025
MULTIPLIER_FEED = [RAY_SCALE] * FEED_LEN

DEBT_CEILING = 20_000 * WAD_SCALE

# Interest rate piece-wise function parameters
RATE_M1 = Decimal("0.02")
RATE_B1 = Decimal("0")
RATE_M2 = Decimal("0.1")
RATE_B2 = Decimal("-0.04")
RATE_M3 = Decimal("1")
RATE_B3 = Decimal("-0.715")
RATE_M4 = Decimal("3.101908")
RATE_B4 = Decimal("-2.651908222")

# Interest rate piece-wise range bounds
RATE_BOUND1 = Decimal("0.5")
RATE_BOUND2 = Decimal("0.75")
RATE_BOUND3 = Decimal("0.9215")


# Threshold test constants
DEPOSITS = [
    {
        "address": YANG1_ADDRESS,
        "amount": 4 * WAD_SCALE,
        "threshold": YANGS[0]["threshold"],
    },
    {
        "address": YANG2_ADDRESS,
        "amount": 5 * WAD_SCALE,
        "threshold": YANGS[1]["threshold"],
    },
    {
        "address": YANG3_ADDRESS,
        "amount": 6 * WAD_SCALE,
        "threshold": YANGS[2]["threshold"],
    },
]

# Forge constant
FORGE_AMT_WAD = 5_000 * WAD_SCALE

SHRINE_FULL_ACCESS = sum([r.value for r in ShrineRoles])
