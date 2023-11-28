mod caretaker_utils {
    use debug::PrintTrait;
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
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};

    use snforge_std::{
        declare, ContractClass, ContractClassTrait, start_prank, start_warp, CheatTarget
    };
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_try_from_felt252,
        contract_address_to_felt252, deploy_syscall, SyscallResultTrait
    };

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('caretaker admin').unwrap()
    }

    // returns the addrs of caretaker, shrine, abbot, sentinel, [yangs addrs], [gate dispatchers]
    fn caretaker_deploy(
        abbot_class: Option<ContractClass>,
        sentinel_class: Option<ContractClass>,
        token_class: Option<ContractClass>,
        gate_class: Option<ContractClass>
    ) -> (
        ICaretakerDispatcher,
        IShrineDispatcher,
        IAbbotDispatcher,
        ISentinelDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>
    ) {
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let (shrine, sentinel, abbot, yangs, gates) = abbot_utils::abbot_deploy(
            abbot_class, sentinel_class, token_class, gate_class
        );
        let (shrine, equalizer, _allocator) = equalizer_utils::equalizer_deploy_with_shrine(
            shrine.contract_address
        );

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(shrine.contract_address),
            contract_address_to_felt252(abbot.contract_address),
            contract_address_to_felt252(sentinel.contract_address),
            contract_address_to_felt252(equalizer.contract_address),
        ];

        let caretaker_class_hash: ClassHash = class_hash_try_from_felt252(
            caretaker_contract::TEST_CLASS_HASH
        )
            .unwrap();
        let (caretaker, _) = deploy_syscall(caretaker_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        // allow Caretaker to do its business with Shrine
        start_prank(CheatTarget::All, shrine_utils::admin());
        IAccessControlDispatcher { contract_address: shrine.contract_address }
            .grant_role(shrine_roles::caretaker(), caretaker);

        // allow Caretaker to call exit in Sentinel during shut
        start_prank(CheatTarget::All, sentinel_utils::admin());
        IAccessControlDispatcher { contract_address: sentinel.contract_address }
            .grant_role(sentinel_roles::caretaker(), caretaker);

        let caretaker = ICaretakerDispatcher { contract_address: caretaker };

        (caretaker, shrine, abbot, sentinel, yangs, gates)
    }

    fn only_eth(
        yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>
    ) -> (Span<ContractAddress>, Span<IGateDispatcher>, Span<u128>) {
        let mut eth_yang = array![*yangs[0]];
        let mut eth_gate = array![*gates[0]];
        let mut eth_amount = array![abbot_utils::ETH_DEPOSIT_AMT];

        (eth_yang.span(), eth_gate.span(), eth_amount.span())
    }
}
