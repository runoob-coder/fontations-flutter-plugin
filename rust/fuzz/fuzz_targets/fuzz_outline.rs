#![no_main]

mod cases;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| cases::run_outline(data));
