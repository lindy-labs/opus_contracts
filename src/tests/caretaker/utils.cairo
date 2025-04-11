pub mod caretaker_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::core::caretaker::caretaker as caretaker_contract;
    use opus::core::roles::{sentinel_roles, shrine_roles};
    use opus::interfaces::IAbbot::IAbbotDispatcher;
    use opus::interfaces::ICaretaker::ICaretakerDispatcher;
    use opus::interfaces::IGate::IGateDispatcher;
    use opus::interfaces::ISentinel::ISentinelDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::tests::abbot::utils::abbot_utils;
    use opus::tests::equalizer::utils::equalizer_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{
        CheatTarget, ContractClass, ContractClassTrait, declare, start_cheat_block_timestamp_global,
        start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::ContractAddress;

    #[derive(Copy, Drop)]
    pub struct CaretakerTestConfig {
        pub abbot: IAbbotDispatcher,
        pub caretaker: ICaretakerDispatcher,
        pub sentinel: ISentinelDispatcher,
        pub shrine: IShrineDispatcher,
        pub yangs: Span<ContractAddress>,
        pub gates: Span<IGateDispatcher>,
    }

    pub fn admin() -> ContractAddress {
        'caretaker admin'.try_into().unwrap()
    }

    pub fn caretaker_deploy() -> CaretakerTestConfig {
        start_cheat_block_timestamp_global(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let abbot_utils::AbbotTestConfig {
            shrine, sentinel, abbot, yangs, gates,
        } = abbot_utils::abbot_deploy(Option::None);
        let equalizer_utils::EqualizerTestConfig {
            shrine, equalizer, ..,
        } = equalizer_utils::equalizer_deploy_with_shrine(shrine.contract_address, Option::None);

        let calldata: Array<felt252> = array![
            admin().into(),
            shrine.contract_address.into(),
            abbot.contract_address.into(),
            sentinel.contract_address.into(),
            equalizer.contract_address.into(),
        ];

        let caretaker_class = declare("caretaker").unwrap().contract_class();
        let (caretaker, _) = caretaker_class.deploy(@calldata).expect('caretaker deploy failed');

        // allow Caretaker to do its business with Shrine
        start_cheat_caller_address(shrine.contract_address, shrine_utils::admin());
        IAccessControlDispatcher { contract_address: shrine.contract_address }
            .grant_role(shrine_roles::caretaker(), caretaker);

        // allow Caretaker to call exit in Sentinel during shut
        start_cheat_caller_address(sentinel.contract_address, sentinel_utils::admin());
        IAccessControlDispatcher { contract_address: sentinel.contract_address }
            .grant_role(sentinel_roles::caretaker(), caretaker);

        stop_cheat_caller_address(CheatTarget::Multiple(array![shrine.contract_address, sentinel.contract_address]));

        let caretaker = ICaretakerDispatcher { contract_address: caretaker };

        CaretakerTestConfig { caretaker, shrine, abbot, sentinel, yangs, gates }
    }

    pub fn only_eth(
        yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>,
    ) -> (Span<ContractAddress>, Span<IGateDispatcher>, Span<u128>) {
        let mut eth_yang = array![*yangs[0]];
        let mut eth_gate = array![*gates[0]];
        let mut eth_amount = array![abbot_utils::ETH_DEPOSIT_AMT];

        (eth_yang.span(), eth_gate.span(), eth_amount.span())
    }
}
