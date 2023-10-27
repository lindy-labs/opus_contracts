mod absorber_roles {
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

mod allocator_roles {
    const SET_ALLOCATION: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SET_ALLOCATION
    }
}

mod blesser_roles {
    const BLESS: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        BLESS
    }
}

mod caretaker_roles {
    const SHUT: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SHUT
    }
}

mod controller_roles {
    const TUNE_CONTROLLER: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        TUNE_CONTROLLER
    }
}

mod equalizer_roles {
    const SET_ALLOCATOR: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SET_ALLOCATOR
    }
}

mod pragma_roles {
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

mod purger_roles {
    const SET_PENALTY_SCALAR: u128 = 1;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        SET_PENALTY_SCALAR
    }
}

mod sentinel_roles {
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

mod shrine_roles {
    const ADD_YANG: u128 = 1;
    const ADJUST_BUDGET: u128 = 2;
    const ADVANCE: u128 = 4;
    const DEPOSIT: u128 = 8;
    const EJECT: u128 = 16;
    const FORGE: u128 = 32;
    const INJECT: u128 = 64;
    const KILL: u128 = 128;
    const MELT: u128 = 256;
    const REDISTRIBUTE: u128 = 512;
    const SEIZE: u128 = 1024;
    const SET_DEBT_CEILING: u128 = 2048;
    const SET_MULTIPLIER: u128 = 4096;
    const SET_THRESHOLD: u128 = 8192;
    const UPDATE_RATES: u128 = 16384;
    const UPDATE_YANG_SUSPENSION: u128 = 32768;
    const UPDATE_YIN_SPOT_PRICE: u128 = 65536;
    const WITHDRAW: u128 = 131072;

    #[inline(always)]
    fn abbot() -> u128 {
        DEPOSIT + FORGE + MELT + WITHDRAW
    }

    #[inline(always)]
    fn bond() -> u128 {
        EJECT + INJECT
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
        EJECT + INJECT + ADJUST_BUDGET
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
            + ADJUST_BUDGET
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

mod bond_roles {
    const ADD_ASSET: u128 = 1;
    const BORROW: u128 = 2;
    const CLOSE: u128 = 4;
    const KILL: u128 = 8;
    const LIQUIDATE: u128 = 16;
    const SET_CEILING: u128 = 32;
    const SET_PRICE: u128 = 64;
    const SET_RATE: u128 = 128;
    const SET_THRESHOLD: u128 = 256;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_ASSET + BORROW + CLOSE + KILL + LIQUIDATE + SET_CEILING + SET_PRICE + SET_THRESHOLD
    }

    #[inline(always)]
    fn borrower() -> u128 {
        BORROW + CLOSE
    }

    #[inline(always)]
    fn bond_registry() -> u128 {
        KILL
    }
}

mod bond_registry_roles {
    const ADD_BOND: u128 = 1;
    const KILL: u128 = 2;
    const REMOVE_BOND: u128 = 4;

    #[inline(always)]
    fn default_admin_role() -> u128 {
        ADD_BOND + KILL + REMOVE_BOND
    }

    #[inline(always)]
    fn caretaker() -> u128 {
        KILL
    }
}
