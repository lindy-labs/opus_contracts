// NOTE: make sure the data feed coming from the oracle is denominated in the same
//       asset as the synthetic in Shrine; typically, feeds are in USD, but if the
//       synth is denominated in something else than USD and there's no feed for it,
//       this module cannot be used as-is, since the price coming from the oracle
//       would need to be divided by the synthetic's USD denominated peg price in
//       order to get ASSET/SYN

#[starknet::contract]
pub mod pragma_v2 {
    use access_control::access_control_component;
    use core::cmp::min;
    use core::num::traits::Zero;
    use opus::external::interfaces::{
        IPragmaSpotOracleDispatcher, IPragmaSpotOracleDispatcherTrait, IPragmaTwapOracleDispatcher,
        IPragmaTwapOracleDispatcherTrait
    };
    use opus::external::roles::pragma_roles;
    use opus::interfaces::IOracle::IOracle;
    use opus::interfaces::IPragma::IPragmaV2;
    use opus::types::pragma::{AggregationMode, DataType, PairSettings, PragmaPricesResponse, PriceValidityThresholds};
    use opus::utils::math::fixed_point_to_wad;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::Wad;

    const TWAP_DURATION: u64 = 7 * 24 * 60 * 60; // 7 days * 24 hours * 60 minutes * 60 seconds

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Constants
    //

