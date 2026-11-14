# Klipper and Moonraker are Python, and on the printer's two slow CPUs the
# interpreter is where their time goes. Build it with link time and profile
# guided optimisation. The profile is gathered at build time in qemu-user
# (see QEMU_EXTRAOPTIONS in the machine's tune file).
PACKAGECONFIG:append:class-target = " pgo lto"

# Poky profiles with seven tests to keep the emulated run short. Profile what
# the printer's programs do instead: containers, strings, numbers, struct,
# JSON, regular expressions, enum, generators and coroutines. Nothing here
# starts a subprocess (a target binary cannot be executed from inside
# qemu-user).
K1OS_PGO_TESTS = "\
    test_grammar test_opcodes test_builtin test_exceptions test_types \
    test_dict test_set test_list test_tuple test_slice test_ordered_dict \
    test_unicode test_string test_fstring test_bytes test_codecs \
    test_int test_long test_float test_math test_binop test_operator \
    test_struct test_array test_memoryview test_binascii test_base64 \
    test_json test_re test_enum test_dataclasses test_collections \
    test_functools test_itertools test_generators test_coroutines \
    test_class test_descr test_scope test_heapq test_bisect \
    test_time test_datetime test_pickle \
"

do_configure:prepend:class-target() {
    sed -i 's#\./python -m test\.regrtest --pgo .* || true#./python -m test.regrtest --pgo --timeout=1200 ${K1OS_PGO_TESTS} || true#' ${S}/Makefile.pre.in
    grep -q -- '--pgo --timeout=1200 ' ${S}/Makefile.pre.in || bbfatal "python3: the PGO task line in Makefile.pre.in was not found"
}
