mod test_switchboard {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use opus::constants::ETH_USD_PAIR_ID;
    use opus::external::roles::switchboard_roles;
    use opus::external::switchboard::switchboard as switchboard_contract;
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::ISwitchboard::{ISwitchboardDispatcher, ISwitchboardDispatcherTrait};
    use opus::mock::mock_switchboard::{IMockSwitchboardDispatcher, IMockSwitchboardDispatcherTrait};
    use opus::tests::common;
    use opus::tests::external::utils::switchboard_utils::{SwitchboardTestConfig, TIMESTAMP};
    use opus::tests::external::utils::{mock_eth_token_addr, switchboard_utils};
    use opus::tests::seer::utils::seer_utils::ETH_INIT_PRICE;
    use snforge_std::{
        start_prank, stop_prank, spy_events, CheatTarget, ContractClassTrait, EventAssertions, EventSpy, SpyOn
    };
    use starknet::ContractAddress;
    use wadray::Wad;

    #[test]
    fn test_switchboard_setup() {
        let SwitchboardTestConfig { switchboard, mock_switchboard } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );

        // check permissions
        let switchboard_ac = IAccessControlDispatcher { contract_address: switchboard.contract_address };
        let admin: ContractAddress = switchboard_utils::admin();

        assert(switchboard_ac.get_admin() == admin, 'wrong admin');
        assert(switchboard_ac.get_roles(admin) == switchboard_roles::default_admin_role(), 'wrong admin role');

