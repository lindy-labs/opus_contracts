
use std::thread::current;

use rand::{seq::SliceRandom, Rng};

use crate::function::Func;



pub struct FuzzGenerator<'a> {
    assert_invariants_command: &'a str, 
    set_timestamp_command: &'a str,
    set_caller_command: &'a str,
    time_increment: u32,
    functions: Vec<Func<'a>>,
}

impl<'a> FuzzGenerator<'a> {
    pub fn new(assert_invariants_command: &'a str, set_timestamp_command: &'a str, set_caller_command: &'a str, time_increment: u32, functions: Vec<Func<'a>>) -> Self {
        Self {
            assert_invariants_command,
            set_timestamp_command,
            set_caller_command,
            time_increment,
            functions,

        }
    }

    pub fn generate_sequence(&self, num_calls: u32) -> String {

        let mut result = String::new();
        let mut current_caller = "0";

        let mut rng = rand::thread_rng();

        for i in 0..num_calls {
            let func = self.functions.choose(&mut rng).unwrap();

            let caller = func.get_caller();

            if i > 0 {
                result.push_str(
                    format!(
                        "{}(get_block_timestamp() + {});\n", 
                        self.set_timestamp_command, 
                        self.time_increment
                    ).as_str()
                )
            }

            if caller != current_caller {
                current_caller = caller;
                result.push_str(format!("{}({});\n", self.set_caller_command, caller).as_str());
            }

            result.push_str(&func.generate_call());
            result.push_str("\n");

            result.push_str(self.assert_invariants_command);
            result.push_str("\n\n");
        }

        result
    }
}