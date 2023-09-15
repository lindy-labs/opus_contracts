#[starknet::contract]
mod Sentinel {
    use starknet::{get_block_timestamp, get_caller_address};
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};

    use aura::core::roles::SentinelRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::ISentinel;
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::types::YangSuspensionStatus;
    use aura::utils::access_control::{AccessControl, IAccessControl};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WadZeroable};

    // Helper constant to set the starting index for iterating over the
    // yangs in the order they were added
    const LOOP_START: u64 = 1;

    const INITIAL_DEPOSIT_AMT: u128 = 1000;

    #[storage]
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

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        YangAdded: YangAdded,
        YangAssetMaxUpdated: YangAssetMaxUpdated,
        GateKilled: GateKilled,
    }

    #[derive(Drop, starknet::Event)]
    struct YangAdded {
        #[key]
        yang: ContractAddress,
        gate: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct YangAssetMaxUpdated {
        #[key]
        yang: ContractAddress,
        old_max: u128,
        new_max: u128
    }

    #[derive(Drop, starknet::Event)]
    struct GateKilled {
        #[key]
        yang: ContractAddress,
        gate: ContractAddress
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress, shrine: ContractAddress) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_helper(SentinelRoles::default_admin_role(), admin);
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
    }

    //
    // External Sentinel functions
    //

    #[external(v0)]
    impl ISentinelImpl of ISentinel<ContractState> {
        //
        // Getters
        //

        fn get_gate_address(self: @ContractState, yang: ContractAddress) -> ContractAddress {
            self.yang_to_gate.read(yang).contract_address
        }

        fn get_gate_live(self: @ContractState, yang: ContractAddress) -> bool {
            self.yang_is_live.read(yang)
        }

        fn get_yang_addresses(self: @ContractState) -> Span<ContractAddress> {
            let mut idx: u64 = LOOP_START;
            let loop_end: u64 = self.yang_addresses_count.read() + LOOP_START;
            let mut addresses: Array<ContractAddress> = Default::default();
            loop {
                if idx == loop_end {
                    break addresses.span();
                }
                addresses.append(self.yang_addresses.read(idx));
                idx += 1;
            }
        }

        fn get_yang_addresses_count(self: @ContractState) -> u64 {
            self.yang_addresses_count.read()
        }

        fn get_yang(self: @ContractState, idx: u64) -> ContractAddress {
            self.yang_addresses.read(idx)
        }

        fn get_yang_asset_max(self: @ContractState, yang: ContractAddress) -> u128 {
            self.yang_asset_max.read(yang)
        }

        // Returns 0 if the yang is invalid, as opposed to `convert_to_yang` and `convert_to_assets`
        // Zero value will be handled by the oracle module so as to prevent price updates from failing
        fn get_asset_amt_per_yang(self: @ContractState, yang: ContractAddress) -> Wad {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);

            if gate.contract_address.is_zero() {
                return WadZeroable::zero();
            }

            gate.get_asset_amt_per_yang()
        }

        //
        // View functions
        //

        // This can be used to simulate the effects of `enter`.
        fn convert_to_yang(self: @ContractState, yang: ContractAddress, asset_amt: u128) -> Wad {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            self.assert_can_enter(yang, gate, asset_amt);
            gate.convert_to_yang(asset_amt)
        }

        // This can be used to simulate the effects of `exit`.
        fn convert_to_assets(self: @ContractState, yang: ContractAddress, yang_amt: Wad) -> u128 {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');
            gate.convert_to_assets(yang_amt)
        }

        //
        // Setters
        //

        fn add_yang(
            ref self: ContractState,
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
            assert(
                self.yang_to_gate.read(yang).contract_address.is_zero(), 'SE: Yang already added'
            );

            let gate = IGateDispatcher { contract_address: gate };
            assert(gate.get_asset() == yang, 'SE: Asset of gate is not yang');

            let index: u64 = self.yang_addresses_count.read() + 1;
            self.yang_addresses_count.write(index);
            self.yang_addresses.write(index, yang);
            self.yang_to_gate.write(yang, gate);
            self.yang_is_live.write(yang, true);
            self.yang_asset_max.write(yang, yang_asset_max);

            // Require an initial deposit when adding a yang to prevent first depositor from front-running
            let yang_erc20 = IERC20Dispatcher { contract_address: yang };
            // scale `asset_amt` up by the difference to match `Wad` precision of yang
            let initial_yang_amt: Wad = wadray::fixed_point_to_wad(
                INITIAL_DEPOSIT_AMT, yang_erc20.decimals()
            );
            let initial_deposit_amt: u256 = INITIAL_DEPOSIT_AMT.into();

            let caller: ContractAddress = get_caller_address();
            let success: bool = yang_erc20
                .transfer_from(caller, gate.contract_address, initial_deposit_amt);
            assert(success, 'SE: Yang transfer failed');

            let shrine: IShrineDispatcher = self.shrine.read();
            shrine.add_yang(yang, yang_threshold, yang_price, yang_rate, initial_yang_amt);

            // Events
            self.emit(YangAdded { yang, gate: gate.contract_address });
            self.emit(YangAssetMaxUpdated { yang, old_max: 0, new_max: yang_asset_max });
        }

        fn set_yang_asset_max(ref self: ContractState, yang: ContractAddress, new_asset_max: u128) {
            AccessControl::assert_has_role(SentinelRoles::SET_YANG_ASSET_MAX);

            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');

            let old_asset_max: u128 = self.yang_asset_max.read(yang);
            self.yang_asset_max.write(yang, new_asset_max);

            self.emit(YangAssetMaxUpdated { yang, old_max: old_asset_max, new_max: new_asset_max });
        }

        fn kill_gate(ref self: ContractState, yang: ContractAddress) {
            AccessControl::assert_has_role(SentinelRoles::KILL_GATE);

            self.yang_is_live.write(yang, false);

            self.emit(GateKilled { yang, gate: self.yang_to_gate.read(yang).contract_address });
        }

        fn suspend_yang(ref self: ContractState, yang: ContractAddress) {
            AccessControl::assert_has_role(SentinelRoles::UPDATE_YANG_SUSPENSION);
            self.shrine.read().update_yang_suspension(yang, get_block_timestamp());
        }

        fn unsuspend_yang(ref self: ContractState, yang: ContractAddress) {
            AccessControl::assert_has_role(SentinelRoles::UPDATE_YANG_SUSPENSION);
            self.shrine.read().update_yang_suspension(yang, 0);
        }

        //
        // Core functions
        //

        fn enter(
            ref self: ContractState,
            yang: ContractAddress,
            user: ContractAddress,
            trove_id: u64,
            asset_amt: u128
        ) -> Wad {
            AccessControl::assert_has_role(SentinelRoles::ENTER);

            let gate: IGateDispatcher = self.yang_to_gate.read(yang);

            self.assert_can_enter(yang, gate, asset_amt);
            gate.enter(user, trove_id, asset_amt)
        }

        fn exit(
            ref self: ContractState,
            yang: ContractAddress,
            user: ContractAddress,
            trove_id: u64,
            yang_amt: Wad
        ) -> u128 {
            AccessControl::assert_has_role(SentinelRoles::EXIT);
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');

            gate.exit(user, trove_id, yang_amt)
        }
    }

    //
    // Internal Sentinel functions
    //

    #[generate_trait]
    impl SentinelHelpers of SentinelHelpersTrait {
        // Helper function to check that `enter` is a valid operation at the current
        // on-chain conditions
        #[inline(always)]
        fn assert_can_enter(
            self: @ContractState, yang: ContractAddress, gate: IGateDispatcher, enter_amt: u128
        ) {
            assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');
            assert(self.yang_is_live.read(yang), 'SE: Gate is not live');
            let suspension_status: YangSuspensionStatus = self
                .shrine
                .read()
                .get_yang_suspension_status(yang);
            assert(suspension_status == YangSuspensionStatus::None(()), 'SE: Yang suspended');
            let current_total: u128 = gate.get_total_assets();
            let max_amt: u128 = self.yang_asset_max.read(yang);
            assert(current_total + enter_amt <= max_amt, 'SE: Exceeds max amount allowed');
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
