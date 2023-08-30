// TODO: shut working; shut working only once
//       various shut scenarios (?) - enough collateral, not enough collateral
//       release; release when system is live; release when not trove owner
//       reclaim; reclaim when system is live; reclaim not enough yin
#[cft(test)]
mod TestCaretaker {
    use array::{ArrayTrait, SpanTrait};
    use debug::PrintTrait;
    use option::OptionTrait;
    use starknet::{ContractAddress};
    use starknet::testing::set_contract_address;
    use traits::{Into, TryInto};

    use aura::core::roles::{CaretakerRoles, ShrineRoles};

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::ICaretaker::{ICaretakerDispatcher, ICaretakerDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::types::AssetBalance;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WadZeroable, WAD_ONE};

    use aura::tests::abbot::utils::AbbotUtils;
    use aura::tests::caretaker::utils::CaretakerUtils;
    use aura::tests::common;
    use aura::tests::shrine::utils::ShrineUtils;


    #[test]
    #[available_gas(100000000)]
    fn test_caretaker_setup() {
        let (caretaker, shrine, _, _, _, _) = CaretakerUtils::caretaker_deploy();

        let caretaker_ac = IAccessControlDispatcher {
            contract_address: caretaker.contract_address
        };

        assert(caretaker_ac.get_admin() == CaretakerUtils::admin(), 'setup admin');
        assert(
            caretaker_ac.get_roles(CaretakerUtils::admin()) == CaretakerRoles::SHUT, 'admin roles'
        );

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        assert(
            shrine_ac.has_role(ShrineRoles::KILL, caretaker.contract_address),
            'caretaker cant kill shrine'
        );
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_caretaker_setup_preview_release_throws() {
        let (caretaker, _, _, _, _, _) = CaretakerUtils::caretaker_deploy();
        caretaker.preview_release(1);
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_caretaker_setup_preview_reclaim_throws() {
        let (caretaker, _, _, _, _, _) = CaretakerUtils::caretaker_deploy();
        caretaker.preview_reclaim(WAD_ONE.into());
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shut_by_badguy_throws() {
        let (caretaker, _, _, _, _, _) = CaretakerUtils::caretaker_deploy();
        set_contract_address(common::badguy());
        caretaker.shut();
    }

    #[test]
    #[available_gas(100000000)]
    fn test_shut() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) =
            CaretakerUtils::caretaker_deploy();

        // user 1 with 950 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (950 * WAD_ONE).into();
        common::fund_user(user1, yangs, AbbotUtils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot, user1, yangs, AbbotUtils::open_trove_yang_asset_amts(), gates, trove1_forge_amt
        );

        // user 2 with 50 yin and 1 yang
        let user2 = common::trove2_owner_addr();
        let trove2_forge_amt: Wad = (50 * WAD_ONE).into();
        common::fund_user(user2, yangs, AbbotUtils::initial_asset_amts());
        let (eth_yang, eth_gate, eth_yang_amt) = CaretakerUtils::only_eth(yangs, gates);
        let trove2_id = common::open_trove_helper(
            abbot, user2, eth_yang, eth_yang_amt, eth_gate, trove2_forge_amt
        );

        let total_yin: Wad = trove1_forge_amt + trove2_forge_amt;
        let (_, total_value) = shrine.get_shrine_threshold_and_value();
        let backing: Ray = wadray::rdiv_ww(total_yin, total_value);

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let g0_before_balance: Wad = y0
            .balance_of(*gates.at(0).contract_address)
            .try_into()
            .unwrap();
        let g1_before_balance: Wad = y1
            .balance_of(*gates.at(1).contract_address)
            .try_into()
            .unwrap();
        let y0_backing = wadray::wmul_wr(g0_before_balance, backing).into();
        let y1_backing = wadray::wmul_wr(g1_before_balance, backing).into();

        set_contract_address(CaretakerUtils::admin());
        caretaker.shut();

        // assert Shrine killed
        assert(!shrine.get_live(), 'shrine should be dead');

        // expecting the gates to have their original balance reduced by the amount needed to cover yin
        let g0_expected_balance: Wad = g0_before_balance - y0_backing;
        let g1_expected_balance: Wad = g1_before_balance - y1_backing;
        let tolerance: Wad = 10_u128.into();

        // assert gates have their balance reduced
        let g0_after_balance: Wad = y0
            .balance_of(*gates.at(0).contract_address)
            .try_into()
            .unwrap();
        let g1_after_balance: Wad = y1
            .balance_of(*gates.at(1).contract_address)
            .try_into()
            .unwrap();
        common::assert_equalish(
            g0_after_balance, g0_after_balance, tolerance, 'gate 0 balance after shut'
        );
        common::assert_equalish(
            g1_after_balance, g1_after_balance, tolerance, 'gate 1 balance after shut'
        );

        // assert the balance diff is now in the hands of the Caretaker
        let caretaker_y0_balance: Wad = y0
            .balance_of(caretaker.contract_address)
            .try_into()
            .unwrap();
        let caretaker_y1_balance: Wad = y1
            .balance_of(caretaker.contract_address)
            .try_into()
            .unwrap();
        common::assert_equalish(
            caretaker_y0_balance, y0_backing, tolerance, 'caretaker yang0 balance'
        );
        common::assert_equalish(
            caretaker_y1_balance, y1_backing, tolerance, 'caretaker yang1 balance'
        );
    }

    #[test]
    #[available_gas(100000000)]
    fn test_release() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) =
            CaretakerUtils::caretaker_deploy();

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_deposit_amts = AbbotUtils::open_trove_yang_asset_amts();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, AbbotUtils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot, user1, yangs, trove1_deposit_amts, gates, trove1_forge_amt
        );

        // user 2 with 100 yin and 1 yang
        let user2 = common::trove2_owner_addr();
        let trove2_forge_amt: Wad = (1000 * WAD_ONE).into();
        common::fund_user(user2, yangs, AbbotUtils::initial_asset_amts());
        let (eth_yang, eth_gate, eth_yang_amt) = CaretakerUtils::only_eth(yangs, gates);
        let trove2_id = common::open_trove_helper(
            abbot, user2, eth_yang, eth_yang_amt, eth_gate, trove2_forge_amt
        );

        let total_yin: Wad = trove1_forge_amt + trove2_forge_amt;
        let (_, total_value) = shrine.get_shrine_threshold_and_value();
        let backing: Ray = wadray::rdiv_ww(total_yin, total_value);

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let user1_yang0_before_balance: u256 = y0.balance_of(user1);
        let user1_yang1_before_balance: u256 = y1.balance_of(user1);
        let trove1_yang0_deposit: Wad = shrine.get_deposit(*yangs[0], trove1_id);
        let trove1_yang1_deposit: Wad = shrine.get_deposit(*yangs[1], trove1_id);

        set_contract_address(CaretakerUtils::admin());
        caretaker.shut();

        set_contract_address(user1);
        let released_assets: Span<AssetBalance> = caretaker.release(trove1_id);

        let user1_yang0_after_balance: u256 = y0.balance_of(user1);
        let user1_yang1_after_balance: u256 = y1.balance_of(user1);

        // assert released amount for eth
        let eth_tolerance: Wad = 10_u128.into(); // 10 wei
        let expected_release_y0: Wad = trove1_yang0_deposit
            - wadray::rmul_rw(backing, trove1_yang0_deposit);
        common::assert_equalish(
            (*released_assets.at(0).amount).into(), expected_release_y0, eth_tolerance, 'y0 release'
        );

        // assert released amount for wbtc (need to deal w/ different decimals)
        let wbtc_tolerance: Wad = (2 * 10000000000_u128).into(); // 2 satoshi
        let wbtc_deposit: Wad = wadray::fixed_point_to_wad(
            *trove1_deposit_amts[1], common::WBTC_DECIMALS
        );
        let expected_release_y1: Wad = wbtc_deposit
            - wadray::rmul_rw(backing, trove1_yang1_deposit);
        let actual_release_y1: Wad = wadray::fixed_point_to_wad(
            *released_assets.at(1).amount, common::WBTC_DECIMALS
        );
        common::assert_equalish(
            actual_release_y1, expected_release_y1, wbtc_tolerance, 'y1 release'
        );

        // assert all deposits were released and assets are back in user's account
        assert(*released_assets.at(0).address == *yangs[0], 'yang 1 not released #1');
        assert(*released_assets.at(1).address == *yangs[1], 'yang 2 not released #1');
        assert(
            user1_yang0_after_balance == user1_yang0_before_balance
                + (*released_assets.at(0).amount).into(),
            'user1 yang0 after balance'
        );
        assert(
            user1_yang1_after_balance == user1_yang1_before_balance
                + (*released_assets.at(1).amount).into(),
            'user1 yang1 after balance'
        );

        // assert nothing's left in the shrine for the released trove
        assert(shrine.get_deposit(*yangs[0], trove1_id).is_zero(), 'trove1 yang0 deposit');
        assert(shrine.get_deposit(*yangs[1], trove1_id).is_zero(), 'trove1 yang1 deposit');

        // sanity check that for user with only one yang, release reports a 0 asset amount
        set_contract_address(user2);
        let released_assets: Span<AssetBalance> = caretaker.release(trove2_id);
        assert(*released_assets.at(0).address == *yangs[0], 'yang 1 not released #2');
        assert(*released_assets.at(1).address == *yangs[1], 'yang 2 not released #2');
        assert((*released_assets.at(1).amount).is_zero(), 'incorrect release');
    }

    #[test]
    #[available_gas(100000000)]
    fn test_reclaim() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) =
            CaretakerUtils::caretaker_deploy();

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, AbbotUtils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot, user1, yangs, AbbotUtils::open_trove_yang_asset_amts(), gates, trove1_forge_amt
        );

        // transfer some yin from user1 elsewhere
        // => user1 got scammed, poor guy
        let scammer = common::badguy();
        let scam_amt: u256 = (4000 * WAD_ONE).into();
        set_contract_address(user1);
        IERC20Dispatcher { contract_address: shrine.contract_address }.transfer(scammer, scam_amt);

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let user1_yang0_before_balance: u256 = y0.balance_of(user1);
        let user1_yang1_before_balance: u256 = y1.balance_of(user1);
        let scammer_yang0_before_balance: u256 = y0.balance_of(scammer);
        let scammer_yang1_before_balance: u256 = y1.balance_of(scammer);

        set_contract_address(CaretakerUtils::admin());
        caretaker.shut();

        //
        // user1 reclaim
        //

        // save Caretaker yang balance after shut but before reclaim
        let ct_yang0_before_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_before_balance: u256 = y1.balance_of(caretaker.contract_address);

        // do the reclaiming
        set_contract_address(user1);
        let reclaimed_assets: Span<AssetBalance> = caretaker.reclaim(shrine.get_yin(user1));

        // assert none of user's yin is left
        assert(shrine.get_yin(user1).is_zero(), 'user yin balance');
        // assert scammer still has theirs
        assert(shrine.get_yin(scammer) == scam_amt.try_into().unwrap(), 'scammer yin balance 1');

        let ct_yang0_after_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_after_balance: u256 = y1.balance_of(caretaker.contract_address);
        let user1_yang0_after_balance: u256 = y0.balance_of(user1);
        let user1_yang1_after_balance: u256 = y1.balance_of(user1);

        // assert yangs have been transfered from Caretaker to user
        let ct_yang0_diff = ct_yang0_before_balance - ct_yang0_after_balance;
        let ct_yang1_diff = ct_yang1_before_balance - ct_yang1_after_balance;
        let user1_yang0_diff = user1_yang0_after_balance - user1_yang0_before_balance;
        let user1_yang1_diff = user1_yang1_after_balance - user1_yang1_before_balance;

        assert(ct_yang0_diff == user1_yang0_diff, 'user1 yang0 diff');
        assert(ct_yang1_diff == user1_yang1_diff, 'user1 yang1 diff');
        assert(ct_yang0_diff == (*reclaimed_assets.at(0).amount).into(), 'user1 reclaimed yang0');
        assert(ct_yang1_diff == (*reclaimed_assets.at(1).amount).into(), 'user1 reclaimed yang1');

        //
        // scammer reclaim
        //

        let tolerance: Wad = 10_u128.into();

        // save Caretaker yang balance after first reclaim but before the second
        let ct_yang0_before_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_before_balance: u256 = y1.balance_of(caretaker.contract_address);

        // do the reclaiming
        set_contract_address(scammer);
        let reclaimed_assets: Span<AssetBalance> = caretaker.reclaim(shrine.get_yin(scammer));

        // assert all yin has been reclaimed
        assert(shrine.get_yin(scammer).is_zero(), 'scammer yin balance 2');

        let ct_yang0_after_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_after_balance: u256 = y1.balance_of(caretaker.contract_address);
        let scammer_yang0_after_balance: u256 = y0.balance_of(scammer);
        let scammer_yang1_after_balance: u256 = y1.balance_of(scammer);

        let ct_yang0_diff: Wad = (ct_yang0_before_balance - ct_yang0_after_balance)
            .try_into()
            .unwrap();
        let ct_yang1_diff: Wad = (ct_yang1_before_balance - ct_yang1_after_balance)
            .try_into()
            .unwrap();
        let scammer_yang0_diff: Wad = (scammer_yang0_after_balance - scammer_yang0_before_balance)
            .try_into()
            .unwrap();
        let scammer_yang1_diff: Wad = (scammer_yang1_after_balance - scammer_yang1_before_balance)
            .try_into()
            .unwrap();

        common::assert_equalish(ct_yang0_diff, scammer_yang0_diff, tolerance, 'scammer yang0 diff');
        common::assert_equalish(ct_yang1_diff, scammer_yang1_diff, tolerance, 'scammer yang1 diff');
        common::assert_equalish(
            ct_yang0_diff,
            (*reclaimed_assets.at(0).amount).into(),
            tolerance,
            'scammer reclaimed yang0'
        );
        common::assert_equalish(
            ct_yang1_diff,
            (*reclaimed_assets.at(1).amount).into(),
            tolerance,
            'scammer reclaimed yang1'
        );
    }

    #[test]
    #[available_gas(100000000)]
    fn test_shut_during_armageddon() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) =
            CaretakerUtils::caretaker_deploy();

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, AbbotUtils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot, user1, yangs, AbbotUtils::open_trove_yang_asset_amts(), gates, trove1_forge_amt
        );

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let gate0_before_balance: Wad = y0
            .balance_of(*gates.at(0).contract_address)
            .try_into()
            .unwrap();
        let gate1_before_balance: Wad = y1
            .balance_of(*gates.at(1).contract_address)
            .try_into()
            .unwrap();

        // manipulate prices to be waaaay below start price to force
        // all yang deposits to be used to back yin
        ShrineUtils::make_root(shrine.contract_address, CaretakerUtils::admin());
        set_contract_address(CaretakerUtils::admin());
        let new_eth_price: Wad = (50 * WAD_ONE).into();
        let new_wbtc_price: Wad = (20 * WAD_ONE).into();
        shrine.advance(*yangs[0], new_eth_price);
        shrine.advance(*yangs[1], new_wbtc_price);

        caretaker.shut();

        let tolerance: Wad = 1_u128.into();

        // assert nothing's left in the gates and everything is now owned by Caretaker
        let gate0_after_balance: Wad = y0
            .balance_of(*gates.at(0).contract_address)
            .try_into()
            .unwrap();
        let gate1_after_balance: Wad = y1
            .balance_of(*gates.at(1).contract_address)
            .try_into()
            .unwrap();
        let ct_yang0_balance: Wad = y0.balance_of(caretaker.contract_address).try_into().unwrap();
        let ct_yang1_balance: Wad = y1.balance_of(caretaker.contract_address).try_into().unwrap();

        common::assert_equalish(
            gate0_after_balance, WadZeroable::zero(), tolerance, 'gate0 after balance'
        );
        common::assert_equalish(
            gate1_after_balance, WadZeroable::zero(), tolerance, 'gate1 after balance'
        );
        common::assert_equalish(
            ct_yang0_balance, gate0_before_balance, tolerance, 'caretaker yang0 after balance'
        );
        common::assert_equalish(
            ct_yang1_balance, gate1_before_balance, tolerance, 'caretaker yang1 after balance'
        );

        // calling release still works, but nothing gets released
        set_contract_address(user1);
        let released_assets: Span<AssetBalance> = caretaker.release(trove1_id);

        // 0 released amounts also mean no `sentinel.exit` and `shrine.seize`
        assert((*released_assets.at(0).amount).is_zero(), 'incorrect armageddon release 1');
        assert((*released_assets.at(1).amount).is_zero(), 'incorrect armageddon release 2')
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_release_when_system_live_reverts() {
        let (caretaker, _, _, _, _, _) = CaretakerUtils::caretaker_deploy();
        set_contract_address(CaretakerUtils::admin());
        caretaker.release(1);
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: Not trove owner', 'ENTRYPOINT_FAILED'))]
    fn test_release_foreign_trove_reverts() {
        let (caretaker, _, _, _, _, _) = CaretakerUtils::caretaker_deploy();
        set_contract_address(CaretakerUtils::admin());
        caretaker.shut();
        caretaker.release(1);
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_reclaim_when_system_live_reverts() {
        let (caretaker, _, _, _, _, _) = CaretakerUtils::caretaker_deploy();
        set_contract_address(CaretakerUtils::admin());
        caretaker.reclaim(WAD_ONE.into());
    }
}
