from datetime import datetime
from decimal import Decimal

from tests.roles import GateRoles, SentinelRoles, ShrineRoles
from tests.utils.math import WAD_RAY_BOUND, custom_error_margin, signed_int_to_felt
from tests.utils.utils import get_interval, str_to_felt

#
# Cairo constants
#


RANGE_CHECK_BOUND = 2**128
MAX_UINT256 = (2**128 - 1, 2**128 - 1)

ZERO_ADDRESS = 0

TRUE = 1
FALSE = 0


# Out of bound values for WadRay
WAD_RAY_OOB_VALUES = [signed_int_to_felt(-1), WAD_RAY_BOUND + 1]


#
# Time constants
#


# Note that timestamp (and timestamp) cannot start at 0 because:
# 1. Initial price and multiplier are assigned to current interval - 1
# 2. Cooldown period in absorber will be automatically triggered
DEPLOYMENT_TIMESTAMP = int(datetime.utcnow().timestamp())
DEPLOYMENT_INTERVAL = get_interval(DEPLOYMENT_TIMESTAMP)

# 1 / Number of intervals in a year (1 / (2 * 24 * 365) = 0.00005707762557077625)
TIME_INTERVAL_DIV_YEAR = Decimal("0.00005707762557077625")


#
# Token constants
#


# Decimal precision
WBTC_DECIMALS = 8
EMPIRIC_DECIMALS = 8

# Default error margin for fixed point calculations
ERROR_MARGIN = custom_error_margin(10)


#
# Addresses
#

ABBOT_OWNER = str_to_felt("abbot owner")
SENTINEL_OWNER = str_to_felt("sentinel owner")
GATE_OWNER = str_to_felt("gate owner")
SHRINE_OWNER = str_to_felt("shrine owner")
EMPIRIC_OWNER = str_to_felt("empiric owner")
ABSORBER_OWNER = str_to_felt("absorber owner")

BAD_GUY = str_to_felt("bad guy")


#
# Roles
#


GATE_ROLE_FOR_SENTINEL = GateRoles.ENTER + GateRoles.EXIT
SENTINEL_ROLE_FOR_ABBOT = SentinelRoles.ENTER + SentinelRoles.EXIT
SHRINE_ROLE_FOR_PURGER = ShrineRoles.MELT + ShrineRoles.SEIZE + ShrineRoles.REDISTRIBUTE
SHRINE_ROLE_FOR_FLASHMINT = ShrineRoles.INJECT + ShrineRoles.EJECT


#
# Shrine constants
#

# Troves
TROVE_1 = 1
TROVE_2 = 2
TROVE_3 = 3

TROVE1_OWNER = str_to_felt("trove 1 owner")
TROVE2_OWNER = str_to_felt("trove 2 owner")
TROVE3_OWNER = str_to_felt("trove 3 owner")

# Yin constants
INFINITE_YIN_ALLOWANCE = 2**256 - 1


#
# Gate constants
#

# Initial deposit amount to Gate to prevent first depositor front-running
INITIAL_ASSET_DEPOSIT_AMT = 10**3
