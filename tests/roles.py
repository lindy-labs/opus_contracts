from enum import IntEnum


class SentinelRoles(IntEnum):
    ADD_YANG = 2**0
    ENTER = 2**1
    EXIT = 2**2


class EmpiricRoles(IntEnum):
    ADD_YANG = 2**0
    SET_ORACLE_ADDRESS = 2**1
    SET_PRICE_VALIDITY_THRESHOLDS = 2**2
    SET_UPDATE_INTERVAL = 2**3


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
    FLASH_MINT = 2**3
    FORGE = 2**4
    KILL = 2**5
    MELT = 2**6
    MOVE_YANG = 2**7
    REDISTRIBUTE = 2**8
    SEIZE = 2**9
    SET_CEILING = 2**10
    SET_MULTIPLIER = 2**11
    SET_THRESHOLD = 2**12
    SET_YANG_MAX = 2**13
    WITHDRAW = 2**14
