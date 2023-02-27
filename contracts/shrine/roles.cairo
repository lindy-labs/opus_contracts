namespace ShrineRoles {
    //
    // Roles
    //
    const ADD_YANG = 2 ** 0;
    const ADVANCE = 2 ** 1;
    const DEPOSIT = 2 ** 2;
    const EJECT = 2 ** 3;
    const FORGE = 2 ** 4;
    const INJECT = 2 ** 5;
    const KILL = 2 ** 6;
    const MELT = 2 ** 7;
    const MOVE_YANG = 2 ** 8;
    const REDISTRIBUTE = 2 ** 9;
    const SEIZE = 2 ** 10;
    const SET_CEILING = 2 ** 11;
    const SET_MULTIPLIER = 2 ** 12;
    const SET_RATES = 2 ** 13;
    const SET_THRESHOLD = 2 ** 14;
    const SET_YANG_MAX = 2 ** 15;
    const WITHDRAW = 2 ** 16;

    //
    // Constants
    //
    const DEFAULT_SHRINE_ADMIN_ROLE = ADD_YANG + SET_YANG_MAX + SET_CEILING + SET_THRESHOLD + KILL + SET_RATES;
    const FLASH_MINT = INJECT + EJECT;
}
