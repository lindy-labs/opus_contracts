mod GateUtils {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const, contract_address_to_felt252, deploy_syscall, SyscallResultTrait};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use traits::{Default, Into};

    use aura::core::gate::Gate;
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad};

    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::erc20::ERC20;

    //
    // Constants
    //

    // Arbitrary timestamp set to approximately 18 May 2023, 7:55:28am UTC
    const DEPLOYMENT_TIMESTAMP: u64 = 1684390000_u64;

    const ETH_TOTAL: u128 = 100000000000;

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_const::<0x1337>()
    }

    // fn asset() -> ContractAddress {
    //     contract_address_const::<0xaa00>()
    // }

    fn sentinel() -> ContractAddress {
        contract_address_const::<0x1234>()
    }

    fn eth_hoarder() -> ContractAddress {
        contract_address_const::<0xeee>()
    }

    //
    // Test setup helpers
    //

    use debug::PrintTrait;

    fn eth_token_deploy() -> ContractAddress {
        let mut calldata = Default::default();
        calldata.append('Ether');
        calldata.append('ETH');
        calldata.append(18);
        calldata.append(ETH_TOTAL.into()); // u256.low
        calldata.append(0); // u256.high
        calldata.append(contract_address_to_felt252(eth_hoarder()));

        let token: ClassHash = class_hash_try_from_felt252(ERC20::TEST_CLASS_HASH).unwrap();
        let (token, _) = deploy_syscall(token, 0, calldata.span(), false).unwrap_syscall();

        // sanity check
        assert(IERC20Dispatcher { contract_address: token }.total_supply() == u256 { low: ETH_TOTAL, high: 0 }, 'wrong ETH supply');

        token
    }

    fn eth_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        set_block_timestamp(DEPLOYMENT_TIMESTAMP);

        let shrine = ShrineUtils::shrine_deploy();
        let eth = eth_token_deploy();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine));
        calldata.append(contract_address_to_felt252(eth));
        calldata.append(contract_address_to_felt252(sentinel()));

        let gate_class_hash: ClassHash = class_hash_try_from_felt252(Gate::TEST_CLASS_HASH).unwrap();
        let (gate, _) = deploy_syscall(gate_class_hash, 0, calldata.span(), false).unwrap_syscall();

        (shrine, eth, gate)
    }

    fn add_eth_as_yang(shrine: ContractAddress, eth: ContractAddress) {
        set_contract_address(ShrineUtils::admin());
        IShrineDispatcher { contract_address: shrine }.add_yang(
            eth,
            ShrineUtils::YANG1_THRESHOLD.into(),
            ShrineUtils::YANG1_START_PRICE.into(),
            ShrineUtils::YANG1_BASE_RATE.into(),
            0_u128.into() // initial amount
        );
        set_contract_address(ContractAddressZeroable::zero());
    }

}
