pub mod seer_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use opus::core::roles::shrine_roles;
    use opus::core::seer::seer as seer_contract;
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaV2Dispatcher, IPragmaV2DispatcherTrait};
    use opus::interfaces::ISeer::{ISeerDispatcher, ISeerDispatcherTrait};
    use opus::interfaces::ISentinel::ISentinelDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::mock::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::tests::external::utils::{pragma_utils, switchboard_utils};
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::{get_block_timestamp, ContractAddress};
    use wadray::Wad;

    //
    // Constants
    //

    pub const ETH_INIT_PRICE: u128 = 1888000000000000000000; // Wad scale
    pub const WBTC_INIT_PRICE: u128 = 20000000000000000000000; // Wad scale

    pub const UPDATE_FREQUENCY: u64 = 30 * 60; // 30 minutes

    //
    // Address constants
    //

    pub fn admin() -> ContractAddress {
        'seer owner'.try_into().unwrap()
    }

    pub fn dummy_eth() -> ContractAddress {
        'eth token'.try_into().unwrap()
    }

    pub fn dummy_wbtc() -> ContractAddress {
        'wbtc token'.try_into().unwrap()
    }

    pub fn deploy_seer(
        seer_class: Option<ContractClass>, sentinel_class: Option<ContractClass>, shrine_class: Option<ContractClass>
    ) -> (ISeerDispatcher, ISentinelDispatcher, IShrineDispatcher) {
        let (sentinel_dispatcher, shrine) = sentinel_utils::deploy_sentinel(sentinel_class, shrine_class);
        let calldata: Array<felt252> = array![
            admin().into(), shrine.into(), sentinel_dispatcher.contract_address.into(), UPDATE_FREQUENCY.into()
        ];

        let seer_class = match seer_class {
            Option::Some(class) => class,
            Option::None => declare("seer").unwrap()
        };

        let (seer_addr, _) = seer_class.deploy(@calldata).expect('failed seer deploy');

        // Allow Seer to advance Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::seer(), seer_addr);
        stop_prank(CheatTarget::One(shrine));

        (
            ISeerDispatcher { contract_address: seer_addr },
            sentinel_dispatcher,
            IShrineDispatcher { contract_address: shrine }
        )
    }

    pub fn deploy_seer_using(
        seer_class: Option<ContractClass>, shrine: ContractAddress, sentinel: ContractAddress
    ) -> ISeerDispatcher {
        let mut calldata: Array<felt252> = array![
            admin().into(), shrine.into(), sentinel.into(), UPDATE_FREQUENCY.into()
        ];

        let seer_class = match seer_class {
            Option::Some(class) => class,
            Option::None => declare("seer").unwrap()
        };

        let (seer_addr, _) = seer_class.deploy(@calldata).expect('failed seer deploy');

        // Allow Seer to advance Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::seer(), seer_addr);
        stop_prank(CheatTarget::One(shrine));

        ISeerDispatcher { contract_address: seer_addr }
    }

    pub fn add_oracles(
        seer: ISeerDispatcher,
        pragma_v2_class: Option<ContractClass>,
        mock_pragma_class: Option<ContractClass>,
        switchboard_class: Option<ContractClass>,
        mock_switchboard_class: Option<ContractClass>
    ) -> Span<ContractAddress> {
        let mut oracles: Array<ContractAddress> = ArrayTrait::new();

        let (pragma, _) = pragma_utils::pragma_v2_deploy(pragma_v2_class, mock_pragma_class);
        oracles.append(pragma.contract_address);

        let (switchboard, _) = switchboard_utils::switchboard_deploy(switchboard_class, mock_switchboard_class);
        oracles.append(switchboard.contract_address);

        start_prank(CheatTarget::One(seer.contract_address), admin());
        seer.set_oracles(oracles.span());
        stop_prank(CheatTarget::One(seer.contract_address));

        oracles.span()
    }

    pub fn mock_valid_price_update(seer: ISeerDispatcher, yang: ContractAddress, price: Wad) {
        let current_ts: u64 = get_block_timestamp();
        let oracles: Span<ContractAddress> = seer.get_oracles();

        // assuming first oracle is Pragma
        let pragma = IOracleDispatcher { contract_address: *oracles.at(0) };
        let mock_pragma = IMockPragmaDispatcher { contract_address: *pragma.get_oracles().at(0) };
        pragma_utils::mock_valid_price_update(mock_pragma, yang, price, current_ts);
    }
}
