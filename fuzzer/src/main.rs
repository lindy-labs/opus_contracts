mod arg;
mod function;

use arg::{Arg, Domain, RayArg, WadArg, BoolArg};
use function::Func;

fn main() {
    let wad = WadArg::new(Domain::Range(0..100));
    let ray = RayArg::new(Domain::Range(0..100));
    let some_bool = BoolArg{};
    let func = Func::new("shrine.deposit", vec_args![wad, ray, some_bool]);
    println!("{}", func);
}
