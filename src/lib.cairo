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
    pub mod interfaces;
    pub mod pragma;
    pub mod roles;
    pub mod switchboard;
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
    pub mod ISwitchboard;
    pub mod ITransmuter;
}

mod utils {
    pub mod address_registry;
    pub mod exp;
    pub mod math;
    pub mod reentrancy_guard;
    pub mod upgradeable;
}

mod periphery {
    pub mod frontend_data_provider;
    pub mod interfaces;
    pub mod roles;
}

// mock used for local devnet deployment
mod mock {
    pub mod blesser;
    pub mod erc20;
    pub mod erc20_mintable;
    pub mod flash_borrower;
    pub mod flash_liquidator;
    pub mod mock_pragma;
    pub mod mock_switchboard;
}

#[cfg(test)]
mod tests {
    mod common;
    mod test_types;
    mod abbot {
        mod test_abbot;
        pub mod utils;
    }
    mod absorber {
        mod test_absorber;
        pub mod utils;
    }
    mod caretaker {
        mod test_caretaker;
        pub mod utils;
    }
    mod controller {
        mod test_controller;
        pub mod utils;
    }
    mod equalizer {
        mod test_allocator;
        mod test_equalizer;
        pub mod utils;
    }
    mod external {
        mod test_pragma;
        mod test_switchboard;
        pub mod utils;
    }
    mod flash_mint {
        mod test_flash_mint;
        pub mod utils;
    }
    mod gate {
        mod test_gate;
        pub mod utils;
    }
    mod purger {
        mod test_purger;
        pub mod utils;
    }
    mod sentinel {
        mod test_sentinel;
        pub mod utils;
    }
    mod seer {
        mod test_seer;
        pub mod utils;
    }
    mod shrine {
        mod test_shrine;
        mod test_shrine_compound;
        mod test_shrine_redistribution;
        pub mod utils;
    }
    mod transmuter {
        mod test_transmuter;
        pub mod test_transmuter_registry;
        pub mod utils;
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
