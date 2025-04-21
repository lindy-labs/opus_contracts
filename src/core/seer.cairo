#[starknet::contract]
pub mod seer {
    use access_control::access_control_component;
    use core::num::traits::Zero;
    use opus::core::roles::seer_roles;
    use opus::external::interfaces::ITask;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IERC4626::{IERC4626Dispatcher, IERC4626DispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::ISeer::ISeer;
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::{ConversionRateInfo, InternalPriceType, PriceType, YangSuspensionStatus};
    use opus::utils::math::pow;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{WAD_DECIMALS, WAD_ONE, Wad};

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

    const LOOP_START: u32 = 1;
    pub const LOWER_UPDATE_FREQUENCY_BOUND: u64 = 15; // seconds (approx. Starknet block prod goal)
    pub const UPPER_UPDATE_FREQUENCY_BOUND: u64 = 4 * 60 * 60; // 4 hours * 60 minutes * 60 seconds

    //
    // Storage
    //

    #[storage]
    struct Storage {
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // Shrine associated with this module
        // this is where a valid price update is posted to
        shrine: IShrineDispatcher,
        // Sentinel associated with the Shrine and this module
        sentinel: ISentinelDispatcher,
        // Mapping of a yang to its price type
        yang_price_types: Map<ContractAddress, InternalPriceType>,
        // Collection of oracles, ordered by priority,
        // starting from 1 as the key.
        // (key) -> (oracle)
        oracles: Map<u32, IOracleDispatcher>,
        // Block timestamp of the last `update_prices_internal` execution
        last_update_prices_call_timestamp: u64,
        // The minimal time difference in seconds of how often we
        // want to fetch from the oracle.
        update_frequency: u64,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        PriceUpdate: PriceUpdate,
        PriceUpdateMissed: PriceUpdateMissed,
        UpdateFrequencyUpdated: UpdateFrequencyUpdated,
        UpdatePricesDone: UpdatePricesDone,
        YangPriceTypeUpdated: YangPriceTypeUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PriceUpdate {
        pub oracle: ContractAddress,
        pub yang: ContractAddress,
        pub price: Wad,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct PriceUpdateMissed {
        pub yang: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct UpdateFrequencyUpdated {
        pub old_frequency: u64,
        pub new_frequency: u64,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct UpdatePricesDone {}

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct YangPriceTypeUpdated {
        #[key]
        pub yang: ContractAddress,
        pub price_type: PriceType,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        update_frequency: u64,
    ) {
        self.access_control.initializer(admin, Option::Some(seer_roles::ADMIN));
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.update_frequency.write(update_frequency);
        self.emit(UpdateFrequencyUpdated { old_frequency: 0, new_frequency: update_frequency });
    }

    //
    // External
    //

    #[abi(embed_v0)]
    impl ISeerImpl of ISeer<ContractState> {
        fn get_oracles(self: @ContractState) -> Span<ContractAddress> {
            let mut oracles: Array<ContractAddress> = Default::default();
            let mut index = LOOP_START;
            loop {
                let oracle: ContractAddress = self.oracles.read(index).contract_address;
                if oracle.is_zero() {
                    break oracles.span();
                }
                oracles.append(oracle);
                index += 1;
            }
        }

        fn get_update_frequency(self: @ContractState) -> u64 {
            self.update_frequency.read()
        }


        fn get_yang_price_type(self: @ContractState, yang: ContractAddress) -> PriceType {
            match self.yang_price_types.read(yang) {
                InternalPriceType::Direct => PriceType::Direct,
                InternalPriceType::Vault(_) => PriceType::Vault,
            }
        }

        fn set_oracles(ref self: ContractState, mut oracles: Span<ContractAddress>) {
            self.access_control.assert_has_role(seer_roles::SET_ORACLES);

            let mut index: u32 = LOOP_START;
            loop {
                match oracles.pop_front() {
                    Option::Some(oracle) => {
                        self.oracles.write(index, IOracleDispatcher { contract_address: *oracle });
                        index += 1;
                    },
                    Option::None => {
                        // setting the terminating condition for looping
                        self.oracles.write(index, IOracleDispatcher { contract_address: Zero::zero() });
                        break;
                    },
                }
            };
        }

        fn set_update_frequency(ref self: ContractState, new_frequency: u64) {
            self.access_control.assert_has_role(seer_roles::SET_UPDATE_FREQUENCY);
            assert(
                LOWER_UPDATE_FREQUENCY_BOUND <= new_frequency && new_frequency <= UPPER_UPDATE_FREQUENCY_BOUND,
                'SEER: Frequency out of bounds',
            );

            let old_frequency: u64 = self.update_frequency.read();
            self.update_frequency.write(new_frequency);
            self.emit(UpdateFrequencyUpdated { old_frequency, new_frequency });
        }

        fn set_yang_price_type(ref self: ContractState, yang: ContractAddress, price_type: PriceType) {
            self.access_control.assert_has_role(seer_roles::SET_YANG_PRICE_TYPE);

            let internal_price_type = match price_type {
                // toggling to vault type
                PriceType::Direct => { InternalPriceType::Direct },
                PriceType::Vault => {
                    assert(
                        IERC20Dispatcher { contract_address: yang }.decimals() == WAD_DECIMALS, 'SEER: Not wad scale',
                    );

                    let vault = IERC4626Dispatcher { contract_address: yang };
                    // This will throw if the yang is not a vault
                    let asset: ContractAddress = vault.asset();
                    let conversion_rate: u256 = vault.convert_to_assets(WAD_ONE.into());
                    assert(conversion_rate.is_non_zero(), 'SEER: Zero conversion rate');

                    let asset_decimals: u8 = IERC20Dispatcher { contract_address: asset }.decimals();
                    assert(asset_decimals <= WAD_DECIMALS, 'SEER: Too many decimals');
                    let conversion_rate_scale: u128 = pow(10_u128, (WAD_DECIMALS - asset_decimals).into());

                    InternalPriceType::Vault(ConversionRateInfo { asset, conversion_rate_scale })
                },
            };

            self.yang_price_types.write(yang, internal_price_type);

            self.emit(YangPriceTypeUpdated { yang, price_type });
        }

        fn update_prices(ref self: ContractState) {
            self.access_control.assert_has_role(seer_roles::UPDATE_PRICES);
            self.update_prices_internal();
        }
    }

    #[abi(embed_v0)]
    impl ITaskImpl of ITask<ContractState> {
        fn probe_task(self: @ContractState) -> bool {
            let seconds_since_last_update: u64 = get_block_timestamp() - self.last_update_prices_call_timestamp.read();
            self.update_frequency.read() <= seconds_since_last_update
        }

        fn execute_task(ref self: ContractState) {
            assert(self.probe_task(), 'SEER: Too soon to update prices');
            self.update_prices_internal();
        }
    }

    //
    // Internal
    //

    #[generate_trait]
    impl SeerInternalFunctions of SeerInternalFunctionsTrait {
        fn update_prices_internal(ref self: ContractState) {
            let shrine: IShrineDispatcher = self.shrine.read();
            let sentinel: ISentinelDispatcher = self.sentinel.read();

            // loop through all yangs
            // for each yang, loop through all oracles until a
            // valid price update is fetched, in which case, call shrine.advance()
            // the expectation is that the primary oracle will provide a
            // valid price in most cases, but if not, we can fallback to other oracles
            let mut yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
            for yang in yangs.pop_front() {
                if shrine.get_yang_suspension_status(*yang) == YangSuspensionStatus::Permanent {
                    continue;
                }

                let price_type = self.yang_price_types.read(*yang);
                let asset = match price_type {
                    InternalPriceType::Direct => *yang,
                    InternalPriceType::Vault(info) => info.asset,
                };

                let mut oracle_index: u32 = LOOP_START;
                loop {
                    let oracle: IOracleDispatcher = self.oracles.read(oracle_index);
                    if oracle.contract_address.is_zero() {
                        // if branch happens, it means no oracle was able to
                        // fetch a price for yang, i.e. we're missing a price update
                        self.emit(PriceUpdateMissed { yang: *yang });
                        break;
                    }

                    // TODO: when possible in Cairo, fetch_price should be wrapped
                    //       in a try-catch block so that an exception does not
                    //       prevent all other price updates

                    match oracle.fetch_price(asset) {
                        Result::Ok(oracle_price) => {
                            let asset_price: Wad = match price_type {
                                InternalPriceType::Direct => oracle_price,
                                InternalPriceType::Vault(info) => {
                                    let unscaled_conversion_rate: u128 = IERC4626Dispatcher { contract_address: *yang }
                                        .convert_to_assets(WAD_ONE.into())
                                        .try_into()
                                        .unwrap();
                                    let scaled_conversion_rate: u128 = unscaled_conversion_rate
                                        * info.conversion_rate_scale;
                                    oracle_price * scaled_conversion_rate.into()
                                },
                            };

                            let asset_amt_per_yang: Wad = sentinel.get_asset_amt_per_yang(*yang);
                            let price: Wad = asset_price * asset_amt_per_yang;
                            shrine.advance(*yang, price);
                            self.emit(PriceUpdate { oracle: oracle.contract_address, yang: *yang, price });
                            break;
                        },
                        // try next oracle for this yang
                        Result::Err(_) => { oracle_index += 1; },
                    }
                };
            }

            self.last_update_prices_call_timestamp.write(get_block_timestamp());
            self.emit(UpdatePricesDone {});
        }
    }
}
