from decimal import Decimal

from tests.roles import ShrineRoles
from tests.utils import RAY_PERCENT, RAY_SCALE, str_to_felt, to_wad

YIN_NAME = str_to_felt("Cash")
YIN_SYMBOL = str_to_felt("CASH")

LIQUIDATION_THRESHOLD = 80 * RAY_PERCENT

YANG1_ADDRESS = 1234
YANG2_ADDRESS = 2345
YANG3_ADDRESS = 3456
YANG4_ADDRESS = 4567
FAUX_YANG_ADDRESS = 7890

YIN_USER1 = str_to_felt("yin user 1")
YIN_USER2 = str_to_felt("yin user 2")


# Shrine setup constants
YANGS = [
    {
        "id": 1,
        "address": YANG1_ADDRESS,
        "start_price": Decimal("2000"),
        "threshold": LIQUIDATION_THRESHOLD,
        "rate": Decimal("0.02"),
    },
    {
        "id": 2,
        "address": YANG2_ADDRESS,
        "start_price": Decimal("500"),
        "threshold": LIQUIDATION_THRESHOLD,
        "rate": Decimal("0.03"),
    },
    {
        "id": 3,
        "address": YANG3_ADDRESS,
        "start_price": Decimal("1.25"),
        "threshold": LIQUIDATION_THRESHOLD,
        "rate": Decimal("0.04"),
    },
    {
        "id": 4,
        "address": YANG4_ADDRESS,
        "start_price": Decimal("17.5"),
        "threshold": LIQUIDATION_THRESHOLD,
        "rate": Decimal("0.05"),
    },
]

YANG1_THRESHOLD = YANGS[0]["threshold"]
YANG1_ID = YANGS[0]["id"]

INITIAL_DEPOSIT = 10
INITIAL_DEPOSIT_WAD = to_wad(INITIAL_DEPOSIT)

FEED_LEN = 10
MAX_PRICE_CHANGE = 0.025
MULTIPLIER_FEED = [RAY_SCALE] * FEED_LEN

DEBT_CEILING = to_wad(20_000)

MAX_BASE_RATE = 0.1

# Threshold test constants
DEPOSITS = [
    {
        "address": YANG1_ADDRESS,
        "amount": to_wad(4),
        "threshold": YANGS[0]["threshold"],
    },
    {
        "address": YANG2_ADDRESS,
        "amount": to_wad(5),
        "threshold": YANGS[1]["threshold"],
    },
    {
        "address": YANG3_ADDRESS,
        "amount": to_wad(6),
        "threshold": YANGS[2]["threshold"],
    },
]

# Forge constant
FORGE_AMT_WAD = to_wad(5_000)

SHRINE_FULL_ACCESS = sum([r.value for r in ShrineRoles])

# Redistribute constants
MOCK_PURGER = str_to_felt("purger")
