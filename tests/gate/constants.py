import decimal

from tests.utils import to_ray, to_wad

INITIAL_AMT = to_wad(100)
FIRST_DEPOSIT_AMT = to_wad(50)
SECOND_DEPOSIT_AMT = INITIAL_AMT - FIRST_DEPOSIT_AMT
FIRST_REBASE_AMT = to_wad(5)
TAX = to_ray(decimal.Decimal("0.05"))
