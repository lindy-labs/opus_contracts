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

        shrine.deposit(yang1_addr, ShrineUtils::TROVE_1, WadZeroable::zero());

        // sanity check that some interest has accrued
        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
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

        shrine.withdraw(yang1_addr, ShrineUtils::TROVE_1, WadZeroable::zero());

        // As the price and multiplier have not been updated since `T+LAST_UPDATED`, we expect the 
        // average values to be that at `T+LAST_UPDATED`.
        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            start_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        shrine.melt(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());
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

        shrine.deposit(yang1_addr, ShrineUtils::TROVE_1, WadZeroable::zero());

        // sanity check that some interest has accrued
        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
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

        shrine.withdraw(yang1_addr, ShrineUtils::TROVE_1, WadZeroable::zero());

        // As the price and multiplier have not been updated since `T+START/LAST_UPDATED`, we expect the 
        // average values to be that at `T+START/LAST_UPDATED`.
        let expected_debt: Wad = ShrineUtils::compound_for_single_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            start_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        shrine.forge(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }
}
