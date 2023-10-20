// NOTE: make sure the data feed coming from the oracle is denominated in the same
//       asset as the synthetic in Shrine; typically, feeds are in USD, but if the
//       synth is denominated in something else than USD and there's no feed for it,
//       this module cannot be used as-is, since the price coming from the oracle
//       would need to be divided by the synthetic's USD denominated peg price in
//       order to get ASSET/SYN

#[starknet::contract]
mod Pragma {
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};

    use opus::core::roles::PragmaRoles;

    use opus::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use opus::interfaces::IOracle::IOracle;
    use opus::interfaces::IPragma::IPragma;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::types::Pragma::{DataType, PricesResponse, PriceValidityThresholds, YangSettings};
    use opus::utils::access_control::{AccessControl, IAccessControl};
    use opus::utils::wadray;
    use opus::utils::wadray::Wad;

    // Helper constant to set the starting index for iterating over the yangs
    // in the order they were added
    const LOOP_START: u32 = 1;

    // there are sanity bounds for settable values, i.e. they can never
    // be set outside of this hardcoded range
    // the range is [lower, upper]
    const LOWER_FRESHNESS_BOUND: u64 = 60; // 1 minute
    const UPPER_FRESHNESS_BOUND: u64 =
        consteval_int!(4 * 60 * 60); // 4 hours * 60 minutes * 60 seconds
    const LOWER_SOURCES_BOUND: u64 = 3;
    const UPPER_SOURCES_BOUND: u64 = 13;
    const LOWER_UPDATE_FREQUENCY_BOUND: u64 = 15; // seconds (approx. Starknet block prod goal)
    const UPPER_UPDATE_FREQUENCY_BOUND: u64 =
        consteval_int!(4 * 60 * 60); // 4 hours * 60 minutes * 60 seconds

    #[storage]
    struct Storage {
        // interface to the Pragma oracle contract
        oracle: IPragmaOracleDispatcher,
        // Shrine associated with this module
        // this is where a valid price update is posted to
        shrine: IShrineDispatcher,
        // Sentinel associated with this module
        // a Sentinel module is necessary to verify a price update
        sentinel: ISentinelDispatcher,
        // the minimal time difference in seconds of how often we
        // want to fetch from the oracle
        update_frequency: u64,
        // block timestamp of the last `update_prices` call
        last_update_prices_call_timestamp: u64,
        // values used to determine if we consider a price update fresh or stale:
        // `freshness` is the maximum number of seconds between block timestamp and
        // the last update timestamp (as reported by Pragma) for which we consider a
        // price update valid
        // `sources` is the minimum number of data publishers used to aggregate the
        // price value
        price_validity_thresholds: PriceValidityThresholds,
        // number of yangs in `yang_settings` "array"
        yangs_count: u32,
        // a 1-based "array" of values used to get the Yang prices from Pragma
        yang_settings: LegacyMap::<u32, YangSettings>
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        InvalidPriceUpdate: InvalidPriceUpdate,
        OracleAddressUpdated: OracleAddressUpdated,
        PricesUpdated: PricesUpdated,
        PriceValidityThresholdsUpdated: PriceValidityThresholdsUpdated,
        UpdateFrequencyUpdated: UpdateFrequencyUpdated,
        YangAdded: YangAdded,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct InvalidPriceUpdate {
        #[key]
        yang: ContractAddress,
        price: Wad,
        pragma_last_updated_ts: u256,
        pragma_num_sources: u256,
        asset_amt_per_yang: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct OracleAddressUpdated {
        old_address: ContractAddress,
        new_address: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct PricesUpdated {
        timestamp: u64,
        caller: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct PriceValidityThresholdsUpdated {
        old_thresholds: PriceValidityThresholds,
        new_thresholds: PriceValidityThresholds
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct UpdateFrequencyUpdated {
        old_frequency: u64,
        new_frequency: u64
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangAdded {
        index: u32,
        settings: YangSettings
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        oracle: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        update_frequency: u64,
        freshness_threshold: u64,
        sources_threshold: u64
    ) {
        AccessControl::initializer(admin, Option::Some(PragmaRoles::default_admin_role()));

        // init storage
        self.oracle.write(IPragmaOracleDispatcher { contract_address: oracle });
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.update_frequency.write(update_frequency);
        let new_thresholds = PriceValidityThresholds {
            freshness: freshness_threshold, sources: sources_threshold
        };
        self.price_validity_thresholds.write(new_thresholds);

        // emit events
        self.emit(OracleAddressUpdated { old_address: Zeroable::zero(), new_address: oracle });
        self.emit(UpdateFrequencyUpdated { old_frequency: 0, new_frequency: update_frequency });
        self
            .emit(
                PriceValidityThresholdsUpdated {
                    old_thresholds: PriceValidityThresholds { freshness: 0, sources: 0 },
                    new_thresholds
                }
            );
    }

    //
    // External Pragma functions
    //

    #[external(v0)]
    impl IPragmaImpl of IPragma<ContractState> {
        //
        // Setters
        //

        fn set_oracle(ref self: ContractState, new_oracle: ContractAddress) {
            AccessControl::assert_has_role(PragmaRoles::SET_ORACLE_ADDRESS);
            assert(new_oracle.is_non_zero(), 'PGM: Address cannot be zero');

            let old_oracle: IPragmaOracleDispatcher = self.oracle.read();
            self.oracle.write(IPragmaOracleDispatcher { contract_address: new_oracle });

            self
                .emit(
                    OracleAddressUpdated {
                        old_address: old_oracle.contract_address, new_address: new_oracle
                    }
                );
        }

        fn set_price_validity_thresholds(ref self: ContractState, freshness: u64, sources: u64) {
            AccessControl::assert_has_role(PragmaRoles::SET_PRICE_VALIDITY_THRESHOLDS);
            assert(
                LOWER_FRESHNESS_BOUND <= freshness && freshness <= UPPER_FRESHNESS_BOUND,
                'PGM: Freshness out of bounds'
            );
            assert(
                LOWER_SOURCES_BOUND <= sources && sources <= UPPER_SOURCES_BOUND,
                'PGM: Sources out of bounds'
            );

            let old_thresholds: PriceValidityThresholds = self.price_validity_thresholds.read();
            let new_thresholds = PriceValidityThresholds { freshness, sources };
            self.price_validity_thresholds.write(new_thresholds);

            self.emit(PriceValidityThresholdsUpdated { old_thresholds, new_thresholds });
        }

        fn set_update_frequency(ref self: ContractState, new_frequency: u64) {
            AccessControl::assert_has_role(PragmaRoles::SET_UPDATE_FREQUENCY);
            assert(
                LOWER_UPDATE_FREQUENCY_BOUND <= new_frequency
                    && new_frequency <= UPPER_UPDATE_FREQUENCY_BOUND,
                'PGM: Frequency out of bounds'
            );

            let old_frequency: u64 = self.update_frequency.read();
            self.update_frequency.write(new_frequency);
            self.emit(UpdateFrequencyUpdated { old_frequency, new_frequency });
        }

        fn add_yang(ref self: ContractState, pair_id: u256, yang: ContractAddress) {
            AccessControl::assert_has_role(PragmaRoles::ADD_YANG);
            assert(pair_id != 0, 'PGM: Invalid pair ID');
            assert(yang.is_non_zero(), 'PGM: Invalid yang address');
            self.assert_new_yang(pair_id, yang);

            // doing a sanity check if Pragma actually offers a price feed
            // of the requested asset and if it's suitable for our needs
            let response: PricesResponse = self
                .oracle
                .read()
                .get_data_median(DataType::Spot(pair_id));
            // Pragma returns 0 decimals for an unknown pair ID
            assert(response.decimals.is_non_zero(), 'PGM: Unknown pair ID');
            assert(response.decimals <= 18, 'PGM: Too many decimals');

            let index: u32 = self.yangs_count.read() + 1;
            let settings = YangSettings { pair_id, yang };
            self.yang_settings.write(index, settings);
            self.yangs_count.write(index);

            self.emit(YangAdded { index, settings });
        }

        //
        // Yagi keepers
        // TODO: check their Cairo 1 API
        //

        #[inline(always)]
        fn probe_task(self: @ContractState) -> bool {
            let seconds_since_last_update: u64 = get_block_timestamp()
                - self.last_update_prices_call_timestamp.read();
            self.update_frequency.read() <= seconds_since_last_update
        }

        fn execute_task(ref self: ContractState) {
            self.update_prices();
        }
    }

    //
    // External oracle functions
    //

    #[external(v0)]
    impl IOracleImpl of IOracle<ContractState> {
        fn update_prices(ref self: ContractState) {
            // check first if an update can happen - under normal circumstances, it means
            // if the minimal time delay between the last update and now has passed
            // but the caller can have a specialized role in which case they can
            // force an update to happen immediatelly
            let can_update: bool = self.probe_task();
            let can_force_update: bool = AccessControl::has_role(
                PragmaRoles::UPDATE_PRICES, get_caller_address()
            );
            assert(can_update | can_force_update, 'PGM: Too soon to update prices');

            let block_timestamp: u64 = get_block_timestamp();
            let mut idx: u32 = LOOP_START;
            let loop_end: u32 = self.yangs_count.read() + LOOP_START;
            let mut has_valid_update: bool = false;

            loop {
                if idx == loop_end {
                    break;
                }

                let settings: YangSettings = self.yang_settings.read(idx);
                let response: PricesResponse = self
                    .oracle
                    .read()
                    .get_data_median(DataType::Spot(settings.pair_id));

                // convert price value to Wad
                // this will revert if the decimals is greater than 18 (wad)
                let price: Wad = wadray::fixed_point_to_wad(
                    response.price.try_into().unwrap(), response.decimals.try_into().unwrap()
                );
                let asset_amt_per_yang: Wad = self
                    .sentinel
                    .read()
                    .get_asset_amt_per_yang(settings.yang);

                // if we receive what we consider a valid price from the oracle, record it in the Shrine,
                // otherwise emit an event about the update being invalid
                if self.is_valid_price_update(response, asset_amt_per_yang, can_force_update) {
                    has_valid_update = true;
                    self.shrine.read().advance(settings.yang, price * asset_amt_per_yang);
                } else {
                    self
                        .emit(
                            InvalidPriceUpdate {
                                yang: settings.yang,
                                price,
                                pragma_last_updated_ts: response.last_updated_timestamp,
                                pragma_num_sources: response.num_sources_aggregated,
                                asset_amt_per_yang
                            }
                        );
                }

                idx += 1;
            };

            // Record the timestamp for the last `update_prices` call
            self.last_update_prices_call_timestamp.write(block_timestamp);
            // Emit the event only if at least one price update is valid
            if has_valid_update {
                self
                    .emit(
                        PricesUpdated { timestamp: block_timestamp, caller: get_caller_address() }
                    );
            }
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl PragmaInternalFunctions of PragmaInternalFunctionsTrait {
        fn assert_new_yang(self: @ContractState, pair_id: u256, yang: ContractAddress) {
            let mut idx: u32 = LOOP_START;
            let loop_end: u32 = self.yangs_count.read() + LOOP_START;

            loop {
                if idx == loop_end {
                    break;
                }

                let settings: YangSettings = self.yang_settings.read(idx);
                assert(settings.yang != yang, 'PGM: Yang already present');
                assert(settings.pair_id != pair_id, 'PGM: Pair ID already present');
                idx += 1;
            };
        }

        fn is_valid_price_update(
            self: @ContractState,
            update: PricesResponse,
            asset_amt_per_yang: Wad,
            can_force_update: bool
        ) -> bool {
            if asset_amt_per_yang.is_zero() {
                // can happen when e.g. the yang is invalid or gate is not added to sentinel
                return false;
            }

            let required: PriceValidityThresholds = self.price_validity_thresholds.read();

            // check if the update is from enough sources
            let has_enough_sources = required
                .sources <= update
                .num_sources_aggregated
                .try_into()
                .unwrap();

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
            let last_updated_timestamp: u64 = update.last_updated_timestamp.try_into().unwrap();

            let is_from_future = block_timestamp <= last_updated_timestamp;
            if is_from_future || can_force_update {
                return has_enough_sources;
            }

            // the result of the first argument `block_timestamp - last_updated_ts` can never be negative if the code reaches here
            let is_fresh = (block_timestamp - last_updated_timestamp) <= required.freshness;

            has_enough_sources && is_fresh
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
