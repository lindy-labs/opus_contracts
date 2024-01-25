#[starknet::contract]
mod switchboard {
    use opus::core::roles::switchboard_roles;
    use opus::interfaces::IOracle::IOracle;
    use opus::interfaces::ISwitchboard::ISwitchboard;
    use opus::interfaces::external::{ISwitchboardOracleDispatcher, ISwitchboardOracleDispatcherTrait};
    use starknet::{ContractAddress};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // interfaces to the Switchboard oracle contract
        oracle: ISwitchboardOracleDispatcher,
        // A mapping between a token's address and the Switchboard ID
        // used to identify the price feed
        // (yang address) -> (Switchboard ID)
        yang_pair_ids: LegacyMap::<ContractAddress, felt252>
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        YangPairIdSet: YangPairIdSet,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangPairIdSet {
        address: ContractAddress,
        pair_id: felt252
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress, oracle: ContractAddress) {
        self.access_control.initializer(admin, Option::Some(switchboard_roles::default_admin_role()));
        self.oracle.write(ISwitchboardOracleDispatcher { contract_address: oracle });
    }

    //
    // External functions
    //

    #[abi(embed_v0)]
    impl ISwitchboardImpl of ISwitchboard<ContractState> {
        fn set_yang_pair_id(ref self: ContractState, yang: ContractAddress, pair_id: felt252) {
            self.access_control.assert_has_role(switchboard_roles::ADD_YANG);
            assert(pair_id != 0, 'SWI: Invalid pair ID');
            assert(yang.is_non_zero(), 'SWI: Invalid yang address');

            // sanity check that the feed actually exists
            let (value, timestamp) = self.oracle.read().get_latest_result(pair_id);
            assert(value.is_non_zero(), 'SWI: Invalid value');
            assert(timestamp.is_non_zero(), 'SWI: Invalid timestamp');

            self.yang_pair_id.write(yang, pair_id);

            self.emit(YangPairIdSet { address: yang, pair_id });
        }
    }

    //
    // External oracle functions
    //

    #[abi(embed_v0)]
    impl IOracleImpl of IOracle<ContractState> {
        fn get_name(self: @ContractState) -> felt252 {
            'Switchboard'
        }

        fn get_oracle_type(self: @ContractState) -> felt256 {
            self.oracle.read()
        }

        fn fetch_price(ref self: ContractState, yang: ContractAddress, force_update: bool) -> Result<Wad, felt252> {
            // note: all feeds are in 10**18
            Result::Err('TODO')
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl SwitchboardInternalFunctions of SwitchboardInternalFunctionsTrait {}
}
