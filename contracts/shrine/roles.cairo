namespace ShrineRoles {
    //
    // Roles
    //
    const ADD_YANG = 2 ** 0;
    const ADVANCE = 2 ** 1;
    const DEPOSIT = 2 ** 2;
    const FORGE = 2 ** 3;
    const KILL = 2 ** 4;
    const MELT = 2 ** 5;
    const MOVE_YANG = 2 ** 6;
    const MOVE_YIN = 2 ** 7;
    const PURGE = 2 ** 8;
    const SET_CEILING = 2 ** 9;
    const SET_THRESHOLD = 2 ** 10;
    const UPDATE_MULTIPLIER = 2 ** 11;
    const UPDATE_YANG_MAX = 2 ** 12;
    const WITHDRAW = 2 ** 13;

    //
    // Constants
    //
    const DEFAULT_SHRINE_ADMIN_ROLE = ADD_YANG + UPDATE_YANG_MAX + SET_CEILING + SET_THRESHOLD + KILL;
}
