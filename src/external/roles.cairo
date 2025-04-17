pub mod ekubo_roles {
    pub const SET_ORACLE_EXTENSION: u128 = 1;
    pub const SET_QUOTE_TOKENS: u128 = 2;
    pub const SET_TWAP_DURATION: u128 = 4;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        SET_ORACLE_EXTENSION + SET_QUOTE_TOKENS + SET_TWAP_DURATION
    }
}

pub mod pragma_roles {
    pub const ADD_YANG: u128 = 1;
    pub const SET_PRICE_VALIDITY_THRESHOLDS: u128 = 2;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        ADD_YANG + SET_PRICE_VALIDITY_THRESHOLDS
    }
}
