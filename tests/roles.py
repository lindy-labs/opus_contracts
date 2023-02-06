from enum import IntEnum


class SentinelRoles(IntEnum):
    ADD_YANG = 2**0
    ENTER = 2**1
    EXIT = 2**2
    SET_YANG_ASSET_MAX = 2**3


class EmpiricRoles(IntEnum):
    ADD_YANG = 2**0
    SET_ORACLE_ADDRESS = 2**1
    SET_PRICE_VALIDITY_THRESHOLDS = 2**2
    SET_UPDATE_INTERVAL = 2**3
    UPDATE_PRICES = 2**4


class GateRoles(IntEnum):
    ENTER = 2**0
    EXIT = 2**1
    KILL = 2**2
    SET_TAX = 2**3
    SET_TAX_COLLECTOR = 2**4


class ShrineRoles(IntEnum):
    ADD_YANG = 2**0
    ADVANCE = 2**1
    DEPOSIT = 2**2
    FORGE_WITH_TROVE = 2**3
    FORGE_WITHOUT_TROVE = 2**4
    KILL = 2**5
    MELT_WITH_TROVE = 2**6
    MELT_WITHOUT_TROVE = 2**7
    MOVE_YANG = 2**8
    REDISTRIBUTE = 2**9
    SEIZE = 2**10
    SET_CEILING = 2**11
    SET_MULTIPLIER = 2**12
    SET_THRESHOLD = 2**13
    SET_YANG_MAX = 2**14
    WITHDRAW = 2**15
