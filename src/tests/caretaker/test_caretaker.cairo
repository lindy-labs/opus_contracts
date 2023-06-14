// TODO: shut working; shut working only once
//       various shut scenarios (?) - enough collateral, not enough collateral
//       release; release when system is live; release when not trove owner
//       reclaim; reclaim when system is live; reclaim not enough yin
#[cft(test)]
mod TestCaretaker {
    use array::SpanTrait;
    use starknet::{ContractAddress};
    use starknet::testing::set_contract_address;
    use traits::Into;

    use aura::core::roles::{CaretakerRoles, ShrineRoles};

    use aura::interfaces::ICaretaker::{ICaretakerDispatcher, ICaretakerDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{WAD_ONE, Wad};

    use aura::tests::caretaker::utils::CaretakerUtils;


    #[test]
    #[available_gas(100000000)]
    fn test_caretaker_setup() {
        let (caretaker, shrine, _, _) = CaretakerUtils::caretaker_deploy();

        let caretaker_ac = IAccessControlDispatcher { contract_address: caretaker };

        assert(caretaker_ac.get_admin() == CaretakerUtils::admin(), 'setup admin');
        assert(
            caretaker_ac.get_roles(CaretakerUtils::admin()) == CaretakerRoles::SHUT, 'admin roles'
        );

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        assert(shrine_ac.has_role(ShrineRoles::KILL, caretaker), 'caretaker cant kill shrine');
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_caretaker_setup_preview_release_throws() {
        let (caretaker, _, _, _) = CaretakerUtils::caretaker_deploy();
        ICaretakerDispatcher { contract_address: caretaker }.preview_release(1);
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_caretaker_setup_preview_reclaim_throws() {
        let (caretaker, _, _, _) = CaretakerUtils::caretaker_deploy();
        ICaretakerDispatcher { contract_address: caretaker }.preview_reclaim(WAD_ONE.into());
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('Caller missing role', 'ENTRYPOINT_FAILED'))]
    fn test_shut_by_badguy_throws() {
        let (caretaker, _, _, _) = CaretakerUtils::caretaker_deploy();
        set_contract_address(CaretakerUtils::badguy());
        ICaretakerDispatcher { contract_address: caretaker }.shut();
    }

    #[test]
    #[available_gas(100000000)]
    fn test_shut() {
        let (caretaker, _, _, _) = CaretakerUtils::caretaker_deploy();

            // add collateral to shrine, mint some yin


        set_contract_address(CaretakerUtils::admin());
        let caretaker = ICaretakerDispatcher { contract_address: caretaker };
        caretaker.shut();

        // assert Shrine killed

        // assert gates have 0 balance and all assets are owned by caretaker

        // assert some yang & asset ratios (which ones?)

    }
        // equalizer is already available
        // need a sentinel w/ added yangs - hence gates for each
        // need multiple troves w/ multiple tokens and owners

    // test cases
    // do shut then release for own trove
    //              release for other trove, should fail
    // do shut then reclaim partial of forged yin
    //              reclaim full yin
    //              reclaim more than has yin, should fail
    //
    // is there some combo of reclaim + release that can break shit?

    // need:
    //   a trove owner with 1 trove w/ multiple assets
    //   a trove owner with 1 trove w/ single asset
    //   an owner with forged yin to reclaim

}
