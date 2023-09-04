#[starknet::contract]
mod MockBlesser {
    use option::OptionTrait;
    use starknet::{ContractAddress, get_contract_address};
    use traits::{Into, TryInto};

    use aura::core::roles::BlesserRoles;

    use aura::interfaces::IAbsorber::IBlesser;
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::utils::access_control::{AccessControl, IAccessControl};

    #[storage]
    struct Storage {
        asset: IERC20Dispatcher,
        absorber: ContractAddress,
        bless_amt: u128,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        asset: ContractAddress,
        absorber: ContractAddress,
        bless_amt: u128
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(BlesserRoles::default_admin_role(), absorber);

        self.asset.write(IERC20Dispatcher { contract_address: asset });
        self.absorber.write(absorber);
        self.bless_amt.write(bless_amt);
    }

    #[external(v0)]
    impl IBlesserImpl of IBlesser<ContractState> {
        fn preview_bless(self: @ContractState) -> u128 {
            self.preview_bless_internal(self.asset.read())
        }

        fn bless(ref self: ContractState) -> u128 {
            AccessControl::assert_has_role(BlesserRoles::BLESS);

            let asset: IERC20Dispatcher = self.asset.read();
            let bless_amt: u256 = self.preview_bless_internal(asset).into();
            asset.transfer(self.absorber.read(), bless_amt);
            bless_amt.try_into().unwrap()
        }
    }

    #[generate_trait]
    impl MockBlesserInternalFunctions of MockBlesserInternalFunctionsTrait {
        fn preview_bless_internal(self: @ContractState, asset: IERC20Dispatcher) -> u128 {
            let balance: u128 = asset.balance_of(get_contract_address()).try_into().unwrap();
            let bless_amt: u128 = self.bless_amt.read();
            if balance < bless_amt {
                0
            } else {
                bless_amt
            }
        }
    }

    //
    // Public AccessControl functions
    //

    #[external(v0)]
    impl IAccessControlImpl of IAccessControl<ContractState> {
        fn get_roles(self: @ContractState, account: ContractAddress) -> u128 {
            AccessControl::get_roles(account)
        }

        fn has_role(self: @ContractState, role: u128, account: ContractAddress) -> bool {
            AccessControl::has_role(role, account)
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_admin()
        }

        fn get_pending_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_pending_admin()
        }

        fn grant_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::grant_role(role, account);
        }

        fn revoke_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::revoke_role(role, account);
        }

        fn renounce_role(ref self: ContractState, role: u128) {
            AccessControl::renounce_role(role);
        }

        fn set_pending_admin(ref self: ContractState, new_admin: ContractAddress) {
            AccessControl::set_pending_admin(new_admin);
        }

        fn accept_admin(ref self: ContractState) {
            AccessControl::accept_admin();
        }
    }
}
