#[contract]
mod FlashMint {
    use starknet::ContractAddress;

    struct Storage {
        shrine: ContractAddress, 
    }
}
