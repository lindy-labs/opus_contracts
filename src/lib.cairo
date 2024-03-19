mod types;

mod core {
    pub mod abbot;
    pub mod absorber;
    pub mod allocator;
    pub mod caretaker;
    pub mod controller;
    pub mod equalizer;
    pub mod flash_mint;
    pub mod gate;
    pub mod purger;
    pub mod roles;
    pub mod seer;
    pub mod sentinel;
    pub mod shrine;
    pub mod transmuter;
    pub mod transmuter_registry;
}

mod external {
    pub mod pragma;
}

mod interfaces {
    pub mod IAbbot;
    pub mod IAbsorber;
    pub mod IAllocator;
    pub mod ICaretaker;
    pub mod IController;
    pub mod IERC20;
    pub mod IEqualizer;
    pub mod IFlashBorrower;
    pub mod IFlashMint;
    pub mod IGate;
    pub mod IOracle;
    pub mod IPragma;
    pub mod IPurger;
    pub mod ISRC5;
    pub mod ISeer;
    pub mod ISentinel;
    pub mod IShrine;
    pub mod ITransmuter;
    pub mod external;
}

mod utils {
    pub mod address_registry;
    pub mod exp;
    pub mod math;
    pub mod reentrancy_guard;
}

// mock used for local devnet deployment
mod mock {
    mod blesser;
    mod erc20;
    mod erc20_mintable;
    mod flash_borrower;
    mod flash_liquidator;
    mod mock_pragma;
//mod oracle;
}

#[cfg(test)]
mod tests {
    mod common;
    mod test_types;
    mod abbot {
        mod test_abbot;
        mod utils;
    }
    mod absorber {
        mod test_absorber;
        mod utils;
    }
    mod caretaker {
        mod test_caretaker;
        mod utils;
    }
    mod controller {
        mod test_controller;
        mod utils;
    }
    mod equalizer {
        mod test_allocator;
        mod test_equalizer;
        mod utils;
    }
    mod external {
        mod test_pragma;
        mod utils;
    }
    mod flash_mint {
        mod test_flash_mint;
        mod utils;
    }
    mod gate {
        mod test_gate;
        mod utils;
    }
    mod purger {
        mod test_purger;
        mod utils;
    }
    mod sentinel {
        mod test_sentinel;
        mod utils;
    }
    mod seer {
        mod test_seer;
        mod utils;
    }
    mod shrine {
        mod test_shrine;
        mod test_shrine_compound;
        mod test_shrine_redistribution;
        mod utils;
    }
    mod transmuter {
        mod test_transmuter;
        mod test_transmuter_registry;
        mod utils;
    }
    mod utils {
        mod mock_address_registry;
        mod mock_reentrancy_guard;
        mod test_address_registry;
        mod test_exp;
        mod test_math;
        mod test_reentrancy_guard;
    }
}
