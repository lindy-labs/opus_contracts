mod GateUtils {
    use array::ArrayTrait;
    use debug::PrintTrait;
    use integer::BoundedInt;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        contract_address_try_from_felt252, deploy_syscall, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::gate::Gate;
    use aura::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WadZeroable};

    use aura::tests::common;
    use aura::tests::erc20::ERC20;
    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Constants
    //

    const ETH_TOTAL: u128 = 100000000000000000000; // 100 * 10**18

    const WBTC_TOTAL: u128 = 30000000000000000000; // 30 * 10**18

    const WBTC_SCALE: u128 = 100000000; // WBTC has 8 decimals, scale is 10**8

    //
    // Address constants
    //

    fn mock_sentinel() -> ContractAddress {
        contract_address_try_from_felt252('mock sentinel').unwrap()
    }

    fn eth_hoarder() -> ContractAddress {
        contract_address_try_from_felt252('eth hoarder').unwrap()
    }

    fn wbtc_hoarder() -> ContractAddress {
        contract_address_try_from_felt252('wbtc hoarder').unwrap()
    }


    //
    // Test setup helpers
    //

    fn eth_token_deploy() -> ContractAddress {
        common::deploy_token('Ether', 'ETH', 18, ETH_TOTAL.into(), eth_hoarder())
    }

    fn wbtc_token_deploy() -> ContractAddress {
        common::deploy_token('Bitcoin', 'WBTC', 8, WBTC_TOTAL.into(), wbtc_hoarder())
    }


    fn gate_deploy(
        token: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress
    ) -> ContractAddress {
        set_block_timestamp(ShrineUtils::DEPLOYMENT_TIMESTAMP);

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(token),
            contract_address_to_felt252(sentinel),
        ];

        let gate_class_hash: ClassHash = class_hash_try_from_felt252(Gate::TEST_CLASS_HASH)
            .unwrap();
        let (gate, _) = deploy_syscall(gate_class_hash, 0, calldata.span(), false).unwrap_syscall();

        gate
    }

    fn eth_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = ShrineUtils::shrine_deploy();
        let eth: ContractAddress = eth_token_deploy();
        let gate: ContractAddress = gate_deploy(eth, shrine, mock_sentinel());
        (shrine, eth, gate)
    }

    fn wbtc_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = ShrineUtils::shrine_deploy();
        let wbtc: ContractAddress = wbtc_token_deploy();
        let gate: ContractAddress = gate_deploy(wbtc, shrine, mock_sentinel());
        (shrine, wbtc, gate)
    }

    fn add_eth_as_yang(shrine: ContractAddress, eth: ContractAddress) {
        set_contract_address(ShrineUtils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine
            .add_yang(
                eth,
                ShrineUtils::YANG1_THRESHOLD.into(),
                ShrineUtils::YANG1_START_PRICE.into(),
                ShrineUtils::YANG1_BASE_RATE.into(),
                WadZeroable::zero() // initial amount
            );
        shrine.set_debt_ceiling(ShrineUtils::DEBT_CEILING.into());
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn add_wbtc_as_yang(shrine: ContractAddress, wbtc: ContractAddress) {
        set_contract_address(ShrineUtils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine
            .add_yang(
                wbtc,
                ShrineUtils::YANG2_THRESHOLD.into(),
                ShrineUtils::YANG2_START_PRICE.into(),
                ShrineUtils::YANG2_BASE_RATE.into(),
                WadZeroable::zero() // initial amount
            );
        shrine.set_debt_ceiling(ShrineUtils::DEBT_CEILING.into());
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn approve_gate_for_token(
        gate: ContractAddress, token: ContractAddress, user: ContractAddress
    ) {
        // user no-limit approves gate to handle their share of token
        set_contract_address(user);
        IERC20Dispatcher { contract_address: token }.approve(gate, BoundedInt::max());
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn rebase(gate: ContractAddress, token: ContractAddress, amount: u128) {
        IMintableDispatcher { contract_address: token }.mint(gate, amount.into());
    }
}
