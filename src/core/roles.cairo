mod AbsorberRoles {
    const KILL: u128 = 1;
    const SET_REMOVAL_LIMIT: u128 = 2;
    const SET_REWARD: u128 = 4;
    const UPDATE: u128 = 8;

    #[inline(always)]
    fn purger() -> u128 {
        UPDATE
    }

    #[inline(always)]
    fn default_admin_role() -> u128 {
        KILL + SET_REMOVAL_LIMIT + SET_REWARD
    }
}

mod BlesserRoles {
    const BLESS: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        BLESS
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

mod SentinelRoles {
    const ADD_YANG: u128 = 1;
    const ENTER: u128 = 2;
    const EXIT: u128 = 4;
    const KILL_GATE: u128 = 8;
    const SET_YANG_ASSET_MAX: u128 = 16;
    const UPDATE_YANG_SUSPENSION: u128 = 32;

    #[inline(always)]
    fn abbot() -> u128 {
        ENTER + EXIT
    }

    #[inline(always)]
    fn purger() -> u128 {
        EXIT
    }

    #[inline(always)]
    fn caretaker() -> u128 {
        EXIT
    }

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_YANG + KILL_GATE + SET_YANG_ASSET_MAX + UPDATE_YANG_SUSPENSION
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
    const SET_DEBT_CEILING: u128 = 1024;
    const SET_MULTIPLIER: u128 = 2048;
    const SET_THRESHOLD: u128 = 4096;
    const UPDATE_RATES: u128 = 8192;
    const UPDATE_YANG_SUSPENSION: u128 = 16384;
    const UPDATE_YIN_SPOT_PRICE: u128 = 32768;
    const WITHDRAW: u128 = 65536;

    #[inline(always)]
    fn abbot() -> u128 {
        DEPOSIT + FORGE + MELT + WITHDRAW
    }

    #[inline(always)]
    fn caretaker() -> u128 {
        EJECT + KILL + SEIZE
    }

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_YANG + SET_DEBT_CEILING + SET_THRESHOLD + KILL + UPDATE_RATES
    }

    #[inline(always)]
    fn flash_mint() -> u128 {
        INJECT + EJECT
    }

    #[inline(always)]
    fn purger() -> u128 {
        MELT + REDISTRIBUTE + SEIZE
    }

    #[inline(always)]
    fn sentinel() -> u128 {
        ADD_YANG + UPDATE_YANG_SUSPENSION
    }

    #[cfg(test)]
    #[inline(always)]
    fn all_roles() -> u128 {
        ADD_YANG
            + ADVANCE
            + DEPOSIT
            + EJECT
            + FORGE
            + INJECT
            + KILL
            + MELT
            + REDISTRIBUTE
            + SEIZE
            + SET_DEBT_CEILING
            + SET_MULTIPLIER
            + SET_THRESHOLD
            + UPDATE_RATES
            + UPDATE_YANG_SUSPENSION
            + UPDATE_YIN_SPOT_PRICE
            + WITHDRAW
    }
}
