import decimal

from tests.utils import to_ray, to_wad

FIRST_DEPOSIT_AMT = to_wad(50)
FIRST_REBASE_AMT = to_wad(5)
TAX = to_ray(decimal.Decimal("0.05"))
