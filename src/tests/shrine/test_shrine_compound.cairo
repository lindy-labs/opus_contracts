mod test_shrine_compound {
    use core::num::traits::Zero;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{Health, YangSuspensionStatus};
    use snforge_std::{
        EventSpyAssertionsTrait, EventSpyTrait, EventsFilterTrait, spy_events, start_cheat_block_timestamp_global,
        start_cheat_caller_address,
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{RAY_SCALE, Ray, SignedWad, WAD_ONE, Wad};

    //
    // Tests - Trove estimate and charge
    //

    // Test for `charge` with all intervals between start and end inclusive updated.
    //
    // T+START--------------T+END
    #[test]
    fn test_compound_and_charge_scenario_1() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        // Advance one interval to avoid overwriting the last price
        shrine_utils::advance_interval();

        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, start_debt);

        let start_interval: u64 = shrine_utils::current_interval();

        let trove_id: u64 = common::TROVE_1;
        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();

        // Note that this is the price at `start_interval - 1` because we advanced one interval
        // after the last price update
        let yang_prices: Span<Wad> = shrine_utils::get_yang_prices(shrine, yangs);
        let trove_health: Health = shrine.get_trove_health(trove_id);

        shrine_utils::advance_prices_and_set_multiplier(shrine, shrine_utils::FEED_LEN, yangs, yang_prices);

        // Offset by 1 because `advance_prices_and_set_multiplier` updates `start_interval`.
        let end_interval: u64 = start_interval + shrine_utils::FEED_LEN - 1;
        assert(shrine_utils::current_interval() == end_interval, 'wrong end interval'); // sanity check

        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = shrine_utils::compound_for_single_yang(
            shrine_utils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            trove_health.debt,
        );

        let estimated_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(estimated_trove_health.debt == expected_debt, 'wrong compounded debt');

        let before_budget: SignedWad = shrine.get_budget();

        // Trigger charge and check interest is accrued
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.melt(common::TROVE1_OWNER_ADDR, trove_id, Zero::zero());
        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == expected_debt, 'debt not updated');

        let interest: Wad = estimated_trove_health.debt - start_debt;
        assert(shrine.get_budget() == before_budget + interest.into(), 'wrong budget');

        // Check events
        let shrine_events = spy.get_events().emitted_by(shrine.contract_address);

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(
            shrine_events.events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"),
        );

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: expected_debt },
                ),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: interest }),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Slight variation of `test_charge_scenario_1` where there is an interval between start and end
    // that does not have a price update.
    //
    // `X` in the diagram below indicates a missed interval.
    //
    // T+START------X-------T+END
    #[test]
    fn test_charge_scenario_1b() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        // Advance one interval to avoid overwriting the last price
        shrine_utils::advance_interval();

        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, start_debt);

        let start_interval: u64 = shrine_utils::current_interval();

        let trove_id: u64 = common::TROVE_1;
        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang1_addr = *yangs.at(0);
        // Note that this is the price at `start_interval - 1` because we advanced one interval
        // after the last price update
        let yang_prices: Span<Wad> = shrine_utils::get_yang_prices(shrine, yangs);
        let trove_health: Health = shrine.get_trove_health(trove_id);

        let num_intervals_before_skip: u64 = 5;
        shrine_utils::advance_prices_and_set_multiplier(shrine, num_intervals_before_skip, yangs, yang_prices);

        let skipped_interval: u64 = start_interval + num_intervals_before_skip;

        // Skip to the next interval after the last price update, and then skip this interval
        // to mock no price update
        shrine_utils::advance_interval();
        shrine_utils::advance_interval();

        let num_intervals_after_skip: u64 = 4;

        let yang_prices: Span<Wad> = shrine_utils::get_yang_prices(shrine, yangs);

        shrine_utils::advance_prices_and_set_multiplier(shrine, num_intervals_after_skip, yangs, yang_prices);

        // sanity check that skipped interval has no price values
        let (skipped_interval_price, _) = shrine.get_yang_price(yang1_addr, skipped_interval);
        let (skipped_interval_multiplier, _) = shrine.get_multiplier(skipped_interval);
        assert(skipped_interval_price == Zero::zero(), 'skipped price is not zero');
        assert(skipped_interval_multiplier == Zero::zero(), 'skipped multiplier is not zero');

        // Offset by 1 by excluding the skipped interval because `advance_prices_and_set_multiplier`
        // updates `start_interval`.
        let end_interval: u64 = start_interval + (num_intervals_before_skip + num_intervals_after_skip);
        assert(shrine_utils::current_interval() == end_interval, 'wrong end interval'); // sanity check

        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = shrine_utils::compound_for_single_yang(
            shrine_utils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            trove_health.debt,
        );
        let estimated_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(estimated_trove_health.debt == expected_debt, 'wrong compounded debt');

        let before_budget: SignedWad = shrine.get_budget();

        // Trigger charge and check interest is accrued
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.melt(common::TROVE1_OWNER_ADDR, trove_id, Zero::zero());
        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == expected_debt, 'debt not updated');

        let interest: Wad = estimated_trove_health.debt - start_debt;
        assert(shrine.get_budget() == before_budget + interest.into(), 'wrong budget');

        // Check events
        let events = spy.get_events().events;

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"));

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: expected_debt },
                ),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: interest }),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Test for `charge` with "missed" price and multiplier updates since before the start interval,
    // Start_interval does not have a price or multiplier update.
    // End interval does not have a price or multiplier update.
    //
    // T+LAST_UPDATED       T+START-------------T+END
    #[test]
    fn test_charge_scenario_2() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        // Advance one interval to avoid overwriting the last price
        shrine_utils::advance_interval();

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, start_debt);

        let before_budget: SignedWad = shrine.get_budget();

        let trove_id: u64 = common::TROVE_1;
        let yang1_addr = shrine_utils::YANG1_ADDR;

        // Advance timestamp by 2 intervals and set price for interval - `T+LAST_UPDATED`
        let time_to_skip: u64 = 2 * shrine_contract::TIME_INTERVAL;
        let last_updated_timestamp: u64 = get_block_timestamp() + time_to_skip;
        start_cheat_block_timestamp_global(last_updated_timestamp);
        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp to `T+START`, assuming that price has not been updated since `T+LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+START`.
        let intervals_after_last_update: u64 = 3;
        let time_to_skip: u64 = intervals_after_last_update * shrine_contract::TIME_INTERVAL;
        let start_timestamp: u64 = last_updated_timestamp + time_to_skip;
        let start_interval: u64 = shrine_utils::get_interval(start_timestamp);
        start_cheat_block_timestamp_global(start_timestamp);

        shrine.deposit(yang1_addr, trove_id, Zero::zero());

        // sanity check that some interest has accrued
        let trove_health: Health = shrine.get_trove_health(trove_id);
        let first_accrued_interest: Wad = trove_health.debt - start_debt;
        assert(first_accrued_interest.is_non_zero(), 'no interest accrued');

        // Advance timestamp to `T+END`, assuming price is still not updated since `T+LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+END`.
        let intervals_after_last_charge: u64 = 17;
        let time_to_skip: u64 = intervals_after_last_charge * shrine_contract::TIME_INTERVAL;
        let end_timestamp: u64 = start_timestamp + time_to_skip;

        // No need for offset here because we are incrementing the intervals directly
        // instead of via `advance_prices_and_set_multiplier`
        let end_interval: u64 = start_interval + intervals_after_last_charge;
        start_cheat_block_timestamp_global(end_timestamp);

        shrine.withdraw(yang1_addr, trove_id, Zero::zero());

        // As the price and multiplier have not been updated since `T+LAST_UPDATED`, we expect the
        // average values to be that at `T+LAST_UPDATED`.
        let expected_debt: Wad = shrine_utils::compound_for_single_yang(
            shrine_utils::YANG1_BASE_RATE.into(), start_multiplier, start_interval, end_interval, trove_health.debt,
        );

        let estimated_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(estimated_trove_health.debt == expected_debt, 'wrong compounded debt');

        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == expected_debt, 'debt not updated');

        let second_accrued_interest: Wad = estimated_trove_health.debt - trove_health.debt;
        assert(
            shrine.get_budget() == before_budget + first_accrued_interest.into() + second_accrued_interest.into(),
            'wrong budget',
        );

        // Check events
        let events = spy.get_events().events;

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"));

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: expected_debt },
                ),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: first_accrued_interest }),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: second_accrued_interest }),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Test for `charge` with "missed" price and multiplier updates after the start interval,
    // Start interval has a price and multiplier update.
    // End interval does not have a price or multiplier update.
    //
    // T+START/LAST_UPDATED-------------T+END
    #[test]
    fn test_charge_scenario_3() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        // Advance one interval to avoid overwriting the last price
        shrine_utils::advance_interval();

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, start_debt);

        let before_budget: SignedWad = shrine.get_budget();

        let trove_id: u64 = common::TROVE_1;
        let yang1_addr = shrine_utils::YANG1_ADDR;

        // Advance timestamp by 2 intervals and set price for interval - `T+LAST_UPDATED`
        let time_to_skip: u64 = 2 * shrine_contract::TIME_INTERVAL;
        let start_timestamp: u64 = get_block_timestamp() + time_to_skip;
        let start_interval: u64 = shrine_utils::get_interval(start_timestamp);
        start_cheat_block_timestamp_global(start_timestamp);
        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        shrine.deposit(yang1_addr, trove_id, Zero::zero());

        // sanity check that some interest has accrued
        let trove_health: Health = shrine.get_trove_health(trove_id);
        let first_accrued_interest: Wad = trove_health.debt - start_debt;
        assert(first_accrued_interest.is_non_zero(), 'no interest accrued');

        // Advance timestamp to `T+END`, to mock lack of price updates since `T+START/LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+END`.
        let intervals_after_last_update: u64 = 17;
        let time_to_skip: u64 = intervals_after_last_update * shrine_contract::TIME_INTERVAL;
        let end_timestamp: u64 = start_timestamp + time_to_skip;

        // No need for offset here because we are incrementing the intervals directly
        // instead of via `advance_prices_and_set_multiplier`
        let end_interval: u64 = start_interval + intervals_after_last_update;
        start_cheat_block_timestamp_global(end_timestamp);
        assert(shrine_utils::current_interval() == end_interval, 'wrong end interval'); // sanity check

        shrine.withdraw(yang1_addr, trove_id, Zero::zero());

        // As the price and multiplier have not been updated since `T+START/LAST_UPDATED`, we expect the
        // average values to be that at `T+START/LAST_UPDATED`.
        let expected_debt: Wad = shrine_utils::compound_for_single_yang(
            shrine_utils::YANG1_BASE_RATE.into(), start_multiplier, start_interval, end_interval, trove_health.debt,
        );

        let estimated_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(expected_debt == estimated_trove_health.debt, 'wrong compounded debt');

        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == expected_debt, 'debt not updated');

        let second_accrued_interest: Wad = estimated_trove_health.debt - trove_health.debt;
        assert(
            shrine.get_budget() == before_budget + first_accrued_interest.into() + second_accrued_interest.into(),
            'wrong budget',
        );

        // Check events
        let events = spy.get_events().events;

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"));

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: expected_debt },
                ),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: first_accrued_interest }),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: second_accrued_interest }),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    // Test for `charge` with "missed" price and multiplier updates from `intervals_after_last_update` intervals
    // after start interval.
    // Start interval has a price and multiplier update.
    // End interval does not have a price or multiplier update.
    //
    // T+START-------T+LAST_UPDATED------T+END
    #[test]
    fn test_charge_scenario_4() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, start_debt);

        let before_budget: SignedWad = shrine.get_budget();

        let trove_id: u64 = common::TROVE_1;
        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang1_addr = *yangs.at(0);

        let trove_health: Health = shrine.get_trove_health(trove_id);
        let start_interval: u64 = shrine_utils::current_interval();

        // Advance one interval to avoid overwriting the last price
        shrine_utils::advance_interval();

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED`
        let intervals_to_skip: u64 = 5;
        shrine_utils::advance_prices_and_set_multiplier(
            shrine, intervals_to_skip, yangs, shrine_utils::three_yang_start_prices(),
        );

        // Advance timestamp to `T+END`, to mock lack of price updates since `T+LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+END`.
        let intervals_after_last_update: u64 = 15;
        let time_to_skip: u64 = intervals_after_last_update * shrine_contract::TIME_INTERVAL;
        let end_timestamp: u64 = get_block_timestamp() + time_to_skip;

        let end_interval: u64 = start_interval + intervals_to_skip + intervals_after_last_update;
        start_cheat_block_timestamp_global(end_timestamp);
        assert(shrine_utils::current_interval() == end_interval, 'wrong end interval'); // sanity check

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.withdraw(yang1_addr, trove_id, Zero::zero());

        let expected_avg_multiplier: Ray = RAY_SCALE.into();
        let expected_debt: Wad = shrine_utils::compound_for_single_yang(
            shrine_utils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            trove_health.debt,
        );

        let trove_health: Health = shrine.get_trove_health(trove_id);
        assert(expected_debt == trove_health.debt, 'wrong compounded debt');

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.forge(common::TROVE1_OWNER_ADDR, trove_id, Zero::zero(), Zero::zero());
        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == expected_debt, 'debt not updated');

        let interest: Wad = trove_health.debt - start_debt;
        assert(shrine.get_budget() == before_budget + interest.into(), 'wrong budget');

        // Check events
        let events = spy.get_events().events;

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"));

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: expected_debt },
                ),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: interest }),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    // Test for `charge` with "missed" price and multiplier updates from `intervals_after_last_update`
    // intervals after start interval onwards.
    // Start interval does not have a price or multiplier update.
    // End interval does not have a price or multiplier update.
    //
    // T+LAST_UPDATED_BEFORE_START       T+START----T+LAST_UPDATED_AFTER_START---------T+END
    #[test]
    fn test_charge_scenario_5() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        let trove_id: u64 = common::TROVE_1;

        // Advance one interval to avoid overwriting the last price
        shrine_utils::advance_interval();

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang1_addr = *yangs.at(0);
        let yang_prices: Span<Wad> = shrine_utils::get_yang_prices(shrine, yangs);

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED_BEFORE_START`'
        let intervals_to_skip: u64 = 5;
        shrine_utils::advance_prices_and_set_multiplier(shrine, intervals_to_skip, yangs, yang_prices);
        let last_updated_interval_before_start: u64 = shrine_utils::current_interval();

        // Advance timestamp to `T+START`.
        let intervals_without_update_before_start: u64 = 10;
        let time_to_skip: u64 = intervals_without_update_before_start * shrine_contract::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        start_cheat_block_timestamp_global(timestamp);
        let start_interval: u64 = shrine_utils::current_interval();

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, start_debt);

        let before_budget: SignedWad = shrine.get_budget();

        let trove_health: Health = shrine.get_trove_health(trove_id);

        // Advance timestamp to `T+LAST_UPDATED_AFTER_START` and set the price
        let intervals_to_last_update_after_start: u64 = 5;
        let time_to_skip: u64 = intervals_to_last_update_after_start * shrine_contract::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        start_cheat_block_timestamp_global(timestamp);
        let last_updated_interval_after_start: u64 = shrine_utils::current_interval();

        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp to `T+END`.
        let intervals_from_last_update_to_end: u64 = 10;
        let time_to_skip: u64 = intervals_from_last_update_to_end * shrine_contract::TIME_INTERVAL;
        let end_timestamp: u64 = get_block_timestamp() + time_to_skip;
        start_cheat_block_timestamp_global(end_timestamp);
        let end_interval: u64 = start_interval
            + intervals_to_last_update_after_start
            + intervals_from_last_update_to_end;
        assert(shrine_utils::current_interval() == end_interval, 'wrong end interval'); // sanity check

        shrine.withdraw(yang1_addr, trove_id, Zero::zero());

        // First, we get the cumulative price values available to us
        // `T+LAST_UPDATED_AFTER_START` - `T+LAST_UPDATED_BEFORE_START`
        let (last_updated_price_before_start, last_updated_cumulative_price_before_start) = shrine
            .get_yang_price(yang1_addr, last_updated_interval_before_start);
        let (last_updated_price_after_start, last_updated_cumulative_price_after_start) = shrine
            .get_yang_price(yang1_addr, last_updated_interval_after_start);

        let mut cumulative_diff: Wad = last_updated_cumulative_price_after_start
            - last_updated_cumulative_price_before_start;

        // Next, we deduct the cumulative price from `T+LAST_UPDATED_BEFORE_START` to `T+START`
        let interval_diff: u128 = (start_interval - last_updated_interval_before_start).into();
        let amount: u128 = interval_diff * last_updated_price_before_start.into();
        cumulative_diff -= amount.into();

        // Finally, we add the cumulative price from `T+LAST_UPDATED_AFTER_START` to `T+END`.
        let interval_diff: u128 = (end_interval - last_updated_interval_after_start).into();
        let amount: u128 = interval_diff * last_updated_price_after_start.into();
        cumulative_diff += amount.into();

        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = shrine_utils::compound_for_single_yang(
            shrine_utils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            trove_health.debt,
        );

        let trove_health: Health = shrine.get_trove_health(trove_id);
        assert(expected_debt == trove_health.debt, 'wrong compounded debt');

        shrine.forge(common::TROVE1_OWNER_ADDR, trove_id, Zero::zero(), Zero::zero());
        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == expected_debt, 'debt not updated');

        let interest: Wad = trove_health.debt - start_debt;
        assert(shrine.get_budget() == before_budget + interest.into(), 'wrong budget');

        // Check events
        let events = spy.get_events().events;

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"));

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: expected_debt },
                ),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: interest }),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Test for `charge` with "missed" price and multiplier update at the start interval.
    // Start interval does not have a price or multiplier update.
    // End interval has both price and multiplier update.
    //
    // T+LAST_UPDATED_BEFORE_START       T+START-------------T+END (with price update)
    //
    #[test]
    fn setup_charge_scenario_6() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        let trove_id: u64 = common::TROVE_1;
        let yang1_addr = shrine_utils::YANG1_ADDR;

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED`
        let intervals_to_skip: u64 = 5;
        let time_to_skip: u64 = intervals_to_skip * shrine_contract::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        start_cheat_block_timestamp_global(timestamp);
        let last_updated_interval: u64 = shrine_utils::current_interval();

        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp by given intervals to `T+START` to mock missed updates.
        let intervals_after_last_update_to_start: u64 = 5;
        let time_to_skip: u64 = intervals_after_last_update_to_start * shrine_contract::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        start_cheat_block_timestamp_global(timestamp);
        let start_interval: u64 = shrine_utils::current_interval();

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, start_debt);

        let before_budget: SignedWad = shrine.get_budget();

        let trove_health: Health = shrine.get_trove_health(trove_id);

        // Advance timestamp by given intervals to `T+END`, to mock missed updates.
        let intervals_from_start_to_end: u64 = 13;
        let time_to_skip: u64 = intervals_from_start_to_end * shrine_contract::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        start_cheat_block_timestamp_global(timestamp);
        let end_interval: u64 = start_interval + intervals_from_start_to_end;
        assert(shrine_utils::current_interval() == end_interval, 'wrong end interval'); // sanity check

        let start_multiplier: Ray = RAY_SCALE.into();
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        shrine.withdraw(yang1_addr, trove_id, Zero::zero());

        // Manually calculate the average since start interval does not have a cumulative value
        let (_, end_cumulative_price) = shrine.get_yang_price(yang1_addr, end_interval);
        let (last_updated_price, last_updated_cumulative_price) = shrine
            .get_yang_price(yang1_addr, last_updated_interval);

        let mut cumulative_diff: Wad = end_cumulative_price - last_updated_cumulative_price;

        // Deduct the cumulative price from `T+LAST_UPDATED_BEFORE_START` to `T+START`
        let interval_diff: u128 = (start_interval - last_updated_interval).into();
        let amount: u128 = interval_diff * last_updated_price.into();
        cumulative_diff -= amount.into();

        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = shrine_utils::compound_for_single_yang(
            shrine_utils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            trove_health.debt,
        );

        let trove_health: Health = shrine.get_trove_health(trove_id);
        assert(expected_debt == trove_health.debt, 'wrong compounded debt');

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.deposit(yang1_addr, trove_id, Zero::zero());
        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == expected_debt, 'debt not updated');

        let interest: Wad = trove_health.debt - start_debt;
        assert(shrine.get_budget() == before_budget + interest.into(), 'wrong budget');

        // Check events
        let events = spy.get_events().events;

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"));

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: expected_debt },
                ),
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: interest }),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Tests for `charge` with three base rate updates and
    // two yangs deposited into the trove
    #[test]
    fn test_charge_scenario_7() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        shrine_utils::advance_prices_and_set_multiplier(
            shrine, shrine_utils::FEED_LEN, yangs, shrine_utils::three_yang_start_prices(),
        );

        let trove_id: u64 = common::TROVE_1;
        let trove1_owner: ContractAddress = common::TROVE1_OWNER_ADDR;
        let yang1_addr: ContractAddress = *yangs.at(0);
        let yang2_addr: ContractAddress = *yangs.at(1);

        let mut expected_events: Array<(ContractAddress, shrine_contract::Event)> = ArrayTrait::new();

        // Setup base rates for calling `Shrine.update_rates`.
        // The base rates are set in the following format:
        //
        // O X O
        // X O X
        //
        // where X is the constant `USE_PREV_ERA_BASE_RATE` value that sets the base rate to the previous value.
        //
        // Note that the arrays are created as a list of yang base rate updates

        // `yang_base_rates_history_to_update` is used to perform the rate updates, while
        // `yang_base_rates_history_to_compound` is used to perform calculation of the compounded interest
        // The main difference between the two arrays are:
        // (1) When setting a base rate to its previous value, the value to update in Shrine is `USE_PREV_ERA_BASE_RATE`
        //     which is equivalent to `RAY_SCALE + 1`, whereas the actual value that is used to calculate
        //     compound interest is the previous base rate.
        // (2) `yang_base_rates_history_to_compound` has an extra item for the initial base rates at the time
        //     the trove was last charged, in order to calculate the compound interest from this interval until
        //     the first rate update interval.

        // Add initial base rates for rates history to calculate compound interest
        let first_rate_history_to_compound: Span<Ray> = array![
            shrine_utils::YANG1_BASE_RATE.into(),
            shrine_utils::YANG2_BASE_RATE.into(),
            shrine_utils::YANG3_BASE_RATE.into(),
        ]
            .span();

        // For first rate update, yang 1 is updated and yang 2 uses previous base rate
        let yang1_first_rate_update: Ray = 25000000000000000000000000_u128.into(); // 2.5% (Ray)
        let first_rate_history_to_update: Span<Ray> = array![
            yang1_first_rate_update, (RAY_SCALE + 1).into(), (RAY_SCALE + 1).into(),
        ]
            .span();
        let second_rate_history_to_compound: Span<Ray> = array![
            yang1_first_rate_update, shrine_utils::YANG2_BASE_RATE.into(), shrine_utils::YANG3_BASE_RATE.into(),
        ]
            .span();

        // For second rate update, yang 1 uses previous base rate and yang 2 is updated
        let yang2_second_rate_update: Ray = 43500000000000000000000000_u128.into(); // 4.35% (Ray)
        let second_rate_history_to_update: Span<Ray> = array![
            (RAY_SCALE + 1).into(), yang2_second_rate_update, (RAY_SCALE + 1).into(),
        ]
            .span();
        let third_rate_history_to_compound: Span<Ray> = array![
            yang1_first_rate_update, yang2_second_rate_update, shrine_utils::YANG3_BASE_RATE.into(),
        ]
            .span();

        // For third rate update, yang 1 is updated and yang 2 uses previous base rate
        let yang1_third_rate_update: Ray = 27500000000000000000000000_u128.into(); // 2.75% (Ray)
        let third_rate_history_to_update: Span<Ray> = array![
            yang1_third_rate_update, (RAY_SCALE + 1).into(), (RAY_SCALE + 1).into(),
        ]
            .span();
        let fourth_rate_history_to_compound: Span<Ray> = array![
            yang1_third_rate_update, yang2_second_rate_update, shrine_utils::YANG3_BASE_RATE.into(),
        ]
            .span();

        let yang_base_rates_history_to_update: Span<Span<Ray>> = array![
            first_rate_history_to_update, second_rate_history_to_update, third_rate_history_to_update,
        ]
            .span();
        let yang_base_rates_history_to_compound: Span<Span<Ray>> = array![
            first_rate_history_to_compound,
            second_rate_history_to_compound,
            third_rate_history_to_compound,
            fourth_rate_history_to_compound,
        ]
            .span();

        // The number of base rate updates
        let num_base_rate_updates: u64 = 3;

        // The number of intervals actually between two base rate updates (not including the intervals on which the
        // updates occur) will be this number minus one
        let BASE_RATE_UPDATE_SPACING: u64 = 5;

        // The number of time periods where the base rates remain constant.
        // We add one because there is also the time period between
        // the base rates set in `add_yang` and the first base rate update
        let num_eras: u64 = num_base_rate_updates + 1;
        let start_interval: u64 = shrine_utils::current_interval();
        let end_interval: u64 = start_interval + BASE_RATE_UPDATE_SPACING * num_eras;

        // Generating the list of intervals at which the base rates will be updated (needed for `compound`)
        // Adding zero as the first interval since that's when the initial base rates were first added in `add_yang`
        let mut rate_update_intervals: Array<u64> = array![0];
        let mut i = 0;
        while i != num_base_rate_updates {
            let rate_update_interval: u64 = start_interval + (i + 1) * BASE_RATE_UPDATE_SPACING;
            rate_update_intervals.append(rate_update_interval);
            i += 1;
        }

        let mut avg_multipliers: Array<Ray> = ArrayTrait::new();

        let mut avg_yang_prices_by_era: Array<Span<Wad>> = ArrayTrait::new();

        // Deposit yangs into trove and forge debt
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        let yang1_deposit_amt: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into();
        shrine.deposit(yang1_addr, trove_id, yang1_deposit_amt);
        let yang2_deposit_amt: Wad = shrine_utils::TROVE1_YANG2_DEPOSIT.into();
        shrine.deposit(yang2_addr, trove_id, yang2_deposit_amt);
        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine.forge(trove1_owner, trove_id, start_debt, Zero::zero());

        let before_budget: SignedWad = shrine.get_budget();

        let yangs_deposited: Span<Wad> = array![yang1_deposit_amt, yang2_deposit_amt, Zero::zero()].span();

        let mut yang_base_rates_history_to_update_copy: Span<Span<Ray>> = yang_base_rates_history_to_update;
        let mut yang_base_rates_history_to_compound_copy: Span<Span<Ray>> = yang_base_rates_history_to_compound;

        let mut i = 0;
        let mut era_start_interval: u64 = start_interval;

        // We perform an extra iteration here to test the last rate era by advancing the prices.
        // Otherwise, if the last interval is also the start of a new rate era, we would not be able to test it.
        let loop_end = num_base_rate_updates + 1;
        while i != loop_end {
            // Fetch the latest yang prices
            let yang_prices: Span<Wad> = shrine_utils::get_yang_prices(shrine, yangs);

            // First, we advance an interval so the last price is not overwritten.
            // Next, Advance the prices by the number of intervals between each base rate update
            shrine_utils::advance_interval();
            shrine_utils::advance_prices_and_set_multiplier(shrine, BASE_RATE_UPDATE_SPACING, yangs, yang_prices);

            let era_end_interval: u64 = era_start_interval + BASE_RATE_UPDATE_SPACING;

            // Calculate average price of yangs over the era for calculating the compounded interest
            let mut avg_yang_prices_for_era: Array<Wad> = ArrayTrait::new();
            for yang in yangs {
                let yang_avg_price: Wad = shrine_utils::get_avg_yang_price(
                    shrine, *yang, era_start_interval, era_end_interval,
                );
                avg_yang_prices_for_era.append(yang_avg_price);
            }

            avg_yang_prices_by_era.append(avg_yang_prices_for_era.span());

            // Append multiplier
            avg_multipliers.append(RAY_SCALE.into());

            if i < num_base_rate_updates {
                // Update base rates
                let mut yang_base_rates_to_update: Span<Ray> = *yang_base_rates_history_to_update_copy
                    .pop_front()
                    .unwrap();

                start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
                shrine.update_rates(yangs, yang_base_rates_to_update);
                let expected_era: u64 = i + 2;
                assert(shrine.get_current_rate_era() == expected_era, 'wrong rate era');

                // Check that base rates are updated correctly
                // Offset by 1 to discount the initial
                let era: u32 = i.try_into().unwrap() + 1;
                let mut expected_base_rates: Span<Ray> = *yang_base_rates_history_to_compound_copy.at(era);
                for yang in yangs {
                    let rate: Ray = shrine.get_yang_rate(*yang, expected_era);
                    let expected_rate: Ray = *expected_base_rates.pop_front().unwrap();
                    assert(rate == expected_rate, 'wrong base rate');
                }

                expected_events
                    .append(
                        (
                            shrine.contract_address,
                            shrine_contract::Event::YangRatesUpdated(
                                shrine_contract::YangRatesUpdated {
                                    rate_era: expected_era,
                                    current_interval: era_end_interval,
                                    yangs: yangs,
                                    new_rates: yang_base_rates_to_update,
                                },
                            ),
                        ),
                    );
            }

            // Increment counter
            i += 1;

            // Update start interval for next era
            era_start_interval = era_end_interval;
        }

        let trove_health: Health = shrine.get_trove_health(trove_id);
        let expected_debt: Wad = shrine_utils::compound(
            yang_base_rates_history_to_compound,
            rate_update_intervals.span(),
            yangs_deposited,
            avg_yang_prices_by_era.span(),
            avg_multipliers.span(),
            start_interval,
            end_interval,
            start_debt,
        );

        assert(trove_health.debt == expected_debt, 'wrong compounded debt');

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.withdraw(yang1_addr, trove_id, Zero::zero());
        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == expected_debt, 'debt not updated');

        let interest: Wad = trove_health.debt - start_debt;
        assert(shrine.get_budget() == before_budget + interest.into(), 'wrong budget');

        // Check events
        let events = spy.get_events().events;

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"));

        expected_events
            .append(
                (
                    shrine.contract_address,
                    shrine_contract::Event::TotalTrovesDebtUpdated(
                        shrine_contract::TotalTrovesDebtUpdated { total: expected_debt },
                    ),
                ),
            );
        expected_events
            .append(
                (
                    shrine.contract_address,
                    shrine_contract::Event::Charge(shrine_contract::Charge { trove_id, amount: interest }),
                ),
            );

        spy.assert_emitted(@expected_events);
    }

    // Check that a delisted yang is not taken into account for interest
    #[test]
    fn test_compound_and_charge_delisted_yang() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        // Advance one interval to avoid overwriting the last price
        shrine_utils::advance_interval();

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang_to_delist: ContractAddress = *yangs[0];

        let start_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, start_debt);

        let trove1_owner = common::TROVE1_OWNER_ADDR;
        let trove_id: u64 = common::TROVE_1;

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.suspend_yang(yang_to_delist);

        shrine_utils::advance_prices_periodically(shrine, yangs, shrine_contract::SUSPENSION_GRACE_PERIOD);

        assert(shrine.get_yang_suspension_status(yang_to_delist) == YangSuspensionStatus::Permanent, 'not delisted');

        // Trigger charge and check no interest is accrued
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.melt(trove1_owner, trove_id, Zero::zero());

        let after_trove_health: Health = shrine.get_trove_health(trove_id);
        assert_eq!(after_trove_health.debt, start_debt, "interest accrued");

        // Ensure iteration limit is not a problem
        shrine_utils::advance_prices_periodically(shrine, yangs, shrine_contract::SUSPENSION_GRACE_PERIOD);

        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.melt(trove1_owner, trove_id, start_debt);
    }

    //
    // Tests - Reducing debt surplus
    //

    #[test]
    fn test_adjust_budget_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events();

        let surplus: Wad = (500 * WAD_ONE).into();
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.adjust_budget(surplus.into());
        assert(shrine.get_budget() == surplus.into(), 'wrong budget #1');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::BudgetAdjusted(shrine_contract::BudgetAdjusted { amount: surplus.into() }),
            ),
        ];
        spy.assert_emitted(@expected_events);

        let deficit = -(surplus.into());
        shrine.adjust_budget(deficit);

        assert(shrine.get_budget().is_zero(), 'wrong budget #2');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::BudgetAdjusted(shrine_contract::BudgetAdjusted { amount: deficit }),
            ),
        ];

        spy.assert_emitted(@expected_events);

        // Adjust budget into a deficit
        let deficit = -((1234 * WAD_ONE).into());
        shrine.adjust_budget(deficit);

        assert(shrine.get_budget() == deficit, 'wrong budget #3');

        // Check events
        let events = spy.get_events().events;

        // Since protocol owned troves' debt is zero, the `ProtocolOwnedTrovesDebtUpdated` event
        // should not be emitted
        common::assert_event_not_emitted_by_name(events.span(), selector!("ProtocolOwnedTrovesDebtUpdated"));

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::BudgetAdjusted(shrine_contract::BudgetAdjusted { amount: deficit }),
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_adjust_budget_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_cheat_caller_address(shrine.contract_address, common::BAD_GUY);

        let surplus: SignedWad = (500 * WAD_ONE).into();
        shrine.adjust_budget(surplus);
    }
}
