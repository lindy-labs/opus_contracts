#[contract]
mod ERC20 {
    use zeroable::Zeroable;
    use starknet::get_caller_address;
    use starknet::contract_address_const;
    use starknet::ContractAddress;

    struct Storage {
        token_name: felt252,
        token_symbol: felt252,
        token_decimals: u8,
        supply: u256,
        balances: LegacyMap::<ContractAddress, u256>,
        allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

    #[event]
    fn Transfer(from: ContractAddress, to: ContractAddress, value: u256) {}

    #[event]
    fn Approval(owner: ContractAddress, spender: ContractAddress, value: u256) {}

    #[constructor]
    fn constructor(
        name: felt252,
        symbol: felt252,
        decimals: u8,
        initial_supply: u256,
        recipient: ContractAddress
    ) {
        token_name::write(name);
        token_symbol::write(symbol);
        token_decimals::write(decimals);
        mint(recipient, initial_supply);
    }

    #[view]
    fn name() -> felt252 {
        token_name::read()
    }

    #[view]
    fn symbol() -> felt252 {
        token_symbol::read()
    }

    #[view]
    fn decimals() -> u8 {
        token_decimals::read()
    }

    #[view]
    fn total_supply() -> u256 {
        supply::read()
    }

    #[view]
    fn balance_of(account: ContractAddress) -> u256 {
        balances::read(account)
    }

    #[view]
    fn allowance(owner: ContractAddress, spender: ContractAddress) -> u256 {
        allowances::read((owner, spender))
    }

    #[external]
    fn transfer(recipient: ContractAddress, amount: u256) -> bool {
        let sender = get_caller_address();
        transfer_helper(sender, recipient, amount);
        true
    }

    #[external]
    fn transfer_from(sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool {
        let caller = get_caller_address();
        spend_allowance(sender, caller, amount);
        transfer_helper(sender, recipient, amount);
        true
    }

    #[external]
    fn approve(spender: ContractAddress, amount: u256) -> bool {
        let caller = get_caller_address();
        approve_helper(caller, spender, amount);
        true
    }

    #[external]
    fn mint(recipient: ContractAddress, amount: u256) -> bool {
        supply::write(supply::read() + amount);
        let balance = balances::read(recipient);
        balances::write(recipient, balance + amount);
        Transfer(contract_address_const::<0>(), recipient, amount);
        true
    }

    fn transfer_helper(sender: ContractAddress, recipient: ContractAddress, amount: u256) {
        assert(!sender.is_zero(), 'ERC20: transfer from 0');
        assert(!recipient.is_zero(), 'ERC20: transfer to 0');
        balances::write(sender, balances::read(sender) - amount);
        balances::write(recipient, balances::read(recipient) + amount);
        Transfer(sender, recipient, amount);
    }

    fn spend_allowance(owner: ContractAddress, spender: ContractAddress, amount: u256) {
        let current_allowance = allowances::read((owner, spender));
        let ONES_MASK = 0xffffffffffffffffffffffffffffffff_u128;
        let is_unlimited_allowance = current_allowance.low == ONES_MASK
            & current_allowance.high == ONES_MASK;
        if !is_unlimited_allowance {
            approve_helper(owner, spender, current_allowance - amount);
        }
    }

    fn approve_helper(owner: ContractAddress, spender: ContractAddress, amount: u256) {
        assert(!spender.is_zero(), 'ERC20: approve from 0');
        allowances::write((owner, spender), amount);
        Approval(owner, spender, amount);
    }
}
