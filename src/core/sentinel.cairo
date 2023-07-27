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
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{AccessControl, IAccessControl};
    use aura::utils::serde::SpanSerde;
    use aura::utils::u256_conversions::U128IntoU256;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad};

    // Helper constant to set the starting index for iterating over the 
    // yangs in the order they were added
    const LOOP_START: u64 = 1;

    const INITIAL_DEPOSIT_AMT: u128 = 1000;

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
    fn YangAdded(yang: ContractAddress, gate: ContractAddress) {}

    #[event]
    fn YangAssetMaxUpdated(yang: ContractAddress, old_max: u128, new_max: u128) {}

    #[event]
    fn GateKilled(yang: ContractAddress, gate: ContractAddress) {}

    //
    // Constructor
    //

    #[constructor]
    fn constructor(admin: ContractAddress, shrine: ContractAddress) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(SentinelRoles::default_admin_role(), admin);
        shrine::write(IShrineDispatcher { contract_address: shrine });
    }

    //
    // View Functions
    // 

    #[view]
    fn get_gate_address(yang: ContractAddress) -> ContractAddress {
        yang_to_gate::read(yang).contract_address
    }

    #[view]
    fn get_gate_live(yang: ContractAddress) -> bool {
        yang_is_live::read(yang)
    }

    #[view]
    fn get_yang_addresses() -> Span<ContractAddress> {
        let mut idx: u64 = LOOP_START;
        let loop_end: u64 = yang_addresses_count::read() + LOOP_START;
        let mut addresses: Array<ContractAddress> = Default::default();
        loop {
            if idx == loop_end {
                break addresses.span();
            }
            addresses.append(yang_addresses::read(idx));
            idx += 1;
        }
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

    #[view]
    fn get_total_assets(yang: ContractAddress) -> u128 {
        let gate: IGateDispatcher = yang_to_gate::read(yang);

        if gate.contract_address.is_zero() {
            return 0_u128.into();
        }

        gate.get_total_assets()
    }

    // Returns 0 if the yang is invalid, as opposed to `preview_enter` and `preview_exit`
    // Zero value will be handled by the oracle module so as to prevent price updates from failing
    #[view]
    fn get_asset_amt_per_yang(yang: ContractAddress) -> Wad {
        let gate: IGateDispatcher = yang_to_gate::read(yang);

        if gate.contract_address.is_zero() {
            return 0_u128.into();
        }

        gate.get_asset_amt_per_yang()
    }

    #[view]
    fn preview_enter(yang: ContractAddress, asset_amt: u128) -> Wad {
        let gate: IGateDispatcher = yang_to_gate::read(yang);
        assert_can_enter(yang, gate, asset_amt);
        gate.preview_enter(asset_amt)
    }

    #[view]
    fn preview_exit(yang: ContractAddress, yang_amt: Wad) -> u128 {
        let gate: IGateDispatcher = yang_to_gate::read(yang);
        assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');
        gate.preview_exit(yang_amt)
    }

    //
    // External functions
    // 

    #[external]
    fn add_yang(
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
        assert(yang_to_gate::read(yang).contract_address.is_zero(), 'SE: Yang already added');

        let gate = IGateDispatcher { contract_address: gate };
        assert(gate.get_asset() == yang, 'SE: Asset of gate is not yang');

        let index: u64 = yang_addresses_count::read() + 1;
        yang_addresses_count::write(index);
        yang_addresses::write(index, yang);
        yang_to_gate::write(yang, gate);
        yang_is_live::write(yang, true);
        yang_asset_max::write(yang, yang_asset_max);

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

        let shrine: IShrineDispatcher = shrine::read();
        shrine.add_yang(yang, yang_threshold, yang_price, yang_rate, initial_yang_amt);

        // Events
        YangAdded(yang, gate.contract_address);
        YangAssetMaxUpdated(yang, 0, yang_asset_max);
    }

    #[external]
    fn set_yang_asset_max(yang: ContractAddress, new_asset_max: u128) {
        AccessControl::assert_has_role(SentinelRoles::SET_YANG_ASSET_MAX);

        let gate: IGateDispatcher = yang_to_gate::read(yang);
        assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');

        let old_asset_max: u128 = yang_asset_max::read(yang);
        yang_asset_max::write(yang, new_asset_max);

        YangAssetMaxUpdated(yang, old_asset_max, new_asset_max);
    }

    #[external]
    fn enter(yang: ContractAddress, user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad {
        AccessControl::assert_has_role(SentinelRoles::ENTER);

        let gate: IGateDispatcher = yang_to_gate::read(yang);

        assert_can_enter(yang, gate, asset_amt);
        gate.enter(user, trove_id, asset_amt)
    }

    #[external]
    fn exit(yang: ContractAddress, user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128 {
        AccessControl::assert_has_role(SentinelRoles::EXIT);
        let gate: IGateDispatcher = yang_to_gate::read(yang);
        assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');

        gate.exit(user, trove_id, yang_amt)
    }

    #[external]
    fn kill_gate(yang: ContractAddress) {
        AccessControl::assert_has_role(SentinelRoles::KILL_GATE);

        yang_is_live::write(yang, false);

        GateKilled(yang, yang_to_gate::read(yang).contract_address);
    }

    //
    // Internal
    //

    // Helper function to check that `enter` is a valid operation at the current
    // on-chain conditions
    #[inline(always)]
    fn assert_can_enter(yang: ContractAddress, gate: IGateDispatcher, enter_amt: u128) {
        assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');
        assert(yang_is_live::read(yang), 'SE: Gate is not live');
        let current_total: u128 = gate.get_total_assets();
        let max_amt: u128 = yang_asset_max::read(yang);
        assert(current_total + enter_amt <= max_amt, 'SE: Exceeds max amount allowed');
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
