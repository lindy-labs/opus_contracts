use array::SpanTrait;
use option::OptionTrait;


fn assert_spans_equal<T, impl TPartialEq: PartialEq<T>, impl DropT: Drop<T>, impl CopyT: Copy<T>>(
    mut a: Span<T>, mut b: Span<T>
) {
    loop {
        match a.pop_front() {
            Option::Some(i) => {
                assert(*i == *b.pop_front().unwrap(), 'elements not equal');
            },
            Option::None(_) => {
                break;
            }
        };
    };
}
