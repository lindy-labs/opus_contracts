pub mod absorber_roles {
    pub const KILL: u128 = 1;
    pub const SET_REWARD: u128 = 2;
    pub const UPDATE: u128 = 4;

    #[inline(always)]
    pub fn purger() -> u128 {
        UPDATE
    }

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        KILL + SET_REWARD
    }
}

pub mod allocator_roles {
    pub const SET_ALLOCATION: u128 = 1;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        SET_ALLOCATION
    }
}

pub mod blesser_roles {
    pub const BLESS: u128 = 1;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        BLESS
    }
}

pub mod caretaker_roles {
    pub const SHUT: u128 = 1;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        SHUT
    }
}

pub mod controller_roles {
    pub const TUNE_CONTROLLER: u128 = 1;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        TUNE_CONTROLLER
    }
}

pub mod equalizer_roles {
    pub const SET_ALLOCATOR: u128 = 1;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        SET_ALLOCATOR
    }
}

pub mod purger_roles {
    pub const SET_PENALTY_SCALAR: u128 = 1;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        SET_PENALTY_SCALAR
    }
}

pub mod receptor_roles {
    pub const SET_ORACLE_EXTENSION: u128 = 1;
    pub const SET_QUOTE_TOKENS: u128 = 2;
    pub const SET_TWAP_DURATION: u128 = 4;
    pub const SET_UPDATE_FREQUENCY: u128 = 8;
    pub const UPDATE_YIN_PRICE: u128 = 16;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        SET_ORACLE_EXTENSION + SET_QUOTE_TOKENS + SET_TWAP_DURATION + SET_UPDATE_FREQUENCY + UPDATE_YIN_PRICE
    }
}

pub mod seer_roles {
    pub const SET_ORACLES: u128 = 1;
    pub const SET_UPDATE_FREQUENCY: u128 = 2;
    pub const SET_YANG_PRICE_TYPE: u128 = 4;
    pub const UPDATE_PRICES: u128 = 8;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        SET_ORACLES + SET_UPDATE_FREQUENCY + SET_YANG_PRICE_TYPE + UPDATE_PRICES
    }

    #[inline(always)]
    pub fn purger() -> u128 {
        UPDATE_PRICES
    }
}

pub mod sentinel_roles {
    pub const ADD_YANG: u128 = 1;
    pub const ENTER: u128 = 2;
    pub const EXIT: u128 = 4;
    pub const KILL_GATE: u128 = 8;
    pub const SET_YANG_ASSET_MAX: u128 = 16;
    pub const UPDATE_YANG_SUSPENSION: u128 = 32;

    #[inline(always)]
    pub fn abbot() -> u128 {
        ENTER + EXIT
    }

    #[inline(always)]
    pub fn purger() -> u128 {
        EXIT
    }

    #[inline(always)]
    pub fn caretaker() -> u128 {
        EXIT
    }

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        ADD_YANG + KILL_GATE + SET_YANG_ASSET_MAX + UPDATE_YANG_SUSPENSION
    }
}

pub mod shrine_roles {
    pub const ADD_YANG: u128 = 1;
    pub const ADJUST_BUDGET: u128 = 2;
    pub const ADVANCE: u128 = 4;
    pub const DEPOSIT: u128 = 8;
    pub const EJECT: u128 = 16;
    pub const FORGE: u128 = 32;
    pub const INJECT: u128 = 64;
    pub const KILL: u128 = 128;
    pub const MELT: u128 = 256;
    pub const REDISTRIBUTE: u128 = 512;
    pub const SEIZE: u128 = 1024;
    pub const SET_DEBT_CEILING: u128 = 2048;
    pub const SET_MINIMUM_TROVE_VALUE: u128 = 4096;
    pub const SET_MULTIPLIER: u128 = 8192;
    pub const SET_RECOVERY_MODE_FACTORS: u128 = 16384;
    pub const SET_THRESHOLD: u128 = 32768;
    pub const UPDATE_RATES: u128 = 65536;
    pub const UPDATE_YANG_SUSPENSION: u128 = 131072;
    pub const UPDATE_YIN_SPOT_PRICE: u128 = 262144;
    pub const WITHDRAW: u128 = 524288;

    #[inline(always)]
    pub fn abbot() -> u128 {
        DEPOSIT + FORGE + MELT + WITHDRAW
    }

    #[inline(always)]
    pub fn caretaker() -> u128 {
        EJECT + KILL + SEIZE
    }

    #[inline(always)]
    pub fn controller() -> u128 {
        SET_MULTIPLIER
    }

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        ADD_YANG
            + SET_DEBT_CEILING
            + SET_MINIMUM_TROVE_VALUE
            + SET_RECOVERY_MODE_FACTORS
            + SET_THRESHOLD
            + KILL
            + UPDATE_RATES
            + UPDATE_YANG_SUSPENSION
    }

    #[inline(always)]
    pub fn equalizer() -> u128 {
        ADJUST_BUDGET + EJECT + INJECT + SET_DEBT_CEILING
    }

    #[inline(always)]
    pub fn flash_mint() -> u128 {
        INJECT + EJECT + SET_DEBT_CEILING
    }

    #[inline(always)]
    pub fn purger() -> u128 {
        MELT + REDISTRIBUTE + SEIZE
    }

    #[inline(always)]
    pub fn receptor() -> u128 {
        UPDATE_YIN_SPOT_PRICE
    }

    #[inline(always)]
    pub fn seer() -> u128 {
        ADVANCE
    }

    #[inline(always)]
    pub fn sentinel() -> u128 {
        ADD_YANG + UPDATE_YANG_SUSPENSION
    }

    #[inline(always)]
    pub fn transmuter() -> u128 {
        ADJUST_BUDGET + EJECT + INJECT
    }

    #[cfg(test)]
    #[inline(always)]
    pub fn all_roles() -> u128 {
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
            + SET_MINIMUM_TROVE_VALUE
            + SET_MULTIPLIER
            + SET_RECOVERY_MODE_FACTORS
            + SET_THRESHOLD
            + UPDATE_RATES
            + UPDATE_YANG_SUSPENSION
            + UPDATE_YIN_SPOT_PRICE
            + WITHDRAW
    }
}

pub mod transmuter_roles {
    pub const ENABLE_RECLAIM: u128 = 1;
    pub const KILL: u128 = 2;
    // For restricted variant of transmuter
    pub const REVERSE: u128 = 4;
    pub const SETTLE: u128 = 8;
    pub const SET_CEILING: u128 = 16;
    pub const SET_FEES: u128 = 32;
    pub const SET_PERCENTAGE_CAP: u128 = 64;
    pub const SET_RECEIVER: u128 = 128;
    pub const SWEEP: u128 = 256;
    pub const TOGGLE_REVERSIBILITY: u128 = 512;
    // For restricted variant of transmuter
    pub const TRANSMUTE: u128 = 1024;
    pub const WITHDRAW_SECONDARY_ASSET: u128 = 2048;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        ENABLE_RECLAIM
            + KILL
            + REVERSE
            + SETTLE
            + SET_CEILING
            + SET_FEES
            + SET_PERCENTAGE_CAP
            + SET_RECEIVER
            + SWEEP
            + TOGGLE_REVERSIBILITY
            + TRANSMUTE
            + WITHDRAW_SECONDARY_ASSET
    }
}

pub mod transmuter_registry_roles {
    pub const MODIFY: u128 = 1;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        MODIFY
    }
}
