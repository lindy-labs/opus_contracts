namespace ShrineRoles {
    //
    // Roles
    //
    const ADD_YANG = 2 ** 0;
    const ADVANCE = 2 ** 1;
    const DEPOSIT = 2 ** 2;
    const DISTRIBTUE = 2 ** 3;
    const FORGE = 2 ** 4;
    const KILL = 2 ** 5;
    const MELT = 2 ** 6;
    const MOVE_YANG = 2 ** 7;
    const MOVE_YIN = 2 ** 8;
    const SEIZE = 2 ** 9;
    const SET_CEILING = 2 ** 10;
    const SET_THRESHOLD = 2 ** 11;
    const UPDATE_MULTIPLIER = 2 ** 12;
    const UPDATE_YANG_MAX = 2 ** 13;
    const WITHDRAW = 2 ** 14;

    //
    // Constants
    //
    const DEFAULT_SHRINE_ADMIN_ROLE = ADD_YANG + UPDATE_YANG_MAX + SET_CEILING + SET_THRESHOLD + KILL;
}