        let oracle = IOracleDispatcher { contract_address: switchboard.contract_address };
        assert(oracle.get_name() == 'Switchboard', 'wrong name');
        assert(oracle.get_oracles() == array![mock_switchboard.contract_address].span(), 'wrong oracle');
    }

    #[test]
    fn test_switchboard_set_yang_pair_id_pass() {
        let SwitchboardTestConfig { switchboard, mock_switchboard } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );

        start_prank(CheatTarget::All, switchboard_utils::admin());
        let mut spy = spy_events(SpyOn::One(switchboard.contract_address));

        let eth: ContractAddress = mock_eth_token_addr();
        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, ETH_INIT_PRICE, TIMESTAMP);
        switchboard.set_yang_pair_id(eth, ETH_USD_PAIR_ID);

        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::YangPairIdSet(
                            switchboard_contract::YangPairIdSet { address: eth, pair_id: ETH_USD_PAIR_ID }
                        )
                    )
                ]
            );
    }

    #[test]
    fn test_switchboard_set_yang_pair_id_twice_pass() {
        let SwitchboardTestConfig { switchboard, mock_switchboard } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );

        start_prank(CheatTarget::All, switchboard_utils::admin());
        let mut spy = spy_events(SpyOn::One(switchboard.contract_address));

        let typo_eth: ContractAddress = 'whoops'.try_into().unwrap();
        let eth: ContractAddress = mock_eth_token_addr();

        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, ETH_INIT_PRICE, TIMESTAMP);
        switchboard.set_yang_pair_id(typo_eth, ETH_USD_PAIR_ID);
        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::YangPairIdSet(
                            switchboard_contract::YangPairIdSet { address: typo_eth, pair_id: ETH_USD_PAIR_ID }
                        )
                    )
                ]
            );

        switchboard.set_yang_pair_id(eth, ETH_USD_PAIR_ID);
        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::YangPairIdSet(
                            switchboard_contract::YangPairIdSet { address: eth, pair_id: ETH_USD_PAIR_ID }
                        )
                    )
                ]
            );
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_switchboard_set_yang_pair_id_unauthorized_fail() {
        let SwitchboardTestConfig { switchboard, .. } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );
        let eth: ContractAddress = mock_eth_token_addr();
        switchboard.set_yang_pair_id(eth, ETH_USD_PAIR_ID);
    }

    #[test]
    #[should_panic(expected: ('SWI: Invalid pair ID',))]
    fn test_switchboard_set_yang_pair_id_zero() {
        let SwitchboardTestConfig { switchboard, .. } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );
        start_prank(CheatTarget::All, switchboard_utils::admin());
        let eth: ContractAddress = mock_eth_token_addr();
        switchboard.set_yang_pair_id(eth, 0);
    }

    #[test]
    #[should_panic(expected: ('SWI: Invalid yang address',))]
    fn test_switchboard_set_yang_pair_id_yang_zero() {
        let SwitchboardTestConfig { switchboard, .. } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );
        start_prank(CheatTarget::All, switchboard_utils::admin());
        switchboard.set_yang_pair_id(0.try_into().unwrap(), ETH_USD_PAIR_ID);
    }

    #[test]
    #[should_panic(expected: ('SWI: Invalid feed value',))]
    fn test_switchboard_set_yang_pair_id_invalid_feed_value() {
        let SwitchboardTestConfig { switchboard, mock_switchboard } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );

        start_prank(CheatTarget::All, switchboard_utils::admin());

        let eth: ContractAddress = mock_eth_token_addr();
        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, 0, TIMESTAMP);
        switchboard.set_yang_pair_id(eth, ETH_USD_PAIR_ID);
    }

    #[test]
    #[should_panic(expected: ('SWI: Invalid feed timestamp',))]
    fn test_switchboard_set_yang_pair_id_invalid_feed_timestamp() {
        let SwitchboardTestConfig { switchboard, mock_switchboard } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );

        start_prank(CheatTarget::All, switchboard_utils::admin());

        let eth: ContractAddress = mock_eth_token_addr();
        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, ETH_INIT_PRICE, 0);
        switchboard.set_yang_pair_id(eth, ETH_USD_PAIR_ID);
    }

    #[test]
    fn test_switchboard_fetch_price_pass() {
        let SwitchboardTestConfig { switchboard, mock_switchboard } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );
        let oracle = IOracleDispatcher { contract_address: switchboard.contract_address };

        let eth: ContractAddress = mock_eth_token_addr();
        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, ETH_INIT_PRICE, TIMESTAMP);
        start_prank(CheatTarget::One(switchboard.contract_address), switchboard_utils::admin());
        switchboard.set_yang_pair_id(eth, ETH_USD_PAIR_ID);
        stop_prank(CheatTarget::One(switchboard.contract_address));

        let result: Result<Wad, felt252> = oracle.fetch_price(eth);
        assert(result.is_ok(), 'fetch price failed');
        assert(result.unwrap() == ETH_INIT_PRICE.into(), 'wrong price');
    }

    #[test]
    fn test_switchboard_fetch_price_invalid_value_err() {
        let SwitchboardTestConfig { switchboard, mock_switchboard } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );
        let oracle = IOracleDispatcher { contract_address: switchboard.contract_address };

        let eth: ContractAddress = mock_eth_token_addr();
        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, ETH_INIT_PRICE, TIMESTAMP);
        start_prank(CheatTarget::One(switchboard.contract_address), switchboard_utils::admin());
        switchboard.set_yang_pair_id(eth, ETH_USD_PAIR_ID);
        stop_prank(CheatTarget::One(switchboard.contract_address));

        let mut spy = spy_events(SpyOn::One(switchboard.contract_address));

        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, 0, TIMESTAMP);

        let result: Result<Wad, felt252> = oracle.fetch_price(eth);
        assert(result.is_err(), 'fetch price should fail');
        assert(result.unwrap_err() == 'SWI: Invalid price update', 'wrong err');

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
    fn test_switchboard_fetch_price_invalid_timestamp_err() {
        let SwitchboardTestConfig { switchboard, mock_switchboard } = switchboard_utils::switchboard_deploy(
            Option::None, Option::None
        );
        let oracle = IOracleDispatcher { contract_address: switchboard.contract_address };

        let eth: ContractAddress = mock_eth_token_addr();
        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, ETH_INIT_PRICE, TIMESTAMP);
        start_prank(CheatTarget::One(switchboard.contract_address), switchboard_utils::admin());
        switchboard.set_yang_pair_id(eth, ETH_USD_PAIR_ID);
        stop_prank(CheatTarget::One(switchboard.contract_address));

        let mut spy = spy_events(SpyOn::One(switchboard.contract_address));

        mock_switchboard.next_get_latest_result(ETH_USD_PAIR_ID, ETH_INIT_PRICE, 0);

        let result: Result<Wad, felt252> = oracle.fetch_price(eth);
        assert(result.is_err(), 'fetch price should fail');
        assert(result.unwrap_err() == 'SWI: Invalid price update', 'wrong err');

        spy
            .assert_emitted(
                @array![
                    (
                        switchboard.contract_address,
                        switchboard_contract::Event::InvalidPriceUpdate(
                            switchboard_contract::InvalidPriceUpdate {
                                yang: eth, price: ETH_INIT_PRICE.into(), timestamp: 0
                            }
                        )
                    )
                ]
            );
    }
}
