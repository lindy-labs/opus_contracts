mod AbsorberRoles {
    const KILL: u128 = 1;
    const SET_REMOVAL_LIMIT: u128 = 2;
    const SET_REWARD: u128 = 4;
    const UPDATE: u128 = 8;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        KILL + SET_REMOVAL_LIMIT + SET_REWARD
    }
}

mod AllocatorRoles {
    const SET_ALLOCATION: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SET_ALLOCATION
    }
}

mod EqualizerRoles {
    const SET_ALLOCATOR: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SET_ALLOCATOR
    }
}

mod GateRoles {
    const ENTER: u128 = 1;
    const EXIT: u128 = 2;
    const KILL: u128 = 4;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        KILL
    }
}

mod PragmaRoles {
    const ADD_YANG: u128 = 1;
    const SET_ORACLE_ADDRESS: u128 = 2;
    const SET_PRICE_VALIDITY_THRESHOLDS: u128 = 4;
    const SET_UPDATE_FREQUENCY: u128 = 8;
    const UPDATE_PRICES: u128 = 16;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_YANG + SET_ORACLE_ADDRESS + SET_PRICE_VALIDITY_THRESHOLDS + SET_UPDATE_FREQUENCY
    }
}

mod ShrineRoles {
    const ADD_YANG: u128 = 1;
    const ADVANCE: u128 = 2;
    const DEPOSIT: u128 = 4;
    const EJECT: u128 = 8;
    const FORGE: u128 = 16;
    const INJECT: u128 = 32;
    const KILL: u128 = 64;
    const MELT: u128 = 128;
    const REDISTRIBUTE: u128 = 256;
    const SEIZE: u128 = 512;
    const SET_CEILING: u128 = 1024;
    const SET_MULTIPLIER: u128 = 2048;
    const SET_THRESHOLD: u128 = 4096;
    const UPDATE_RATES: u128 = 8192;
    const WITHDRAW: u128 = 16384;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_YANG + SET_CEILING + SET_THRESHOLD + KILL + UPDATE_RATES
    }

    #[inline(always)]
    fn flash_mint() -> u128 {
        INJECT + EJECT
    }
}


mod SentinelRoles {
    const ADD_YANG: u128 = 1;
    const ENTER: u128 = 2;
    const EXIT: u128 = 4;
    const SET_YANG_ASSET_MAX: u128 = 8;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_YANG + SET_YANG_ASSET_MAX
    }
}
