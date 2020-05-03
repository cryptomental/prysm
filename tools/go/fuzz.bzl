load("@io_bazel_rules_go//go:def.bzl", "go_context", "go_rule")
load(
    "@io_bazel_rules_go//go/private:providers.bzl",
    "GoLibrary",
    "INFERRED_PATH",
)
load(
    "@io_bazel_rules_go//go/private:mode.bzl",
    "LINKMODE_C_ARCHIVE",
    "LINKMODE_C_SHARED",
)
load(
    "@io_bazel_rules_go//go:def.bzl",
    "go_binary",
    "go_library",
)

main_tpl = """
// Generated file. DO NOT EDIT.

package main
import (
    "unsafe"
    target "%s"
)
// #include <stdint.h>
import "C"
//export LLVMFuzzerTestOneInput
func LLVMFuzzerTestOneInput(data *C.char, size C.size_t) C.int {
	s := make([]byte, size)
	copy(s, (*[1 << 30]byte)(unsafe.Pointer(data))[:size:size])
	target.%s(s)
	return 0
}
func main() {
}
"""


main_differential_tpl = """
// Code generated for differential fuzzer. DO NOT EDIT

package main
import (
	"unsafe"
	"fmt"
	target "%s"
)
// #include <stdint.h>
import "C"
//export prysm_%s_LLVMFuzzerInitialize
func prysm_%s_LLVMFuzzerInitialize(argc uintptr, argv uintptr) int {
    return 0
}

var bfuzz_return_data []byte

//export prysm_%s_LLVMFuzzerTestOneInput
func prysm_%s_LLVMFuzzerTestOneInput(data *C.char, size C.size_t) (resultSize C.size_t, errnum C.int) {
    input := (*[1<<31]byte)(unsafe.Pointer(data))[:size:size]
    var result []byte
    result, err := target.%s(input)
    if err != false || result == nil {
        return 0, 1
    }
    bfuzz_return_data = result
    return C.size_t(len(bfuzz_return_data)), 0
}

//export prysm_%s_get_return_data
func prysm_%s_get_return_data(buf *C.char) {
    size := len(bfuzz_return_data)
    output := (*[1<<30]byte)(unsafe.Pointer(buf))[:size:size]
    nCopied := copy(output, bfuzz_return_data)
    if (nCopied != size) {
        panic(fmt.Sprintf("Go: Unable to copy entire result."))
    }
    bfuzz_return_data = nil
}

//export prysm_%s_get_return_size
func prysm_%s_get_return_size() int {
    return len(bfuzz_return_data)
}

func main() {
}
"""

def _gen_fuzz_main_impl(ctx):
    if ctx.var.get("gotags") != "libfuzzer":
        fail("gotags must be set to libfuzzer. Use --config=fuzz or --config=fuzzit.")
    if ctx.var.get("gc_goopts") != "-d=libfuzzer":
        fail("gc_goopts must be set to -d=libfuzzer. Use --config=fuzz or --config=fuzzit.")

    pkg = ctx.attr.target_pkg
    func = ctx.attr.func

    output_file_name = ctx.label.name + "_main.fuzz.go"
    output_file = ctx.actions.declare_file(output_file_name)
    ctx.actions.write(output_file, main_tpl % (pkg, func))
    return [DefaultInfo(files = depset([output_file]))]

gen_fuzz_main = rule(
    implementation = _gen_fuzz_main_impl,
    attrs = {
        "target_pkg": attr.string(mandatory = True),
        "func": attr.string(mandatory = True),
    },
)

