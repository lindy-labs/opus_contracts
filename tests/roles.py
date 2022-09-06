from enum import IntEnum


class AbbotRoles(IntEnum):
    ADD_YANG = 2**0


class GateRoles(IntEnum):
    DEPOSIT = 2**0
    KILL = 2**1
    SET_TAX = 2**2
    SET_TAX_COLLECTOR = 2**3
    WITHDRAW = 2**4


class PurgerRoles(IntEnum):
    RESTRICTED_PURGE = 2**0


class ShrineRoles(IntEnum):
    ADD_YANG = 2**0
    ADVANCE = 2**1
    DEPOSIT = 2**2
    FORGE = 2**3
    KILL = 2**4
    MELT = 2**5
    MOVE_YANG = 2**6
    MOVE_YIN = 2**7
    SEIZE = 2**8
    SET_CEILING = 2**9
    SET_THRESHOLD = 2**10
    UPDATE_MULTIPLIER = 2**11
    UPDATE_YANG_MAX = 2**12
    WITHDRAW = 2**13
