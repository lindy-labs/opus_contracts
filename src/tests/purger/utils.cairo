mod PurgerUtils {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252,
        get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::purger::Purger;
    use aura::core::roles::{AbsorberRoles, PragmaRoles, SentinelRoles, ShrineRoles};

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{
        Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_ONE, WAD_SCALE
    };

    use aura::tests::absorber::utils::AbsorberUtils;
    use aura::tests::common;
    use aura::tests::external::mock_pragma::{
        IMockPragmaDispatcher, IMockPragmaDispatcherTrait, MockPragma
    };
    use aura::tests::external::utils::PragmaUtils;
    use aura::tests::purger::flash_liquidator::{
        FlashLiquidator, IFlashLiquidatorDispatcher, IFlashLiquidatorDispatcherTrait
    };
    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

    //
    // Constants
    //

    const SEARCHER_YIN: u128 = 10000000000000000000000; // 10_000 (Wad)
    const TARGET_TROVE_YIN: u128 = 1000000000000000000000; // 1000 (Wad)

    const TARGET_TROVE_ETH_DEPOSIT_AMT: u128 = 2000000000000000000; // 2 (Wad) - ETH
    const TARGET_TROVE_WBTC_DEPOSIT_AMT: u128 = 50000000; // 0.5 (10 ** 8) - wBTC

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('purger owner').unwrap()
    }

    fn random_user() -> ContractAddress {
        contract_address_try_from_felt252('random user').unwrap()
    }

    fn searcher() -> ContractAddress {
        contract_address_try_from_felt252('searcher').unwrap()
    }

    fn target_trove_owner() -> ContractAddress {
        contract_address_try_from_felt252('target trove owner').unwrap()
    }

    //
    // Constant helpers
    //

    fn target_trove_yang_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(TARGET_TROVE_ETH_DEPOSIT_AMT);
        asset_amts.append(TARGET_TROVE_WBTC_DEPOSIT_AMT);
        asset_amts.span()
    }

    fn interesting_thresholds_for_liquidation() -> Span<Ray> {
        let mut thresholds: Array<Ray> = Default::default();
        thresholds.append((70 * RAY_PERCENT).into());
        thresholds.append((80 * RAY_PERCENT).into());
        thresholds.append((90 * RAY_PERCENT).into());
        thresholds.append((96 * RAY_PERCENT).into());
        // theoretical upper bound beyond which a penalty is not guaranteed 
        // for absorptions after deducting compensation, meaning providers
        // to the absorber will incur a loss for each absorption.
        thresholds.append((97 * RAY_PERCENT).into());
        // Note that this threshold should not be used because it makes absorber 
        // providers worse off, but it should not break the purger's logic.
        thresholds.append((99 * RAY_PERCENT).into());
        thresholds.span()
    }

    // From around 78.74+% threshold onwards, absorptions liquidate all of the trove's debt
    fn interesting_thresholds_for_absorption_below_trove_debt() -> Span<Ray> {
        let mut thresholds: Array<Ray> = Default::default();
        thresholds.append((65 * RAY_PERCENT).into());
        thresholds.append((70 * RAY_PERCENT).into());
        thresholds.append((75 * RAY_PERCENT).into());
        thresholds.append(787400000000000000000000000_u128.into()); // 78.74%
        thresholds.span()
    }

    // From around 78.74+% threshold onwards, absorptions liquidate all of the trove's debt
    fn interesting_thresholds_for_absorption_entire_trove_debt() -> Span<Ray> {
        let mut thresholds: Array<Ray> = Default::default();
        thresholds.append(787500000000000000000000000_u128.into()); // 78.75%
        thresholds.append((80 * RAY_PERCENT).into());
        thresholds.append((90 * RAY_PERCENT).into());
        thresholds.append((96 * RAY_PERCENT).into());
        // theoretical upper bound beyond which a penalty is not guaranteed 
        // for absorptions after deducting compensation, meaning providers
        // to the absorber will incur a loss for each absorption.
        thresholds.append((97 * RAY_PERCENT).into());
        // Note that this threshold should not be used because it makes absorber 
        // providers worse off, but it should not break the purger's logic.
        thresholds.append((99 * RAY_PERCENT).into());
        thresholds.span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/qoizltusle.
    fn ltvs_for_interesting_thresholds_for_absorption_below_trove_debt() -> Span<Span<Ray>> {
        // The max possible penalty LTV is last reached around this value for these thresholds
        let max_possible_penalty_ltv: Ray = 862200000000000000000000000_u128.into(); // 86.22%

        let mut trove_ltvs: Array<Span<Ray>> = Default::default();

        // First threshold of 65% (Ray)
        let mut ltvs_for_first_threshold: Array<Ray> = Default::default();
        // 71.18% (Ray) - LTV at which maximum penalty of 12.5% is first reached
        ltvs_for_first_threshold.append(711800000000000000000000000_u128.into());
        ltvs_for_first_threshold.append(max_possible_penalty_ltv);
        trove_ltvs.append(ltvs_for_first_threshold.span());

        // Second threshold of 70% (Ray)
        let mut ltvs_for_second_threshold: Array<Ray> = Default::default();
        // 76.65% (Ray) - LTV at which maximum penalty of 12.5% is first reached
        ltvs_for_second_threshold.append(766500000000000000000000000_u128.into());
        ltvs_for_second_threshold.append(max_possible_penalty_ltv);
        trove_ltvs.append(ltvs_for_second_threshold.span());

        // Third threshold of 75% (Ray)
        let mut ltvs_for_third_threshold: Array<Ray> = Default::default();
        // 82.13% (Ray) - LTV at which maximum penalty of 12.5% is reached
        ltvs_for_third_threshold.append(821300000000000000000000000_u128.into());
        ltvs_for_third_threshold.append(max_possible_penalty_ltv);
        trove_ltvs.append(ltvs_for_third_threshold.span());

        // Fourth threshold of 78.74% (Ray)
        let mut ltvs_for_fourth_threshold: Array<Ray> = Default::default();
        // 85.93% (Ray) - LTV at which maximum penalty of 12.5% is reached
        ltvs_for_first_threshold.append(859300000000000000000000000_u128.into());
        ltvs_for_third_threshold.append(max_possible_penalty_ltv);
        trove_ltvs.append(ltvs_for_fourth_threshold.span());

        trove_ltvs.span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/b8drqdb32a.
    fn ltvs_for_interesting_thresholds_for_absorption_entire_trove_debt() -> Span<Span<Ray>> {
        let ninety_nine_pct: Ray = (RAY_ONE - RAY_PERCENT).into();
        let exceed_hundred_pct: Ray = (RAY_ONE + RAY_PERCENT).into();

        let mut trove_ltvs: Array<Span<Ray>> = Default::default();

        // First threshold of 78.75% (Ray)
        let mut ltvs_for_first_threshold: Array<Ray> = Default::default();
        // 86.23% (Ray) - Greater than LTV at which maximum penalty of 12.5% is last reached
        ltvs_for_first_threshold.append(862300000000000000000000000_u128.into());
        ltvs_for_first_threshold.append(ninety_nine_pct);
        ltvs_for_first_threshold.append(exceed_hundred_pct);
        trove_ltvs.append(ltvs_for_first_threshold.span());

        // Second threshold of 80% (Ray)
        let mut ltvs_for_second_threshold: Array<Ray> = Default::default();
        // 86.9% (Ray) - LTV at which maximum penalty is reached
        ltvs_for_second_threshold.append(869000000000000000000000000_u128.into());
        ltvs_for_second_threshold.append(ninety_nine_pct);
        ltvs_for_second_threshold.append(exceed_hundred_pct);
        trove_ltvs.append(ltvs_for_second_threshold.span());

        // Third threshold of 90% (Ray)
        let mut ltvs_for_third_threshold: Array<Ray> = Default::default();
        // 92.09% (Ray) - LTV at which maximum penalty is reached
        ltvs_for_third_threshold.append(921000000000000000000000000_u128.into());
        ltvs_for_third_threshold.append(ninety_nine_pct);
        ltvs_for_third_threshold.append(exceed_hundred_pct);
        trove_ltvs.append(ltvs_for_third_threshold.span());

        // Fourth threshold of 96% (Ray)
        let mut ltvs_for_fourth_threshold: Array<Ray> = Default::default();
        // Max penalty is already exceeded, so we simply increase the LTV by the smallest unit
        ltvs_for_fourth_threshold.append((96 * RAY_PERCENT + 1).into());
        ltvs_for_fourth_threshold.append(ninety_nine_pct);
        ltvs_for_fourth_threshold.append(exceed_hundred_pct);
        trove_ltvs.append(ltvs_for_fourth_threshold.span());

        // Fifth threshold of 97% (Ray)
        // This is the highest possible threshold because it may not be possible to charge a 
        // penalty after deducting compensation at this LTV and beyond
        let mut ltvs_for_fifth_threshold: Array<Ray> = Default::default();
        ltvs_for_fifth_threshold.append((97 * RAY_PERCENT + 1).into());
        ltvs_for_fifth_threshold.append(ninety_nine_pct);
        ltvs_for_fifth_threshold.append(exceed_hundred_pct);
        trove_ltvs.append(ltvs_for_fifth_threshold.span());

        // Sixth threshold of 99% (Ray)
        // Note that this threshold should not be used because it makes absorber 
        // providers worse off, but it should not break the purger's logic.
        let mut ltvs_for_sixth_threshold: Array<Ray> = Default::default();
        ltvs_for_sixth_threshold.append((99 * RAY_PERCENT + 1).into());
        ltvs_for_sixth_threshold.append(exceed_hundred_pct);
        trove_ltvs.append(ltvs_for_sixth_threshold.span());

        trove_ltvs.span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/b8drqdb32a.
    // Note that thresholds >= 90% will be absorbable once LTV >= threshold
    fn interesting_thresholds_and_ltvs_below_absorption_ltv() -> (Span<Ray>, Span<Ray>) {
        let mut thresholds: Array<Ray> = Default::default();
        thresholds.append((65 * RAY_PERCENT).into());
        thresholds.append((70 * RAY_PERCENT).into());
        thresholds.append((75 * RAY_PERCENT).into());
        thresholds.append(787400000000000000000000000_u128.into()); // 78.74% (Ray)
        thresholds.append(787500000000000000000000000_u128.into()); // 78.75% (Ray)
        thresholds.append((80 * RAY_PERCENT).into());

        // The LTV at which the maximum penalty is reached minus 0.01%
        let mut trove_ltvs: Array<Ray> = Default::default();
        trove_ltvs.append(711700000000000000000000000_u128.into()); // 71.17% (Ray)
        trove_ltvs.append(766400000000000000000000000_u128.into()); // 76.64% (Ray)
        trove_ltvs.append(821200000000000000000000000_u128.into()); // 82.12% (Ray)
        trove_ltvs.append(859200000000000000000000000_u128.into()); // 85.92% (Ray)
        trove_ltvs.append(862200000000000000000000000_u128.into()); // 86.22% (Ray)
        trove_ltvs.append(868900000000000000000000000_u128.into()); // 86.89% (Ray)

        (thresholds.span(), trove_ltvs.span())
    }


    //
    // Test setup helpers
    //

    fn purger_deploy() -> (
        IShrineDispatcher,
        IAbbotDispatcher,
        IMockPragmaDispatcher,
        IAbsorberDispatcher,
        IPurgerDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>,
    ) {
        let (shrine, sentinel, abbot, absorber, yangs, gates) = AbsorberUtils::absorber_deploy();

        let reward_tokens: Span<ContractAddress> = AbsorberUtils::reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = AbsorberUtils::reward_amts_per_blessing();
        AbsorberUtils::deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );

        let (_, oracle, _, mock_pragma) = PragmaUtils::pragma_deploy_with_shrine(
            sentinel, shrine.contract_address
        );
        PragmaUtils::add_yangs_to_pragma(oracle, yangs);

        // Seed initial prices for ETH and WBTC in Pragma
        let current_ts = get_block_timestamp();
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::ETH_USD_PAIR_ID, PragmaUtils::ETH_INIT_PRICE, current_ts
        );
        PragmaUtils::mock_valid_price_update(
            mock_pragma, PragmaUtils::WBTC_USD_PAIR_ID, PragmaUtils::WBTC_INIT_PRICE, current_ts
        );
        IOracleDispatcher { contract_address: oracle.contract_address }.update_prices();

        let admin: ContractAddress = admin();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(admin));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel.contract_address));
        calldata.append(contract_address_to_felt252(absorber.contract_address));
        calldata.append(contract_address_to_felt252(oracle.contract_address));

        let purger_class_hash: ClassHash = class_hash_try_from_felt252(Purger::TEST_CLASS_HASH)
            .unwrap();
        let (purger_addr, _) = deploy_syscall(purger_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let purger = IPurgerDispatcher { contract_address: purger_addr };

        // Approve Purger in Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        set_contract_address(ShrineUtils::admin());
        shrine_ac.grant_role(ShrineRoles::purger(), purger_addr);

        // Approve Purger in Sentinel
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        set_contract_address(SentinelUtils::admin());
        sentinel_ac.grant_role(SentinelRoles::purger(), purger_addr);

        // Approve Purger in Oracle
        let oracle_ac = IAccessControlDispatcher { contract_address: oracle.contract_address };
        set_contract_address(PragmaUtils::admin());
        oracle_ac.grant_role(PragmaRoles::purger(), purger_addr);

        // Approve Purger in Absorber
        let absorber_ac = IAccessControlDispatcher { contract_address: absorber.contract_address };
        set_contract_address(AbsorberUtils::admin());
        absorber_ac.grant_role(AbsorberRoles::purger(), purger_addr);

        // Increase debt ceiling
        set_contract_address(ShrineUtils::admin());
        let debt_ceiling: Wad = (100000 * WAD_ONE).into();
        shrine.set_debt_ceiling(debt_ceiling);

        set_contract_address(ContractAddressZeroable::zero());

        (shrine, abbot, mock_pragma, absorber, purger, yangs, gates)
    }

    fn purger_deploy_with_searcher(
        searcher_yin_amt: Wad
    ) -> (
        IShrineDispatcher,
        IAbbotDispatcher,
        IMockPragmaDispatcher,
        IAbsorberDispatcher,
        IPurgerDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>,
    ) {
        let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) = purger_deploy();
        funded_searcher(abbot, yangs, gates, searcher_yin_amt);

        (shrine, abbot, mock_pragma, absorber, purger, yangs, gates)
    }

    fn flash_liquidator_deploy(
        shrine: ContractAddress,
        abbot: ContractAddress,
        flashmint: ContractAddress,
        purger: ContractAddress,
    ) -> IFlashLiquidatorDispatcher {
        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine));
        calldata.append(contract_address_to_felt252(abbot));
        calldata.append(contract_address_to_felt252(flashmint));
        calldata.append(contract_address_to_felt252(purger));

        let flash_liquidator_class_hash: ClassHash = class_hash_try_from_felt252(
            FlashLiquidator::TEST_CLASS_HASH
        )
            .unwrap();
        let (flash_liquidator_addr, _) = deploy_syscall(
            flash_liquidator_class_hash, 0, calldata.span(), false
        )
            .unwrap_syscall();

        IFlashLiquidatorDispatcher { contract_address: flash_liquidator_addr }
    }

    fn funded_searcher(
        abbot: IAbbotDispatcher,
        yangs: Span<ContractAddress>,
        gates: Span<IGateDispatcher>,
        yin_amt: Wad,
    ) {
        let user: ContractAddress = searcher();
        common::fund_user(user, yangs, AbsorberUtils::provider_asset_amts());
        common::open_trove_helper(
            abbot, user, yangs, AbsorberUtils::provider_asset_amts(), gates, yin_amt
        );
    }

    fn funded_absorber(
        shrine: IShrineDispatcher,
        abbot: IAbbotDispatcher,
        absorber: IAbsorberDispatcher,
        yangs: Span<ContractAddress>,
        gates: Span<IGateDispatcher>,
        amt: Wad,
    ) {
        AbsorberUtils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            AbsorberUtils::provider_1(),
            yangs,
            AbsorberUtils::provider_asset_amts(),
            gates,
            amt,
        );
    }

    // Creates a healthy trove and returns the trove ID
    fn funded_healthy_trove(
        abbot: IAbbotDispatcher,
        yangs: Span<ContractAddress>,
        gates: Span<IGateDispatcher>,
        yin_amt: Wad,
    ) -> u64 {
        let user: ContractAddress = target_trove_owner();
        let deposit_amts: Span<u128> = target_trove_yang_asset_amts();
        common::fund_user(user, yangs, deposit_amts);
        common::open_trove_helper(abbot, user, yangs, deposit_amts, gates, yin_amt)
    }

    // Update thresholds for all yangs to the given value
    fn set_thresholds(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, threshold: Ray) {
        set_contract_address(ShrineUtils::admin());
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    shrine.set_threshold(*yang, threshold);
                },
                Option::None(_) => {
                    break;
                },
            };
        };
        set_contract_address(ContractAddressZeroable::zero());
    }

    // Helper function to decrease yang prices by the given percentage
    fn decrease_yang_prices_by_pct(
        shrine: IShrineDispatcher,
        mock_pragma: IMockPragmaDispatcher,
        mut yangs: Span<ContractAddress>,
        mut yang_pair_ids: Span<u256>,
        pct_decrease: Ray,
    ) {
        let current_ts = get_block_timestamp();
        set_contract_address(ShrineUtils::admin());
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    let new_price: Wad = wadray::rmul_wr(
                        yang_price, (RAY_ONE.into() - pct_decrease)
                    );
                    let new_price: u128 = new_price.val / WAD_SCALE;
                    shrine.advance(*yang, (new_price * WAD_SCALE).into());

                    //let new_empiric_price: u128 = new_price.val / scale;
                    PragmaUtils::mock_valid_price_update(
                        mock_pragma, *yang_pair_ids.pop_front().unwrap(), new_price, current_ts
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };
        set_contract_address(ContractAddressZeroable::zero());
    }

    // Helper function to adjust a trove's LTV to the target by manipulating the 
    // yang prices
    fn adjust_prices_for_trove_ltv(
        shrine: IShrineDispatcher,
        mock_pragma: IMockPragmaDispatcher,
        yangs: Span<ContractAddress>,
        yang_pair_ids: Span<u256>,
        value: Wad,
        debt: Wad,
        target_ltv: Ray,
    ) {
        let unhealthy_value: Wad = wadray::rmul_wr(debt, (RAY_ONE.into() / target_ltv));
        let decrease_pct: Ray = wadray::rdiv_ww((value - unhealthy_value), value);
        decrease_yang_prices_by_pct(shrine, mock_pragma, yangs, yang_pair_ids, decrease_pct);
    }

    //
    // Test assertion helpers
    //

    fn get_expected_compensation_assets(
        trove_asset_amts: Span<u128>, trove_value: Wad, compensation_value: Wad
    ) -> Span<u128> {
        let expected_compensation_pct: Ray = wadray::rdiv_ww(compensation_value, trove_value);
        common::scale_span_by_pct(trove_asset_amts, expected_compensation_pct)
    }

    fn get_expected_liquidation_assets(
        trove_asset_amts: Span<u128>, trove_value: Wad, close_amt: Wad, penalty: Ray
    ) -> Span<u128> {
        let freed_amt: Wad = wadray::rmul_wr(close_amt, RAY_ONE.into() + penalty);
        let expected_freed_pct: Ray = wadray::rdiv_ww(freed_amt, trove_value);
        common::scale_span_by_pct(trove_asset_amts, expected_freed_pct)
    }

    fn assert_trove_is_healthy(
        shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64
    ) {
        assert(shrine.is_healthy(trove_id), 'should be healthy');

        assert(
            purger.get_liquidation_penalty(trove_id) == RayZeroable::zero(), 'penalty should be 0'
        );
        assert(
            purger.get_max_liquidation_amount(trove_id) == WadZeroable::zero(),
            'close amount should be 0'
        );
        assert_trove_is_not_absorbable(purger, trove_id);
    }

    fn assert_trove_is_liquidatable(
        shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64, ltv: Ray
    ) {
        assert(!shrine.is_healthy(trove_id), 'should not be healthy');

        assert(
            purger.get_max_liquidation_amount(trove_id).is_non_zero(),
            'close amount should not be 0'
        );
        if ltv < RAY_ONE.into() {
            assert(
                purger.get_liquidation_penalty(trove_id).is_non_zero(), 'penalty should not be 0'
            );
        } else {
            assert(purger.get_liquidation_penalty(trove_id).is_zero(), 'penalty should be 0');
        }
    }

    fn assert_trove_is_absorbable(
        shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64, ltv: Ray
    ) {
        assert(!shrine.is_healthy(trove_id), 'should not be healthy');
        assert(purger.is_absorbable(trove_id), 'should be absorbable');

        assert(
            purger.get_max_absorption_amount(trove_id).is_non_zero(), 'close amount should not be 0'
        );
        if ltv < (RAY_ONE - Purger::COMPENSATION_PCT).into() {
            assert(
                purger.get_absorption_penalty(trove_id).is_non_zero(), 'penalty should not be 0'
            );
        } else {
            assert(purger.get_absorption_penalty(trove_id).is_zero(), 'penalty should be 0');
        }
    }

    fn assert_trove_is_not_absorbable(purger: IPurgerDispatcher, trove_id: u64, ) {
        assert(
            purger.get_absorption_penalty(trove_id) == RayZeroable::zero(), 'penalty should be 0'
        );
        assert(
            purger.get_max_absorption_amount(trove_id) == WadZeroable::zero(),
            'close amount should be 0'
        );
    }

    fn assert_ltv_at_safety_margin(threshold: Ray, ltv: Ray) {
        let expected_ltv: Ray = Purger::THRESHOLD_SAFETY_MARGIN.into() * threshold;
        let error_margin: Ray = (RAY_PERCENT / 100).into(); // 0.01%
        common::assert_equalish(ltv, expected_ltv, error_margin, 'LTV not within safety margin');
    }

    // Helper function to assert that an address received the expected amount of assets based 
    // on the before and after balances.
    // `before_asset_bals` and `after_asset_bals` should be retrieved using `get_token_balances`.
    fn assert_received_assets(
        mut before_asset_bals: Span<Span<u128>>,
        mut after_asset_bals: Span<Span<u128>>,
        mut expected_freed_asset_amts: Span<u128>,
        error_margin: u128,
        message: felt252
    ) {
        loop {
            match expected_freed_asset_amts.pop_front() {
                Option::Some(expected_freed_asset_amt) => {
                    let mut before_asset_bal_arr: Span<u128> = *before_asset_bals
                        .pop_front()
                        .unwrap();
                    let before_asset_bal: u128 = *before_asset_bal_arr.pop_front().unwrap();

                    let mut after_asset_bal_arr: Span<u128> = *after_asset_bals
                        .pop_front()
                        .unwrap();
                    let after_asset_bal: u128 = *after_asset_bal_arr.pop_front().unwrap();

                    let expected_after_asset_bal: u128 = before_asset_bal
                        + *expected_freed_asset_amt;
                    common::assert_equalish(
                        after_asset_bal, expected_after_asset_bal, error_margin, message, 
                    );
                },
                Option::None(_) => {
                    break;
                },
            };
        };
    }
}
