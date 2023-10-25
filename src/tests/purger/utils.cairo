mod purger_utils {
    use cmp::min;
    use starknet::{
        deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress,
        contract_address_to_felt252, contract_address_try_from_felt252, get_block_timestamp,
        SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;

    use opus::core::absorber::absorber as absorber_contract;
    use opus::core::purger::purger as purger_contract;
    use opus::core::roles::{absorber_roles, pragma_roles, sentinel_roles, shrine_roles};

    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::types::AssetBalance;
    use opus::utils::math::pow;
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_DECIMALS, WAD_ONE};

    use opus::tests::absorber::utils::absorber_utils;
    use opus::tests::common;
    use opus::tests::external::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::tests::external::utils::pragma_utils;
    use opus::tests::purger::flash_liquidator::{
        flash_liquidator, IFlashLiquidatorDispatcher, IFlashLiquidatorDispatcherTrait
    };
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;

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
        array![TARGET_TROVE_ETH_DEPOSIT_AMT, TARGET_TROVE_WBTC_DEPOSIT_AMT].span()
    }

    #[inline(always)]
    fn recipient_trove_yang_asset_amts() -> Span<u128> {
        array![30 * WAD_ONE, // 30 (Wad) - ETH
         500000000 // 5 (10 ** 8) - BTC
        ].span()
    }

    fn whale_trove_yang_asset_amts() -> Span<u128> {
        array![50 * WAD_ONE, // 50 (Wad) - ETH
         5000000000 // 50 (10 ** 8) - BTC
        ].span()
    }

    fn interesting_thresholds_for_liquidation() -> Span<Ray> {
        array![
            (70 * RAY_PERCENT).into(),
            (80 * RAY_PERCENT).into(),
            (90 * RAY_PERCENT).into(),
            (96 * RAY_PERCENT).into(),
            // theoretical upper bound beyond which a penalty is not guaranteed
            // for absorptions after deducting compensation, meaning providers
            // to the absorber will incur a loss for each absorption.
            (97 * RAY_PERCENT).into(),
            // Note that this threshold should not be used because it makes absorber
            // providers worse off, but it should not break the purger's logic.
            (99 * RAY_PERCENT).into()
        ]
            .span()
    }

    // From around 78.74+% threshold onwards, absorptions liquidate all of the trove's debt
    fn interesting_thresholds_for_absorption_below_trove_debt() -> Span<Ray> {
        array![
            (65 * RAY_PERCENT).into(),
            (70 * RAY_PERCENT).into(),
            (75 * RAY_PERCENT).into(),
            787400000000000000000000000_u128.into()
        ]
            .span()
    }

    // From around 78.74+% threshold onwards, absorptions liquidate all of the trove's debt
    fn interesting_thresholds_for_absorption_entire_trove_debt() -> Span<Ray> {
        array![
            787500000000000000000000000_u128.into(), // 78.75%
            (80 * RAY_PERCENT).into(),
            (90 * RAY_PERCENT).into(),
            (96 * RAY_PERCENT).into(),
            // theoretical upper bound beyond which a penalty is not guaranteed
            // for absorptions after deducting compensation, meaning providers
            // to the absorber will incur a loss for each absorption.
            (97 * RAY_PERCENT).into(),
            // Note that this threshold should not be used because it makes absorber
            // providers worse off, but it should not break the purger's logic.
            (99 * RAY_PERCENT).into()
        ]
            .span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/qoizltusle.
    fn ltvs_for_interesting_thresholds_for_absorption_below_trove_debt() -> Span<Span<Ray>> {
        // The max possible penalty LTV is last reached around this value for these thresholds
        let max_possible_penalty_ltv: Ray = 862200000000000000000000000_u128.into(); // 86.22%

        array![
            // First threshold of 65% (Ray)
            array![ // 71.18% (Ray) - LTV at which maximum penalty of 12.5% is first reached
                711800000000000000000000000_u128.into(), max_possible_penalty_ltv
            ]
                .span(),
            // Second threshold of 70% (Ray)
            array![ // 76.65% (Ray) - LTV at which maximum penalty of 12.5% is first reached
                766500000000000000000000000_u128.into(), max_possible_penalty_ltv
            ]
                .span(),
            // Third threshold of 75% (Ray)
            array![ // 82.13% (Ray) - LTV at which maximum penalty of 12.5% is reached
                821300000000000000000000000_u128.into(), max_possible_penalty_ltv,
            ]
                .span(),
            // Fourth threshold of 78.74% (Ray)
            array![ // 86.2203% (Ray) - LTV at which maximum penalty of 12.5% is reached
                862203000000000000000000000_u128.into(), 862222200000000000000000000_u128.into()
            ]
                .span()
        ]
            .span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/b8drqdb32a.
    fn ltvs_for_interesting_thresholds_for_absorption_entire_trove_debt() -> Span<Span<Ray>> {
        let ninety_nine_pct: Ray = (RAY_ONE - RAY_PERCENT).into();
        let exceed_hundred_pct: Ray = (RAY_ONE + RAY_PERCENT).into();

        array![
            // First threshold of 78.75% (Ray)
            array![ // 86.23% (Ray) - Greater than LTV at which maximum penalty of 12.5% is last reached
                862300000000000000000000000_u128.into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Second threshold of 80% (Ray)
            array![ // 86.9% (Ray) - LTV at which maximum penalty is reached
                869000000000000000000000000_u128.into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Third threshold of 90% (Ray)
            array![ // 92.1% (Ray) - LTV at which maximum penalty is reached
                921000000000000000000000000_u128.into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Fourth threshold of 96% (Ray)
            array![ // Max penalty is already exceeded, so we simply increase the LTV by the smallest unit
                (96 * RAY_PERCENT + 1).into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Fifth threshold of 97% (Ray)
            // This is the highest possible threshold because it may not be possible to charge a
            // penalty after deducting compensation at this LTV and beyond
            array![ // Max penalty is already exceeded, so we simply increase the LTV by the smallest unit
                (97 * RAY_PERCENT + 1).into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Sixth threshold of 99% (Ray)
            // Note that this threshold should not be used because it makes absorber
            // providers worse off, but it should not break the purger's logic.
            array![ // Max penalty is already exceeded, so we simply increase the LTV by the smallest unit
                (99 * RAY_PERCENT + 1).into(), exceed_hundred_pct
            ]
                .span()
        ]
            .span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/b8drqdb32a.
    // Note that thresholds >= 90% will be absorbable once LTV >= threshold
    fn interesting_thresholds_and_ltvs_below_absorption_ltv() -> (Span<Ray>, Span<Ray>) {
        let mut thresholds: Array<Ray> = array![
            (65 * RAY_PERCENT).into(),
            (70 * RAY_PERCENT).into(),
            (75 * RAY_PERCENT).into(),
            787400000000000000000000000_u128.into(), // 78.74% (Ray)
            787500000000000000000000000_u128.into(), // 78.75% (Ray)
            (80 * RAY_PERCENT).into()
        ];

        // The LTV at which the maximum penalty is reached minus 0.01%
        let mut trove_ltvs: Array<Ray> = array![
            711700000000000000000000000_u128.into(), // 71.17% (Ray)
            766400000000000000000000000_u128.into(), // 76.64% (Ray)
            821200000000000000000000000_u128.into(), // 82.12% (Ray)
            859200000000000000000000000_u128.into(), // 85.92% (Ray)
            862200000000000000000000000_u128.into(), // 86.22% (Ray)
            868900000000000000000000000_u128.into(), // 86.89% (Ray)
        ];

        (thresholds.span(), trove_ltvs.span())
    }

    fn interesting_yang_amts_for_recipient_trove() -> Span<Span<u128>> {
        array![
            // base case for ordinary redistributions
            recipient_trove_yang_asset_amts(),
            // recipient trove has dust amount of the first yang
            // 100 wei (Wad) ETH, 20 (10 ** 8) WBTC
            array![100_u128, 2000000000_u128].span(),
            // recipient trove has dust amount of a yang that is not the first yang
            // 50 (Wad) ETH, 0.00001 (10 ** 8) WBTC
            array![50 * WAD_ONE, 100_u128].span(),
            // exceptional redistribution because recipient trove does not have
            // WBTC yang but redistributed trove has WBTC yang
            // 50 (Wad) ETH, 0 WBTC
            array![50 * WAD_ONE, 0_u128].span()
        ]
            .span()
    }

    fn interesting_yang_amts_for_redistributed_trove() -> Span<Span<u128>> {
        array![
            target_trove_yang_asset_amts(), // Dust yang case
             // 20 (Wad) ETH, 100E-8 (WBTC decimals) WBTC
            array![20 * WAD_ONE, 100_u128].span()
        ]
            .span()
    }

    fn inoperational_absorber_yin_cases() -> Span<Wad> {
        array![ // minimum amount that must be provided based on initial shares
            absorber_contract::INITIAL_SHARES
                .into(), // largest possible amount of yin in Absorber based on initial shares
            (absorber_contract::MINIMUM_SHARES - 1).into()
        ]
            .span()
    }

    // Generate interesting cases for absorber's yin balance based on the
    // redistributed trove's debt to test absorption with partial redistribution
    fn generate_operational_absorber_yin_cases(trove_debt: Wad) -> Span<Wad> {
        array![
            // smallest possible amount of yin in Absorber based on initial shares
            absorber_contract::MINIMUM_SHARES.into(),
            (trove_debt.val / 3).into(),
            (trove_debt.val - 1000).into(),
            // trove's debt minus the smallest unit of Wad
            (trove_debt.val - 1).into()
        ]
            .span()
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
        let (shrine, sentinel, abbot, absorber, yangs, gates) = absorber_utils::absorber_deploy();

        let reward_tokens: Span<ContractAddress> = absorber_utils::reward_tokens_deploy();
        let reward_amts_per_blessing: Span<u128> = absorber_utils::reward_amts_per_blessing();
        absorber_utils::deploy_blesser_for_rewards(
            absorber, reward_tokens, reward_amts_per_blessing
        );

        let (_, oracle, _, mock_pragma) = pragma_utils::pragma_deploy_with_shrine(
            sentinel, shrine.contract_address
        );
        pragma_utils::add_yangs_to_pragma(oracle, yangs);

        // Seed initial prices for ETH and WBTC in Pragma
        let current_ts = get_block_timestamp();
        pragma_utils::mock_valid_price_update(
            mock_pragma,
            pragma_utils::ETH_USD_PAIR_ID,
            pragma_utils::convert_price_to_pragma_scale(pragma_utils::ETH_INIT_PRICE),
            current_ts
        );
        pragma_utils::mock_valid_price_update(
            mock_pragma,
            pragma_utils::WBTC_USD_PAIR_ID,
            pragma_utils::convert_price_to_pragma_scale(pragma_utils::WBTC_INIT_PRICE),
            current_ts
        );
        IOracleDispatcher { contract_address: oracle.contract_address }.update_prices();

        let admin: ContractAddress = admin();

        let mut calldata = array![
            contract_address_to_felt252(admin),
            contract_address_to_felt252(shrine.contract_address),
            contract_address_to_felt252(sentinel.contract_address),
            contract_address_to_felt252(absorber.contract_address),
            contract_address_to_felt252(oracle.contract_address)
        ];

        let purger_class_hash: ClassHash = class_hash_try_from_felt252(
            purger_contract::TEST_CLASS_HASH
        )
            .unwrap();
        let (purger_addr, _) = deploy_syscall(purger_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let purger = IPurgerDispatcher { contract_address: purger_addr };

        // Approve Purger in Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        set_contract_address(shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::purger(), purger_addr);

        // Approve Purger in Sentinel
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        set_contract_address(sentinel_utils::admin());
        sentinel_ac.grant_role(sentinel_roles::purger(), purger_addr);

        // Approve Purger in Oracle
        let oracle_ac = IAccessControlDispatcher { contract_address: oracle.contract_address };
        set_contract_address(pragma_utils::admin());
        oracle_ac.grant_role(pragma_roles::purger(), purger_addr);

        // Approve Purger in Absorber
        let absorber_ac = IAccessControlDispatcher { contract_address: absorber.contract_address };
        set_contract_address(absorber_utils::admin());
        absorber_ac.grant_role(absorber_roles::purger(), purger_addr);

        // Increase debt ceiling
        set_contract_address(shrine_utils::admin());
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
        let mut calldata = array![
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(abbot),
            contract_address_to_felt252(flashmint),
            contract_address_to_felt252(purger)
        ];

        let flash_liquidator_class_hash: ClassHash = class_hash_try_from_felt252(
            flash_liquidator::TEST_CLASS_HASH
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
        common::fund_user(user, yangs, recipient_trove_yang_asset_amts());
        common::open_trove_helper(
            abbot, user, yangs, recipient_trove_yang_asset_amts(), gates, yin_amt
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
        absorber_utils::provide_to_absorber(
            shrine,
            abbot,
            absorber,
            absorber_utils::provider_1(),
            yangs,
            recipient_trove_yang_asset_amts(),
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

    // Creates a trove with a lot of collateral
    // This is used to ensure the system doesn't unintentionally enter recovery mode during tests
    fn create_whale_trove(
        abbot: IAbbotDispatcher, yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>
    ) -> u64 {
        let user: ContractAddress = target_trove_owner();
        let deposit_amts: Span<u128> = whale_trove_yang_asset_amts();
        let yin_amt: Wad = TARGET_TROVE_YIN.into();
        common::fund_user(user, yangs, deposit_amts);
        common::open_trove_helper(abbot, user, yangs, deposit_amts, gates, yin_amt)
    }

    // Update thresholds for all yangs to the given value
    fn set_thresholds(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, threshold: Ray) {
        set_contract_address(shrine_utils::admin());
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => { shrine.set_threshold(*yang, threshold); },
                Option::None => { break; },
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
        let scale: u128 = pow(10_u128, WAD_DECIMALS - pragma_utils::PRAGMA_DECIMALS);
        set_contract_address(shrine_utils::admin());
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    let new_price: Wad = wadray::rmul_wr(
                        yang_price, (RAY_ONE.into() - pct_decrease)
                    );
                    let new_pragma_price: u128 = new_price.val / scale;
                    // Note that `new_price` is more precise than `new_pragma_price` so
                    // the `new_pragma_price` is a rounded down value of `new_price`.
                    // `new_price` is used so that there is more control over the precision of
                    // the target LTV.
                    shrine.advance(*yang, new_price);

                    pragma_utils::mock_valid_price_update(
                        mock_pragma,
                        *yang_pair_ids.pop_front().unwrap(),
                        new_pragma_price,
                        current_ts
                    );
                },
                Option::None => { break; },
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

    // Returns a tuple of the expected freed percentage of trove value and the 
    // freed asset amounts
    fn get_expected_liquidation_assets(
        trove_asset_amts: Span<u128>,
        trove_value: Wad,
        close_amt: Wad,
        penalty: Ray,
        compensation_value: Option<Wad>
    ) -> (Ray, Span<u128>) {
        let freed_amt: Wad = wadray::rmul_wr(close_amt, RAY_ONE.into() + penalty);
        let value_offset: Wad = if compensation_value.is_some() {
            compensation_value.unwrap()
        } else {
            WadZeroable::zero()
        };
        let value_after_compensation: Wad = trove_value - value_offset;
        let expected_freed_pct_of_value_before_compensation: Ray =
            if freed_amt < value_after_compensation {
            wadray::rdiv_ww(freed_amt, trove_value)
        } else {
            wadray::rdiv_ww(value_after_compensation, trove_value)
        };
        let expected_freed_pct_of_value_after_compensation: Ray =
            if freed_amt < value_after_compensation {
            wadray::rdiv_ww(freed_amt, value_after_compensation)
        } else {
            expected_freed_pct_of_value_before_compensation
        };
        (
            expected_freed_pct_of_value_after_compensation,
            common::scale_span_by_pct(
                trove_asset_amts, expected_freed_pct_of_value_before_compensation
            )
        )
    }

    fn assert_trove_is_healthy(
        shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64
    ) {
        assert(shrine.is_healthy(trove_id), 'should be healthy');

        let (penalty, max_liquidation_amt) = purger.preview_liquidate(trove_id);
        assert(penalty.is_zero(), 'penalty should be 0');
        assert(max_liquidation_amt.is_zero(), 'close amount should be 0');
        assert_trove_is_not_absorbable(purger, trove_id);
    }

    fn assert_trove_is_liquidatable(
        shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64, ltv: Ray
    ) {
        assert(!shrine.is_healthy(trove_id), 'should not be healthy');

        let (penalty, max_liquidation_amt) = purger.preview_liquidate(trove_id);
        assert(penalty.is_non_zero(), 'close amount should not be 0');
        if ltv < RAY_ONE.into() {
            assert(penalty.is_non_zero(), 'penalty should not be 0');
        } else {
            assert(penalty.is_zero(), 'penalty should be 0');
        }
    }

    fn assert_trove_is_absorbable(
        shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64, ltv: Ray
    ) {
        assert(!shrine.is_healthy(trove_id), 'should not be healthy');
        assert(purger.is_absorbable(trove_id), 'should be absorbable');

        let (penalty, max_absorption_amt, _) = purger.preview_absorb(trove_id);
        assert(max_absorption_amt.is_non_zero(), 'close amount should not be 0');
        if ltv < (RAY_ONE - purger_contract::COMPENSATION_PCT).into() {
            assert(penalty.is_non_zero(), 'penalty should not be 0');
        } else {
            assert(penalty.is_zero(), 'penalty should be 0');
        }
    }

    fn assert_trove_is_not_absorbable(purger: IPurgerDispatcher, trove_id: u64,) {
        let (penalty, max_absorption_amt, _) = purger.preview_absorb(trove_id);
        assert(penalty.is_zero(), 'penalty should be 0');
        assert(max_absorption_amt.is_zero(), 'close amount should be 0');
    }

    fn assert_ltv_at_safety_margin(threshold: Ray, ltv: Ray) {
        let expected_ltv: Ray = purger_contract::THRESHOLD_SAFETY_MARGIN.into() * threshold;
        let error_margin: Ray = (RAY_PERCENT / 10).into(); // 0.1%
        common::assert_equalish(ltv, expected_ltv, error_margin, 'LTV not within safety margin');
    }

    // Helper function to assert that an address received the expected amount of assets based
    // on the before and after balances.
    // `before_asset_bals` and `after_asset_bals` should be retrieved using `get_token_balances`.
    fn assert_received_assets(
        mut before_asset_bals: Span<Span<u128>>,
        mut after_asset_bals: Span<Span<u128>>,
        mut expected_freed_assets: Span<AssetBalance>,
        error_margin: u128,
        message: felt252
    ) {
        loop {
            match expected_freed_assets.pop_front() {
                Option::Some(expected_freed_asset) => {
                    let mut before_asset_bal_arr: Span<u128> = *before_asset_bals
                        .pop_front()
                        .unwrap();
                    let before_asset_bal: u128 = *before_asset_bal_arr.pop_front().unwrap();

                    let mut after_asset_bal_arr: Span<u128> = *after_asset_bals
                        .pop_front()
                        .unwrap();
                    let after_asset_bal: u128 = *after_asset_bal_arr.pop_front().unwrap();

                    let expected_after_asset_bal: u128 = before_asset_bal
                        + *expected_freed_asset.amount;

                    common::assert_equalish(
                        after_asset_bal, expected_after_asset_bal, error_margin, message,
                    );
                },
                Option::None => { break; },
            };
        };
    }
}
