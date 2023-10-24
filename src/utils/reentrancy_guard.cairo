#[starknet::interface]
trait IReentrancyGuard<TContractState> {}

#[starknet::component]
mod reentrancy_guard_component {
    #[storage]
    struct Storage {
        entered: bool,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {}

    #[embeddable_as(ReentrancyGuard)]
    impl ReentrancyGuardPublic<
        TContractState, +HasComponent<TContractState>
    > of super::IReentrancyGuard<ComponentState<TContractState>> {}


    #[generate_trait]
    impl ReentrancyGuardHelpers<
        TContractState, +HasComponent<TContractState>
    > of ReentrancyGuardHelpersTrait<TContractState> {
        fn start(ref self: ComponentState<TContractState>) {
            assert(!self.entered.read(), 'RG: reentrant call');
            self.entered.write(true);
        }

        fn end(ref self: ComponentState<TContractState>) {
            self.entered.write(false);
        }
    }
}
