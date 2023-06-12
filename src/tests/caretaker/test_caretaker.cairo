// TODO: shut working; shut working only once; badguy calling shut
//       release; release when system is live
//       reclaim; reclaim when system is live
#[cft(test)]
mod TestCaretaker {
    use array::SpanTrait;
    use starknet::{ContractAddress};
    use traits::Into;

    {CaretakerRoles, ShrineRoles};

    use aura::interfaces::ICaretaker::{ICaretakerDispatcher, ICaretakerDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{WAD_ONE, Wad};

    use aura::tests::caretaker::utils::CaretakerUtils;


    #[test]
    #[available_gas(100000000)]
    fn test_caretaker_setup() {
        let (caretaker, shrine) = CaretakerUtils::caretaker_deploy();

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
        let (caretaker, _) = CaretakerUtils::caretaker_deploy();
        ICaretakerDispatcher { contract_address: caretaker }.preview_release(1);
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_caretaker_setup_preview_reclaim_throws() {
        let (caretaker, _) = CaretakerUtils::caretaker_deploy();
        ICaretakerDispatcher { contract_address: caretaker }.preview_reclaim(WAD_ONE.into());
    }
}
