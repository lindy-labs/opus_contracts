pub mod transmuter_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::integer::BoundedInt;
    use opus::core::roles::shrine_roles;
    use opus::core::transmuter::transmuter as transmuter_contract;
    use opus::core::transmuter_registry::transmuter_registry as transmuter_registry_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::{
        ITransmuterDispatcher, ITransmuterDispatcherTrait, ITransmuterRegistryDispatcher,
        ITransmuterRegistryDispatcherTrait
    };
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::ContractAddress;
    use wadray::Wad;

    #[derive(Copy, Drop)]
    pub struct TransmuterTestConfig {
        pub shrine: IShrineDispatcher,
        pub transmuter: ITransmuterDispatcher,
        pub wad_usd_stable: IERC20Dispatcher,
    }

    // Constants

    // 1_000_000 (Wad)
    pub const INITIAL_CEILING: u128 = 1000000000000000000000000;

    // 20_000_000 (Wad)
    pub const START_TOTAL_YIN: u128 = 20000000000000000000000000;

    // 2_000_000 (Wad)
    pub const MOCK_WAD_USD_TOTAL: u128 = 2000000000000000000000000;

    // 2_000_000 (6 decimals)
    pub const MOCK_NONWAD_USD_TOTAL: u128 = 2000000000000;

    pub fn admin() -> ContractAddress {
        'transmuter admin'.try_into().unwrap()
    }

    pub fn receiver() -> ContractAddress {
        'receiver'.try_into().unwrap()
    }

    pub fn user() -> ContractAddress {
        'transmuter user'.try_into().unwrap()
    }


    //
    // Test setup helpers
    //

    pub fn declare_transmuter() -> ContractClass {
        declare("transmuter").unwrap()
    }

    pub fn transmuter_deploy(
        transmuter_class: Option<ContractClass>,
        shrine: ContractAddress,
        asset: ContractAddress,
        receiver: ContractAddress
    ) -> ITransmuterDispatcher {
        let mut calldata: Array<felt252> = array![
            admin().into(), shrine.into(), asset.into(), receiver.into(), INITIAL_CEILING.into()
        ];

        let transmuter_class = match transmuter_class {
            Option::Some(class) => class,
            Option::None => declare_transmuter(),
        };

        let (transmuter_addr, _) = transmuter_class.deploy(@calldata).expect('transmuter deploy failed');

        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        let shrine_ac: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine };
        shrine_ac.grant_role(shrine_roles::transmuter(), transmuter_addr);

        ITransmuterDispatcher { contract_address: transmuter_addr }
    }

    pub fn setup_shrine_with_transmuter(
        shrine: IShrineDispatcher,
        transmuter: ITransmuterDispatcher,
        shrine_ceiling: Wad,
        shrine_start_yin: Wad,
        start_yin_recipient: ContractAddress,
        user: ContractAddress
    ) {
        // set debt ceiling to 30m
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.set_debt_ceiling(shrine_ceiling);
        shrine.inject(start_yin_recipient, shrine_start_yin);
        stop_prank(CheatTarget::One(shrine.contract_address));

        // approve transmuter to deal with user's tokens
        let asset: ContractAddress = transmuter.get_asset();
        start_prank(CheatTarget::One(asset), user);
        IERC20Dispatcher { contract_address: asset }.approve(transmuter.contract_address, BoundedInt::max());
        stop_prank(CheatTarget::One(asset));
    }

    pub fn shrine_with_wad_usd_stable_transmuter(
        transmuter_class: Option<ContractClass>, token_class: Option<ContractClass>
    ) -> TransmuterTestConfig {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let wad_usd_stable = IERC20Dispatcher { contract_address: common::dai_token_deploy(token_class) };

        let transmuter: ITransmuterDispatcher = transmuter_deploy(
            transmuter_class, shrine.contract_address, wad_usd_stable.contract_address, receiver()
        );

        let debt_ceiling: Wad = 30000000000000000000000000_u128.into();
        let seed_amt: Wad = START_TOTAL_YIN.into();
        setup_shrine_with_transmuter(shrine, transmuter, debt_ceiling, seed_amt, receiver(), user());

        TransmuterTestConfig { shrine, transmuter, wad_usd_stable }
    }

    pub fn transmuter_registry_deploy() -> ITransmuterRegistryDispatcher {
        let mut calldata: Array<felt252> = array![admin().into()];

        let transmuter_registry_class = declare("transmuter_registry").unwrap();
        let (transmuter_registry_addr, _) = transmuter_registry_class
            .deploy(@calldata)
            .expect('TR registry deploy failed');

        ITransmuterRegistryDispatcher { contract_address: transmuter_registry_addr }
    }
}
