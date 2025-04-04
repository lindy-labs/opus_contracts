// With reference to OpenZeppelin's cairo-contracts
// https://github.com/OpenZeppelin/cairo-contracts/blob/main/src/upgrades/upgradeable.cairo

use starknet::ClassHash;

#[starknet::interface]
pub trait IUpgradeable<TContractState> {
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
}

#[starknet::component]
pub mod upgradeable_component {
    use core::num::traits::Zero;
    use starknet::syscalls::replace_class_syscall;
    use starknet::{ClassHash, SyscallResultTrait};

    #[storage]
    pub struct Storage {}

    #[event]
    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    pub enum Event {
        Upgraded: Upgraded
    }

    #[derive(Copy, Drop, PartialEq, starknet::Event)]
    pub struct Upgraded {
        class_hash: ClassHash
    }

    #[generate_trait]
    pub impl UpgradeableHelpers<
        TContractState, +HasComponent<TContractState>
    > of UpgradeableHelpersTrait<TContractState> {
        fn upgrade(ref self: ComponentState<TContractState>, new_class_hash: ClassHash) {
            assert(!new_class_hash.is_zero(), 'Class hash cannot be zero');
            replace_class_syscall(new_class_hash).unwrap_syscall();
            self.emit(Upgraded { class_hash: new_class_hash });
        }
    }
}
