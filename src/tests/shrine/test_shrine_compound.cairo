#[cfg(test)]
mod TestShrineCompound {
    use option::OptionTrait;
    use traits::Into;
    use starknet::{ContractAddress, get_block_timestamp};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::shrine::Shrine;

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::exp::exp;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_SCALE, Wad, WadZeroable};

    use aura::tests::shrine::shrine_utils::ShrineUtils;

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
        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);

        ShrineUtils::advance_prices_and_set_multiplier(
            shrine, ShrineUtils::FEED_LEN, yang1_price, yang2_price
        );

        // Offset by 1 because `advance_prices_and_set_multiplier` updates `start_interval`.
        let end_interval: u64 = start_interval + ShrineUtils::FEED_LEN - 1;
        // commented out because of gas usage error
        //assert(current_interval() == end_interval, 'wrong end interval');  // sanity check

        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, estimated_debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(estimated_debt == expected_debt, 'wrong compounded debt');

        // Trigger charge and check interest is accrued
        shrine.melt(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());
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
        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);

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
        //assert(current_interval() == end_interval + 1, 'wrong end interval');  // sanity check

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
        let (_, _, _, estimated_debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(estimated_debt == expected_debt, 'wrong compounded debt');

        // Trigger charge and check interest is accrued
        shrine.melt(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }
}
