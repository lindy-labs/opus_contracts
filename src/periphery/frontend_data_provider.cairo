#[starknet::contract]
pub mod frontend_data_provider {
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::periphery::interfaces::IFrontendDataProvider;
    use opus::types::{ShrineYangAssetInfo, TroveYangAssetInfo, YangBalance};
    use starknet::ContractAddress;
    use wadray::{Ray, Wad};

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // Sentinel associated with the Shrine
        sentinel: ISentinelDispatcher,
        shrine: IShrineDispatcher,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: ContractState, shrine: ContractAddress, sentinel: ContractAddress) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
    }

    //
    // External functions
    //

    #[abi(embed_v0)]
    impl IFrontendDataProviderImpl of IFrontendDataProvider<ContractState> {
        // Returns an ordered array of TroveYangAssetInfo struct for a trove
        fn get_trove_deposits(self: @ContractState, trove_id: u64) -> Span<TroveYangAssetInfo> {
            let shrine: IShrineDispatcher = self.shrine.read();
            let sentinel: ISentinelDispatcher = self.sentinel.read();

            let mut trove_yang_balances: Span<YangBalance> = shrine.get_trove_deposits(trove_id);
            let mut yang_addresses: Span<ContractAddress> = sentinel.get_yang_addresses();

            assert(trove_yang_balances.len() == yang_addresses.len(), 'FDP: Length mismatch');

            let mut yang_infos: Array<TroveYangAssetInfo> = ArrayTrait::new();
            let current_rate_era: u64 = shrine.get_current_rate_era();
            loop {
                match trove_yang_balances.pop_front() {
                    Option::Some(yang_balance) => {
                        let yang: ContractAddress = *yang_addresses.pop_front().unwrap();
                        assert(sentinel.get_yang(*yang_balance.yang_id) == yang, 'FDP: Address mismatch');

                        let (shrine_yang_info, yang_price) = self
                            .get_shrine_yang_info_helper(
                                shrine, sentinel, yang, *yang_balance.amount, current_rate_era
                            );

                        let asset_amt: u128 = sentinel.convert_to_assets(yang, *yang_balance.amount);
                        let trove_yang_info = TroveYangAssetInfo {
                            shrine_yang_info, amount: asset_amt, value: *yang_balance.amount * yang_price,
                        };
                        yang_infos.append(trove_yang_info);
                    },
                    Option::None => { break yang_infos.span(); }
                }
            }
        }

        // Returns an ordered array of ShrineYangAssetInfo struct for the Shrine
        fn get_shrine_deposits(self: @ContractState) -> Span<ShrineYangAssetInfo> {
            let shrine: IShrineDispatcher = self.shrine.read();
            let sentinel: ISentinelDispatcher = self.sentinel.read();

            let mut shrine_yang_balances: Span<YangBalance> = shrine.get_shrine_deposits();
            let mut yang_addresses: Span<ContractAddress> = sentinel.get_yang_addresses();

            assert(shrine_yang_balances.len() == yang_addresses.len(), 'FDP: Length mismatch');

            let mut yang_infos: Array<ShrineYangAssetInfo> = ArrayTrait::new();
            let current_rate_era: u64 = shrine.get_current_rate_era();
            loop {
                match shrine_yang_balances.pop_front() {
                    Option::Some(yang_balance) => {
                        let yang: ContractAddress = *yang_addresses.pop_front().unwrap();
                        assert(sentinel.get_yang(*yang_balance.yang_id) == yang, 'FDP: Address mismatch');

                        let (shrine_yang_info, _) = self
                            .get_shrine_yang_info_helper(
                                shrine, sentinel, yang, *yang_balance.amount, current_rate_era
                            );
                        yang_infos.append(shrine_yang_info);
                    },
                    Option::None => { break yang_infos.span(); }
                }
            }
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl FrontendDataProviderHelpers of FrontendDataProviderHelpersTrait {
        // Helper function to generate a ShrineYangAssetInfo struct for a yang.
        // Returns a tuple of a ShrineYangAssetInfo struct and the yang price
        fn get_shrine_yang_info_helper(
            self: @ContractState,
            shrine: IShrineDispatcher,
            sentinel: ISentinelDispatcher,
            yang: ContractAddress,
            yang_amt: Wad,
            current_rate_era: u64
        ) -> (ShrineYangAssetInfo, Wad) {
            let gate = IGateDispatcher { contract_address: sentinel.get_gate_address(yang) };
            let deposited: u128 = gate.get_total_assets();

            let (yang_price, _, _) = shrine.get_current_yang_price(yang);
            let yang_value: Wad = yang_amt * yang_price;
            let asset_price: Wad = yang_value / deposited.into();

            let threshold: Ray = shrine.get_yang_threshold(yang);
            let base_rate: Ray = shrine.get_yang_rate(yang, current_rate_era);
            let ceiling: u128 = sentinel.get_yang_asset_max(yang);

            (
                ShrineYangAssetInfo {
                    address: yang,
                    price: asset_price,
                    threshold,
                    base_rate,
                    deposited,
                    ceiling,
                    deposited_value: yang_value
                },
                yang_price
            )
        }
    }
}
