#[contract]
mod MockBlesser {
    use option::OptionTrait;
    use starknet::{ContractAddress, get_contract_address};
    use traits::{Into, TryInto};

    use aura::core::roles::BlesserRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::u256_conversions;

    struct Storage {
        asset: IERC20Dispatcher,
        absorber: ContractAddress,
        bless_amt: u128,
    }

    #[constructor]
    fn constructor(
        admin: ContractAddress, asset: ContractAddress, absorber: ContractAddress, bless_amt: u128
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(BlesserRoles::default_admin_role(), absorber);

        asset::write(IERC20Dispatcher { contract_address: asset });
        absorber::write(absorber);
        bless_amt::write(bless_amt);
    }

    #[view]
    fn preview_bless() -> u128 {
        preview_bless_internal(asset::read())
    }

    #[external]
    fn bless() -> u128 {
        AccessControl::assert_has_role(BlesserRoles::BLESS);

        let asset: IERC20Dispatcher = asset::read();
        let bless_amt: u256 = preview_bless_internal(asset).into();
        asset.transfer(absorber::read(), bless_amt);
        bless_amt.try_into().unwrap()
    }

    fn preview_bless_internal(asset: IERC20Dispatcher) -> u128 {
        let balance: u128 = asset.balance_of(get_contract_address()).try_into().unwrap();
        let bless_amt: u128 = bless_amt::read();
        if balance < bless_amt {
            0
        } else {
            bless_amt
        }
    }

    //
    // Public AccessControl functions
    //

    #[view]
    fn get_roles(account: ContractAddress) -> u128 {
        AccessControl::get_roles(account)
    }

    #[view]
    fn has_role(role: u128, account: ContractAddress) -> bool {
        AccessControl::has_role(role, account)
    }

    #[view]
    fn get_admin() -> ContractAddress {
        AccessControl::get_admin()
    }

    #[view]
    fn get_pending_admin() -> ContractAddress {
        AccessControl::get_pending_admin()
    }

    #[external]
    fn grant_role(role: u128, account: ContractAddress) {
        AccessControl::grant_role(role, account);
    }

    #[external]
    fn revoke_role(role: u128, account: ContractAddress) {
        AccessControl::revoke_role(role, account);
    }

    #[external]
    fn renounce_role(role: u128) {
        AccessControl::renounce_role(role);
    }

    #[external]
    fn set_pending_admin(new_admin: ContractAddress) {
        AccessControl::set_pending_admin(new_admin);
    }

    #[external]
    fn accept_admin() {
        AccessControl::accept_admin();
    }
}
