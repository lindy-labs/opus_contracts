namespace ShrineRoles:
    #
    # Roles
    #
    const ADD_YANG = 2 ** 0
    const UPDATE_YANG_MAX = 2 ** 1
    const SET_CEILING = 2 ** 2
    const SET_THRESHOLD = 2 ** 3
    const KILL = 2 ** 4
    const ADVANCE = 2 ** 5
    const UPDATE_MULTIPLIER = 2 ** 6
    const MOVE_YANG = 2 ** 7
    const DEPOSIT = 2 ** 8
    const WITHDRAW = 2 ** 9
    const FORGE = 2 ** 10
    const MELT = 2 ** 11
    const SEIZE = 2 ** 12
    const MOVE_YIN = 2 ** 13

    #
    # Constants
    #
    const DEFAULT_SHRINE_ADMIN_ROLE = ADD_YANG + UPDATE_YANG_MAX + SET_CEILING + SET_THRESHOLD + KILL
end
