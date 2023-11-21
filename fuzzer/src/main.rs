mod arg;
mod function;

use std::rc::Rc;

use arg::{BoolArg, Domain, RayArg, TupleArg, WadArg};
use function::Func;

fn main() {
    let wad = Rc::new(WadArg::new(Domain::Range(0..100)));
    let ray = Rc::new(RayArg::new(Domain::Range(0..100)));
    let some_bool = Rc::new(BoolArg::new(None));
    let tuple = Rc::new(TupleArg::new(vec![
        some_bool.clone(),
        ray.clone(),
        wad.clone(),
    ]));
    let func = Func::new("shrine.deposit", vec![wad, ray, some_bool, tuple]);
    println!("{}", func);
}
