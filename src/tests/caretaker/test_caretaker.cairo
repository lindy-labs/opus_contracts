// TODO: auth functions
//       setup
//       preview release / reclaim after setup
//       shut working; shut working only once; badguy calling shut
//       release; release when system is live
//       reclaim; reclaim when system is live
#[cft(test)]
mod TestCaretaker {
    use array::SpanTrait;
    use traits::Into;

    use aura::utils::wadray;
    use aura::utils::wadray::{WAD_ONE, Wad};

    use aura::tests::caretaker::utils::CaretakerUtils;

    use aura::interfaces::ICaretaker::{ICaretakerDispatcher, ICaretakerDispatcherTrait};

    #[test]
    #[available_gas(100000000)]
    fn test_caretaker_setup() {
        let caretaker = ICaretakerDispatcher { contract_address: CaretakerUtils::caretaker_deploy() };

        assert(caretaker.get_live(), 'is_live');

        // let (release_yangs, release_amts) = caretaker.preview_release(1);
        // assert(release_yangs.len() == 0, 'preview_release yangs');
        // assert(release_amts.len() == 0, 'preview_release amts');

        // let (reclaim_yangs, reclaim_amts) = caretaker.preview_reclaim(WAD_ONE.into());
        // assert(reclaim_yangs.len() == 0, 'preview_reclaim yangs');
        // assert(reclaim_amts.len() == 0, 'preview_reclaim amts');
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_caretaker_setup_preview_release_throws() {
        ICaretakerDispatcher { contract_address: CaretakerUtils::caretaker_deploy() }.preview_release(1);
    }

    #[test]
    #[available_gas(100000000)]
    #[should_panic(expected: ('CA: System is live', 'ENTRYPOINT_FAILED'))]
    fn test_caretaker_setup_preview_reclaim_throws() {
        ICaretakerDispatcher { contract_address: CaretakerUtils::caretaker_deploy() }.preview_reclaim(WAD_ONE.into());
    }

}
