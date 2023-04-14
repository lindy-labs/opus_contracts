from decimal import Decimal

from tests.utils.utils import str_to_felt
from tests.utils.wadray import to_ray, to_wad

# Constants for removal request
SECONDS_PER_MINUTE = 60
SECONDS_PER_DAY = 24 * 60 * SECONDS_PER_MINUTE
REQUEST_BASE_TIMELOCK_SECONDS = SECONDS_PER_MINUTE
REQUEST_MAX_TIMELOCK_SECONDS = 7 * SECONDS_PER_DAY
REQUEST_VALIDITY_PERIOD_SECONDS = 60 * SECONDS_PER_MINUTE
REQUEST_TIMELOCK_COOLDOWN = 7 * SECONDS_PER_DAY
REQUEST_TIMELOCK_MULTIPLIER = 5

# Initial shares minted to the system if total shares are 0
INITIAL_SHARES_WAD = Decimal("1E3")

REMOVAL_LIMIT_RAY = to_ray(Decimal("0.9"))
MIN_REMOVAL_LIMIT_RAY = to_ray(Decimal("0.5"))

DEBT_CEILING_WAD = to_wad(1_000_000)

# Constants for providers to absorber
PROVIDER_STETH_DEPOSIT_WAD = to_wad(100)

PROVIDER_1 = str_to_felt("provider 1")
PROVIDER_1_TROVE = 4
PROVIDER_2 = str_to_felt("provider 2")
PROVIDER_2_TROVE = 5

MOCK_PURGER = str_to_felt("mock purger")
NEW_MOCK_PURGER = str_to_felt("new mock purger")
BURNER = str_to_felt("burner")
NON_PROVIDER = str_to_felt("non-provider")
BLESSER_OWNER = str_to_felt("blesser owner")

MAX_REMOVE_AMT = 2**125

# Amounts of assets for first update
FIRST_UPDATE_ASSETS_AMT = [
    Decimal("10"),  # stETH,
    Decimal("10_000"),  # DOGE,
    Decimal("1"),  # WBTC
]

SECOND_UPDATE_ASSETS_AMT = [
    Decimal("6.5"),  # stETH,
    Decimal("5_555"),  # DOGE,
    Decimal("0.234"),  # WBTC
]

AURA_BLESS_AMT = Decimal("1_000")
AURA_BLESS_AMT_WAD = to_wad(AURA_BLESS_AMT)
AURA_BLESSER_STARTING_BAL = Decimal("1_000_000")

VESTED_AURA_BLESS_AMT = Decimal("999")
VESTED_AURA_BLESS_AMT_WAD = to_wad(VESTED_AURA_BLESS_AMT)
VESTED_AURA_BLESSER_STARTING_BAL = Decimal("5_000_000")
