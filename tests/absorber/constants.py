from decimal import Decimal

from tests.utils import WBTC_DECIMALS, str_to_felt, to_fixed_point, to_wad

# Initial shares minted to the system if total shares are 0
INITIAL_SHARES_WAD = Decimal("1E3")

DEBT_CEILING_WAD = to_wad(1_000_000)

# Starting value of USD 20_000
USER_STETH_DEPOSIT_WAD = to_wad(10)

# Starting value of USD 700
USER_DOGE_DEPOSIT_WAD = to_wad(10_000)

# Starting value of USD 10_000, with WBTC decimal precision
USER_WBTC_DEPOSIT_AMT = to_fixed_point(5, WBTC_DECIMALS)

# Constants for providers to absorber
PROVIDER_STETH_DEPOSIT_WAD = to_wad(100)

PROVIDER_1 = str_to_felt("provider 1")
PROVIDER_1_TROVE = 4
PROVIDER_2 = str_to_felt("provider 2")
PROVIDER_2_TROVE = 5

MOCK_PURGER = str_to_felt("mock purger")
BURNER = str_to_felt("burner")
NON_PROVIDER = str_to_felt("non-provider")

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
