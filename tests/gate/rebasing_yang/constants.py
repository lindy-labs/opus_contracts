import decimal

from tests.utils import to_ray, to_uint, to_wad

TAX = decimal.Decimal("0.025")
TAX_MAX = decimal.Decimal("0.05")
TAX_RAY = to_ray(TAX)

INITIAL_AMT = to_wad(100)
INITIAL_AMT_UINT = to_uint(INITIAL_AMT)

FIRST_DEPOSIT_AMT = to_wad(50)
FIRST_DEPOSIT_AMT_UINT = to_uint(FIRST_DEPOSIT_AMT)
FIRST_MINT_AMT = FIRST_DEPOSIT_AMT
FIRST_MINT_AMT_UINT = to_uint(FIRST_MINT_AMT)
FIRST_REBASE_AMT = to_wad(5)
FIRST_REBASE_AMT_UINT = to_uint(FIRST_REBASE_AMT)
FIRST_TAX_AMT = int(TAX * FIRST_REBASE_AMT)

SECOND_DEPOSIT_AMT = INITIAL_AMT - FIRST_DEPOSIT_AMT
SECOND_DEPOSIT_AMT_UINT = to_uint(SECOND_DEPOSIT_AMT)
SECOND_MINT_AMT = to_wad(4)
SECOND_MINT_AMT_UINT = to_uint(SECOND_MINT_AMT)

# Value for simulated `compound` in `levy` for `test_gate_taxable.cairo`
COMPOUND_MULTIPLIER = decimal.Decimal("1.1")
