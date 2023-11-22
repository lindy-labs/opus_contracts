mod arg;
mod function;
mod fuzz_generator;

use arg::{
    Arg, AssetBalanceArg, BoolArg, Domain, RayArg, SpanArg, TupleArg, U128Arg, WadArg, RAY_ONE, WAD_ONE,
};
use function::Func;
use fuzz_generator::FuzzGenerator;

fn main() {
    let funcs = vec![

        //
        // Abbot
        //

        Func::new(
            "abbot.open_trove",
            vec_boxed![SpanArg::new(
                2,
                AssetBalanceArg::new(
                    vec!["*yangs[0]", "*yangs[1]"],
                    Domain::Range(0..2 * WAD_ONE),
                )),
                WadArg::new(Domain::Range(0..1000 * RAY_ONE)),
                WadArg::new(Domain::Range(0..WAD_ONE))
            ],
            vec!["user1", "user2"],
        ),
        Func::new(
            "abbot.close_trove",
            vec_boxed![U128Arg::new(Domain::Range(0..10))],
            vec!["user1", "user2"],
        ),
        // Abbot.deposit 
        Func::new(
            "abbot.deposit",
            vec![
                Box::new(U128Arg::new(Domain::Range(0..10))),
                Box::new(AssetBalanceArg::new(
                    vec!["*yangs[0]", "*yangs[1]"],
                    Domain::Range(0..2 * WAD_ONE),
                )),
            ], 
            vec!["user1", "user2"],
        ), 
        Func::new(
            "abbot.withdraw",
            vec_boxed![
                U128Arg::new(Domain::Range(0..10)),
                AssetBalanceArg::new(
                    vec!["*yangs[0]", "*yangs[1]"],
                    Domain::Range(0..2 * WAD_ONE),
                )
            ], 
            vec!["user1", "user2"],
        ), 
        Func::new(
            "abbot.forge",
            vec_boxed![
                U128Arg::new(Domain::Range(0..10)),
                WadArg::new(Domain::Range(0..1000*RAY_ONE)),
                WadArg::new(Domain::Range(0..WAD_ONE))
            ],
            vec!["user1", "user2"],
        ), 
        Func::new(
            "abbot.melt",
            vec_boxed![
                U128Arg::new(Domain::Range(0..10)),
                WadArg::new(Domain::Range(0..1000*RAY_ONE))
            ],
            vec!["user1", "user2"],
        ),
    ];

    let fuzzerator = FuzzGenerator::new(
        "assert_invariants(shrine, abbot, yangs);",
        "set_block_timestamp",
        "set_contract_address",
        3600,
        funcs,
    );

    println!("{}", fuzzerator.generate_sequence(10));
}