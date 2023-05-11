#[contract]
mod Sentinel {
    use array::ArrayTrait;
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};
    use starknet::get_caller_address;
    use traits::Into;
    use zeroable::Zeroable;

    use aura::core::roles::SentinelRoles;

    use aura::utils::access_control::{AccessControl, IAccessControl};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::u256_conversions::U128IntoU256;
    use aura::utils::wadray::{Ray, Wad};

    const INITIAL_DEPOSIT_AMT: u128 = 1000;

    struct Storage {
        // mapping between a yang address and our deployed Gate
        yang_to_gate: LegacyMap::<ContractAddress, ContractAddress>,
        // length of the yang_addresses array
        yang_addresses_count: u64,
        // 0-based array of yang addresses added to the Shrine via this Sentinel
        yang_addresses: LegacyMap::<u64, ContractAddress>,
        // the address of the Shrine associated with this Sentinel
        shrine_address: ContractAddress,
        // mapping between a yang address and the cap on the yang's asset in the
        // asset's decimals
        yang_asset_max: LegacyMap::<ContractAddress, u128>,
    }

    //
    // Events
    //

    #[event]
    fn YangAdded(yang: ContractAddress, gate: ContractAddress) {}

    #[event]
    fn YangAssetMaxUpdated(yang: ContractAddress, old_max: u128, new_max: u128) {}

    #[constructor]
    fn constructor(admin: ContractAddress, shrine: ContractAddress) {
        AccessControl::initializer(admin);
        AccessControl::grant_role(
            SentinelRoles::ADD_YANG + SentinelRoles::SET_YANG_ASSET_MAX, admin
        );
        shrine_address::write(shrine);
    }

    //
    // View Functions
    // 

    #[view]
    fn get_gate_address(yang: ContractAddress) -> ContractAddress {
        yang_to_gate::read(yang)
    }

    #[view]
    fn get_yang_addresses() -> Array<ContractAddress> {
        let count: u64 = yang_addresses_count::read();
        let mut idx: u64 = 0;
        let mut addresses: Array<ContractAddress> = ArrayTrait::new();
        loop {
            if idx == count {
                break ();
            }
            addresses.append(yang_addresses::read(idx));
            idx += 1;
        };
        addresses
    }

    #[view]
    fn get_yang(idx: u64) -> ContractAddress {
        yang_addresses::read(idx)
    }

    #[view]
    fn get_yang_asset_max(yang: ContractAddress) -> u128 {
        yang_asset_max::read(yang)
    }

    #[view]
    fn get_yang_addresses_count() -> u64 {
        yang_addresses_count::read()
    }

    // Returns 0 if the yang is invalid, as opposed to `preview_enter` and `preview_exit`
    // Zero value will be handled by the oracle module so as to prevent price updates from failing
    #[view]
    fn get_asset_amt_per_yang(yang_addr: ContractAddress) -> Wad {
        let gate: IGateDispatcher = IGateDispatcher {
            contract_address: yang_to_gate::read(yang_addr)
        };

        if gate.contract_address.is_zero() {
            return Wad { val: 0 };
        }

        gate.get_asset_amt_per_yang()
    }

    #[view]
    fn preview_enter(yang_addr: ContractAddress, asset_amt: u128) -> Wad {
        let gate: IGateDispatcher = IGateDispatcher {
            contract_address: yang_to_gate::read(yang_addr)
        };
        assert(gate.contract_address.is_non_zero(), 'Yang is not approved');
        gate.preview_enter(asset_amt)
    }

    #[view]
    fn preview_exit(yang_addr: ContractAddress, yang_amt: Wad) -> u128 {
        let gate: IGateDispatcher = IGateDispatcher {
            contract_address: yang_to_gate::read(yang_addr)
        };
        assert(gate.contract_address.is_non_zero(), 'Yang is not approved');
        gate.preview_exit(yang_amt)
    }

    //
    // External functions
    // 

    #[external]
    fn add_yang(
        yang_addr: ContractAddress,
        yang_asset_max: u128,
        yang_threshold: Ray,
        yang_price: Wad,
        yang_rate: Ray,
        gate_addr: ContractAddress
    ) {
        AccessControl::assert_has_role(SentinelRoles::ADD_YANG);
        assert(yang_addr.is_non_zero(), 'Yang can\'t be zero address');
        assert(gate_addr.is_non_zero(), 'Gate can\'t be zero address');
        assert(yang_to_gate::read(yang_addr).is_zero(), 'Yang already added');

        let gate = IGateDispatcher { contract_address: gate_addr };
        assert(gate.get_asset() == yang_addr, 'Yang doesn\'t match gate asset');

        let yang_count: u64 = yang_addresses_count::read();
        yang_addresses_count::write(yang_count + 1);
        yang_addresses::write(yang_count, yang_addr);
        yang_asset_max::write(yang_addr, yang_asset_max);

        // Require an initial deposit when adding a yang to prevent first depositor from front-running
        let caller: ContractAddress = get_caller_address();
        let initial_yang_amt: Wad = gate.preview_enter(INITIAL_DEPOSIT_AMT);
        let initial_yang_amt_u256: u256 = initial_yang_amt.val.into();
        let success: bool = IERC20Dispatcher {
            contract_address: yang_addr
        }.transfer_from(caller, gate_addr, initial_yang_amt_u256);
        assert(success, 'Yang transfer failed');

        IShrineDispatcher {
            contract_address: shrine_address::read()
        }.add_yang(yang_addr, yang_threshold, yang_price, yang_rate, initial_yang_amt);

        // Events
        YangAdded(yang_addr, gate_addr);
        YangAssetMaxUpdated(yang_addr, 0, yang_asset_max);
    }

    #[external]
    fn set_yang_asset_max(yang_addr: ContractAddress, new_asset_max: u128) {
        AccessControl::assert_has_role(SentinelRoles::SET_YANG_ASSET_MAX);

        let gate_addr: ContractAddress = yang_to_gate::read(yang_addr);
        assert(gate_addr.is_non_zero(), 'Yang is not approved');

        let old_asset_max: u128 = yang_asset_max::read(yang_addr);
        yang_asset_max::write(yang_addr, new_asset_max);

        YangAssetMaxUpdated(yang_addr, old_asset_max, new_asset_max);
    }

    #[external]
    fn enter(
        yang_addr: ContractAddress, user: ContractAddress, trove_id: u64, asset_amt: u128
    ) -> Wad {
        AccessControl::assert_has_role(SentinelRoles::ENTER);

        let gate: IGateDispatcher = IGateDispatcher {
            contract_address: yang_to_gate::read(yang_addr)
        };
        assert(gate.contract_address.is_non_zero(), 'Yang is not approved');

        let yang_max: u128 = yang_asset_max::read(yang_addr);
        let current_total: u128 = gate.get_total_assets();

        assert(current_total + asset_amt <= yang_max, 'Exceeds max amount allowed');

        gate.enter(user, trove_id, asset_amt)
    }

    #[external]
    fn exit(
        yang_addr: ContractAddress, user: ContractAddress, trove_id: u64, yang_amt: Wad
    ) -> u128 {
        AccessControl::assert_has_role(SentinelRoles::EXIT);

        let gate: IGateDispatcher = IGateDispatcher {
            contract_address: yang_to_gate::read(yang_addr)
        };
        assert(gate.contract_address.is_non_zero(), 'Yang is not approved');

        gate.exit(user, trove_id, yang_amt)
    }
}
