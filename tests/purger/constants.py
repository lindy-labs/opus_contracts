from decimal import Decimal

from tests.utils import WBTC_DECIMALS, str_to_felt, to_fixed_point, to_wad

#
# Constants
#

MIN_PENALTY = Decimal("0.03")
MAX_PENALTY = Decimal("0.125")
MAX_PENALTY_LTV = Decimal("0.8888")

DEBT_CEILING_WAD = to_wad(1_000_000)

# Starting value of USD 20_000
USER_STETH_DEPOSIT_WAD = to_wad(10)

# Starting value of USD 700
USER_DOGE_DEPOSIT_WAD = to_wad(10_000)

# Starting value of USD 10_000, with WBTC decimal precision
USER_WBTC_DEPOSIT_AMT = to_fixed_point(5, WBTC_DECIMALS)

SEARCHER = str_to_felt("searcher")
SEARCHER_STETH_WAD = to_wad(2_000)
SEARCHER_FORGE_AMT_WAD = to_wad(100_000)

ABSORBER_PROVIDER = str_to_felt("absorber provider")
ABSORBER_PROVIDER_STETH_WAD = to_wad(1_000)
ABSORBER_PROVIDER_FORGE_AMT_WAD = to_wad(100_000)