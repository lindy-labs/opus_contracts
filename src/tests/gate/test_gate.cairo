// NOTE: no need to test access control in Gate because only Sentinel, as
//       declared in constructor args when deploying, can call the gate

mod test_gate {
    use core::num::traits::Zero;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::gate::utils::gate_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
    use starknet::ContractAddress;
    use wadray::{WAD_SCALE, Wad};

    #[test]
    fn test_eth_gate_deploy() {
        let (shrine, eth, gate) = gate_utils::eth_gate_deploy(Option::None);
        let gate = IGateDispatcher { contract_address: gate };

        assert(gate.get_shrine() == shrine, 'get_shrine');
        assert(gate.get_asset() == eth, 'get_asset');
        assert(gate.get_total_assets().is_zero(), 'get_total_assets');

        // need to add_yang for the next set of asserts
        gate_utils::add_eth_as_yang(shrine, eth);

        assert(gate.get_total_yang().is_zero(), 'get_total_yang');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
    }

    #[test]
    fn test_wbtc_gate_deploy() {
        // WBTC has different decimals (8) than ETH / opus (18)
        let (shrine, wbtc, gate) = gate_utils::wbtc_gate_deploy(Option::None);
        let gate = IGateDispatcher { contract_address: gate };

        assert(gate.get_shrine() == shrine, 'get_shrine');
        assert(gate.get_asset() == wbtc, 'get_asset');
        assert(gate.get_total_assets().is_zero(), 'get_total_assets');

        // need to add_yang for the next set of asserts
        gate_utils::add_wbtc_as_yang(shrine, wbtc);

        assert(gate.get_total_yang().is_zero(), 'get_total_yang');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
    }

    #[test]
    fn test_eth_gate_enter_pass() {
        let (shrine, eth, gate) = gate_utils::eth_gate_deploy(Option::None);
        gate_utils::add_eth_as_yang(shrine, eth);

        let user = common::ETH_HOARDER;
        gate_utils::approve_gate_for_token(gate, eth, user);

        let asset_amt = 20_u128 * WAD_SCALE;

        // a gate can only be called from a sentinel
        start_cheat_caller_address(gate, gate_utils::MOCK_SENTINEL);

        let gate = IGateDispatcher { contract_address: gate };
        let enter_yang_amt: Wad = gate.enter(user, asset_amt);

        let eth = IERC20Dispatcher { contract_address: eth };

        // check exchange rate and gate asset balance
        assert(enter_yang_amt.into() == asset_amt, 'enter amount');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
        assert(eth.balance_of(gate.contract_address) == asset_amt.into(), 'gate balance');
    }

    #[test]
    fn test_wbtc_gate_enter_pass() {
        let (shrine, wbtc, gate) = gate_utils::wbtc_gate_deploy(Option::None);

        gate_utils::add_wbtc_as_yang(shrine, wbtc);

        let user = common::WBTC_HOARDER;
        gate_utils::approve_gate_for_token(gate, wbtc, user);

        let asset_amt = 3_u128 * common::WBTC_SCALE;

        // a gate can only be called from a sentinel
        start_cheat_caller_address(gate, gate_utils::MOCK_SENTINEL);

        let gate = IGateDispatcher { contract_address: gate };
        let enter_yang_amt: Wad = gate.enter(user, asset_amt);

        let wbtc = IERC20Dispatcher { contract_address: wbtc };

        // check exchange rate and gate asset balance
        assert(enter_yang_amt.into() == asset_amt * (WAD_SCALE / common::WBTC_SCALE), 'enter amount');
        assert(gate.get_asset_amt_per_yang() == WAD_SCALE.into(), 'get_asset_amt_per_yang');
        assert(wbtc.balance_of(gate.contract_address) == asset_amt.into(), 'gate balance');
    }

    #[test]
    fn test_eth_gate_exit() {
        let (shrine, eth, gate) = gate_utils::eth_gate_deploy(Option::None);

        gate_utils::add_eth_as_yang(shrine, eth);

        let user = common::ETH_HOARDER;
        gate_utils::approve_gate_for_token(gate, eth, user);

        let eth = IERC20Dispatcher { contract_address: eth };

        let asset_amt = 10_u128 * WAD_SCALE;
        let exit_yang_amt: Wad = (2_u128 * WAD_SCALE).into();
        let remaining_yang_amt = 8_u128 * WAD_SCALE;

        // a gate can only be called from a sentinel
        start_cheat_caller_address(gate, gate_utils::MOCK_SENTINEL);

        let gate = IGateDispatcher { contract_address: gate };
        gate.enter(user, asset_amt);

        let exit_amt = gate.exit(user, exit_yang_amt);
        assert(exit_amt == exit_yang_amt.into(), 'exit amount');
        assert(gate.get_total_assets() == remaining_yang_amt, 'get_total_assets');
        assert(eth.balance_of(gate.contract_address) == remaining_yang_amt.into(), 'gate eth balance');
    }

