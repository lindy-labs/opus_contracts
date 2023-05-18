#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252, SyscallResultTrait};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::wadray::{Ray, RAY_ONE, U128IntoRay, U128IntoWad, Wad, WAD_DECIMALS};

    // Arbitrary timestamp set to approximately 18 May 2023, 7:55:28am UTC
    const DEPLOYMENT_TIMESTAMP: u64 = 1684390000_u64;

    // Shrine ERC-20 constants
    const YIN_NAME: felt252 = 'Cash';
    const YIN_SYMBOL: felt252 = 'CASH';

    // Shrine constants
    const DEBT_CEILING: u128 = 20000000000000000000000;  // 20_000

    // Yang constants
    const YANG1_THRESHOLD: u128 = 800000000000000000000000000;  // 80%
    const YANG1_START_PRICE: u128 = 2000000000000000000000;  // 2_000
    const YANG1_BASE_RATE: u128 = 30000000000000000000000000;  // 2%

    const YANG2_THRESHOLD: u128 = 800000000000000000000000000;  // 80%
    const YANG2_START_PRICE: u128 = 500000000000000000000;  // 500
    const YANG2_BASE_RATE: u128 = 30000000000000000000000000;  // 3%

    const INITIAL_YANG_AMT: u128 = 0;

    //
    // Test setup
    //

    fn admin() -> ContractAddress {
        contract_address_const::<0x1337>()
    }

    fn yang1_addr() -> ContractAddress {
        contract_address_const::<0x1234>()
    }

    fn yang2_addr() -> ContractAddress {
        contract_address_const::<0x2345>()
    }

    fn yang_addrs() -> Span<ContractAddress> {
        let mut yang_addrs: Array<ContractAddress> = ArrayTrait::new();
        yang_addrs.append(yang1_addr());
        yang_addrs.append(yang2_addr());
        yang_addrs.span()
    }

    fn deploy_shrine() -> ContractAddress {
        set_block_timestamp(DEPLOYMENT_TIMESTAMP);

        let mut calldata = ArrayTrait::new();
        calldata.append(contract_address_to_felt252(admin()));
        calldata.append(YIN_NAME);
        calldata.append(YIN_SYMBOL);

        let shrine_class_hash: ClassHash = class_hash_try_from_felt252(Shrine::TEST_CLASS_HASH).unwrap();
        let (shrine_addr, _) = deploy_syscall(
            shrine_class_hash, 0, calldata.span(), false
        ).unwrap_syscall();

        shrine_addr
    }

    fn setup_shrine(shrine_addr: ContractAddress) {
        // Grant admin role
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine_addr };
        let admin: ContractAddress = admin();
        let admin_role: u128 = ShrineRoles::default_admin_role();
        set_contract_address(admin);
        shrine_accesscontrol.grant_role(admin_role, admin);
        
        // Set debt ceiling
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        shrine.set_ceiling(DEBT_CEILING.into());

        // Add yangs
        shrine.add_yang(yang1_addr(), YANG1_THRESHOLD.into(), YANG1_START_PRICE.into(), YANG1_BASE_RATE.into(), INITIAL_YANG_AMT.into());
        shrine.add_yang(yang2_addr(), YANG2_THRESHOLD.into(), YANG2_START_PRICE.into(), YANG2_BASE_RATE.into(), INITIAL_YANG_AMT.into());
    }

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_deploy() {
        let shrine_addr: ContractAddress = deploy_shrine();

        // Check ERC-20 getters
        let yin: IERC20Dispatcher = IERC20Dispatcher { contract_address: shrine_addr };
        assert(yin.name() == YIN_NAME, 'wrong name');
        assert(yin.symbol() == YIN_SYMBOL, 'wrong symbol');
        assert(yin.decimals() == WAD_DECIMALS, 'wrong decimals');

        // Check Shrine getters
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        assert(shrine.get_live(), 'not live');
        let (multiplier, _, _) = shrine.get_current_multiplier();
        assert(multiplier == RAY_ONE.into(), 'wrong multiplier');

        let admin: ContractAddress = admin();
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine_addr };
        assert(shrine_accesscontrol.get_admin() == admin, 'wrong admin');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_shrine_setup() {
        let shrine_addr: ContractAddress = deploy_shrine();
        setup_shrine(shrine_addr);

        // Check debt ceiling
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        assert(shrine.get_debt_ceiling() == DEBT_CEILING.into(), 'wrong debt ceiling');

        // Check yangs
        assert(shrine.get_yangs_count() == 2, 'wrong yangs count');

        let expected_era: u64 = 0;

        let yang1_addr: ContractAddress = yang1_addr();
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        assert(yang1_price == YANG1_START_PRICE.into(), 'wrong yang1 start price');
        assert(shrine.get_yang_threshold(yang1_addr) == YANG1_THRESHOLD.into(), 'wrong yang1 threshold');
        assert(shrine.get_yang_rate(yang1_addr, expected_era) == YANG1_BASE_RATE.into(), 'wrong yang1 base rate');

        let yang2_addr: ContractAddress = yang2_addr();
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        assert(yang2_price == YANG2_START_PRICE.into(), 'wrong yang2 start price');
        assert(shrine.get_yang_threshold(yang2_addr) == YANG2_THRESHOLD.into(), 'wrong yang2 threshold');
        assert(shrine.get_yang_rate(yang2_addr, expected_era) == YANG2_BASE_RATE.into(), 'wrong yang2 base rate');

        // Check shrine threshold and value
        let (threshold, value) = shrine.get_shrine_threshold_and_value();
        assert(threshold == 0_u128.into(), 'wrong shrine threshold');
        assert(value == 0_u128.into(), 'wrong shrine value');
    }

}
