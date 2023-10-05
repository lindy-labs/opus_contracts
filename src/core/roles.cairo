mod AbsorberRoles {
    const KILL: u128 = 1;
    const SET_REWARD: u128 = 2;
    const UPDATE: u128 = 4;

    #[inline(always)]
    fn purger() -> u128 {
        UPDATE
    }

    #[inline(always)]
    fn default_admin_role() -> u128 {
        KILL + SET_REWARD
    }
}

mod AllocatorRoles {
    const SET_ALLOCATION: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SET_ALLOCATION
    }
}

mod BlesserRoles {
    const BLESS: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        BLESS
    }
}

mod CaretakerRoles {
    const SHUT: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SHUT
    }
}

mod ControllerRoles {
    const TUNE_CONTROLLER: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        TUNE_CONTROLLER
    }
}

mod EqualizerRoles {
    const SET_ALLOCATOR: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SET_ALLOCATOR
    }
}

mod PragmaRoles {
    const ADD_YANG: u128 = 1;
    const SET_ORACLE_ADDRESS: u128 = 2;
    const SET_PRICE_VALIDITY_THRESHOLDS: u128 = 4;
    const SET_UPDATE_FREQUENCY: u128 = 8;
    const UPDATE_PRICES: u128 = 16;

    #[inline(always)]
    fn purger() -> u128 {
        UPDATE_PRICES
    }

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_YANG + SET_ORACLE_ADDRESS + SET_PRICE_VALIDITY_THRESHOLDS + SET_UPDATE_FREQUENCY
    }
}

mod PurgerRoles {
    const SET_PENALTY_SCALAR: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SET_PENALTY_SCALAR
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
    fn controller() -> u128 {
        SET_MULTIPLIER
    }

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_YANG + SET_DEBT_CEILING + SET_THRESHOLD + KILL + UPDATE_RATES
    }

    #[inline(always)]
    fn equalizer() -> u128 {
        INJECT
    }

    #[inline(always)]
    fn flash_mint() -> u128 {
        INJECT + EJECT
    }

    #[inline(always)]
    fn oracle() -> u128 {
        ADVANCE
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

mod StabilizerRoles {
    const ADD_STRATEGY: u128 = 1;
    const EXECUTE_STRATEGY: u128 = 2;
    const EXTRACT: u128 = 4;
    const INITIALIZE: u128 = 8;
    const KILL: u128 = 16;
    const SET_CEILING: u128 = 32;
    const SET_RECEIVER: u128 = 64;
    const SET_STRATEGY_CEILING: u128 = 128;
    const UNWIND_STRATEGY: u128 = 256;

    #[inline(always)]
    fn caretaker() -> u128 {
        KILL
    }

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_STRATEGY
            + EXECUTE_STRATEGY
            + EXTRACT
            + INITIALIZE
            + KILL
            + SET_CEILING
            + SET_RECEIVER
            + SET_STRATEGY_CEILING
            + UNWIND_STRATEGY
    }
}

