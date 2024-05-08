#[starknet::contract]
pub mod frontend_data_provider {
    use access_control::access_control_component;
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::periphery::interfaces::IFrontendDataProvider;
    use opus::periphery::roles::frontend_data_provider_roles;
    use opus::periphery::types::{RecoveryModeInfo, ShrineAssetInfo, TroveAssetInfo, YinInfo};
    use opus::types::{Health, YangBalance};
    use opus::utils::upgradeable::{IUpgradeable, upgradeable_component};
    use starknet::{ClassHash, ContractAddress};
    use wadray::{Ray, Wad};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    component!(path: upgradeable_component, storage: upgradeable, event: UpgradeableEvent);

    impl UpgradeableHelpers = upgradeable_component::UpgradeableHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage,
        sentinel: ISentinelDispatcher,
        shrine: IShrineDispatcher,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        UpgradeableEvent: upgradeable_component::Event,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState, admin: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress
    ) {
        self.access_control.initializer(admin, Option::Some(frontend_data_provider_roles::default_admin_role()));
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
    }

    //
    // Upgradeable
    //

    #[abi(embed_v0)]
    impl IUpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.access_control.assert_has_role(frontend_data_provider_roles::UPGRADE);
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    //
    // External functions
    //

    #[abi(embed_v0)]
    impl IFrontendDataProviderImpl of IFrontendDataProvider<ContractState> {
        fn get_yin_info(self: @ContractState) -> YinInfo {
            let shrine: IShrineDispatcher = self.shrine.read();

            YinInfo {
                spot_price: shrine.get_yin_spot_price(),
                total_supply: shrine.get_total_yin(),
                ceiling: shrine.get_debt_ceiling(),
            }
        }

        fn get_recovery_mode_info(self: @ContractState) -> RecoveryModeInfo {
            let shrine: IShrineDispatcher = self.shrine.read();
            let shrine_health: Health = shrine.get_shrine_health();

            let target_factor: Ray = shrine.get_recovery_mode_target_factor();
            let buffer_factor: Ray = shrine.get_recovery_mode_buffer_factor();
            let target_ltv: Ray = target_factor * shrine_health.threshold;
            let buffer_ltv: Ray = (target_factor + buffer_factor) * shrine_health.threshold;

            RecoveryModeInfo { is_recovery_mode: shrine.is_recovery_mode(), target_ltv, buffer_ltv }
        }

        // Returns an ordered array of TroveAssetInfo struct for a trove
        fn get_trove_assets_info(self: @ContractState, trove_id: u64) -> Span<TroveAssetInfo> {
            let shrine: IShrineDispatcher = self.shrine.read();
            let sentinel: ISentinelDispatcher = self.sentinel.read();

            let mut trove_yang_balances: Span<YangBalance> = shrine.get_trove_deposits(trove_id);
            let mut yang_addresses: Span<ContractAddress> = sentinel.get_yang_addresses();

            assert(trove_yang_balances.len() == yang_addresses.len(), 'FDP: Length mismatch');

            let mut asset_infos: Array<TroveAssetInfo> = ArrayTrait::new();
            let current_rate_era: u64 = shrine.get_current_rate_era();
            loop {
                match trove_yang_balances.pop_front() {
                    Option::Some(yang_balance) => {
                        let yang: ContractAddress = *yang_addresses.pop_front().unwrap();
                        assert(sentinel.get_yang(*yang_balance.yang_id) == yang, 'FDP: Address mismatch');

                        let (shrine_asset_info, yang_price) = self
                            .get_shrine_asset_info_helper(
                                shrine, sentinel, yang, *yang_balance.amount, current_rate_era
                            );

                        let asset_amt: u128 = sentinel.convert_to_assets(yang, *yang_balance.amount);
                        let trove_asset_info = TroveAssetInfo {
                            shrine_asset_info, amount: asset_amt, value: *yang_balance.amount * yang_price,
                        };
                        asset_infos.append(trove_asset_info);
                    },
                    Option::None => { break asset_infos.span(); }
                }
            }
        }

        // Returns an ordered array of ShrineAssetInfo struct for the Shrine
        fn get_shrine_assets_info(self: @ContractState) -> Span<ShrineAssetInfo> {
            let shrine: IShrineDispatcher = self.shrine.read();
            let sentinel: ISentinelDispatcher = self.sentinel.read();

            let mut shrine_yang_balances: Span<YangBalance> = shrine.get_shrine_deposits();
            let mut yang_addresses: Span<ContractAddress> = sentinel.get_yang_addresses();

            assert(shrine_yang_balances.len() == yang_addresses.len(), 'FDP: Length mismatch');

            let mut asset_infos: Array<ShrineAssetInfo> = ArrayTrait::new();
            let current_rate_era: u64 = shrine.get_current_rate_era();
            loop {
                match shrine_yang_balances.pop_front() {
                    Option::Some(yang_balance) => {
                        let yang: ContractAddress = *yang_addresses.pop_front().unwrap();
                        assert(sentinel.get_yang(*yang_balance.yang_id) == yang, 'FDP: Address mismatch');

                        let (shrine_asset_info, _) = self
                            .get_shrine_asset_info_helper(
                                shrine, sentinel, yang, *yang_balance.amount, current_rate_era
                            );
                        asset_infos.append(shrine_asset_info);
                    },
                    Option::None => { break asset_infos.span(); }
                }
            }
        }
    }

    //
    // Internal functions
    //

    #[generate_trait]
    impl FrontendDataProviderHelpers of FrontendDataProviderHelpersTrait {
        // Helper function to generate a ShrineAssetInfo struct for a yang.
        // Returns a tuple of a ShrineAssetInfo struct and the yang price
        fn get_shrine_asset_info_helper(
            self: @ContractState,
            shrine: IShrineDispatcher,
            sentinel: ISentinelDispatcher,
            yang: ContractAddress,
            yang_amt: Wad,
            current_rate_era: u64
        ) -> (ShrineAssetInfo, Wad) {
            let gate = IGateDispatcher { contract_address: sentinel.get_gate_address(yang) };
            let deposited: u128 = gate.get_total_assets();

            let (yang_price, _, _) = shrine.get_current_yang_price(yang);
            let yang_value: Wad = yang_amt * yang_price;
            let asset_price: Wad = yang_value / deposited.into();

            let threshold: Ray = shrine.get_yang_threshold(yang);
            let base_rate: Ray = shrine.get_yang_rate(yang, current_rate_era);
            let ceiling: u128 = sentinel.get_yang_asset_max(yang);

            (
                ShrineAssetInfo {
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
