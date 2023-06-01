mod EqualizerUtils {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Default, Into};
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, SyscallResultTrait
    };

    use aura::core::allocator::Allocator;
    use aura::core::roles::AllocatorRoles;

    use aura::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::utils::serde;
    use aura::utils::wadray;
    use aura::utils::wadray::Ray;

    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Constants
    //



    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_const::<0x1337>()
    }

    fn badguy() -> ContractAddress {
        contract_address_const::<0x42069>()
    }

    fn trove1_owner_addr() -> ContractAddress {
        contract_address_const::<0x0001>()
    }

    fn trove2_owner_addr() -> ContractAddress {
        contract_address_const::<0x0002>()
    }

    fn trove3_owner_addr() -> ContractAddress {
        contract_address_const::<0x0003>()
    }

    fn yin_user_addr() -> ContractAddress {
        contract_address_const::<0x0004>()
    }

    fn yang1_addr() -> ContractAddress {
        contract_address_const::<0x1234>()
    }

    fn yang2_addr() -> ContractAddress {
        contract_address_const::<0x2345>()
    }

    fn invalid_yang_addr() -> ContractAddress {
        contract_address_const::<0xabcd>()
    }

    //
    // Convenience helpers
    // 

    fn initial_recipients() -> Span<ContractAddress> {
        let mut recipients: Array<ContractAddress> = Default::default();
        recipients.append(contract_address_const::<0x12341234>());
        recipients.append(contract_address_const::<0x23412341>());
        recipients.append(contract_address_const::<0x34123412>());

        recipients.span()
    }

    fn new_recipients() -> Span<ContractAddress> {
        let mut recipients: Array<ContractAddress> = Default::default();
        recipients.append(contract_address_const::<0x34563456>());
        recipients.append(contract_address_const::<0x45634563>());
        recipients.append(contract_address_const::<0x56345634>());
        recipients.append(contract_address_const::<0x63456345>());

        recipients.span()
    }

    fn initial_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = Default::default();
        percentages.append(150000000000000000000000000_u128.into());  // 15% (Ray)
        percentages.append(500000000000000000000000000_u128.into());  // 50% (Ray)
        percentages.append(350000000000000000000000000_u128.into());  // 35% (Ray)

        percentages.span()
    }

    fn new_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = Default::default();
        percentages.append(125000000000000000000000000_u128.into());  // 12.5% (Ray)
        percentages.append(372500000000000000000000000_u128.into());  // 37.25% (Ray)
        percentages.append(216350000000000000000000000_u128.into());  // 21.635% (Ray)
        percentages.append(286150000000000000000000000_u128.into());  // 28.615% (Ray)

        percentages.span()
    }

    // Percentages do not add to 1
    fn invalid_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = Default::default();
        percentages.append(150000000000000000000000000_u128.into());  // 15% (Ray)
        percentages.append(500000000000000000000000000_u128.into());  // 50% (Ray)
        percentages.append(350000000000000000000000001_u128.into());  // (35 + 1E-27)% (Ray)

        percentages.span()
    }

    //
    // Test setup helpers
    //

    fn allocator_deploy(mut recipients: Span<ContractAddress>, mut percentages: Span<Ray>) -> IAllocatorDispatcher {
        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(ShrineUtils::admin()));

        calldata.append(recipients.len().into());
        loop {
            match recipients.pop_front() {
                Option::Some(recipient) => {
                    calldata.append(contract_address_to_felt252(*recipient));
                },
                Option::None(_) => {
                    break;
                }
            };
        };
        
        calldata.append(percentages.len().into());
        loop {
            match percentages.pop_front() {
                Option::Some(percentage) => {
                    let val: felt252 = (*percentage.val).into();
                    calldata.append(val);
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        let allocator_class_hash: ClassHash = class_hash_try_from_felt252(Allocator::TEST_CLASS_HASH)
            .unwrap();
        let (allocator_addr, _) = deploy_syscall(allocator_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        IAllocatorDispatcher { contract_address: allocator_addr }
    }
}
