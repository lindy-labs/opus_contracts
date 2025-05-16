#[starknet::contract]
pub mod frontend_data_provider {
    use access_control::access_control_component;
    use core::num::traits::Pow;
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::periphery::interfaces::IFrontendDataProvider;
    use opus::periphery::roles::frontend_data_provider_roles;
    use opus::periphery::types::{RecoveryModeInfo, ShrineAssetInfo, TroveAssetInfo, TroveInfo, YinInfo};
    use opus::types::{Health, YangBalance};
    use opus::utils::upgradeable::{IUpgradeable, upgradeable_component};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ClassHash, ContractAddress};
    use wadray::{Ray, WAD_DECIMALS, Wad};

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
        abbot: IAbbotDispatcher,
        purger: IPurgerDispatcher,
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
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        abbot: ContractAddress,
        purger: ContractAddress,
    ) {
        self.access_control.initializer(admin, Option::Some(frontend_data_provider_roles::ADMIN));
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.purger.write(IPurgerDispatcher { contract_address: purger });
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

        // Returns a TroveInfo struct for a trove
        fn get_trove_info(self: @ContractState, trove_id: u64) -> TroveInfo {
            let shrine: IShrineDispatcher = self.shrine.read();
            let sentinel: ISentinelDispatcher = self.sentinel.read();

            let trove_owner: ContractAddress = self.abbot.read().get_trove_owner(trove_id).unwrap();
            let max_forge_amt: Wad = shrine.get_max_forge(trove_id);
            let is_liquidatable: bool = !shrine.is_healthy(trove_id);
            let is_absorbable: bool = if !is_liquidatable {
                false
            } else {
                self.purger.read().is_absorbable(trove_id)
            };
            let health: Health = shrine.get_trove_health(trove_id);

            let mut shrine_yang_balances: Span<YangBalance> = shrine.get_shrine_deposits();
            let trove_yang_balances: Span<YangBalance> = shrine.get_trove_deposits(trove_id);
            let mut yang_addresses: Span<ContractAddress> = sentinel.get_yang_addresses();

            assert(trove_yang_balances.len() == yang_addresses.len(), 'FDP: Length mismatch');

            let mut asset_infos: Array<TroveAssetInfo> = ArrayTrait::new();
            let current_rate_era: u64 = shrine.get_current_rate_era();
            for yang_balance in trove_yang_balances {
                let yang: ContractAddress = *yang_addresses.pop_front().unwrap();
                assert(sentinel.get_yang(*yang_balance.yang_id) == yang, 'FDP: Address mismatch');

                let (shrine_asset_info, yang_price) = self
                    .get_shrine_asset_info_helper(
                        shrine, sentinel, yang, (*shrine_yang_balances.pop_front().unwrap()).amount, current_rate_era,
                    );

                let asset_amt: u128 = sentinel.convert_to_assets(yang, *yang_balance.amount);
                let trove_asset_info = TroveAssetInfo {
                    shrine_asset_info, amount: asset_amt, value: *yang_balance.amount * yang_price,
                };
                asset_infos.append(trove_asset_info);
            }

            TroveInfo {
                trove_id,
                owner: trove_owner,
                max_forge_amt,
                is_liquidatable,
                is_absorbable,
                health,
                assets: asset_infos.span(),
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
            for yang_balance in shrine_yang_balances {
                let yang: ContractAddress = *yang_addresses.pop_front().unwrap();
                assert(sentinel.get_yang(*yang_balance.yang_id) == yang, 'FDP: Address mismatch');

                let (shrine_asset_info, _) = self
                    .get_shrine_asset_info_helper(shrine, sentinel, yang, *yang_balance.amount, current_rate_era);
                asset_infos.append(shrine_asset_info);
            }

            asset_infos.span()
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
            current_rate_era: u64,
        ) -> (ShrineAssetInfo, Wad) {
            let gate = IGateDispatcher { contract_address: sentinel.get_gate_address(yang) };
            let deposited: u128 = gate.get_total_assets();

            let (yang_price, _, _) = shrine.get_current_yang_price(yang);
            let yang_value: Wad = yang_amt * yang_price;
            // Scale deposited to Wad
            let decimals: u8 = IERC20Dispatcher { contract_address: yang }.decimals();
            let deposited_scaled: u128 = deposited * 10_u128.pow((WAD_DECIMALS - decimals).into());
            let asset_price: Wad = yang_value / deposited_scaled.into();

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
                    deposited_value: yang_value,
                },
                yang_price,
            )
        }
    }
}