    #[test]
    #[should_panic(expected: 'GA: Caller is not authorized')]
    fn test_gate_unauthorized_enter() {
        let (shrine, eth, gate) = gate_utils::eth_gate_deploy(Option::None);
        gate_utils::add_eth_as_yang(shrine, eth);
        IGateDispatcher { contract_address: gate }.enter(common::BAD_GUY, WAD_SCALE);
    }

    #[test]
    #[should_panic(expected: 'GA: Caller is not authorized')]
    fn test_gate_unauthorized_exit() {
        let (shrine, eth, gate) = gate_utils::eth_gate_deploy(Option::None);
        gate_utils::add_eth_as_yang(shrine, eth);
        IGateDispatcher { contract_address: gate }.exit(common::BAD_GUY, WAD_SCALE.into());
    }

    #[test]
    fn test_gate_multi_user_enter_exit_with_rebasing() {
        let (shrine, eth, gate) = gate_utils::eth_gate_deploy(Option::None);
        gate_utils::add_eth_as_yang(shrine, eth);

        let shrine = IShrineDispatcher { contract_address: shrine };
        let eth = IERC20Dispatcher { contract_address: eth };
        let gate = IGateDispatcher { contract_address: gate };

        let user1: ContractAddress = common::TROVE1_OWNER_ADDR;
        let trove1: u64 = common::TROVE_1;
        let enter1_amt = 50_u128 * WAD_SCALE;
        let enter2_amt = 30_u128 * WAD_SCALE;

        gate_utils::approve_gate_for_token(gate.contract_address, eth.contract_address, user1);

        // fund user1
        start_cheat_caller_address(eth.contract_address, common::ETH_HOARDER);
        eth.transfer(user1, (enter1_amt + enter2_amt).into());
        stop_cheat_caller_address(eth.contract_address);
        //
        // first deposit to trove1
        //

        // simulate sentinel calling enter
        start_cheat_caller_address(gate.contract_address, gate_utils::MOCK_SENTINEL);
        let enter1_yang_amt = gate.enter(user1, enter1_amt);

        // simulate depositing
        shrine_utils::make_root(shrine.contract_address, shrine_utils::ADMIN);
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.deposit(eth.contract_address, trove1, enter1_yang_amt);

        //
        // rebase
        //
        let rebase1_amt = 5_u128 * WAD_SCALE;
        gate_utils::rebase(gate.contract_address, eth.contract_address, rebase1_amt);

        // mark values before second deposit
        let before_user_yang: Wad = shrine.get_deposit(eth.contract_address, trove1);
        let before_total_yang: Wad = gate.get_total_yang();
        let before_total_assets: u128 = gate.get_total_assets();
        assert(before_total_yang == enter1_amt.into(), 'before_total_yang');
        assert(before_total_assets == enter1_amt + rebase1_amt, 'before_total_assets');

        //
        // second deposit to trove1
        //

        // simulate sentinel calling enter
        start_cheat_caller_address(gate.contract_address, gate_utils::MOCK_SENTINEL);
        let enter2_yang_amt = gate.enter(user1, enter2_amt);

        // simulate depositing
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.deposit(eth.contract_address, trove1, enter2_yang_amt);

        //
        // checks
        //

        let expected_total_assets: u128 = enter1_amt + rebase1_amt + enter2_amt;
        let expected_yang: Wad = before_total_yang * enter2_amt.into() / before_total_assets.into();
        let expected_total_yang: Wad = before_total_yang + expected_yang;

        assert(gate.get_total_assets() == expected_total_assets, 'get_total_assets 1');
        assert(gate.get_total_yang() == expected_total_yang, 'get_total_yang 1');
        assert(shrine.get_deposit(eth.contract_address, trove1) == before_user_yang + expected_yang, 'user deposits 1');

        //
        // deposit to trove 2 by user 2 after the previous deposits to trove 1 and rebase
        //

        let user2: ContractAddress = common::TROVE2_OWNER_ADDR;
        let trove2: u64 = common::TROVE_2;
        let enter3_amt = 10_u128 * WAD_SCALE;
        let enter4_amt = 8_u128 * WAD_SCALE;

        gate_utils::approve_gate_for_token(gate.contract_address, eth.contract_address, user2);
        start_cheat_caller_address(eth.contract_address, common::ETH_HOARDER);
        eth.transfer(user2, (enter3_amt + enter4_amt).into());
        stop_cheat_caller_address(eth.contract_address);

        let before_total_yang: Wad = gate.get_total_yang();
        let before_total_assets: u128 = gate.get_total_assets();
        let before_asset_amt_per_yang: Wad = gate.get_asset_amt_per_yang();

        // simulate sentinel calling enter
        start_cheat_caller_address(gate.contract_address, gate_utils::MOCK_SENTINEL);
        let enter3_yang_amt = gate.enter(user2, enter3_amt);

        // simulate depositing
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.deposit(eth.contract_address, trove2, enter3_yang_amt);

        //
        // checks
        //

        let expected_total_assets: u128 = expected_total_assets + enter3_amt;
        let expected_total_yang: Wad = expected_total_yang + enter3_yang_amt;
        let expected_trove2_deposit: Wad = before_total_yang * enter3_amt.into() / before_total_assets.into();

        assert(gate.get_total_assets() == expected_total_assets, 'get_total_assets 2');
        assert(gate.get_total_yang() == expected_total_yang, 'get_total_yang 2');
        assert(shrine.get_deposit(eth.contract_address, trove2) == expected_trove2_deposit, 'user deposit 2');
        assert(gate.get_asset_amt_per_yang() == before_asset_amt_per_yang, 'asset_amt_per_yang deposit 2');

        //
        // rebase
        //

        let rebase2_amt = 2_u128 * WAD_SCALE;
        gate_utils::rebase(gate.contract_address, eth.contract_address, rebase2_amt);

        //
        // second deposit to trove 2 by user 2
        //

        let before_asset_amt_per_yang = gate.get_asset_amt_per_yang();

        // simulate sentinel calling enter
        start_cheat_caller_address(gate.contract_address, gate_utils::MOCK_SENTINEL);
        let enter4_yang_amt = gate.enter(user2, enter4_amt);

        // simulate depositing
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.deposit(eth.contract_address, trove2, enter4_yang_amt);

        //
        // checks
        //

        let expected_total_assets = expected_total_assets + rebase2_amt + enter4_amt;
        let expected_total_yang: Wad = expected_total_yang + enter4_yang_amt;

        assert(gate.get_total_assets() == expected_total_assets, 'get_total_assets 3');
        assert(gate.get_total_yang() == expected_total_yang, 'get_total_yang 3');

        //
        // exit
        //

        // simulate sentinel calling exit
        start_cheat_caller_address(gate.contract_address, gate_utils::MOCK_SENTINEL);
        let exit_amt = gate.exit(eth.contract_address, enter4_yang_amt);

        // simulate withdrawing
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.withdraw(eth.contract_address, trove2, enter4_yang_amt);

        //
        // checks
        //

        let expected_total_assets = expected_total_assets - exit_amt;

        common::assert_equalish::<Wad>(enter4_amt.into(), exit_amt.into(), 1_u128.into(), 'exit amount');
        assert(gate.get_total_assets() == expected_total_assets, 'exit get_total_assets');
        assert(gate.get_asset_amt_per_yang() == before_asset_amt_per_yang, 'exit get_asset_amt_per_yang');
    }

