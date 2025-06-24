pub mod equalizer_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::{One, Zero};
    use opus::core::roles::{equalizer_roles, shrine_roles};
    use opus::interfaces::IAllocator::IAllocatorDispatcher;
    use opus::interfaces::IEqualizer::IEqualizerDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{
        ContractClass, ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::Ray;

    #[derive(Copy, Drop)]
    pub struct EqualizerTestConfig {
        pub allocator: IAllocatorDispatcher,
        pub equalizer: IEqualizerDispatcher,
        pub shrine: IShrineDispatcher,
    }

    //
    // Convenience helpers
    //

    pub fn initial_recipients() -> Span<ContractAddress> {
        array!['recipient 1'.try_into().unwrap(), 'recipient 2'.try_into().unwrap(), 'recipient 3'.try_into().unwrap()]
            .span()
    }

    pub fn new_recipients() -> Span<ContractAddress> {
        array![
            'new recipient 1'.try_into().unwrap(),
            'new recipient 2'.try_into().unwrap(),
            'new recipient 3'.try_into().unwrap(),
            'new recipient 4'.try_into().unwrap(),
        ]
            .span()
    }

    pub fn initial_percentages() -> Span<Ray> {
        array![
            150000000000000000000000000_u128.into(), // 15% (Ray)
            500000000000000000000000000_u128.into(), // 50% (Ray)
            350000000000000000000000000_u128.into() // 35% (Ray)
        ]
            .span()
    }

    pub fn new_percentages() -> Span<Ray> {
        array![
            125000000000000000000000000_u128.into(), // 12.5% (Ray)
            372500000000000000000000000_u128.into(), // 37.25% (Ray)
            216350000000000000000000000_u128.into(), // 21.635% (Ray)
            286150000000000000000000000_u128.into() // 28.615% (Ray)
        ]
            .span()
    }

    // Percentages do not add to 1
    pub fn invalid_percentages() -> Span<Ray> {
        array![
            150000000000000000000000000_u128.into(), // 15% (Ray)
            500000000000000000000000000_u128.into(), // 50% (Ray)
            350000000000000000000000001_u128.into() // (35 + 1E-27)% (Ray)
        ]
            .span()
    }

    //
    // Test setup helpers
    //

    pub fn allocator_deploy(
        mut recipients: Span<ContractAddress>, mut percentages: Span<Ray>, allocator_class: Option<ContractClass>,
    ) -> IAllocatorDispatcher {
        let mut calldata: Array<felt252> = array![shrine_utils::ADMIN.into(), recipients.len().into()];

        for recipient in recipients {
            calldata.append((*recipient).into());
        }

        calldata.append(percentages.len().into());
        for percentage in percentages {
            let val: u128 = (*percentage).into();
            calldata.append(val.into());
        }

        let allocator_class = match allocator_class {
            Option::Some(class) => class,
            Option::None => *declare("allocator").unwrap().contract_class(),
        };
        let (allocator_addr, _) = allocator_class.deploy(@calldata).expect('failed allocator deploy');

        IAllocatorDispatcher { contract_address: allocator_addr }
    }

    pub fn tcr_allocator_deploy(
        shrine: ContractAddress,
        absorber: ContractAddress,
        stabilizer: ContractAddress,
        tcr_allocator_class: Option<ContractClass>,
    ) -> IAllocatorDispatcher {
        let mut calldata: Array<felt252> = array![
            shrine.into(), shrine_utils::ADMIN.into(), absorber.into(), stabilizer.into(),
        ];

        let tcr_allocator_class = match tcr_allocator_class {
            Option::Some(class) => class,
            Option::None => *declare("tcr_allocator").unwrap().contract_class(),
        };
        let (tcr_allocator_addr, _) = tcr_allocator_class.deploy(@calldata).expect('failed tcr allocator deploy');

        IAllocatorDispatcher { contract_address: tcr_allocator_addr }
    }

    pub fn equalizer_deploy(allocator_class: Option<ContractClass>) -> EqualizerTestConfig {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        equalizer_deploy_with_shrine(shrine.contract_address, allocator_class)
    }

    pub fn equalizer_deploy_with_shrine(
        shrine: ContractAddress, allocator_class: Option<ContractClass>,
    ) -> EqualizerTestConfig {
        let allocator: IAllocatorDispatcher = allocator_deploy(
            initial_recipients(), initial_percentages(), allocator_class,
        );
        let admin = shrine_utils::ADMIN;

        let mut calldata: Array<felt252> = array![admin.into(), shrine.into(), allocator.contract_address.into()];

        let equalizer_class = declare("equalizer").unwrap().contract_class();
        let (equalizer_addr, _) = equalizer_class.deploy(@calldata).expect('failed equalizer deploy');

        let equalizer_ac: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: equalizer_addr };
        start_cheat_caller_address(equalizer_addr, admin);
        equalizer_ac.grant_role(equalizer_roles::ADMIN, admin);
        stop_cheat_caller_address(equalizer_addr);

        start_cheat_caller_address(shrine, admin);
        let shrine_ac: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine };
        shrine_ac.grant_role(shrine_roles::EQUALIZER, equalizer_addr);
        stop_cheat_caller_address(shrine);

        EqualizerTestConfig {
            shrine: IShrineDispatcher { contract_address: shrine },
            equalizer: IEqualizerDispatcher { contract_address: equalizer_addr },
            allocator,
        }
    }

    // Assertion helpers

    pub fn sums_to_one(percentages: Span<Ray>) {
        let mut sum: Ray = Zero::zero();
        for percentage in percentages {
            sum += *percentage;
        }
        assert!(sum.is_one(), "percentage sum not 100%");
    }
}
