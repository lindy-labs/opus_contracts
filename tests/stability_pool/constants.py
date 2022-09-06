from tests.utils import (
    str_to_felt
)
from tests.purger.constants import USER_STETH_DEPOSIT_WAD, USER_DOGE_DEPOSIT_WAD

USER_2 = str_to_felt("user2")
# We base the user2 deposits (for opening a trove) based on
# the AURA_USER deposits, to maintaing easier calculations
USER_2_STETH_DEPOSIT_WAD = USER_STETH_DEPOSIT_WAD // 2
USER_2_DOGE_DEPOSIT_WAD = USER_DOGE_DEPOSIT_WAD // 2

USER_3 = str_to_felt("user3")
# We base the user2 deposits (for opening a trove) based on
# the AURA_USER deposits, to maintaing easier calculations
USER_3_STETH_DEPOSIT_WAD = USER_STETH_DEPOSIT_WAD // 2
USER_3_DOGE_DEPOSIT_WAD = USER_DOGE_DEPOSIT_WAD // 2