    #[test]
    #[should_panic(expected: 'u256_sub Overflow')]
    fn test_gate_enter_insufficient_bags() {
        let (shrine, eth, gate) = gate_utils::eth_gate_deploy(Option::None);
        gate_utils::add_eth_as_yang(shrine, eth);

        let eth = IERC20Dispatcher { contract_address: eth };
        let gate = IGateDispatcher { contract_address: gate };

        let user: ContractAddress = common::TROVE1_OWNER_ADDR;
        let enter_amt = 10_u128 * WAD_SCALE;

        // make funds available and fund user
        gate_utils::approve_gate_for_token(gate.contract_address, eth.contract_address, user);

        start_cheat_caller_address(eth.contract_address, common::ETH_HOARDER);
        eth.transfer(user, (enter_amt - 1).into());
        stop_cheat_caller_address(eth.contract_address);

        // simulate sentinel calling enter
        start_cheat_caller_address(gate.contract_address, gate_utils::MOCK_SENTINEL);
        gate.enter(user, enter_amt);
    }

    #[test]
    #[should_panic(expected: 'u256_sub Overflow')]
    fn test_gate_exit_insufficient_bags() {
        let (shrine, eth, gate) = gate_utils::eth_gate_deploy(Option::None);
        gate_utils::add_eth_as_yang(shrine, eth);

        let shrine = IShrineDispatcher { contract_address: shrine };
        let eth = IERC20Dispatcher { contract_address: eth };
        let gate = IGateDispatcher { contract_address: gate };

        let user = common::TROVE1_OWNER_ADDR;
        let trove_id = common::TROVE_1;
        let enter_amt = 10_u128 * WAD_SCALE;
        let exit_amt = enter_amt + 1;

        // make funds available and fund user
        gate_utils::approve_gate_for_token(gate.contract_address, eth.contract_address, user);
        start_cheat_caller_address(eth.contract_address, common::ETH_HOARDER);
        eth.transfer(user, enter_amt.into());
        stop_cheat_caller_address(eth.contract_address);

        //
        // enter
        //

        // simulate sentinel calling enter
        start_cheat_caller_address(gate.contract_address, gate_utils::MOCK_SENTINEL);
        let enter_yang_amt = gate.enter(user, enter_amt);

        // simulate depositing
        shrine_utils::make_root(shrine.contract_address, shrine_utils::ADMIN);
        start_cheat_caller_address(shrine.contract_address, shrine_utils::ADMIN);
        shrine.deposit(eth.contract_address, trove_id, enter_yang_amt);

        //
        // exit
        //
        gate.exit(user, exit_amt.into());
    }
}
