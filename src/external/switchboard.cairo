#[starknet::contract]
pub mod switchboard {
    use access_control::access_control_component;
    use core::num::traits::Zero;
    use opus::external::interfaces::{ISwitchboardOracleDispatcher, ISwitchboardOracleDispatcherTrait};
    use opus::external::roles::switchboard_roles;
    use opus::interfaces::IOracle::IOracle;
    use opus::interfaces::ISwitchboard::ISwitchboard;
    use starknet::{ContractAddress};
    use wadray::Wad;

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
        // interface to the Switchboard oracle contract
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
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        InvalidPriceUpdate: InvalidPriceUpdate,
        YangPairIdSet: YangPairIdSet,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct InvalidPriceUpdate {
        pub yang: ContractAddress,
        pub price: Wad,
        pub timestamp: u64
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct YangPairIdSet {
        pub address: ContractAddress,
        pub pair_id: felt252
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
            assert(pair_id.is_non_zero(), 'SWI: Invalid pair ID');
            assert(yang.is_non_zero(), 'SWI: Invalid yang address');

            // sanity check that the feed actually exists
            let (value, timestamp) = self.oracle.read().get_latest_result(pair_id);
            assert(value.is_non_zero(), 'SWI: Invalid feed value');
            assert(timestamp.is_non_zero(), 'SWI: Invalid feed timestamp');

            self.yang_pair_ids.write(yang, pair_id);

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

        fn get_oracles(self: @ContractState) -> Span<ContractAddress> {
            array![self.oracle.read().contract_address].span()
        }

        fn fetch_price(ref self: ContractState, yang: ContractAddress) -> Result<Wad, felt252> {
            // Switchboard reports all feeds in 10**18 (i.e. in Wad)
            let pair_id: felt252 = self.yang_pair_ids.read(yang);
            let (price, timestamp) = self.oracle.read().get_latest_result(pair_id);

            // default Switchboard functions updates:
            // - for "expedited tickers" (ETH & BTC), when the price difference is greater than 0.5%;
            // - for other tokens, when the price difference is greater than 1.5%;
            // if the price diff is below these thresholds, the price won't be posted on chain

            if self.is_valid_price_update(price, timestamp) {
                Result::Ok(price.into())
            } else {
                self.emit(InvalidPriceUpdate { yang, price: price.into(), timestamp });
                Result::Err('SWI: Invalid price update')
            }
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl SwitchboardInternalFunctions of SwitchboardInternalFunctionsTrait {
        fn is_valid_price_update(self: @ContractState, value: u128, timestamp: u64) -> bool {
            value.is_non_zero() && timestamp.is_non_zero()
        }
    }
}