    // there are sanity bounds for settable values, i.e. they can never
    // be set outside of this hardcoded range
    // the range is [lower, upper]
    pub const LOWER_FRESHNESS_BOUND: u64 = 60; // 1 minute
    pub const UPPER_FRESHNESS_BOUND: u64 = 4 * 60 * 60; // 4 hours * 60 minutes * 60 seconds
    pub const LOWER_SOURCES_BOUND: u32 = 3;
    pub const UPPER_SOURCES_BOUND: u32 = 13;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // interface to the spot Pragma oracle contract
        spot_oracle: IPragmaSpotOracleDispatcher,
        // interface to the twap Pragma oracle contract,
        twap_oracle: IPragmaTwapOracleDispatcher,
        // values used to determine if we consider a price update from the spot
        // oracle fresh or stale:
        // `freshness` is the maximum number of seconds between block timestamp and
        // the last update timestamp (as reported by Pragma) for which we consider a
        // price update valid
        // `sources` is the minimum number of data publishers used to aggregate the
        // price value
        price_validity_thresholds: PriceValidityThresholds,
        // A mapping between a token's address and its pair settings in Pragma
        // (yang address) -> (PairSettings struct)
        yang_pair_settings: Map::<ContractAddress, PairSettings>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        InvalidSpotPriceUpdate: InvalidSpotPriceUpdate,
        PriceValidityThresholdsUpdated: PriceValidityThresholdsUpdated,
        YangPairSettingsUpdated: YangPairSettingsUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct InvalidSpotPriceUpdate {
        #[key]
        pub pair_id: felt252,
        pub aggregation_mode: AggregationMode,
        pub price: Wad,
        pub pragma_last_updated_ts: u64,
        pub pragma_num_sources: u32,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PriceValidityThresholdsUpdated {
        pub old_thresholds: PriceValidityThresholds,
        pub new_thresholds: PriceValidityThresholds
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct YangPairSettingsUpdated {
        pub address: ContractAddress,
        pub pair_settings: PairSettings
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        spot_oracle: ContractAddress,
        twap_oracle: ContractAddress,
        freshness_threshold: u64,
        sources_threshold: u32
    ) {
        self.access_control.initializer(admin, Option::Some(pragma_roles::default_admin_role()));

        // init storage
        self.spot_oracle.write(IPragmaSpotOracleDispatcher { contract_address: spot_oracle });
        self.twap_oracle.write(IPragmaTwapOracleDispatcher { contract_address: twap_oracle });
        let new_thresholds = PriceValidityThresholds { freshness: freshness_threshold, sources: sources_threshold };
        self.price_validity_thresholds.write(new_thresholds);

        self
            .emit(
                PriceValidityThresholdsUpdated {
                    old_thresholds: PriceValidityThresholds { freshness: 0, sources: 0 }, new_thresholds
                }
            );
    }

    //
    // External Pragma functions
    //

    #[abi(embed_v0)]
    impl IPragmaV2Impl of IPragmaV2<ContractState> {
        fn set_yang_pair_settings(ref self: ContractState, yang: ContractAddress, pair_settings: PairSettings) {
            self.access_control.assert_has_role(pragma_roles::ADD_YANG);
            assert(pair_settings.pair_id != 0, 'PGM: Invalid pair ID');
            assert(yang.is_non_zero(), 'PGM: Invalid yang address');

            // doing a sanity check if Pragma actually offers a price feed
            // of the requested asset and if it's suitable for our needs

            let response: PragmaPricesResponse = self
                .spot_oracle
                .read()
                .get_data(DataType::SpotEntry(pair_settings.pair_id), pair_settings.aggregation_mode);
            // Pragma returns 0 decimals for an unknown pair ID
            assert(response.decimals.is_non_zero(), 'PGM: Spot unknown pair ID');
            assert(response.decimals <= 18, 'PGM: Spot too many decimals');

            let start_time: u64 = get_block_timestamp() - TWAP_DURATION;
            let (_, decimals) = self
                .twap_oracle
                .read()
                .calculate_twap(
                    DataType::SpotEntry(pair_settings.pair_id),
                    pair_settings.aggregation_mode,
                    TWAP_DURATION,
                    start_time
                );
            assert(decimals.is_non_zero(), 'PGM: TWAP unknown pair ID');
            assert(decimals <= 18, 'PGM: TWAP too many decimals');

            self.yang_pair_settings.write(yang, pair_settings);

            self.emit(YangPairSettingsUpdated { address: yang, pair_settings });
        }

        fn set_price_validity_thresholds(ref self: ContractState, freshness: u64, sources: u32) {
            self.access_control.assert_has_role(pragma_roles::SET_PRICE_VALIDITY_THRESHOLDS);
            assert(
                LOWER_FRESHNESS_BOUND <= freshness && freshness <= UPPER_FRESHNESS_BOUND, 'PGM: Freshness out of bounds'
            );
            assert(LOWER_SOURCES_BOUND <= sources && sources <= UPPER_SOURCES_BOUND, 'PGM: Sources out of bounds');

            let old_thresholds: PriceValidityThresholds = self.price_validity_thresholds.read();
            let new_thresholds = PriceValidityThresholds { freshness, sources };
            self.price_validity_thresholds.write(new_thresholds);

            self.emit(PriceValidityThresholdsUpdated { old_thresholds, new_thresholds });
        }
    }

    //
    // External oracle functions
    //

    #[abi(embed_v0)]
    impl IOracleImpl of IOracle<ContractState> {
        fn get_name(self: @ContractState) -> felt252 {
            'Pragma'
        }

        fn get_oracles(self: @ContractState) -> Span<ContractAddress> {
            array![self.spot_oracle.read().contract_address, self.twap_oracle.read().contract_address].span()
        }

        fn fetch_price(ref self: ContractState, yang: ContractAddress) -> Result<Wad, felt252> {
            let pair_settings: PairSettings = self.yang_pair_settings.read(yang);
            assert(pair_settings.pair_id.is_non_zero(), 'PGM: Unknown yang');

            let spot_price: Wad = self.fetch_spot_price(pair_settings)?; // propagate Err if any
            let twap_price: Wad = self.fetch_twap_price(pair_settings);
            let pessimistic_price: Wad = min(spot_price, twap_price);
            Result::Ok(pessimistic_price)
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl PragmaInternalFunctions of PragmaInternalFunctionsTrait {
        fn fetch_spot_price(ref self: ContractState, pair_settings: PairSettings) -> Result<Wad, felt252> {
            let response: PragmaPricesResponse = self
                .spot_oracle
                .read()
                .get_data(DataType::SpotEntry(pair_settings.pair_id), pair_settings.aggregation_mode);

            // convert price value to Wad
            let price: Wad = fixed_point_to_wad(response.price, response.decimals.try_into().unwrap());

            // if we receive what we consider a valid price from the oracle,
            // return it back, otherwise emit an event about the update being invalid
            if self.is_valid_price_update(response) {
                Result::Ok(price)
            } else {
                self
                    .emit(
                        InvalidSpotPriceUpdate {
                            pair_id: pair_settings.pair_id,
                            aggregation_mode: pair_settings.aggregation_mode,
                            price,
                            pragma_last_updated_ts: response.last_updated_timestamp,
                            pragma_num_sources: response.num_sources_aggregated,
                        }
                    );
                Result::Err('PGM: Invalid price update')
            }
        }

        fn fetch_twap_price(ref self: ContractState, pair_settings: PairSettings) -> Wad {
            let start_time: u64 = get_block_timestamp() - TWAP_DURATION;
            let (twap, decimals) = self
                .twap_oracle
                .read()
                .calculate_twap(
                    DataType::SpotEntry(pair_settings.pair_id),
                    pair_settings.aggregation_mode,
                    TWAP_DURATION,
                    start_time
                );
            fixed_point_to_wad(twap, decimals.try_into().unwrap())
        }

        fn is_valid_price_update(self: @ContractState, update: PragmaPricesResponse) -> bool {
            let required: PriceValidityThresholds = self.price_validity_thresholds.read();

            // check if the update is from enough sources
            let has_enough_sources = required.sources <= update.num_sources_aggregated;

            // it is possible that the last_updated_ts is greater than the block_timestamp (in other words,
            // it is from the future from the chain's perspective), because the update timestamp is coming
            // from a data publisher while the block timestamp from the sequencer, they can be out of sync
            //
            // in such a case, we base the whole validity check only on the number of sources and we trust
            // Pragma with regards to data freshness - they have a check in place where they discard
            // updates that are too far in the future
            //
            // we considered having our own "too far in the future" check but that could lead to us
            // discarding updates in cases where just a single publisher would push updates with future
            // timestamp; that could be disastrous as we would have stale prices
            let block_timestamp = get_block_timestamp();
            let last_updated_timestamp: u64 = update.last_updated_timestamp;

            if block_timestamp <= last_updated_timestamp {
                return has_enough_sources;
            }

            // the result of `block_timestamp - last_updated_timestamp` can
            // never be negative if the code reaches here
            let is_fresh = (block_timestamp - last_updated_timestamp) <= required.freshness;

            has_enough_sources && is_fresh
        }
    }
}
