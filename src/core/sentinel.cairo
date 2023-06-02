#[contract]
mod Sentinel {
    use array::{ArrayTrait, SpanTrait};
    use starknet::get_caller_address;
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::core::roles::SentinelRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::ISentinel;
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{AccessControl, IAccessControl};
    use aura::utils::serde::SpanSerde;
    use aura::utils::u256_conversions::U128IntoU256;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad};

    const INITIAL_DEPOSIT_AMT: u128 = 1000;

    #[starknet::storage]
    struct Storage {
        // mapping between a yang address and our deployed Gate
        yang_to_gate: LegacyMap::<ContractAddress, IGateDispatcher>,
        // length of the yang_addresses array
        yang_addresses_count: u64,
        // 0-based array of yang addresses added to the Shrine via this Sentinel
        yang_addresses: LegacyMap::<u64, ContractAddress>,
        // The Shrine associated with this Sentinel
        shrine: IShrineDispatcher,
        // mapping between a yang address and the cap on the yang's asset in the
        // asset's decimals
        yang_asset_max: LegacyMap::<ContractAddress, u128>,
        // mapping between a yang address and whether its Gate is live
        yang_is_live: LegacyMap::<ContractAddress, bool>,
    }

    //
    // Events
    //

    #[derive(Drop, starknet::Event)]
    enum Event {
        #[event]
        YangAdded: YangAdded,
        #[event]
        YangAssetMaxUpdated: YangAssetMaxUpdated,
        #[event]
        GateKilled: GateKilled,
    }

    #[derive(Drop, starknet::Event)]
    struct YangAdded {
        yang: ContractAddress,
        gate: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct YangAssetMaxUpdated {
        yang: ContractAddress,
        old_max: u128,
        new_max: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct GateKilled {
        yang: ContractAddress,
        gate: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: Storage, admin: ContractAddress, shrine: ContractAddress) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(SentinelRoles::default_admin_role(), admin);
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
    }

    impl ISentinelImpl of ISentinel<Storage> {
        //
        // View Functions
        // 

        fn get_gate_address(self: @Storage, yang: ContractAddress) -> ContractAddress {
            self.yang_to_gate.read(yang).contract_address
        }

        fn get_gate_live(self: @Storage, yang: ContractAddress) -> bool {
            self.yang_is_live.read(yang)
        }

        fn get_yang_addresses(self: @Storage) -> Span<ContractAddress> {
            let count: u64 = self.yang_addresses_count.read();
            let mut idx: u64 = 0;
            let mut addresses: Array<ContractAddress> = Default::default();
            loop {
                if idx == count {
                    break addresses.span();
                }
                addresses.append(self.yang_addresses.read(idx));
                idx += 1;
            }
        }

        fn get_yang(self: @Storage, idx: u64) -> ContractAddress {
            self.yang_addresses.read(idx)
        }

        fn get_yang_asset_max(self: @Storage, yang: ContractAddress) -> u128 {
            self.yang_asset_max.read(yang)
        }

        fn get_yang_addresses_count(self: @Storage) -> u64 {
            self.yang_addresses_count.read()
        }

        // Returns 0 if the yang is invalid, as opposed to `preview_enter` and `preview_exit`
        // Zero value will be handled by the oracle module so as to prevent price updates from failing
        fn get_asset_amt_per_yang(self: @Storage, yang: ContractAddress) -> Wad {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);

            if gate.contract_address.is_zero() {
                return 0_u128.into();
            }

            gate.get_asset_amt_per_yang()
        }

        fn preview_enter(self: @Storage, yang: ContractAddress, asset_amt: u128) -> Wad {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            self.assert_can_enter(yang, gate, asset_amt);
            gate.preview_enter(asset_amt)
        }

        fn preview_exit(self: @Storage, yang: ContractAddress, yang_amt: Wad) -> u128 {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang is not approved');
            gate.preview_exit(yang_amt)
        }

        //
        // External functions
        // 

        fn add_yang(
            ref self: Storage,
            yang: ContractAddress,
            yang_asset_max: u128,
            yang_threshold: Ray,
            yang_price: Wad,
            yang_rate: Ray,
            gate: ContractAddress
        ) {
            AccessControl::assert_has_role(SentinelRoles::ADD_YANG);
            assert(yang.is_non_zero(), 'SE: Yang cannot be zero address');
            assert(gate.is_non_zero(), 'SE: Gate cannot be zero address');
            assert(self.yang_to_gate.read(yang).contract_address.is_zero(), 'SE: Yang already added');

            let gate = IGateDispatcher { contract_address: gate };
            assert(gate.get_asset() == yang, 'SE: Asset of gate is not yang');

            let yang_count: u64 = self.yang_addresses_count.read();
            self.yang_addresses_count.write(yang_count + 1);
            self.yang_addresses.write(yang_count, yang);
            self.yang_to_gate.write(yang, gate);
            self.yang_is_live.write(yang, true);
            self.yang_asset_max.write(yang, yang_asset_max);

            // Require an initial deposit when adding a yang to prevent first depositor from front-running
            let caller: ContractAddress = get_caller_address();
            let initial_yang_amt: Wad = gate.preview_enter(INITIAL_DEPOSIT_AMT);
            let initial_deposit_amt: u256 = INITIAL_DEPOSIT_AMT.into();

            let success: bool = IERC20Dispatcher {
                contract_address: yang
            }.transfer_from(caller, gate.contract_address, initial_deposit_amt);
            assert(success, 'SE: Yang transfer failed');

            let shrine: IShrineDispatcher = self.shrine.read();
            shrine.add_yang(yang, yang_threshold, yang_price, yang_rate, initial_yang_amt);

            // Events
            self.emit(Event::YangAdded(YangAdded{yang, gate: gate.contract_address}));
            self.emit(Event::YangAssetMaxUpdated(YangAssetMaxUpdated{yang, old_max: 0, new_max: yang_asset_max}));
        }

        fn set_yang_asset_max(ref self: Storage, yang: ContractAddress, new_asset_max: u128) {
            AccessControl::assert_has_role(SentinelRoles::SET_YANG_ASSET_MAX);

            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang is not approved');

            let old_asset_max: u128 = self.yang_asset_max.read(yang);
            self.yang_asset_max.write(yang, new_asset_max);

            self.emit(Event::YangAssetMaxUpdated(YangAssetMaxUpdated{yang, old_max: old_asset_max, new_max: new_asset_max}));
        }

        fn enter(ref self: Storage, yang: ContractAddress, user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad {
            AccessControl::assert_has_role(SentinelRoles::ENTER);

            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            self.assert_can_enter(yang, gate, asset_amt);
            gate.enter(user, trove_id, asset_amt)
        }

        fn exit(ref self: Storage, yang: ContractAddress, user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128 {
            AccessControl::assert_has_role(SentinelRoles::EXIT);

            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang is not approved');

            gate.exit(user, trove_id, yang_amt)
        }

        fn kill_gate(ref self: Storage, yang: ContractAddress) {
            AccessControl::assert_has_role(SentinelRoles::KILL_GATE);

            self.yang_is_live.write(yang, false);

            self.emit(Event::GateKilled(GateKilled{yang, gate: self.yang_to_gate.read(yang).contract_address}));
        }
    }

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        //
        // Internal
        //

        // Helper function to check that `enter` is a valid operation at the current
        // on-chain conditions
        #[inline(always)]
        fn assert_can_enter(self: @Storage, yang: ContractAddress, gate: IGateDispatcher, enter_amt: u128) {
            assert(gate.contract_address.is_non_zero(), 'SE: Yang is not approved');
            assert(self.yang_is_live.read(yang), 'SE: Gate is not live');
            let current_total: u128 = gate.get_total_assets();
            let max_amt: u128 = self.yang_asset_max.read(yang);
            assert(current_total + enter_amt <= max_amt, 'SE: Exceeds max amount allowed');
        }
    }
}
