from enum import IntEnum


class EmpiricRoles(IntEnum):
    ADD_YANG = 2**0
    SET_ORACLE_ADDRESS = 2**1
    SET_PRICE_VALIDITY_THRESHOLDS = 2**2
    SET_UPDATE_INTERVAL = 2**3
    UPDATE_PRICES = 2**4


class EqualizerRoles(IntEnum):
    SET_ALLOCATOR = 2**0


class GateRoles(IntEnum):
    ENTER = 2**0
    EXIT = 2**1
    KILL = 2**2
    SET_TAX = 2**3
    SET_TAX_COLLECTOR = 2**4


class SentinelRoles(IntEnum):
    ADD_YANG = 2**0
    ENTER = 2**1
    EXIT = 2**2
    SET_YANG_ASSET_MAX = 2**3


class ShrineRoles(IntEnum):
    ADD_YANG = 2**0
    ADVANCE = 2**1
    DEPOSIT = 2**2
    FORGE = 2**3
    EJECT = 2**4
    INJECT = 2**5
    KILL = 2**6
    MELT = 2**7
    MOVE_YANG = 2**8
    REDISTRIBUTE = 2**9
    SEIZE = 2**10
    SET_CEILING = 2**11
    SET_MULTIPLIER = 2**12
    SET_THRESHOLD = 2**13
    SET_YANG_MAX = 2**14
    WITHDRAW = 2**15
