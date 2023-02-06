namespace ShrineRoles {
    //
    // Roles
    //
    const ADD_YANG = 2 ** 0;
    const ADVANCE = 2 ** 1;
    const DEPOSIT = 2 ** 2;
    const FORGE_WITH_TROVE = 2 ** 3;
    const FORGE_WITHOUT_TROVE = 2 ** 4;
    const KILL = 2 ** 5;
    const MELT_WITH_TROVE = 2 ** 6;
    const MELT_WITHOUT_TROVE = 2 ** 7;
    const MOVE_YANG = 2 ** 8;
    const REDISTRIBUTE = 2 ** 9;
    const SEIZE = 2 ** 10;
    const SET_CEILING = 2 ** 11;
    const SET_MULTIPLIER = 2 ** 12;
    const SET_THRESHOLD = 2 ** 13;
    const SET_YANG_MAX = 2 ** 14;
    const WITHDRAW = 2 ** 15;

    //
    // Constants
    //
    const DEFAULT_SHRINE_ADMIN_ROLE = ADD_YANG + SET_YANG_MAX + SET_CEILING + SET_THRESHOLD + KILL;
    const FLASH_MINT = FORGE_WITHOUT_TROVE + MELT_WITHOUT_TROVE;
}
