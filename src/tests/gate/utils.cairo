mod gate_utils {
    use debug::PrintTrait;
    use integer::BoundedInt;
    use opus::core::gate::gate as gate_contract;
    use opus::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::erc20::ERC20;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::wadray::{Ray, Wad, WadZeroable};
    use opus::utils::wadray;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        contract_address_try_from_felt252, deploy_syscall, SyscallResultTrait
    };

    //
    // Address constants
    //

    fn mock_sentinel() -> ContractAddress {
        contract_address_try_from_felt252('mock sentinel').unwrap()
    }

    //
    // Test setup helpers
    //

    fn gate_deploy(token: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress) -> ContractAddress {
        set_block_timestamp(shrine_utils::DEPLOYMENT_TIMESTAMP);

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(token),
            contract_address_to_felt252(sentinel),
        ];

        let gate_class_hash: ClassHash = class_hash_try_from_felt252(gate_contract::TEST_CLASS_HASH).unwrap();
        let (gate, _) = deploy_syscall(gate_class_hash, 0, calldata.span(), false).unwrap_syscall();

        gate
    }

    fn eth_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = shrine_utils::shrine_deploy(Option::None);
        let eth: ContractAddress = common::eth_token_deploy();
        let gate: ContractAddress = gate_deploy(eth, shrine, mock_sentinel());
        (shrine, eth, gate)
    }

    fn wbtc_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = shrine_utils::shrine_deploy(Option::None);
        let wbtc: ContractAddress = common::wbtc_token_deploy();
        let gate: ContractAddress = gate_deploy(wbtc, shrine, mock_sentinel());
        (shrine, wbtc, gate)
    }

    fn add_eth_as_yang(shrine: ContractAddress, eth: ContractAddress) {
        set_contract_address(shrine_utils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine
            .add_yang(
                eth,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                WadZeroable::zero() // initial amount
            );
        shrine.set_debt_ceiling(shrine_utils::DEBT_CEILING.into());
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn add_wbtc_as_yang(shrine: ContractAddress, wbtc: ContractAddress) {
        set_contract_address(shrine_utils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine
            .add_yang(
                wbtc,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                WadZeroable::zero() // initial amount
            );
        shrine.set_debt_ceiling(shrine_utils::DEBT_CEILING.into());
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn approve_gate_for_token(gate: ContractAddress, token: ContractAddress, user: ContractAddress) {
        // user no-limit approves gate to handle their share of token
        set_contract_address(user);
        IERC20Dispatcher { contract_address: token }.approve(gate, BoundedInt::max());
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn rebase(gate: ContractAddress, token: ContractAddress, amount: u128) {
        IMintableDispatcher { contract_address: token }.mint(gate, amount.into());
    }
}
