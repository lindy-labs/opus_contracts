pub mod frontend_data_provider_roles {
    pub const UPGRADE: u128 = 1;

    pub fn default_admin_role() -> u128 {
        UPGRADE
    }
}
