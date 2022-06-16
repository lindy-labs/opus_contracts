from utils import (
    WAD_SCALE,
    RAY_SCALE
)

from decimal import Decimal

# Shrine setup constants
GAGES = [
    {
        "start_price": 2000,
        "ceiling": 10_000 * WAD_SCALE,
    },
    {
        "start_price": 500,
        "ceiling": 100_000 * WAD_SCALE,
    },
    {"start_price": 1.25, "ceiling": 10_000_000 * WAD_SCALE},
]

FEED_LEN = 20
MAX_PRICE_CHANGE = 0.025
MULTIPLIER_FEED = [RAY_SCALE] * FEED_LEN

SECONDS_PER_MINUTE = 60

DEBT_CEILING = 10_000 * WAD_SCALE
LIQUIDATION_THRESHOLD = 8 * 10**17

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

# 1 / Number of intervals in a year
TIME_INTERVAL_DIV_YEAR = Decimal("0.00005707762557077625")
