from decimal import Decimal

from tests.utils.math import to_ray, to_wad
from tests.utils.utils import str_to_felt

TAX = Decimal("0.025")
TAX_MAX = Decimal("0.05")
TAX_RAY = to_ray(TAX)

INITIAL_AMT = 100

FIRST_DEPOSIT_AMT = 50
FIRST_DEPOSIT_YANG = to_wad(FIRST_DEPOSIT_AMT)

FIRST_REBASE_AMT = 5
FIRST_TAX_AMT = TAX * FIRST_REBASE_AMT

SECOND_DEPOSIT_AMT = INITIAL_AMT - FIRST_DEPOSIT_AMT

# Value for simulated `compound` in `levy` for `test_gate_taxable.cairo`
COMPOUND_MULTIPLIER = Decimal("1.1")

# Accounts
TAX_COLLECTOR = str_to_felt("tax collector")

# Minimum initial deposit to prevent first depositor front-running
MINIMUM_INITIAL_DEPOSIT = 10**3
