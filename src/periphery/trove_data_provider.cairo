#[starknet::contract]
pub mod trove_data_provider {
    use core::num::traits::Zero;
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::periphery::interfaces::IFrontendDataProvider;
    use opus::types::{AssetBalance, YangBalance};
    use starknet::ContractAddress;
    use wadray::Wad;

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
        // Returns a tuple of ordered arrays of 
        // 1. asset balances for a given trove
        // 2. total value of each deposited asset for a given trove
        fn get_trove_deposits(self: @ContractState, trove_id: u64) -> (Span<AssetBalance>, Span<Wad>) {
            let shrine: IShrineDispatcher = self.shrine.read();
            let sentinel: ISentinelDispatcher = self.sentinel.read();

            let mut trove_yang_balances: Span<YangBalance> = shrine.get_trove_deposits(trove_id);
            let mut yang_addresses: Span<ContractAddress> = sentinel.get_yang_addresses();

            assert(trove_yang_balances.len() == yang_addresses.len(), 'TDP: Length mismatch');

            let mut trove_asset_balances: Array<AssetBalance> = ArrayTrait::new();
            let mut yang_values: Array<Wad> = ArrayTrait::new();

            loop {
                match trove_yang_balances.pop_front() {
                    Option::Some(yang_balance) => {
                        let asset: ContractAddress = *yang_addresses.pop_front().unwrap();
                        let asset_amt: u128 = sentinel.convert_to_assets(asset, *yang_balance.amount);
                        trove_asset_balances.append(AssetBalance { address: asset, amount: asset_amt });

                        let (yang_price, _, _) = shrine.get_current_yang_price(asset);
                        let yang_value: Wad = *yang_balance.amount * yang_price;
                        yang_values.append(yang_value);
                    },
                    Option::None => { break (trove_asset_balances.span(), yang_values.span()); }
                }
            }
        }

        // Returns a tuple of ordered arrays of 
        // 1. asset balances for the Shrine
        // 2. total value of each deposited asset for the Shrine
        // 3. ceiling for the asset
        fn get_shrine_deposits(self: @ContractState) -> (Span<AssetBalance>, Span<Wad>, Span<u128>) {
            let shrine: IShrineDispatcher = self.shrine.read();
            let sentinel: ISentinelDispatcher = self.sentinel.read();

            let mut shrine_yang_balances: Span<YangBalance> = shrine.get_shrine_deposits();
            let mut yang_addresses: Span<ContractAddress> = sentinel.get_yang_addresses();

            assert(shrine_yang_balances.len() == yang_addresses.len(), 'TDP: Length mismatch');

            let mut shrine_asset_balances: Array<AssetBalance> = ArrayTrait::new();
            let mut yang_values: Array<Wad> = ArrayTrait::new();
            let mut asset_ceilings: Array<u128> = ArrayTrait::new();

            loop {
                match shrine_yang_balances.pop_front() {
                    Option::Some(yang_balance) => {
                        let asset: ContractAddress = *yang_addresses.pop_front().unwrap();
                        let asset_amt: u128 = sentinel.convert_to_assets(asset, *yang_balance.amount);
                        shrine_asset_balances.append(AssetBalance { address: asset, amount: asset_amt });

                        let (yang_price, _, _) = shrine.get_current_yang_price(asset);
                        let yang_value: Wad = *yang_balance.amount * yang_price;
                        yang_values.append(yang_value);

                        asset_ceilings.append(sentinel.get_yang_asset_max(asset));
                    },
                    Option::None => { break (shrine_asset_balances.span(), yang_values.span(), asset_ceilings.span()); }
                }
            }
        }
    }
}
