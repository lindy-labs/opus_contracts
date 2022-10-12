from decimal import Decimal

from tests.utils import str_to_felt, to_wad

#
# Constants
#

MAX_PENALTY_LTV = Decimal("0.8888")

DEBT_CEILING_WAD = to_wad(100_000)

# Starting value of USD 20_000
USER_STETH_DEPOSIT_WAD = to_wad(10)

# Starting value of USD 700
USER_DOGE_DEPOSIT_WAD = to_wad(10_000)

SEARCHER = str_to_felt("searcher")
SEARCHER_STETH_WAD = to_wad(1_000)
SEARCHER_FORGE_AMT_WAD = to_wad(50_000)
