mod arg;
mod function;
mod fuzz_generator;

use std::rc::Rc;

use arg::{
    AssetBalanceArg, BoolArg, Domain, RayArg, SpanArg, TupleArg, U128Arg, WadArg, RAY_ONE, WAD_ONE,
};
use function::Func;
use fuzz_generator::FuzzGenerator;

fn main() {
    let funcs = vec![
        // Abbot.open_trove
        Func::new(
            "abbot.open_trove",
            vec![Rc::new(SpanArg::new(
                2,
                AssetBalanceArg::new(
                    vec!["*yangs[0]", "*yangs[1]"],
                    Domain::Range(0..2 * WAD_ONE),
                ),
            ))],
            vec!["user1", "user2"],
        ),
        // Abbot.close_trove
        Func::new(
            "abbot.close_trove",
            vec![Rc::new(U128Arg::new(Domain::Range(0..10)))],
            vec!["user1", "user2"],
        ),
    ];

    let fuzzerator = FuzzGenerator::new(
        "assert_invariants(shrine, abbot, yangs);",
        "set_block_timestamp",
        "set_caller",
        3600,
        funcs,
    );

    println!("{}", fuzzerator.generate_sequence(10));
}
