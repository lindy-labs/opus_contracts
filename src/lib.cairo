mod core {
    mod abbot;
    mod absorber;
    mod allocator;
    mod caretaker;
    mod controller;
    mod equalizer;
    mod flashmint;
    mod gate;
    mod purger;
    mod roles;
    mod sentinel;
    mod shrine;
    mod stabilizer;
}

mod external {
    mod pragma;
}

mod interfaces {
    mod external;
    mod IAbbot;
    mod IAbsorber;
    mod IAllocator;
    mod ICaretaker;
    mod IController;
    mod IEqualizer;
    mod IERC20;
    mod IFlashBorrower;
    mod IFlashMint;
    mod IGate;
    mod IOracle;
    mod IPragma;
    mod IPurger;
    mod ISentinel;
    mod IShrine;
    mod IStabilizer;
}

mod types;

mod utils {
    mod access_control;
    mod exp;
    mod math;
    mod reentrancy_guard;
    mod wadray;
    mod wadray_signed;
}

#[cfg(test)]
mod tests {
    mod abbot {
        mod test_abbot;
        mod utils;
    }
    mod absorber {
        mod mock_blesser;
        mod test_absorber;
        mod utils;
    }
    mod caretaker {
        mod test_caretaker;
        mod utils;
    }
    mod common;
    mod controller {
        mod test_controller;
        mod utils;
    }
    mod erc20;
    mod equalizer {
        mod test_allocator;
        mod test_equalizer;
        mod utils;
    }
    mod external {
        mod mock_pragma;
        mod test_pragma;
        mod utils;
    }
    mod flashmint {
        mod flash_borrower;
        mod test_flashmint;
        mod utils;
    }
    mod gate {
        mod test_gate;
        mod utils;
    }
    mod purger {
        mod flash_liquidator;
        mod test_purger;
        mod utils;
    }
    mod sentinel {
        mod test_sentinel;
        mod utils;
    }
    mod shrine {
        mod test_shrine;
        mod test_shrine_compound;
        mod test_shrine_redistribution;
        mod utils;
    }
    mod utils {
        mod test_access_control;
        mod test_exp;
        mod test_math;
        mod test_reentrancy_guard;
        mod test_wadray_signed;
        mod test_wadray;
    }
}
