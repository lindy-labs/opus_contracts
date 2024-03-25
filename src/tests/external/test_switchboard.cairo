mod test_switchboard {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use opus::external::roles::switchboard_roles;
    use opus::external::switchboard::switchboard as switchboard_contract;
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::ISwitchboard::{ISwitchboardDispatcher, ISwitchboardDispatcherTrait};
    use opus::mock::mock_switchboard::{IMockSwitchboardDispatcher, IMockSwitchboardDispatcherTrait};
    use opus::tests::common;
    use opus::tests::external::utils::{switchboard_utils, {switchboard_utils::ETH_PRICE, switchboard_utils::TIMESTAMP}};
    use snforge_std::{
        start_prank, stop_prank, spy_events, CheatTarget, ContractClassTrait, EventAssertions, EventSpy, SpyOn
    };
    use starknet::ContractAddress;
    use wadray::Wad;

    #[test]
    fn test_switchboard_setup() {
        let (switchboard, mock_switchboard) = switchboard_utils::switchboard_deploy();

        // check permissions
        let switchboard_ac = IAccessControlDispatcher { contract_address: switchboard.contract_address };
        let admin: ContractAddress = switchboard_utils::admin();

        assert(switchboard_ac.get_admin() == admin, 'wrong admin');
        assert(switchboard_ac.get_roles(admin) == switchboard_roles::default_admin_role(), 'wrong admin role');

        let oracle = IOracleDispatcher { contract_address: switchboard.contract_address };
        assert(oracle.get_name() == 'Switchboard', 'wrong name');
        assert(oracle.get_oracle() == mock_switchboard.contract_address, 'wrong oracle');
    }

    #[test]
    fn test_switchboard_set_yang_pair_id_pass() {
        let (switchboard, mock_switchboard) = switchboard_utils::switchboard_deploy();

        start_prank(CheatTarget::All, switchboard_utils::admin());
        let mut spy = spy_events(SpyOn::One(switchboard.contract_address));

        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();
        mock_switchboard.next_get_latest_result('ETH/USD', ETH_PRICE, TIMESTAMP);
        switchboard.set_yang_pair_id(eth, 'ETH/USD');

        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::YangPairIdSet(
                            switchboard_contract::YangPairIdSet { address: eth, pair_id: 'ETH/USD' }
                        )
                    )
                ]
            );
    }

    #[test]
    fn test_switchboard_set_yang_pair_id_twice_pass() {
        let (switchboard, mock_switchboard) = switchboard_utils::switchboard_deploy();

        start_prank(CheatTarget::All, switchboard_utils::admin());
        let mut spy = spy_events(SpyOn::One(switchboard.contract_address));

        let typo_eth: ContractAddress = 'whoops'.try_into().unwrap();
        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();

        mock_switchboard.next_get_latest_result('ETH/USD', ETH_PRICE, TIMESTAMP);
        switchboard.set_yang_pair_id(typo_eth, 'ETH/USD');
        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::YangPairIdSet(
                            switchboard_contract::YangPairIdSet { address: typo_eth, pair_id: 'ETH/USD' }
                        )
                    )
                ]
            );

        switchboard.set_yang_pair_id(eth, 'ETH/USD');
        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::YangPairIdSet(
                            switchboard_contract::YangPairIdSet { address: eth, pair_id: 'ETH/USD' }
                        )
                    )
                ]
            );
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_switchboard_set_yang_pair_id_unauthorized_fail() {
        let (switchboard, _) = switchboard_utils::switchboard_deploy();
        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();
        switchboard.set_yang_pair_id(eth, 'ETH/USD');
    }

    #[test]
    #[should_panic(expected: ('SWI: Invalid pair ID',))]
    fn test_switchboard_set_yang_pair_id_zero() {
        let (switchboard, _) = switchboard_utils::switchboard_deploy();
        start_prank(CheatTarget::All, switchboard_utils::admin());
        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();
        switchboard.set_yang_pair_id(eth, 0);
    }

    #[test]
    #[should_panic(expected: ('SWI: Invalid yang address',))]
    fn test_switchboard_set_yang_pair_id_yang_zero() {
        let (switchboard, _) = switchboard_utils::switchboard_deploy();
        start_prank(CheatTarget::All, switchboard_utils::admin());
        switchboard.set_yang_pair_id(0.try_into().unwrap(), 'ETH/USD');
    }

    #[test]
    #[should_panic(expected: ('SWI: Invalid feed value',))]
    fn test_switchboard_set_yang_pair_id_invalid_feed_value() {
        let (switchboard, mock_switchboard) = switchboard_utils::switchboard_deploy();

        start_prank(CheatTarget::All, switchboard_utils::admin());

        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();
        mock_switchboard.next_get_latest_result('ETH/USD', 0, TIMESTAMP);
        switchboard.set_yang_pair_id(eth, 'ETH/USD');
    }

    #[test]
    #[should_panic(expected: ('SWI: Invalid feed timestamp',))]
    fn test_switchboard_set_yang_pair_id_invalid_feed_timestamp() {
        let (switchboard, mock_switchboard) = switchboard_utils::switchboard_deploy();

        start_prank(CheatTarget::All, switchboard_utils::admin());

        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();
        mock_switchboard.next_get_latest_result('ETH/USD', ETH_PRICE, 0);
        switchboard.set_yang_pair_id(eth, 'ETH/USD');
    }

    #[test]
    fn test_switchboard_fetch_price_pass() {
        let (switchboard, mock_switchboard) = switchboard_utils::switchboard_deploy();
        let oracle = IOracleDispatcher { contract_address: switchboard.contract_address };

        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();
        mock_switchboard.next_get_latest_result('ETH/USD', ETH_PRICE, TIMESTAMP);
        start_prank(CheatTarget::One(switchboard.contract_address), switchboard_utils::admin());
        switchboard.set_yang_pair_id(eth, 'ETH/USD');
        stop_prank(CheatTarget::One(switchboard.contract_address));

        let result: Result<Wad, felt252> = oracle.fetch_price(eth, false);
        assert(result.is_ok(), 'fetch price failed');
        assert(result.unwrap() == ETH_PRICE.into(), 'wrong price');
    }

    #[test]
    fn test_switchboard_fetch_price_invalid_value_err_forced_ok() {
        let (switchboard, mock_switchboard) = switchboard_utils::switchboard_deploy();
        let oracle = IOracleDispatcher { contract_address: switchboard.contract_address };

        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();
        mock_switchboard.next_get_latest_result('ETH/USD', ETH_PRICE, TIMESTAMP);
        start_prank(CheatTarget::One(switchboard.contract_address), switchboard_utils::admin());
        switchboard.set_yang_pair_id(eth, 'ETH/USD');
        stop_prank(CheatTarget::One(switchboard.contract_address));

        let mut spy = spy_events(SpyOn::One(switchboard.contract_address));

        mock_switchboard.next_get_latest_result('ETH/USD', 0, TIMESTAMP);

        let result: Result<Wad, felt252> = oracle.fetch_price(eth, false);
        assert(result.is_err(), 'fetch price should fail');
        assert(result.unwrap_err() == 'SWI: Invalid price update', 'wrong err');

        let result: Result<Wad, felt252> = oracle.fetch_price(eth, true); // forced fetch
        assert(result.is_ok(), 'forced fetch should pass');
        assert(result.unwrap().is_zero(), 'wrong price');

        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::InvalidPriceUpdate(
                            switchboard_contract::InvalidPriceUpdate {
                                yang: eth, price: Zero::zero(), timestamp: TIMESTAMP
                            }
                        )
                    )
                ]
            );
    }

    #[test]
    fn test_switchboard_fetch_price_invalid_timestamp_err_forced_ok() {
        let (switchboard, mock_switchboard) = switchboard_utils::switchboard_deploy();
        let oracle = IOracleDispatcher { contract_address: switchboard.contract_address };

        let eth: ContractAddress = switchboard_utils::mock_eth_token_addr();
        mock_switchboard.next_get_latest_result('ETH/USD', ETH_PRICE, TIMESTAMP);
        start_prank(CheatTarget::One(switchboard.contract_address), switchboard_utils::admin());
        switchboard.set_yang_pair_id(eth, 'ETH/USD');
        stop_prank(CheatTarget::One(switchboard.contract_address));

        let mut spy = spy_events(SpyOn::One(switchboard.contract_address));

        mock_switchboard.next_get_latest_result('ETH/USD', ETH_PRICE, 0);

        let result: Result<Wad, felt252> = oracle.fetch_price(eth, false);
        assert(result.is_err(), 'fetch price should fail');
        assert(result.unwrap_err() == 'SWI: Invalid price update', 'wrong err');

        let result: Result<Wad, felt252> = oracle.fetch_price(eth, true); // forced fetch
        assert(result.is_ok(), 'forced fetch should pass');
        assert(result.unwrap() == ETH_PRICE.into(), 'wrong price');

        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::InvalidPriceUpdate(
                            switchboard_contract::InvalidPriceUpdate {
                                yang: eth, price: ETH_PRICE.into(), timestamp: 0
                            }
                        )
                    )
                ]
            );
    }
}
