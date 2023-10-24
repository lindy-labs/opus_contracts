#[starknet::interface]
trait IMockReentrancyGuard<TContractState> {
    fn guarded_func(ref self: TContractState, recurse_once: bool);
}

#[starknet::contract]
mod MockReentrancyGuard {
    use opus::utils::reentrancy_guard::reentrancy_guard_component;

    component!(
        path: reentrancy_guard_component, storage: reentrancy_guard, event: ReentrancyGuardEvent
    );

    #[abi(embed_v0)]
    impl ReentrancyGuardPublic =
        reentrancy_guard_component::ReentrancyGuard<ContractState>;
    impl ReentrancyGuardHelpers = reentrancy_guard_component::ReentrancyGuardHelpers<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        reentrancy_guard: reentrancy_guard_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ReentrancyGuardEvent: reentrancy_guard_component::Event
    }

    #[external(v0)]
    impl IMockReentrancyGuardImpl of super::IMockReentrancyGuard<ContractState> {
        fn guarded_func(ref self: ContractState, recurse_once: bool) {
            self.reentrancy_guard.start();

            if recurse_once {
                self.guarded_func(false);
            }

            self.reentrancy_guard.end();
        }
    }
}
