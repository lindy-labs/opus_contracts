mod GateUtils {
    use array::{ArrayTrait, SpanTrait};
    use integer::BoundedInt;
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

    const ETH_TOTAL: u128 = 100000000000000000000; // 100 * 10**18

    const WBTC_TOTAL: u128 = 30000000000000000000; // 30 * 10**18

    //
    // Address constants
    //

    fn sentinel() -> ContractAddress {
        contract_address_const::<0x1234>()
    }

    fn eth_hoarder() -> ContractAddress {
        contract_address_const::<0xeee>()
    }

    fn wbtc_hoarder() -> ContractAddress {
        contract_address_const::<0xb1c>()
    }


    //
    // Test setup helpers
    //

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

    fn wbtc_token_deploy() -> ContractAddress {
        let mut calldata = Default::default();
        calldata.append('Bitcoin');
        calldata.append('WBTC');
        calldata.append(8);
        calldata.append(WBTC_TOTAL.into()); // u256.low
        calldata.append(0); // u256.high
        calldata.append(contract_address_to_felt252(wbtc_hoarder()));

        let token: ClassHash = class_hash_try_from_felt252(ERC20::TEST_CLASS_HASH).unwrap();
        let (token, _) = deploy_syscall(token, 0, calldata.span(), false).unwrap_syscall();

        // sanity check
        assert(IERC20Dispatcher { contract_address: token }.total_supply() == u256 { low: WBTC_TOTAL, high: 0 }, 'wrong ETH supply');

        token
    }

    fn eth_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        set_block_timestamp(DEPLOYMENT_TIMESTAMP);

        let shrine = ShrineUtils::shrine_deploy();
        let eth = eth_token_deploy();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine));
        calldata.append(contract_address_to_felt252(eth));
        // TODO: replace w/ a real deployed Sentinel later on
        calldata.append(contract_address_to_felt252(sentinel()));

        let gate_class_hash: ClassHash = class_hash_try_from_felt252(Gate::TEST_CLASS_HASH).unwrap();
        let (gate, _) = deploy_syscall(gate_class_hash, 0, calldata.span(), false).unwrap_syscall();

        (shrine, eth, gate)
    }

    fn wbtc_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        set_block_timestamp(DEPLOYMENT_TIMESTAMP);

        let shrine = ShrineUtils::shrine_deploy();
        let wbtc = wbtc_token_deploy();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine));
        calldata.append(contract_address_to_felt252(wbtc));
        // TODO: replace w/ a real deployed Sentinel later on
        calldata.append(contract_address_to_felt252(sentinel()));

        let gate_class_hash: ClassHash = class_hash_try_from_felt252(Gate::TEST_CLASS_HASH).unwrap();
        let (gate, _) = deploy_syscall(gate_class_hash, 0, calldata.span(), false).unwrap_syscall();

        (shrine, wbtc, gate)
    }

    fn add_eth_as_yang(shrine: ContractAddress, eth: ContractAddress) {
        // TODO: eventually do add_yang via a fn in ShrineUtils
        //       but one that takes `eth` as input, for we need a "real mock"
        //       contract deployed for the tests to run
        set_contract_address(ShrineUtils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine.add_yang(
            eth,
            ShrineUtils::YANG1_THRESHOLD.into(),
            ShrineUtils::YANG1_START_PRICE.into(),
            ShrineUtils::YANG1_BASE_RATE.into(),
            0_u128.into() // initial amount
        );
        shrine.set_debt_ceiling(ShrineUtils::DEBT_CEILING.into());
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn add_wbtc_as_yang(shrine: ContractAddress, wbtc: ContractAddress) {
        // TODO: eventually do add_yang via a fn in ShrineUtils
        //       but one that takes `wbtc` as input, for we need a "real mock"
        //       contract deployed for the tests to run
        set_contract_address(ShrineUtils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine.add_yang(
            wbtc,
            ShrineUtils::YANG2_THRESHOLD.into(),
            ShrineUtils::YANG2_START_PRICE.into(),
            ShrineUtils::YANG2_BASE_RATE.into(),
            0_u128.into() // initial amount
        );
        shrine.set_debt_ceiling(ShrineUtils::DEBT_CEILING.into());
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn approve_gate_to_user_token(gate: ContractAddress, user: ContractAddress, token: ContractAddress) {
        // user no-limit approves gate to handle their share of token
        set_contract_address(user);
        IERC20Dispatcher { contract_address: token }.approve(gate, BoundedInt::max());
        set_contract_address(contract_address_const::<0>());
    }

    fn rebase(gate: ContractAddress, amount: u128) {
        
    }
}
