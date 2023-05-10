mod ShrineRoles {
    const ADD_YANG: u128 = 1;
    const ADVANCE: u128 = 2;
    const DEPOSIT: u128 = 4;
    const EJECT: u128 = 8;
    const FORGE: u128 = 16;
    const INJECT: u128 = 32;
    const KILL: u128 = 64;
    const MELT: u128 = 128;
    const MOVE_YANG: u128 = 256;
    const REDISTRIBUTE: u128 = 512;
    const SEIZE: u128 = 1024;
    const SET_CEILING: u128 = 2048;
    const SET_MULTIPLIER: u128 = 4096;
    const SET_THRESHOLD: u128 = 8192;
    const SET_YANG_MAX: u128 = 16384;
    const UPDATE_RATES: u128 = 32768;
    const WITHDRAW: u128 = 65536;

    fn default_admin_role() -> u128 {
        ADD_YANG + SET_YANG_MAX + SET_CEILING + SET_THRESHOLD + KILL + UPDATE_RATES
    }

    fn flash_mint() -> u128 {
        INJECT + EJECT
    }
}