def _gen_diff_fuzz_main_impl(ctx):
    if ctx.var.get("gotags") != "libfuzzer":
        fail("gotags must be set to libfuzzer. Use --config=fuzz or --config=fuzzit.")
    if ctx.var.get("gc_goopts") != "-d=libfuzzer":
        fail("gc_goopts must be set to -d=libfuzzer. Use --config=fuzz or --config=fuzzit.")

    pkg = ctx.attr.target_pkg
    func = ctx.attr.func
    name = ctx.attr.name

    output_file_name = ctx.label.name + "_main.diff_fuzz.go"
    output_file = ctx.actions.declare_file(output_file_name)
    ctx.actions.write(output_file, main_differential_tpl % (pkg,
        name, name, name, name, func, name, name, name, name))
    return [DefaultInfo(files = depset([output_file]))]

gen_diff_fuzz_main = rule(
    implementation = _gen_diff_fuzz_main_impl,
    attrs = {
        "target_pkg": attr.string(mandatory = True),
        "func": attr.string(mandatory = True),
    },
)

def go_fuzz_test(
        name,
        corpus,
        corpus_path,
        importpath,
        func = "Fuzz",
        repository = "",
        input_size = 0,
        size = "medium",
        tags = [],
        **kwargs):
    go_library(
        name = name + "_lib_with_fuzzer",
        tags = ["manual"] + tags,
        visibility = ["//visibility:private"],
        testonly = 1,
        importpath = importpath,
        cgo = True,
        gc_goopts = ["-d=libfuzzer"],
        **kwargs
    )
    gen_fuzz_main(
        name = name + "_libfuzz_main",
        target_pkg = importpath,
        func = func,
        tags = ["manual"] + tags,
        testonly = 1,
        visibility = ["//visibility:private"],
    )
    gen_diff_fuzz_main(
        name = name + "_diff_libfuzz_main",
        target_pkg = importpath,
        func = func,
        tags = ["manual"] + tags,
        testonly = 1,
        visibility = ["//visibility:private"],
    )
    go_binary(
        name = name + "_binary",
        srcs = [name + "_libfuzz_main"],
        deps = [name + "_lib_with_fuzzer"],
        linkmode = LINKMODE_C_ARCHIVE,
        cgo = True,
        tags = ["manual"] + tags,
        visibility = ["//visibility:private"],
        gc_goopts = ["-d=libfuzzer"],
        testonly = 1,
    )
    go_binary(
        # For inclusion in beacon fuzz project.
        name = name + "_c_shared",
        srcs = [name + "_diff_libfuzz_main"],
        deps = [name + "_lib_with_fuzzer"],
        linkmode = LINKMODE_C_SHARED,
        static = "on",
        cgo = True,
        tags = ["manual"] + tags,
        visibility = ["//visibility:private"],
        gc_goopts = ["-d=libfuzzer"],
        gc_linkopts=["-buildmode=c-shared"],
        testonly = 1,
    )
    native.genrule(
        name = name,
        outs = [name + ".a"],
        srcs = [":" + name + "_binary"],
        cmd = "cp $< $@",
        visibility = kwargs.get("visibility"),
        tags = ["manual"] + tags,
        testonly = 1,
    )

    if not (corpus.startswith("//") or corpus.startswith(":") or corpus.startswith("@")):
        corpus_name = name + "_corpus"
        corpus = native.glob([corpus + "/**"])
        native.filegroup(
            name = corpus_name,
            srcs = corpus,
        )
    else:
        corpus_name = corpus

    additional_args = []
    if input_size > 0:
        additional_args += ["-max_len=%s" % input_size]

    native.cc_test(
        name = name + "_with_libfuzzer",
        linkopts = ["-fsanitize=fuzzer,address"],
        copts = ["-fsantize=fuzzer,address"],
        testonly = 1,
        linkstatic = False,
        srcs = [":" + name],
        deps = ["@herumi_bls_eth_go_binary//:lib"],
        tags = ["manual", "fuzzer"] + tags,
        args = [
            corpus_path,
            "-print_final_stats=1",
            "-use_value_profile=1",
            "-max_total_time=3540",  # One minute early of 3600.
        ] + additional_args,
        data = [corpus_name],
        timeout = "eternal",
    )
