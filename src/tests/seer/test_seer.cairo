// TODO: once we have a fallback oracle, add a test that the fallback
//       in update_prices actually works
mod test_seer {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::array::SpanTrait;
    use core::num::traits::Zero;
    use opus::constants::PRAGMA_DECIMALS;
    use opus::core::roles::seer_roles;
    use opus::core::seer::seer as seer_contract;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::external::interfaces::{ITaskDispatcher, ITaskDispatcherTrait};
    use opus::interfaces::IERC20::{IMintableDispatcher, IMintableDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::ISeer::{ISeerDispatcher, ISeerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::mock::mock_switchboard::{IMockSwitchboardDispatcher, IMockSwitchboardDispatcherTrait};
    use opus::tests::common;
    use opus::tests::external::utils::{pragma_utils, switchboard_utils};
    use opus::tests::seer::utils::seer_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::YangSuspensionStatus;
    use opus::types::pragma::PragmaPricesResponse;
    use snforge_std::{
        declare, start_prank, stop_prank, start_warp, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions,
        ContractClassTrait
    };
    use starknet::{get_block_timestamp, ContractAddress};
    use wadray::{Wad, WAD_SCALE};

    #[test]
    fn test_seer_setup() {
        let mut spy = spy_events(SpyOn::All);
        let (seer, _, _) = seer_utils::deploy_seer(Option::None, Option::None, Option::None);
        let seer_ac = IAccessControlDispatcher { contract_address: seer.contract_address };
        assert(seer_ac.get_roles(seer_utils::admin()) == seer_roles::default_admin_role(), 'wrong role for admin');
        assert(seer.get_update_frequency() == seer_utils::UPDATE_FREQUENCY, 'wrong update frequency');
        assert(seer.get_oracles().len() == 0, 'wrong number of oracles');

        let expected_events = array![
            (
                seer.contract_address,
                seer_contract::Event::UpdateFrequencyUpdated(
                    seer_contract::UpdateFrequencyUpdated {
                        old_frequency: 0, new_frequency: seer_utils::UPDATE_FREQUENCY
                    }
                )
            )
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_set_oracles() {
        let (seer, _, _) = seer_utils::deploy_seer(Option::None, Option::None, Option::None);

        // seer doesn't validate the addresses, so any will do
        let oracles: Span<ContractAddress> = array![
            'pragma addr'.try_into().unwrap(), 'switchboard addr'.try_into().unwrap()
        ]
            .span();

        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.set_oracles(oracles);

        assert(oracles == seer.get_oracles(), 'wrong set oracles');
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_oracles_unauthorized() {
        let (seer, _, _) = seer_utils::deploy_seer(Option::None, Option::None, Option::None);

        // seer doesn't validate the addresses, so any will do
        let oracles: Span<ContractAddress> = array![
            'pragma addr'.try_into().unwrap(), 'switchboard addr'.try_into().unwrap()
        ]
            .span();

        start_prank(CheatTarget::One(seer.contract_address), common::badguy());
        seer.set_oracles(oracles);
    }

    #[test]
    fn test_set_update_frequency() {
        let (seer, _, _) = seer_utils::deploy_seer(Option::None, Option::None, Option::None);
        let mut spy = spy_events(SpyOn::One(seer.contract_address));

        let new_frequency: u64 = 1200;
        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.set_update_frequency(new_frequency);

        assert(seer.get_update_frequency() == new_frequency, 'wrong update frequency');

        let expected_events = array![
            (
                seer.contract_address,
                seer_contract::Event::UpdateFrequencyUpdated(
                    seer_contract::UpdateFrequencyUpdated { old_frequency: seer_utils::UPDATE_FREQUENCY, new_frequency }
                )
            )
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_update_frequency_unauthorized() {
        let (seer, _, _) = seer_utils::deploy_seer(Option::None, Option::None, Option::None);

        start_prank(CheatTarget::One(seer.contract_address), common::badguy());
        seer.set_update_frequency(1200);
    }

    #[test]
    #[should_panic(expected: ('SEER: Frequency out of bounds',))]
    fn test_set_update_frequency_oob_lower() {
        let (seer, _, _) = seer_utils::deploy_seer(Option::None, Option::None, Option::None);

        let new_frequency: u64 = seer_contract::LOWER_UPDATE_FREQUENCY_BOUND - 1;
        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.set_update_frequency(new_frequency);
    }

    #[test]
    #[should_panic(expected: ('SEER: Frequency out of bounds',))]
    fn test_set_update_frequency_oob_higher() {
        let (seer, _, _) = seer_utils::deploy_seer(Option::None, Option::None, Option::None);

        let new_frequency: u64 = seer_contract::UPPER_UPDATE_FREQUENCY_BOUND + 1;
        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.set_update_frequency(new_frequency);
    }

    #[test]
    fn test_update_prices_successful() {
        let (sentinel, shrine, yangs, gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None,
        );

        let seer: ISeerDispatcher = seer_utils::deploy_seer_using(
            Option::None, shrine.contract_address, sentinel.contract_address
        );

        let mut spy = spy_events(SpyOn::One(seer.contract_address));

        let oracles: Span<ContractAddress> = seer_utils::add_oracles(
            seer, Option::None, Option::None, Option::None, Option::None
        );
        pragma_utils::add_yangs_v2(*oracles.at(0), yangs);
        // add_yangs_v2 uses ETH_INIT_PRICE and WBTC_INIT_PRICE
        let mut eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        let mut wbtc_price: Wad = seer_utils::WBTC_INIT_PRICE.into();

        let eth_addr: ContractAddress = *yangs.at(0);
        let wbtc_addr: ContractAddress = *yangs.at(1);
        let eth_gate: IGateDispatcher = *gates.at(0);
        let wbtc_gate: IGateDispatcher = *gates.at(1);
        let pragma: ContractAddress = *(oracles[0]);
        let switchboard: ContractAddress = *(oracles[1]);

        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.update_prices();

        let (shrine_eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        let (shrine_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_addr);
        assert(shrine_eth_price == eth_price, 'wrong eth price in shrine 1');
        assert(shrine_wbtc_price == wbtc_price, 'wrong wbtc price in shrine 1');

        let expected_events_seer = array![
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate { oracle: pragma, yang: eth_addr, price: eth_price }
                )
            ),
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate { oracle: pragma, yang: wbtc_addr, price: wbtc_price }
                )
            ),
            (seer.contract_address, seer_contract::Event::UpdatePricesDone(seer_contract::UpdatePricesDone {}))
        ];

        spy.assert_emitted(@expected_events_seer);

        let expected_missing_seer = array![
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdateMissed(seer_contract::PriceUpdateMissed { yang: *yangs[0] })
            ),
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdateMissed(seer_contract::PriceUpdateMissed { yang: *yangs[1] })
            ),
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate { oracle: switchboard, yang: eth_addr, price: eth_price }
                )
            ),
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate { oracle: switchboard, yang: wbtc_addr, price: wbtc_price }
                )
            ),
        ];
        spy.assert_not_emitted(@expected_missing_seer);

        let gate_eth_bal: u128 = eth_gate.get_total_assets();
        let gate_wbtc_bal: u128 = wbtc_gate.get_total_assets();

        IMintableDispatcher { contract_address: eth_addr }.mint(eth_gate.contract_address, gate_eth_bal.into());
        IMintableDispatcher { contract_address: wbtc_addr }.mint(wbtc_gate.contract_address, gate_wbtc_bal.into());

        let mut next_ts = get_block_timestamp() + shrine_contract::TIME_INTERVAL;
        start_warp(CheatTarget::All, next_ts);
        eth_price += (100 * WAD_SCALE).into();
        wbtc_price += (1000 * WAD_SCALE).into();
        let pragma = IOracleDispatcher { contract_address: *oracles[0] };
        let mock_pragma = IMockPragmaDispatcher { contract_address: *pragma.get_oracles().at(0) };
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, next_ts);
        pragma_utils::mock_valid_price_update(mock_pragma, wbtc_addr, wbtc_price, next_ts);

        seer.update_prices();

        let (shrine_eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        let (shrine_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_addr);
        // shrine's price is rebased by 2
        assert(shrine_eth_price == eth_price + eth_price, 'wrong eth price in shrine 2');
        assert(shrine_wbtc_price == wbtc_price + wbtc_price, 'wrong wbtc price in shrine 2');

        // Check that delisted yangs are skipped by suspending ETH
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.suspend_yang(eth_addr);
        stop_prank(CheatTarget::One(shrine.contract_address));

        // avoid hitting iteration limit by splitting the suspension period into parts
        let mut period_div = 8;
        let suspension_grace_period_quarter = (shrine_contract::SUSPENSION_GRACE_PERIOD / period_div);

        let mut last_delisted_yang_interval: u64 = 0;
        loop {
            if period_div.is_zero() {
                break;
            }

            next_ts += suspension_grace_period_quarter;
            start_warp(CheatTarget::All, next_ts);

            pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, next_ts);
            pragma_utils::mock_valid_price_update(mock_pragma, wbtc_addr, wbtc_price, next_ts);

            seer.update_prices();

            if period_div != 1 {
                assert(
                    shrine.get_yang_suspension_status(eth_addr) == YangSuspensionStatus::Temporary, 'yang suspended'
                );
                last_delisted_yang_interval = shrine_utils::get_interval(get_block_timestamp());
            }

            period_div -= 1;
        };

        assert(shrine.get_yang_suspension_status(eth_addr) == YangSuspensionStatus::Permanent, 'yang not suspended');

        let (last_eth_price, last_cumulative_eth_price) = shrine.get_yang_price(eth_addr, last_delisted_yang_interval);
        assert(last_eth_price.is_non_zero(), 'price should not be zero');
        assert(last_cumulative_eth_price.is_non_zero(), 'wrong cumulative price #1');

        let first_delisted_interval: u64 = last_delisted_yang_interval + 1;
        let (first_delisted_price, first_delisted_cumulative_eth_price) = shrine
            .get_yang_price(eth_addr, first_delisted_interval);
        assert(first_delisted_price.is_zero(), 'price should be zero #1');
        assert(first_delisted_cumulative_eth_price.is_zero(), 'wrong cumulative price #2');

        let (eth_price, cumulative_eth_price, eth_price_interval) = shrine.get_current_yang_price(eth_addr);
        assert(eth_price.is_zero(), 'price should be zero #2');
        assert(cumulative_eth_price.is_zero(), 'wrong cumulative price #3');
        let current_interval: u64 = shrine_utils::get_interval(get_block_timestamp());
        assert_eq!(eth_price_interval, current_interval, "wrong delisted price interval");
    }

    #[test]
    fn test_update_prices_from_fallback_oracle_successful() {
        let (sentinel, shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None,
        );

        let seer: ISeerDispatcher = seer_utils::deploy_seer_using(
            Option::None, shrine.contract_address, sentinel.contract_address
        );

        let oracles: Span<ContractAddress> = seer_utils::add_oracles(
            seer, Option::None, Option::None, Option::None, Option::None
        );
        pragma_utils::add_yangs_v2(*oracles.at(0), yangs);
        switchboard_utils::add_yangs(*oracles.at(1), yangs);

        // mock an ETH price update of spot Pragma that will fail due to too few sources,
        // causing Seer to use Switchboard
        let eth_addr: ContractAddress = *yangs[0];
        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        let pragma = IOracleDispatcher { contract_address: *oracles[0] };
        let mock_pragma = IMockPragmaDispatcher { contract_address: *pragma.get_oracles().at(0) };
        mock_pragma
            .next_get_data(
                pragma_utils::get_pair_id_for_yang(eth_addr),
                PragmaPricesResponse {
                    price: pragma_utils::convert_price_to_pragma_scale(eth_price),
                    decimals: PRAGMA_DECIMALS.into(),
                    last_updated_timestamp: get_block_timestamp(),
                    num_sources_aggregated: 0,
                    expiration_timestamp: Option::None,
                }
            );

        let mut spy = spy_events(SpyOn::One(seer.contract_address));
        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.update_prices();

        let expected_eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        let (shrine_eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        assert(expected_eth_price == shrine_eth_price, 'wrong eth price in shrine');

        let pragma: ContractAddress = *oracles.at(0);
        let switchboard: ContractAddress = *oracles.at(1);
        let wbtc_addr: ContractAddress = *yangs[1];
        // asserting that PriceUpdate event for ETH coming from Switchboard,
        // but for WBTC coming from Pragma
        let expected_events_seer = array![
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate { oracle: switchboard, yang: eth_addr, price: expected_eth_price }
                )
            ),
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate {
                        oracle: pragma, yang: wbtc_addr, price: seer_utils::WBTC_INIT_PRICE.into()
                    }
                )
            ),
            (seer.contract_address, seer_contract::Event::UpdatePricesDone(seer_contract::UpdatePricesDone {}))
        ];
        spy.assert_emitted(@expected_events_seer);
    }

    #[test]
    fn test_update_prices_via_execute_task_successful() {
        let (sentinel, shrine, yangs, _) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None
        );
        let seer: ISeerDispatcher = seer_utils::deploy_seer_using(
            Option::None, shrine.contract_address, sentinel.contract_address
        );

        let mut spy = spy_events(SpyOn::One(seer.contract_address));

        let oracles: Span<ContractAddress> = seer_utils::add_oracles(
            seer, Option::None, Option::None, Option::None, Option::None
        );
        pragma_utils::add_yangs_v2(*oracles.at(0), yangs);
        // add_yangs_v2 uses ETH_INIT_PRICE and WBTC_INIT_PRICE
        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        let wbtc_price: Wad = seer_utils::WBTC_INIT_PRICE.into();
        let eth_addr: ContractAddress = *yangs.at(0);
        let wbtc_addr: ContractAddress = *yangs.at(1);
        let pragma: ContractAddress = *(oracles[0]);

        ITaskDispatcher { contract_address: seer.contract_address }.execute_task();

        let (shrine_eth_price, _, _) = shrine.get_current_yang_price(eth_addr);
        let (shrine_wbtc_price, _, _) = shrine.get_current_yang_price(wbtc_addr);
        assert(shrine_eth_price == eth_price, 'wrong eth price in shrine 1');
        assert(shrine_wbtc_price == wbtc_price, 'wrong wbtc price in shrine 1');

        let expected_events_seer = array![
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate { oracle: pragma, yang: eth_addr, price: eth_price }
                )
            ),
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate { oracle: pragma, yang: wbtc_addr, price: wbtc_price }
                )
            ),
            (seer.contract_address, seer_contract::Event::UpdatePricesDone(seer_contract::UpdatePricesDone {}))
        ];

        spy.assert_emitted(@expected_events_seer);

        let expected_missing_seer = array![
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdateMissed(seer_contract::PriceUpdateMissed { yang: *yangs[0] })
            ),
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdateMissed(seer_contract::PriceUpdateMissed { yang: *yangs[1] })
            ),
        ];
        spy.assert_not_emitted(@expected_missing_seer);
    }

    #[test]
    #[should_panic(expected: ('PGM: Unknown yang',))]
    fn test_update_prices_fails_with_no_yangs_in_seer() {
        let (sentinel, shrine, _yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None,
        );
        let seer: ISeerDispatcher = seer_utils::deploy_seer_using(
            Option::None, shrine.contract_address, sentinel.contract_address
        );
        seer_utils::add_oracles(seer, Option::None, Option::None, Option::None, Option::None);
        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.update_prices();
    }

    #[test]
    #[should_panic]
    fn test_update_prices_fails_with_wrong_yang_in_seer() {
        let token_class = Option::Some(declare("erc20_mintable").unwrap());
        let (sentinel, shrine, _yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, token_class, Option::None, Option::None,
        );
        let seer: ISeerDispatcher = seer_utils::deploy_seer_using(
            Option::None, shrine.contract_address, sentinel.contract_address
        );
        let oracles: Span<ContractAddress> = seer_utils::add_oracles(
            seer, Option::None, Option::None, Option::None, Option::None
        );
        let eth_yang: ContractAddress = common::eth_token_deploy(token_class);
        let yangs = array![eth_yang, eth_yang].span();
        pragma_utils::add_yangs_v2(*oracles.at(0), yangs);

        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.update_prices();
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_update_prices_unauthorized() {
        let (seer, _, _) = seer_utils::deploy_seer(Option::None, Option::None, Option::None);

        start_prank(CheatTarget::One(seer.contract_address), common::badguy());
        seer.update_prices();
    }

    #[test]
    fn test_update_prices_missed_updates() {
        let (sentinel, shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None,
        );
        let seer: ISeerDispatcher = seer_utils::deploy_seer_using(
            Option::None, shrine.contract_address, sentinel.contract_address
        );

        let mut spy = spy_events(SpyOn::One(seer.contract_address));

        let oracles: Span<ContractAddress> = seer_utils::add_oracles(
            seer, Option::None, Option::None, Option::None, Option::None
        );
        pragma_utils::add_yangs_v2(*oracles.at(0), yangs);
        switchboard_utils::add_yangs(*oracles.at(1), yangs);

        // mock a price update of Pragma spot eth that
        // fails validation and fetch_price returns a Result::Err
        // so that Switchboard is called as update - mock its price
        // such that it fails validation too, so there's nothing more to
        // fall back on and a PriceUpdateMissed is emitted
        let eth_addr: ContractAddress = *yangs[0];
        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        let pragma = IOracleDispatcher { contract_address: *oracles[0] };
        let mock_pragma = IMockPragmaDispatcher { contract_address: *pragma.get_oracles().at(0) };
        mock_pragma
            .next_get_data(
                pragma_utils::get_pair_id_for_yang(eth_addr),
                PragmaPricesResponse {
                    price: pragma_utils::convert_price_to_pragma_scale(eth_price),
                    decimals: PRAGMA_DECIMALS.into(),
                    last_updated_timestamp: get_block_timestamp(),
                    num_sources_aggregated: 0,
                    expiration_timestamp: Option::None,
                }
            );

        let switchboard = IOracleDispatcher { contract_address: *oracles[1] };
        let mock_switchboard = IMockSwitchboardDispatcher { contract_address: *switchboard.get_oracles().at(0) };
        // mock a price update that fails Switchboard validation too
        mock_switchboard.next_get_latest_result(switchboard_utils::ETH_USD_PAIR_ID, 0, 0);

        ITaskDispatcher { contract_address: seer.contract_address }.execute_task();

        // expecting one PriceUpdateMissed event but also UpdatePricesDone
        let expected_events = array![
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdateMissed(seer_contract::PriceUpdateMissed { yang: eth_addr })
            ),
            (seer.contract_address, seer_contract::Event::UpdatePricesDone(seer_contract::UpdatePricesDone {}))
        ];

        spy.assert_emitted(@expected_events);

        // not expecting PriceUpdate
        let expected_missing = array![
            (
                seer.contract_address,
                seer_contract::Event::PriceUpdate(
                    seer_contract::PriceUpdate { oracle: pragma.contract_address, yang: eth_addr, price: eth_price }
                )
            )
        ];
        spy.assert_not_emitted(@expected_missing);
    }

    #[test]
    fn test_probe_task() {
        let (sentinel, shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None,
        );
        let seer: ISeerDispatcher = seer_utils::deploy_seer_using(
            Option::None, shrine.contract_address, sentinel.contract_address
        );
        let oracles: Span<ContractAddress> = seer_utils::add_oracles(
            seer, Option::None, Option::None, Option::None, Option::None
        );
        pragma_utils::add_yangs_v2(*oracles.at(0), yangs);

        let task = ITaskDispatcher { contract_address: seer.contract_address };
        assert(task.probe_task(), 'should be ready 1');

        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.update_prices();

        assert(!task.probe_task(), 'should not be ready 1');

        start_warp(CheatTarget::All, get_block_timestamp() + seer.get_update_frequency() - 1);
        assert(!task.probe_task(), 'should not be ready 2');

        start_warp(CheatTarget::All, get_block_timestamp() + 1);
        assert(task.probe_task(), 'should be ready 2');
    }
}
