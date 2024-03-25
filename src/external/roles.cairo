pub mod pragma_roles {
    pub const ADD_YANG: u128 = 1;
    pub const SET_PRICE_VALIDITY_THRESHOLDS: u128 = 2;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        ADD_YANG + SET_PRICE_VALIDITY_THRESHOLDS
    }
}

pub mod switchboard_roles {
    pub const ADD_YANG: u128 = 1;

    #[inline(always)]
    pub fn default_admin_role() -> u128 {
        ADD_YANG
    }
}
