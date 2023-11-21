use crate::arg::Arg;
use std::rc::Rc;
use std::{fmt, result};

use rand::{seq::SliceRandom, Rng};

pub struct Func<'a> {
    name: String,
    args: Vec<Rc<dyn Arg>>,
    canonical_callers: Vec<&'a str>, // Vec of addresses that 'should'/could be calling this function
}

impl<'a> Func<'a> {
    pub fn new(name: &str, args: Vec<Rc<dyn Arg>>, canonical_callers: Vec<&'a str>) -> Self {
        Self {
            name: name.to_string(),
            args,
            canonical_callers,
        }
    }

    pub fn generate_call(&self) -> String {
        let mut result = format!("{}(", String::from(&self.name));

        for (i, arg) in self.args.iter().enumerate() {
            if i > 0 {
                result.push_str(", ");
            }
            result.push_str(&arg.generate());
        }
        result.push_str(");");
        result
    }

    pub fn get_caller(&self) -> &str {
        // Randomly select a caller from `canonical_callers`
        let mut rng = rand::thread_rng();
        self.canonical_callers.choose(&mut rng).unwrap()

    }
}

impl fmt::Display for Func<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.generate_call())
    }
}
