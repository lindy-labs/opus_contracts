mod arg;
mod function;
mod fuzz_generator;

use std::rc::Rc;

use arg::{BoolArg, Domain, RayArg, TupleArg, WadArg};
use function::Func;
use fuzz_generator::FuzzGenerator;

fn main() {
    let wad = Rc::new(WadArg::new(Domain::Range(0..100)));
    let ray = Rc::new(RayArg::new(Domain::Range(0..100)));
    let some_bool = Rc::new(BoolArg::new(None));

    let tuple = Rc::new(TupleArg::new(vec![
        some_bool.clone(),
        ray.clone(),
        wad.clone(),
    ]));

    let func = Func::new(
        "shrine.deposit",
        vec![wad.clone(), ray.clone(), some_bool.clone(), tuple.clone()],
        vec!["account1"],
    );

    let func2 = Func::new(
        "shrine.withdraw",
        vec![tuple],
        vec!["account2", "account1"],
    );

    let fuzzerator = FuzzGenerator::new(
        "assert_invariants",
        "set_block_timestamp",
        "set_caller",
        3600,
        vec![func, func2],
    );

    println!("{}", fuzzerator.generate_sequence(10));
}
