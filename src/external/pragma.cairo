// NOTE: make sure the data feed coming from the oracle is denominated in the same
//       asset as the synthetic in Shrine; typically, feeds are in USD, but if the
//       synth is denominated in something else than USD and there's no feed for it,
//       this module cannot be used as-is, since the price coming from the oracle
//       would need to be divided by the synthetic's USD denominated peg price in
//       order to get ASSET/SYN

#[contract]
mod Pragma {
    use array::ArrayTrait;
    use box::BoxTrait;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use traits::TryInto;
    use zeroable::Zeroable;

    use aura::core::roles::PragmaRoles;

    use aura::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::utils::access_control::{AccessControl, IAccessControl};
    use aura::utils::storage_access;
    use aura::utils::types::Pragma::{
        DataType, PricesResponse, PriceValidityThresholds, YangSettings
    };
    use aura::utils::u256_conversions::{U256TryIntoU8, U256TryIntoU64, U256TryIntoU128};
    use aura::utils::wadray::{fixed_point_to_wad, Wad};

    // there are sanity bounds for settable values, i.e. they can never
    // be set outside of this hardcoded range
    // the range is [lower, upper]
    const LOWER_FRESHNESS_BOUND: u64 = 60; // 1 minute
    const UPPER_FRESHNESS_BOUND: u64 = 14400; // 60 * 60 * 4 = 4 hours
    const LOWER_SOURCES_BOUND: u64 = 3;
    const UPPER_SOURCES_BOUND: u64 = 13;
    const LOWER_UPDATE_FREQUENCY_BOUND: u64 = 15; // seconds (approx. Starknet block prod goal)
    const UPPER_UPDATE_FREQUENCY_BOUND: u64 = 14400; // 60 * 60 * 4 = 4 hours

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
        // a 0-based "array" of values used to get the Yang prices from Pragma
        yang_settings: LegacyMap::<u32, YangSettings>
    }

    //
    // Events
    //

    #[event]
    fn InvalidPriceUpdate(
        yang: ContractAddress,
        price: Wad,
        pragma_last_updated_ts: u256,
        pragma_num_sources: u256,
        asset_amt_per_yang: Wad
    ) {}

    #[event]
    fn OracleAddressUpdated(old_address: ContractAddress, new_address: ContractAddress) {}

    #[event]
    fn PricesUpdated(timestamp: u64, caller: ContractAddress) {}

    #[event]
    fn PriceValidityThresholdsUpdated(
        old_thresholds: PriceValidityThresholds, new_thresholds: PriceValidityThresholds
    ) {}

    #[event]
    fn UpdateFrequencyUpdated(old_frequency: u64, new_frequency: u64) {}

    #[event]
    fn YangAdded(index: u32, settings: YangSettings) {}

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        admin: ContractAddress,
        oracle: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        update_frequency: u64,
        freshness_threshold: u64,
        sources_threshold: u64
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(PragmaRoles::default_admin_role(), admin);

        // init storage
        oracle::write(IPragmaOracleDispatcher { contract_address: oracle });
        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
        update_frequency::write(update_frequency);
        let pvt = PriceValidityThresholds {
            freshness: freshness_threshold, sources: sources_threshold
        };
        price_validity_thresholds::write(pvt);

        // emit events
        OracleAddressUpdated(Zeroable::zero(), oracle);
        UpdateFrequencyUpdated(0, update_frequency);
        PriceValidityThresholdsUpdated(PriceValidityThresholds { freshness: 0, sources: 0 }, pvt);
    }

    //
    // External functions
    //

    #[external]
    fn set_oracle(new_oracle: ContractAddress) {
        AccessControl::assert_has_role(PragmaRoles::SET_ORACLE_ADDRESS);
        assert(new_oracle.is_non_zero(), 'PGM: Address cannot be zero');

        let old_oracle: IPragmaOracleDispatcher = oracle::read();
        oracle::write(IPragmaOracleDispatcher { contract_address: new_oracle });

        OracleAddressUpdated(old_oracle.contract_address, new_oracle);
    }

    #[external]
    fn set_price_validity_thresholds(freshness: u64, sources: u64) {
        AccessControl::assert_has_role(PragmaRoles::SET_PRICE_VALIDITY_THRESHOLDS);
        assert(
            LOWER_FRESHNESS_BOUND <= freshness & freshness <= UPPER_FRESHNESS_BOUND,
            'PGM: Freshness out of bounds'
        );
        assert(
            LOWER_SOURCES_BOUND <= sources & sources <= UPPER_SOURCES_BOUND,
            'PGM: Sources out of bounds'
        );

        let old_pvt: PriceValidityThresholds = price_validity_thresholds::read();
        let new_pvt = PriceValidityThresholds { freshness, sources };
        price_validity_thresholds::write(new_pvt);

        PriceValidityThresholdsUpdated(old_pvt, new_pvt);
    }

    #[external]
    fn set_update_frequency(new_frequency: u64) {
        AccessControl::assert_has_role(PragmaRoles::SET_UPDATE_FREQUENCY);
        assert(
            LOWER_UPDATE_FREQUENCY_BOUND <= new_frequency
                & new_frequency <= UPPER_UPDATE_FREQUENCY_BOUND,
            'PGM: Frequency out of bounds'
        );

        let old_frequency: u64 = update_frequency::read();
        update_frequency::write(new_frequency);
        UpdateFrequencyUpdated(old_frequency, new_frequency);
    }

    #[external]
    fn add_yang(pair_id: u256, yang: ContractAddress) {
        AccessControl::assert_has_role(PragmaRoles::ADD_YANG);
        assert(pair_id != 0, 'PGM: Invalid pair ID');
        assert(yang.is_non_zero(), 'PGM: Invalid yang address');
        assert_new_yang(yang);

        // doing a sanity check if Pragma actually offers a price feed
        // of the requested asset and if it's suitable for our needs
        let response: PricesResponse = oracle::read().get_data_median(DataType::Spot(pair_id));
        // Pragma returns 0 decimals for an unknown pair ID
        assert(response.decimals != 0, 'PGM: Unknown pair ID');
        assert(response.decimals <= 18_u256, 'PGM: Too many decimals');

        let index: u32 = yangs_count::read();
        let settings = YangSettings { pair_id, yang };
        yang_settings::write(index, settings);
        yangs_count::write(index + 1);

        YangAdded(index, settings);
    }

    #[external]
    fn update_prices() {
        // check first if an update can happen - under normal circumstances, it means
        // if the minimal time delay between the last update and now has passed
        // but the caller can have a specialized role in which case they can
        // force an update to happen immediatelly
        let mut can_update: bool = probe_task();
        if !can_update {
            can_update = AccessControl::has_role(PragmaRoles::UPDATE_PRICES, get_caller_address());
        }
        assert(can_update, 'PGM: Too soon to update prices');

        let block_timestamp: u64 = get_block_timestamp();
        let mut has_valid_update: bool = false;

        let mut idx: u32 = 0;
        let yangs_count: u32 = yangs_count::read();

        loop {
            if idx == yangs_count {
                break;
            }

            let settings: YangSettings = yang_settings::read(idx);
            let response: PricesResponse = oracle::read()
                .get_data_median(DataType::Spot(settings.pair_id));

            // convert price value to Wad
            // this will revert if the decimals is greater than 18 (wad)
            let price: Wad = fixed_point_to_wad(
                response.price.try_into().unwrap(), response.decimals.try_into().unwrap()
            );
            let asset_amt_per_yang: Wad = sentinel::read().get_asset_amt_per_yang(settings.yang);

            // if we receive what we consider a valid price from the oracle, record it in the Shrine,
            // otherwise emit an event about the update being invalid
            if is_valid_price_update(response, asset_amt_per_yang) {
                has_valid_update = true;
                shrine::read().advance(settings.yang, price * asset_amt_per_yang);
            } else {
                InvalidPriceUpdate(
                    settings.yang,
                    price,
                    response.last_updated_timestamp,
                    response.num_sources_aggregated,
                    asset_amt_per_yang
                );
            }

            idx += 1;
        };

        // Record the timestamp for the last `update_prices` call 
        last_update_prices_call_timestamp::write(block_timestamp);
        // Emit the event only if at least one price update is valid
        if has_valid_update {
            PricesUpdated(block_timestamp, get_caller_address());
        }
    }

    //
    // Yagi keepers
    // TODO: check their Cairo 1 API
    //

    #[external]
    #[inline(always)]
    fn probe_task() -> bool {
        let seconds_since_last_update: u64 = get_block_timestamp()
            - last_update_prices_call_timestamp::read();
        update_frequency::read() <= seconds_since_last_update
    }

    #[external]
    fn execute_task() {
        update_prices();
    }

    //
    // Internal functions
    //

    fn assert_new_yang(yang: ContractAddress) {
        let mut idx: u32 = 0;
        let yangs_count: u32 = yangs_count::read();

        loop {
            if idx == yangs_count {
                break;
            }

            let settings: YangSettings = yang_settings::read(idx);
            assert(settings.yang != yang, 'PGM: Yang already present');
            idx += 1;
        };
    }

    fn is_valid_price_update(update: PricesResponse, asset_amt_per_yang: Wad) -> bool {
        if asset_amt_per_yang.is_zero() {
            // can happen when e.g. the yang is invalid or gate is not added to sentinel
            return false;
        }

        let required: PriceValidityThresholds = price_validity_thresholds::read();

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
        if is_from_future {
            return has_enough_sources;
        }

        // the result of the first argument `block_timestamp - last_updated_ts` can never be negative if the code reaches here
        let is_fresh = (block_timestamp - last_updated_timestamp) <= required.freshness;

        has_enough_sources & is_fresh
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
