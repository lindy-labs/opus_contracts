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
mod tests;
