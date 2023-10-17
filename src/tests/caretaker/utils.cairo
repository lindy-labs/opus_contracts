mod CaretakerUtils {
    use debug::PrintTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_try_from_felt252,
        contract_address_to_felt252, deploy_syscall, SyscallResultTrait
    };
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use opus::core::caretaker::Caretaker;
    use opus::core::roles::{SentinelRoles, ShrineRoles};

    use opus::interfaces::IAbbot::IAbbotDispatcher;
    use opus::interfaces::ICaretaker::ICaretakerDispatcher;
    use opus::interfaces::IGate::IGateDispatcher;
    use opus::interfaces::ISentinel::ISentinelDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::utils::access_control_component::{
        IAccessControlDispatcher, IAccessControlDispatcherTrait
    };

    use opus::tests::abbot::utils::AbbotUtils;
    use opus::tests::equalizer::utils::EqualizerUtils;
    use opus::tests::sentinel::utils::SentinelUtils;
    use opus::tests::shrine::utils::ShrineUtils;

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('caretaker admin').unwrap()
    }

    // returns the addrs of caretaker, shrine, abbot, sentinel, [yangs addrs], [gate dispatchers]
    fn caretaker_deploy() -> (
        ICaretakerDispatcher,
        IShrineDispatcher,
        IAbbotDispatcher,
        ISentinelDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>
    ) {
        set_block_timestamp(ShrineUtils::DEPLOYMENT_TIMESTAMP);

        let (shrine, sentinel, abbot, yangs, gates) = AbbotUtils::abbot_deploy();
        let (shrine, equalizer, _allocator) = EqualizerUtils::equalizer_deploy_with_shrine(
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
            Caretaker::TEST_CLASS_HASH
        )
            .unwrap();
        let (caretaker, _) = deploy_syscall(caretaker_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        // allow Caretaker to do its business with Shrine
        set_contract_address(ShrineUtils::admin());
        IAccessControlDispatcher { contract_address: shrine.contract_address }
            .grant_role(ShrineRoles::caretaker(), caretaker);

        // allow Caretaker to call exit in Sentinel during shut
        set_contract_address(SentinelUtils::admin());
        IAccessControlDispatcher { contract_address: sentinel.contract_address }
            .grant_role(SentinelRoles::caretaker(), caretaker);

        let caretaker = ICaretakerDispatcher { contract_address: caretaker };

        (caretaker, shrine, abbot, sentinel, yangs, gates)
    }

    fn only_eth(
        yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>
    ) -> (Span<ContractAddress>, Span<IGateDispatcher>, Span<u128>) {
        let mut eth_yang = array![*yangs[0]];
        let mut eth_gate = array![*gates[0]];
        let mut eth_amount = array![AbbotUtils::ETH_DEPOSIT_AMT];

        (eth_yang.span(), eth_gate.span(), eth_amount.span())
    }
}
