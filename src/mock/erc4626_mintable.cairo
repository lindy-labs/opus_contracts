#[starknet::interface]
pub trait IMockERC4626<TContractState> {
    fn set_convert_to_assets_per_wad_scale(ref self: TContractState, assets: u256);
}

#[starknet::contract]
pub mod erc4626_mintable {
    use core::num::traits::Zero;
    use opus::interfaces::IERC20::IERC20;
    use opus::interfaces::IERC4626::IERC4626;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};
    use super::IMockERC4626;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        decimals: u8,
        total_supply: u256,
        balances: Map<ContractAddress, u256>,
        allowances: Map<(ContractAddress, ContractAddress), u256>,
        // storage variables for mock ERC-4626
        asset: ContractAddress,
        convert_to_assets_wad_scale: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Transfer: Transfer,
        Approval: Approval,
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        from: ContractAddress,
        to: ContractAddress,
        value: u256,
    }
    #[derive(Drop, starknet::Event)]
    struct Approval {
        owner: ContractAddress,
        spender: ContractAddress,
        value: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name_: felt252,
        symbol_: felt252,
        decimals_: u8,
        initial_supply: u256,
        recipient: ContractAddress,
        asset: ContractAddress,
    ) {
        self.name.write(name_);
        self.symbol.write(symbol_);
        self.decimals.write(decimals_);
        self.asset.write(asset);

        // Mint initial supply
        assert(!recipient.is_zero(), 'ERC20: mint to the 0 address');
        self.total_supply.write(initial_supply);
        self.balances.write(recipient, initial_supply);
        self.emit(Transfer { from: Zero::zero(), to: recipient, value: initial_supply });
    }

    #[abi(embed_v0)]
    impl IERC20Impl of IERC20<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
            self.allowances.read((owner, spender))
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let sender = get_caller_address();
            self.transfer_helper(sender, recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            self.spend_allowance(sender, caller, amount);
            self.transfer_helper(sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            self.approve_helper(caller, spender, amount);
            true
        }
    }

    // All functions are dummy except for `asset` and `convert_to_assets`.
    #[abi(embed_v0)]
    impl IERC4626Impl of IERC4626<ContractState> {
        fn asset(self: @ContractState) -> ContractAddress {
            self.asset.read()
        }

        fn total_assets(self: @ContractState) -> u256 {
            0
        }

        fn convert_to_shares(self: @ContractState, assets: u256) -> u256 {
            0
        }

        fn convert_to_assets(self: @ContractState, shares: u256) -> u256 {
            self.convert_to_assets_wad_scale.read()
        }

        fn max_deposit(self: @ContractState, receiver: ContractAddress) -> u256 {
            0
        }

        fn preview_deposit(self: @ContractState, assets: u256) -> u256 {
            0
        }

        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            0
        }

        fn max_mint(self: @ContractState, receiver: ContractAddress) -> u256 {
            0
        }

        fn preview_mint(self: @ContractState, shares: u256) -> u256 {
            0
        }

        fn mint(ref self: ContractState, shares: u256, receiver: ContractAddress) -> u256 {
            self.total_supply.write(self.total_supply.read() + shares);
            let balance = self.balances.read(receiver);
            self.balances.write(receiver, balance + shares);
            self.emit(Transfer { from: Zero::zero(), to: receiver, value: shares });
            shares
        }

        fn max_withdraw(self: @ContractState, owner: ContractAddress) -> u256 {
            0
        }

        fn preview_withdraw(self: @ContractState, assets: u256) -> u256 {
            0
        }

        fn withdraw(ref self: ContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress) -> u256 {
            0
        }

        fn max_redeem(self: @ContractState, owner: ContractAddress) -> u256 {
            0
        }

        fn preview_redeem(self: @ContractState, shares: u256) -> u256 {
            0
        }

        fn redeem(ref self: ContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress) -> u256 {
            0
        }
    }

    #[abi(embed_v0)]
    impl IMockERC4626Impl of IMockERC4626<ContractState> {
        fn set_convert_to_assets_per_wad_scale(ref self: ContractState, assets: u256) {
            self.convert_to_assets_wad_scale.write(assets);
        }
    }

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        fn transfer_helper(ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) {
            assert(!sender.is_zero(), 'ERC20: transfer from 0');
            assert(!recipient.is_zero(), 'ERC20: transfer to 0');
            self.balances.write(sender, self.balances.read(sender) - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self.emit(Transfer { from: sender, to: recipient, value: amount });
        }

        fn spend_allowance(ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256) {
            let current_allowance = self.allowances.read((owner, spender));
            let ONES_MASK = 0xffffffffffffffffffffffffffffffff_u128;
            let is_unlimited_allowance = current_allowance.low == ONES_MASK && current_allowance.high == ONES_MASK;
            if !is_unlimited_allowance {
                self.approve_helper(owner, spender, current_allowance - amount);
            }
        }

        fn approve_helper(ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256) {
            assert(!spender.is_zero(), 'ERC20: approve from 0');
            self.allowances.write((owner, spender), amount);
            self.emit(Approval { owner, spender, value: amount });
        }
    }
}
