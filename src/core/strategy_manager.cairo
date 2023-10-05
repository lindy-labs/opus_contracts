#[starknet::contract]
mod StrategyManager {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::ITransmuter::{
        ITransmuterDispatcher, ITransmuterDispatcherTrait, IStrategyManager
    };

    #[storage]
    struct Storage {
        transmuter: ITransmuterDispatcher,
    // TODO: To be customized according to strategy, e.g. LP tokens
    // strategy_token: IERC20Dispatcher
    }

    #[constructor]
    fn constructor(ref self: ContractState, transmuter: ContractAddress,) {
        self.transmuter.write(ITransmuterDispatcher { contract_address: transmuter });
    }

    #[external(v0)]
    impl IStrategyManagerImpl of IStrategyManager<ContractState> {
        //
        // Core functions
        //

        fn execute(ref self: ContractState, execute_amt: u128) {
            let transmuter: ITransmuterDispatcher = self.transmuter.read();
            assert(get_caller_address() == transmuter.contract_address, 'SM: Only transmuter');
        // TODO: Do stuff
        }

        fn unwind(ref self: ContractState, deployed_amt: u128, unwind_amt: u128) {
            let transmuter: ITransmuterDispatcher = self.transmuter.read();
            assert(get_caller_address() == transmuter.contract_address, 'SM: Only transmuter');

            let asset: IERC20Dispatcher = IERC20Dispatcher {
                contract_address: transmuter.get_asset()
            };

            // TODO: Do stuff
            //       For example, assuming this is a CASH/DAI LP strategy, withdraw
            //       (unwind_amt / deployed_amt) * LP token balance of manager, and
            //       transfer the DAI to Transmuter and excess to the receiver.

            let manager: ContractAddress = get_contract_address();

            // Transfer all assets back to Transmuter
            asset.transfer(transmuter.contract_address, asset.balance_of(manager));
        }
    }

    #[generate_trait]
    impl StrategyManagerHelpers of StrategyManagerHelpersTrait {}
}
