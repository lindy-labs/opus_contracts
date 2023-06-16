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
    use traits::{Default, Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::roles::{CaretakerRoles, ShrineRoles};

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::ICaretaker::{ICaretakerDispatcher, ICaretakerDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{WAD_ONE, Ray, Wad};

    use aura::tests::abbot::utils::AbbotUtils;
    use aura::tests::caretaker::utils::CaretakerUtils;
    use aura::tests::common;
    use aura::tests::shrine::utils::ShrineUtils;


    #[test]
    #[available_gas(100000000)]
    fn test_caretaker_setup() {
        let (caretaker, shrine, _, _, _, _) = CaretakerUtils::caretaker_deploy();

        let caretaker_ac = IAccessControlDispatcher { contract_address: caretaker.contract_address };

        assert(caretaker_ac.get_admin() == CaretakerUtils::admin(), 'setup admin');
        assert(
            caretaker_ac.get_roles(CaretakerUtils::admin()) == CaretakerRoles::SHUT, 'admin roles'
        );

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        assert(shrine_ac.has_role(ShrineRoles::KILL, caretaker.contract_address), 'caretaker cant kill shrine');
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
        set_contract_address(CaretakerUtils::badguy());
        caretaker.shut();
    }

    #[test]
    #[available_gas(100000000)]
    fn test_shut() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) = CaretakerUtils::caretaker_deploy();

        // user 1 with 950 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (950 * WAD_ONE).into();
        common::fund_user(user1, yangs, AbbotUtils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot,
            user1,
            yangs,
            AbbotUtils::open_trove_yang_asset_amts(),
            gates,
            trove1_forge_amt
        );

        // user 2 with 50 yin and 1 yang
        let user2 = common::trove2_owner_addr();
        let trove2_forge_amt: Wad = (50 * WAD_ONE).into();
        common::fund_user(user2, yangs, AbbotUtils::initial_asset_amts());
        let (eth_yang, eth_gate, eth_yang_amt) = CaretakerUtils::only_eth(yangs, gates);
        let trove2_id = common::open_trove_helper(
            abbot,
            user2,
            eth_yang,
            eth_yang_amt,
            eth_gate,
            trove2_forge_amt
        );

        let total_yin: Wad = trove1_forge_amt + trove2_forge_amt;
        let (_, total_value) = shrine.get_shrine_threshold_and_value();
        let backing: Ray = wadray::rdiv_ww(total_yin, total_value);

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let g0_before_balance: Wad = y0.balance_of(*gates[0].contract_address).try_into().unwrap();
        let g1_before_balance: Wad = y1.balance_of(*gates[1].contract_address).try_into().unwrap();
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
        let g0_after_balance: Wad = y0.balance_of(*gates[0].contract_address).try_into().unwrap();
        let g1_after_balance: Wad = y1.balance_of(*gates[1].contract_address).try_into().unwrap();
        common::assert_equalish(g0_after_balance, g0_after_balance, tolerance, 'gate 0 balance after shut');
        common::assert_equalish(g1_after_balance, g1_after_balance, tolerance, 'gate 1 balance after shut');

        // assert the balance diff is now in the hands of the Caretaker
        let caretaker_y0_balance: Wad = y0.balance_of(caretaker.contract_address).try_into().unwrap();
        let caretaker_y1_balance: Wad = y1.balance_of(caretaker.contract_address).try_into().unwrap();
        common::assert_equalish(caretaker_y0_balance, y0_backing, tolerance, 'caretaker yang0 balance');
        common::assert_equalish(caretaker_y1_balance, y1_backing, tolerance, 'caretaker yang1 balance');
    }

    #[test]
    #[available_gas(100000000)]
    fn test_release() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) = CaretakerUtils::caretaker_deploy();

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, AbbotUtils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot,
            user1,
            yangs,
            AbbotUtils::open_trove_yang_asset_amts(),
            gates,
            trove1_forge_amt
        );

        // user 2 with 100 yin and 1 yang
        let user2 = common::trove2_owner_addr();
        let trove2_forge_amt: Wad = (1000 * WAD_ONE).into();
        common::fund_user(user2, yangs, AbbotUtils::initial_asset_amts());
        let (eth_yang, eth_gate, eth_yang_amt) = CaretakerUtils::only_eth(yangs, gates);
        let trove2_id = common::open_trove_helper(
            abbot,
            user2,
            eth_yang,
            eth_yang_amt,
            eth_gate,
            trove2_forge_amt
        );

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let user1_yang0_before_balance: u256 = y0.balance_of(user1);
        let user1_yang1_before_balance: u256 = y1.balance_of(user1);

        set_contract_address(CaretakerUtils::admin());
        caretaker.shut();

        set_contract_address(user1);
        let (released_assets, released_amounts) = caretaker.release(trove1_id);

        let user1_yang0_after_balance: u256 = y0.balance_of(user1);
        let user1_yang1_after_balance: u256 = y1.balance_of(user1);

        // assert all deposits were released and assets are back in user's account
        assert(released_assets == yangs, 'not all yangs released 1');
        assert(user1_yang0_after_balance == user1_yang0_before_balance + (*released_amounts[0]).into(), 'user1 yang0 after balance');
        assert(user1_yang1_after_balance == user1_yang1_before_balance + (*released_amounts[1]).into(), 'user1 yang1 after balance');

        // assert nothing's left in the shrine for the released trove
        assert(shrine.get_deposit(*yangs[0], trove1_id) == 0_u128.into(), 'trove1 yang0 deposit');
        assert(shrine.get_deposit(*yangs[1], trove1_id) == 0_u128.into(), 'trove1 yang1 deposit');

        // sanity check that for user with only one yang, release reports a 0 asset amount
        set_contract_address(user2);
        let (released_assets, released_amounts) = caretaker.release(trove2_id);
        assert(released_assets == yangs, 'not all yangs released 2');
        assert(*released_amounts[1] == 0_u128, 'incorrect release');
    }

    #[test]
    #[available_gas(100000000)]
    fn test_reclaim() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) = CaretakerUtils::caretaker_deploy();

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, AbbotUtils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot,
            user1,
            yangs,
            AbbotUtils::open_trove_yang_asset_amts(),
            gates,
            trove1_forge_amt
        );

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };


        let user1_yang0_before_balance: u256 = y0.balance_of(user1);
        let user1_yang1_before_balance: u256 = y1.balance_of(user1);

        set_contract_address(CaretakerUtils::admin());
        caretaker.shut();

        // save Caretaker yang balance after shut but before reclaim
        let ct_yang0_before_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_before_balance: u256 = y1.balance_of(caretaker.contract_address);

        // reclaim all yin
        set_contract_address(user1);
        let (reclaimed_assets, reclaimed_amounts) = caretaker.reclaim(shrine.get_yin(user1));

        let ct_yang0_after_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_after_balance: u256 = y1.balance_of(caretaker.contract_address);
        let user1_yang0_after_balance: u256 = y0.balance_of(user1);
        let user1_yang1_after_balance: u256 = y1.balance_of(user1);

        // assert yangs have been transfered from Caretaker to user
        let ct_yang0_diff = ct_yang0_before_balance - ct_yang0_after_balance;
        let ct_yang1_diff = ct_yang1_before_balance - ct_yang1_after_balance;
        let user1_yang0_diff = user1_yang0_after_balance - user1_yang0_before_balance;
        let user1_yang1_diff = user1_yang1_after_balance - user1_yang1_before_balance;

        assert(ct_yang0_diff == user1_yang0_diff, 'yang0 diff');
        assert(ct_yang1_diff == user1_yang1_diff, 'yang1 diff');
        assert(ct_yang0_diff == (*reclaimed_amounts[0]).into(), 'reclaimed yang0');
        assert(ct_yang1_diff == (*reclaimed_amounts[1]).into(), 'reclaimed yang1');

        // assert none of user's yin is left
        assert(shrine.get_yin(user1) == 0_u128.into(), 'yin balance');
    }

    #[test]
    #[available_gas(100000000)]
    fn test_shut_during_armageddon() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) = CaretakerUtils::caretaker_deploy();

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, AbbotUtils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot,
            user1,
            yangs,
            AbbotUtils::open_trove_yang_asset_amts(),
            gates,
            trove1_forge_amt
        );

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let gate0_before_balance: Wad = y0.balance_of(*gates[0].contract_address).try_into().unwrap();
        let gate1_before_balance: Wad = y1.balance_of(*gates[1].contract_address).try_into().unwrap();

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
        let gate0_after_balance: Wad = y0.balance_of(*gates[0].contract_address).try_into().unwrap();
        let gate1_after_balance: Wad = y1.balance_of(*gates[1].contract_address).try_into().unwrap();
        let ct_yang0_balance: Wad = y0.balance_of(caretaker.contract_address).try_into().unwrap();
        let ct_yang1_balance: Wad = y1.balance_of(caretaker.contract_address).try_into().unwrap();

        common::assert_equalish(gate0_after_balance, 0_u128.into(), tolerance, 'gate0 after balance');
        common::assert_equalish(gate1_after_balance, 0_u128.into(), tolerance, 'gate1 after balance');
        common::assert_equalish(ct_yang0_balance, gate0_before_balance, tolerance, 'caretaker yang0 after balance');
        common::assert_equalish(ct_yang1_balance, gate1_before_balance, tolerance, 'caretaker yang1 after balance');
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
