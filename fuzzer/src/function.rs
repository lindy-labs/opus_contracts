use crate::arg::Arg;
use std::fmt;

use rand::seq::SliceRandom;

pub struct Func<'a> {
    name: String,
    args: Vec<Box<dyn Arg>>,
    canonical_callers: Vec<&'a str>, // Vec of addresses that 'should'/could be calling this function
}

impl<'a> Func<'a> {
    pub fn new(name: &str, args: Vec<Box<dyn Arg>>, canonical_callers: Vec<&'a str>) -> Self {
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

#[macro_export]
macro_rules! vec_boxed {
    ($($type:expr),*) => {
        {
            let vb: Vec<Box<dyn Arg>> = vec![
            $(
                Box::new($type),
            )*
            ];

            vb
        }
    };
}