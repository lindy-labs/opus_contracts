#[cfg(test)]
mod TestShrineCompound {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{ContractAddress, get_block_timestamp};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::shrine::Shrine;

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::exp::exp;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_SCALE, Wad, WadZeroable};

    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::test_utils;

    //
    // Tests - Trove estimate and charge
    // 

    // Test for `charge` with all intervals between start and end inclusive updated.
    //
    // T+START--------------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_compound_and_charge_scenario_1() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        // Advance one interval to avoid overwriting the last price
        ShrineUtils::advance_interval();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let start_interval: u64 = ShrineUtils::current_interval();

        let yang1_addr = ShrineUtils::yang1_addr();
        // Note that this is the price at `start_interval - 1` because we advanced one interval
        // after the last price update
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        // technically not needed since we only use yang1 here but we do so to simplify the helper
        let (yang2_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang2_addr());
        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);

        ShrineUtils::advance_prices_and_set_multiplier(
            shrine, ShrineUtils::FEED_LEN, yang1_price, yang2_price
        );

        // Offset by 1 because `advance_prices_and_set_multiplier` updates `start_interval`.
        let end_interval: u64 = start_interval + ShrineUtils::FEED_LEN - 1;
        // commented out because of gas usage error
        assert(ShrineUtils::current_interval() == end_interval, 'wrong end interval');  // sanity check

        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, estimated_debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(estimated_debt == expected_debt, 'wrong compounded debt');

        // Trigger charge and check interest is accrued
        set_contract_address(ShrineUtils::admin());
        shrine.melt(test_utils::trove1_owner_addr(), test_utils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    // Slight variation of `test_charge_scenario_1` where there is an interval between start and end
    // that does not have a price update.
    //
    // `X` in the diagram below indicates a missed interval.
    // 
    // T+START------X-------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_1b() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        // Advance one interval to avoid overwriting the last price
        ShrineUtils::advance_interval();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        ShrineUtils::trove1_forge(shrine, ShrineUtils::TROVE1_FORGE_AMT.into());

        let start_interval: u64 = ShrineUtils::current_interval();

        let yang1_addr = ShrineUtils::yang1_addr();
        let yang2_addr = ShrineUtils::yang2_addr();
        // Note that this is the price at `start_interval - 1` because we advanced one interval
        // after the last price update
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        // technically not needed since we only use yang1 here but we do so to simplify the helper
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);

        let num_intervals_before_skip: u64 = 5;
        ShrineUtils::advance_prices_and_set_multiplier(
            shrine, num_intervals_before_skip, yang1_price, yang2_price
        );

        let skipped_interval: u64 = start_interval + num_intervals_before_skip;

        // Skip to the next interval after the last price update, and then skip this interval
        // to mock no price update
        ShrineUtils::advance_interval();
        ShrineUtils::advance_interval();

        let num_intervals_after_skip: u64 = 4;

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);

        ShrineUtils::advance_prices_and_set_multiplier(
            shrine, num_intervals_after_skip, yang1_price, yang2_price
        );

        // sanity check that skipped interval has no price values
        let (skipped_interval_price, _) = shrine.get_yang_price(yang1_addr, skipped_interval);
        let (skipped_interval_multiplier, _) = shrine.get_multiplier(skipped_interval);
        assert(skipped_interval_price == WadZeroable::zero(), 'skipped price is not zero');
        assert(
            skipped_interval_multiplier == RayZeroable::zero(), 'skipped multiplier is not zero'
        );

        // Offset by 1 by excluding the skipped interval because `advance_prices_and_set_multiplier` 
        // updates `start_interval`.
        let end_interval: u64 = start_interval
            + (num_intervals_before_skip + num_intervals_after_skip);
        // commented out because of gas usage error
        assert(ShrineUtils::current_interval() == end_interval, 'wrong end interval');  // sanity check

        let expected_avg_price: Wad = ShrineUtils::get_avg_yang_price(
            shrine, yang1_addr, start_interval, end_interval
        );
        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );
        let (_, _, _, estimated_debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(estimated_debt == expected_debt, 'wrong compounded debt');

        // Trigger charge and check interest is accrued
        set_contract_address(ShrineUtils::admin());
        shrine.melt(test_utils::trove1_owner_addr(), test_utils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier updates since before the start interval,
    // Start_interval does not have a price or multiplier update.
    // End interval does not have a price or multiplier update.
    //
    // T+LAST_UPDATED       T+START-------------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_2() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        // Advance one interval to avoid overwriting the last price
        ShrineUtils::advance_interval();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let yang1_addr = ShrineUtils::yang1_addr();

        // Advance timestamp by 2 intervals and set price for interval - `T+LAST_UPDATED`
        let time_to_skip: u64 = 2 * Shrine::TIME_INTERVAL;
        let last_updated_timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(last_updated_timestamp);
        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        set_contract_address(ShrineUtils::admin());
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp to `T+START`, assuming that price has not been updated since `T+LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+START`.
        let intervals_after_last_update: u64 = 3;
        let time_to_skip: u64 = intervals_after_last_update * Shrine::TIME_INTERVAL;
        let start_timestamp: u64 = last_updated_timestamp + time_to_skip;
        let start_interval: u64 = ShrineUtils::get_interval(start_timestamp);
        set_block_timestamp(start_timestamp);

        shrine.deposit(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());

        // sanity check that some interest has accrued
        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(debt > forge_amt, '!(starting debt > forged)');

        // Advance timestamp to `T+END`, assuming price is still not updated since `T+LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+END`.
        let intervals_after_last_charge: u64 = 17;
        let time_to_skip: u64 = intervals_after_last_charge * Shrine::TIME_INTERVAL;
        let end_timestamp: u64 = start_timestamp + time_to_skip;

        // No need for offset here because we are incrementing the intervals directly
        // instead of via `advance_prices_and_set_multiplier`
        let end_interval: u64 = start_interval + intervals_after_last_charge;
        set_block_timestamp(end_timestamp);

        shrine.withdraw(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());

        // As the price and multiplier have not been updated since `T+LAST_UPDATED`, we expect the 
        // average values to be that at `T+LAST_UPDATED`.
        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            start_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        shrine.melt(test_utils::trove1_owner_addr(), test_utils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier updates after the start interval,
    // Start interval has a price and multiplier update.
    // End interval does not have a price or multiplier update.
    // 
    // T+START/LAST_UPDATED-------------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_3() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        // Advance one interval to avoid overwriting the last price
        ShrineUtils::advance_interval();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let yang1_addr = ShrineUtils::yang1_addr();

        // Advance timestamp by 2 intervals and set price for interval - `T+LAST_UPDATED`
        let time_to_skip: u64 = 2 * Shrine::TIME_INTERVAL;
        let start_timestamp: u64 = get_block_timestamp() + time_to_skip;
        let start_interval: u64 = ShrineUtils::get_interval(start_timestamp);
        set_block_timestamp(start_timestamp);
        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        set_contract_address(ShrineUtils::admin());
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        shrine.deposit(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());

        // sanity check that some interest has accrued
        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(debt > forge_amt, '!(starting debt > forged)');

        // Advance timestamp to `T+END`, to mock lack of price updates since `T+START/LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+END`.
        let intervals_after_last_update: u64 = 17;
        let time_to_skip: u64 = intervals_after_last_update * Shrine::TIME_INTERVAL;
        let end_timestamp: u64 = start_timestamp + time_to_skip;

        // No need for offset here because we are incrementing the intervals directly
        // instead of via `advance_prices_and_set_multiplier`
        let end_interval: u64 = start_interval + intervals_after_last_update;
        set_block_timestamp(end_timestamp);
        assert(ShrineUtils::current_interval() == end_interval, 'wrong end interval');  // sanity check

        shrine.withdraw(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());

        // As the price and multiplier have not been updated since `T+START/LAST_UPDATED`, we expect the 
        // average values to be that at `T+START/LAST_UPDATED`.
        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            start_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        shrine.forge(test_utils::trove1_owner_addr(), test_utils::TROVE_1, WadZeroable::zero(), 0_u128.into());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier updates from `intervals_after_last_update` intervals
    // after start interval.
    // Start interval has a price and multiplier update.
    // End interval does not have a price or multiplier update.
    //
    // T+START-------T+LAST_UPDATED------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_4() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let yang1_addr = ShrineUtils::yang1_addr();

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);
        let start_interval: u64 = ShrineUtils::current_interval();

        // Advance one interval to avoid overwriting the last price
        ShrineUtils::advance_interval();

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED`
        let intervals_to_skip: u64 = 5;
        ShrineUtils::advance_prices_and_set_multiplier(
            shrine,
            intervals_to_skip,
            ShrineUtils::YANG1_START_PRICE.into(),
            ShrineUtils::YANG2_START_PRICE.into()
        );
        // Offset by 1 because of a single call to `advance_prices_and_set_multiplier`
        let last_updated_interval: u64 = start_interval + intervals_to_skip - 1;

        // Advance timestamp to `T+END`, to mock lack of price updates since `T+LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+END`.
        let intervals_after_last_update: u64 = 15;
        let time_to_skip: u64 = intervals_after_last_update * Shrine::TIME_INTERVAL;
        let end_timestamp: u64 = get_block_timestamp() + time_to_skip;

        let end_interval: u64 = start_interval + intervals_to_skip + intervals_after_last_update;
        set_block_timestamp(end_timestamp);
        assert(ShrineUtils::current_interval() == end_interval, 'wrong end interval');  // sanity check

        set_contract_address(ShrineUtils::admin());
        shrine.withdraw(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());

        // Manually calculate the average since end interval does not have a cumulative value
        let (_, start_cumulative_price) = shrine.get_yang_price(yang1_addr, start_interval);
        let (last_updated_price, last_updated_cumulative_price) = shrine
            .get_yang_price(yang1_addr, last_updated_interval);
        let intervals_after_last_update_temp: u128 = intervals_after_last_update.into();
        let cumulative_diff: Wad = (last_updated_cumulative_price - start_cumulative_price)
            + (intervals_after_last_update_temp * last_updated_price.val).into();

        let expected_avg_price: Wad = (cumulative_diff.val / (end_interval - start_interval).into())
            .into();
        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        set_contract_address(ShrineUtils::admin());
        shrine.forge(test_utils::trove1_owner_addr(), test_utils::TROVE_1, WadZeroable::zero(), 0_u128.into());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier updates from `intervals_after_last_update`
    // intervals after start interval onwards.
    // Start interval does not have a price or multiplier update.
    // End interval does not have a price or multiplier update.
    //
    // T+LAST_UPDATED_BEFORE_START       T+START----T+LAST_UPDATED_AFTER_START---------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_5() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let yang1_addr = ShrineUtils::yang1_addr();

        // Advance one interval to avoid overwriting the last price
        ShrineUtils::advance_interval();

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let (yang2_price, _, _) = shrine.get_current_yang_price(ShrineUtils::yang2_addr());

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED_BEFORE_START`'
        let intervals_to_skip: u64 = 5;
        ShrineUtils::advance_prices_and_set_multiplier(
            shrine,
            intervals_to_skip,
            yang1_price,
            yang2_price
        );
        let last_updated_interval_before_start: u64 = ShrineUtils::current_interval();

        // Advance timestamp to `T+START`.
        let intervals_without_update_before_start: u64 = 10;
        let time_to_skip: u64 = intervals_without_update_before_start * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let start_interval: u64 = ShrineUtils::current_interval();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);

        // Advance timestamp to `T+LAST_UPDATED_AFTER_START` and set the price
        let intervals_to_last_update_after_start: u64 = 5;
        let time_to_skip: u64 = intervals_to_last_update_after_start * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let last_updated_interval_after_start: u64 = ShrineUtils::current_interval();

        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        set_contract_address(ShrineUtils::admin());
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp to `T+END`.
        let intervals_from_last_update_to_end: u64 = 10;
        let time_to_skip: u64 = intervals_from_last_update_to_end * Shrine::TIME_INTERVAL;
        let end_timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(end_timestamp);
        let end_interval: u64 = start_interval + intervals_to_last_update_after_start + intervals_from_last_update_to_end;
        assert(ShrineUtils::current_interval() == end_interval, 'wrong end interval');  // sanity check

        shrine.withdraw(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());

        // Manually calculate the average since end interval does not have a cumulative value
        let (_, start_cumulative_price) = shrine.get_yang_price(yang1_addr, start_interval);

        // First, we get the cumulative price values available to us 
        // `T+LAST_UPDATED_AFTER_START` - `T+LAST_UPDATED_BEFORE_START`
        let (last_updated_price_before_start, last_updated_cumulative_price_before_start) = shrine
            .get_yang_price(yang1_addr, last_updated_interval_before_start);
        let (last_updated_price_after_start, last_updated_cumulative_price_after_start) = shrine
            .get_yang_price(yang1_addr, last_updated_interval_after_start);

        let mut cumulative_diff: Wad = last_updated_cumulative_price_after_start
            - last_updated_cumulative_price_before_start;

        // Next, we deduct the cumulative price from `T+LAST_UPDATED_BEFORE_START` to `T+START`
        cumulative_diff -=
            ((start_interval - last_updated_interval_before_start).into()
                * last_updated_price_before_start.val)
            .into();

        // Finally, we add the cumulative price from `T+LAST_UPDATED_AFTER_START` to `T+END`.
        cumulative_diff +=
            ((end_interval - last_updated_interval_after_start).into()
                * last_updated_price_after_start.val)
            .into();

        let expected_avg_price: Wad = (cumulative_diff.val / (end_interval - start_interval).into())
            .into();
        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        shrine.forge(test_utils::trove1_owner_addr(), test_utils::TROVE_1, WadZeroable::zero(), 0_u128.into());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier update at the start interval.
    // Start interval does not have a price or multiplier update.
    // End interval has both price and multiplier update.
    // 
    // T+LAST_UPDATED_BEFORE_START       T+START-------------T+END (with price update)
    //
    #[test]
    #[available_gas(20000000000)]
    fn setup_charge_scenario_6() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let yang1_addr = ShrineUtils::yang1_addr();

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED`
        let intervals_to_skip: u64 = 5;
        let time_to_skip: u64 = intervals_to_skip * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let last_updated_interval: u64 = ShrineUtils::current_interval();

        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        set_contract_address(ShrineUtils::admin());
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp by given intervals to `T+START` to mock missed updates.
        let intervals_after_last_update_to_start: u64 = 5;
        let time_to_skip: u64 = intervals_after_last_update_to_start * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let start_interval: u64 = ShrineUtils::current_interval();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);

        // Advance timestamp by given intervals to `T+END`, to mock missed updates.
        let intervals_from_start_to_end: u64 = 13;
        let time_to_skip: u64 = intervals_from_start_to_end * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let end_interval: u64 = start_interval + intervals_from_start_to_end;
        assert(ShrineUtils::current_interval() == end_interval, 'wrong end interval');  // sanity check

        let end_price: Wad = 2333000000000000000000_u128.into(); // 2_333 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        set_contract_address(ShrineUtils::admin());
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        shrine.withdraw(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());

        // Manually calculate the average since start interval does not have a cumulative value
        let (_, end_cumulative_price) = shrine.get_yang_price(yang1_addr, end_interval);
        let (last_updated_price, last_updated_cumulative_price) = shrine
            .get_yang_price(yang1_addr, last_updated_interval);

        let mut cumulative_diff: Wad = end_cumulative_price - last_updated_cumulative_price;

        // Deduct the cumulative price from `T+LAST_UPDATED_BEFORE_START` to `T+START`
        cumulative_diff -=
            ((start_interval - last_updated_interval).into() * last_updated_price.val)
            .into();

        let expected_avg_price: Wad = (cumulative_diff.val / (end_interval - start_interval).into())
            .into();
        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        set_contract_address(ShrineUtils::admin());
        shrine.deposit(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    // Tests for `charge` with three base rate updates and 
    // two yangs deposited into the trove
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_7() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::advance_prices_and_set_multiplier(
            shrine,
            ShrineUtils::FEED_LEN,
            ShrineUtils::YANG1_START_PRICE.into(),
            ShrineUtils::YANG2_START_PRICE.into()
        );

        let trove1_owner: ContractAddress = test_utils::trove1_owner_addr();
        let yang1_addr: ContractAddress = ShrineUtils::yang1_addr();
        let yang2_addr: ContractAddress = ShrineUtils::yang2_addr();

        let mut yang_addrs: Array<ContractAddress> = Default::default();
        yang_addrs.append(yang1_addr);
        yang_addrs.append(yang2_addr);

        // Setup base rates for calling `Shrine.update_rates`.
        // The base rates are set in the following format:
        //
        // O X O
        // X O X
        //
        // where X is the constant `USE_PREV_BASE_RATE` value that sets the base rate to the previous value.
        //
        // Note that the arrays are created as a list of yang base rate updates

        // `yang_base_rates_history_to_update` is used to perform the rate updates, while 
        // `yang_base_rates_history_to_compound` is used to perform calculation of the compounded interest
        // The main difference between the two arrays are:
        // (1) When setting a base rate to its previous value, the value to update in Shrine is `USE_PREV_BASE_RATE`
        //     which is equivalent to `RAY_SCALE + 1`, whereas the actual value that is used to calculate
        //     compound interest is the previous base rate.
        // (2) `yang_base_rates_history_to_compound` has an extra item for the initial base rates at the time
        //     the trove was last charged, in order to calculate the compound interest from this interval until
        //     the first rate update interval.
        let mut yang_base_rates_history_to_update: Array<Span<Ray>> = Default::default();
        let mut yang_base_rates_history_to_compound: Array<Span<Ray>> = Default::default();

        // Add initial base rates for rates history to calculate compound interest
        let mut first_rate_history_to_compound: Array<Ray> = Default::default();
        first_rate_history_to_compound.append(ShrineUtils::YANG1_BASE_RATE.into());
        first_rate_history_to_compound.append(ShrineUtils::YANG2_BASE_RATE.into());
        yang_base_rates_history_to_compound.append(first_rate_history_to_compound.span());

        let mut first_rate_history_to_update: Array<Ray> = Default::default();
        let mut second_rate_history_to_compound: Array<Ray> = Default::default();

        // For first rate update, yang 1 is updated and yang 2 uses previous base rate
        let yang1_first_rate_update: Ray = 25000000000000000000000000_u128.into(); // 2.5% (Ray)
        first_rate_history_to_update.append(yang1_first_rate_update);
        second_rate_history_to_compound.append(yang1_first_rate_update);

        first_rate_history_to_update.append((RAY_SCALE + 1).into());
        second_rate_history_to_compound.append(ShrineUtils::YANG2_BASE_RATE.into());

        yang_base_rates_history_to_update.append(first_rate_history_to_update.span());
        yang_base_rates_history_to_compound.append(second_rate_history_to_compound.span());

        // For second rate update, yang 1 uses previous base rate and yang 2 is updated
        let mut second_rate_history_to_update: Array<Ray> = Default::default();
        let mut third_rate_history_to_compound: Array<Ray> = Default::default();

        second_rate_history_to_update.append((RAY_SCALE + 1).into());
        third_rate_history_to_compound.append(yang1_first_rate_update);

        let yang2_second_rate_update: Ray = 43500000000000000000000000_u128.into(); // 4.35% (Ray)
        second_rate_history_to_update.append(yang2_second_rate_update);
        third_rate_history_to_compound.append(yang2_second_rate_update);

        yang_base_rates_history_to_update.append(second_rate_history_to_update.span());
        yang_base_rates_history_to_compound.append(third_rate_history_to_compound.span());

        // For third rate update, yang 1 is updated and yang 2 uses previous base rate
        let mut third_rate_history_to_update: Array<Ray> = Default::default();
        let mut fourth_rate_history_to_compound: Array<Ray> = Default::default();

        let yang1_third_rate_update: Ray = 27500000000000000000000000_u128.into(); // 2.75% (Ray)
        third_rate_history_to_update.append(yang1_third_rate_update);
        fourth_rate_history_to_compound.append(yang1_third_rate_update);

        third_rate_history_to_update.append((RAY_SCALE + 1).into());
        fourth_rate_history_to_compound.append(yang2_second_rate_update);

        yang_base_rates_history_to_update.append(third_rate_history_to_update.span());
        yang_base_rates_history_to_compound.append(fourth_rate_history_to_compound.span());

        // The number of base rate updates
        let num_base_rate_updates: u64 = 3;

        // The number of intervals actually between two base rate updates (not including the intervals on which the updates occur) will be this number minus one
        let BASE_RATE_UPDATE_SPACING: u64 = 5;

        // The number of time periods where the base rates remain constant.
        // We add one because there is also the time period between
        // the base rates set in `add_yang` and the first base rate update
        let num_eras: u64 = num_base_rate_updates + 1;
        let current_timestamp: u64 = get_block_timestamp();
        let start_interval: u64 = ShrineUtils::current_interval();
        let end_interval: u64 = start_interval + BASE_RATE_UPDATE_SPACING * num_eras;
        let charging_period: u64 = end_interval - start_interval;

        // Generating the list of intervals at which the base rates will be updated (needed for `compound`)
        // Adding zero as the first interval since that's when the initial base rates were first added in `add_yang`
        let mut rate_update_intervals: Array<u64> = Default::default();
        rate_update_intervals.append(0);
        let mut i = 0;
        loop {
            if i == num_base_rate_updates {
                break ();
            }
            let rate_update_interval: u64 = start_interval + (i + 1) * BASE_RATE_UPDATE_SPACING;
            rate_update_intervals.append(rate_update_interval);
            i += 1;
        };

        let mut avg_multipliers: Array<Ray> = Default::default();

        let mut avg_yang_prices_by_era: Array<Span<Wad>> = Default::default();

        // Deposit yangs into trove and forge debt
        set_contract_address(ShrineUtils::admin());
        let yang1_deposit_amt: Wad = ShrineUtils::TROVE1_YANG1_DEPOSIT.into();
        shrine.deposit(yang1_addr, test_utils::TROVE_1, yang1_deposit_amt);
        let yang2_deposit_amt: Wad = ShrineUtils::TROVE1_YANG2_DEPOSIT.into();
        shrine.deposit(yang2_addr, test_utils::TROVE_1, yang2_deposit_amt);
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        shrine.forge(trove1_owner, test_utils::TROVE_1, forge_amt, 0_u128.into());

        let mut yangs_deposited: Array<Wad> = Default::default();
        yangs_deposited.append(yang1_deposit_amt);
        yangs_deposited.append(yang2_deposit_amt);

        let mut yang_base_rates_history_to_update_copy: Span<Span<Ray>> = yang_base_rates_history_to_update
            .span();
        let mut yang_base_rates_history_to_compound_copy: Span<Span<Ray>> =
            yang_base_rates_history_to_compound
            .span();

        let mut i = 0;
        let mut era_start_interval: u64 = start_interval;
        loop {
            // We perform an extra iteration here to test the last rate era by advancing the prices.
            // Otherwise, if the last interval is also the start of a new rate era, we would not be able to test it.
            if i == num_base_rate_updates + 1 {
                break ();
            }

            // Fetch the latest yang prices
            let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
            let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);

            // First, we advance an interval so the last price is not overwritten.
            // Next, Advance the prices by the number of intervals between each base rate update
            ShrineUtils::advance_interval();
            ShrineUtils::advance_prices_and_set_multiplier(
                shrine, BASE_RATE_UPDATE_SPACING, yang1_price, yang2_price
            );

            let era_end_interval: u64 = era_start_interval + BASE_RATE_UPDATE_SPACING;

            // Calculate average price of yangs over the era for calculating the compounded interest
            let mut avg_yang_prices_for_era: Array<Wad> = Default::default();
            let yang1_avg_price: Wad = ShrineUtils::get_avg_yang_price(
                shrine, yang1_addr, era_start_interval, era_end_interval
            );
            avg_yang_prices_for_era.append(yang1_avg_price);

            let yang2_avg_price: Wad = ShrineUtils::get_avg_yang_price(
                shrine, yang2_addr, era_start_interval, era_end_interval
            );
            avg_yang_prices_for_era.append(yang2_avg_price);

            avg_yang_prices_by_era.append(avg_yang_prices_for_era.span());

            // Append multiplier
            avg_multipliers.append(RAY_SCALE.into());

            if i < num_base_rate_updates {
                // Update base rates
                let mut yang_base_rates_to_update: Span<Ray> = *yang_base_rates_history_to_update_copy
                    .pop_front()
                    .unwrap();

                set_contract_address(ShrineUtils::admin());
                shrine.update_rates(yang_addrs.span(), yang_base_rates_to_update);

                // Check that base rates are updated correctly
                let mut yang_addrs_copy: Span<ContractAddress> = yang_addrs.span();
                // Offset by 1 to discount the initial 
                let era: u32 = i.try_into().unwrap() + 1;
                let mut expected_base_rates: Span<Ray> = *yang_base_rates_history_to_compound_copy
                    .at(era);
                loop {
                    match yang_addrs_copy.pop_front() {
                        Option::Some(yang_addr) => {
                            let era: u64 = i + 1;
                            let rate: Ray = shrine.get_yang_rate(*yang_addr, era);
                            let expected_rate: Ray = *expected_base_rates.pop_front().unwrap();
                            assert(rate == expected_rate, 'wrong base rate');
                        },
                        Option::None(_) => {
                            break ();
                        },
                    };
                };
            }

            // Increment counter
            i += 1;

            // Update start interval for next era
            era_start_interval = era_end_interval;
        };

        let (_, _, _, debt) = shrine.get_trove_info(test_utils::TROVE_1);

        let expected_debt: Wad = ShrineUtils::compound(
            yang_base_rates_history_to_compound.span(),
            rate_update_intervals.span(),
            yangs_deposited.span(),
            avg_yang_prices_by_era.span(),
            avg_multipliers.span(),
            start_interval,
            end_interval,
            forge_amt,
        );

        assert(debt == expected_debt, 'wrong compounded debt');

        set_contract_address(ShrineUtils::admin());
        shrine.withdraw(yang1_addr, test_utils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }
}
