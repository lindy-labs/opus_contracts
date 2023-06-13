mod CaretakerUtils {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const, contract_address_try_from_felt252,
        contract_address_to_felt252, deploy_syscall, SyscallResultTrait
    };
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use traits::Default;

    use aura::core::caretaker::Caretaker;
    use aura::core::roles::ShrineRoles;

    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};

    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::equalizer::utils::EqualizerUtils;

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('caretaker admin').unwrap()
    }
    fn badguy() -> ContractAddress {
        contract_address_try_from_felt252('caretaker bad guy').unwrap()
    }

    fn caretaker_deploy() -> (ContractAddress, ContractAddress, ContractAddress, ContractAddress) {
        set_block_timestamp(ShrineUtils::DEPLOYMENT_TIMESTAMP);

        let (shrine, equalizer, _) = EqualizerUtils::equalizer_deploy();
        let abbot = contract_address_const::<0xab0>();
        let sentinel = contract_address_const::<0xe771>(); // TODO: replace w/ real sentinel eventually

        let mut calldata: Array<felt252> = Default::default();
        calldata.append(contract_address_to_felt252(admin()));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(abbot)); // abbot
        calldata.append(contract_address_to_felt252(sentinel)); // sentinel
        calldata.append(contract_address_to_felt252(equalizer.contract_address));

        let caretaker_class_hash: ClassHash = class_hash_try_from_felt252(
            Caretaker::TEST_CLASS_HASH
        ).unwrap();
        let (caretaker, _) = deploy_syscall(caretaker_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        // allow Caretaker to kill Shrine
        set_contract_address(ShrineUtils::admin());
        IAccessControlDispatcher { contract_address: shrine.contract_address }.grant_role(ShrineRoles::KILL, caretaker);

        (caretaker, shrine.contract_address, abbot, sentinel)
    }
}
