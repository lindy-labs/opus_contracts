mod gate_utils {
    use debug::PrintTrait;
    use integer::BoundedInt;
    use opus::core::gate::gate as gate_contract;
    use opus::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::erc20_mintable::ERC20;
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::wadray::{Ray, Wad, WadZeroable};
    use opus::utils::wadray;

    use snforge_std::{
        declare, ContractClassTrait, start_prank, stop_prank, start_warp, CheatTarget
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252};

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
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let calldata: Array<felt252> = array![
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(token),
            contract_address_to_felt252(sentinel),
        ];

        let gate_class = declare('gate');
        gate_class.deploy(@calldata).expect('gate deploy failed')
    }

    fn eth_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = shrine_utils::shrine_deploy(Option::None);
        let eth: ContractAddress = eth_token_deploy();
        let gate: ContractAddress = gate_deploy(eth, shrine, mock_sentinel());
        (shrine, eth, gate)
    }

    fn wbtc_gate_deploy() -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = shrine_utils::shrine_deploy(Option::None);
        let wbtc: ContractAddress = wbtc_token_deploy();
        let gate: ContractAddress = gate_deploy(wbtc, shrine, mock_sentinel());
        (shrine, wbtc, gate)
    }

    fn add_eth_as_yang(shrine: ContractAddress, eth: ContractAddress) {
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
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
        stop_prank(CheatTarget::All);
    }

    fn add_wbtc_as_yang(shrine: ContractAddress, wbtc: ContractAddress) {
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
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
        stop_prank(CheatTarget::All);
    }

    fn approve_gate_for_token(
        gate: ContractAddress, token: ContractAddress, user: ContractAddress
    ) {
        // user no-limit approves gate to handle their share of token
        start_prank(CheatTarget::One(token), user);
        IERC20Dispatcher { contract_address: token }.approve(gate, BoundedInt::max());
        stop_prank(CheatTarget::All);
    }

    fn rebase(gate: ContractAddress, token: ContractAddress, amount: u128) {
        IMintableDispatcher { contract_address: token }.mint(gate, amount.into());
    }
}
