load("@io_bazel_rules_go//go:def.bzl", "GoPath", "GoSource", "go_context", "go_path")

EntGenerateInfo = provider(
    "Ent schema generation info",
    fields = {
        "libraries": "Dict of library names mapped to output file lists",
        "entities": "String list of entity names",
        "schema": "Label of schema lib",
        "schema_path": "Local path of schema package",
        "schema_packagename": "Name of schema package",
        "target_path": "Local path of target package",
        "target_importpath": "Importpath of target package",
    },
)

def _ent_generate_impl(ctx):
    go = go_context(ctx)

    # We create these
    gomod_file = ctx.actions.declare_file("go.mod.tmp")
    gosum_file = ctx.actions.declare_file("go.sum.tmp")

    ctx.actions.run_shell(
        inputs = [ctx.file.gomod],
        outputs = [gomod_file],
        progress_message = "Copying go.mod from %s to %s" % (ctx.file.gomod.short_path, gomod_file.short_path),
        command = "cp %s %s" % (ctx.file.gomod.path, gomod_file.path),
    )

    ctx.actions.run_shell(
        inputs = [ctx.file.gosum],
        outputs = [gosum_file],
        progress_message = "Copying go.sum from %s to %s" % (ctx.file.gosum.short_path, gosum_file.short_path),
        command = "cp %s %s" % (ctx.file.gosum.path, gosum_file.path),
    )

    # TODO: Discuss single-file output with Ent maintainers.

    files = []
    for f in [
        "client",
        "ent",
        "mutation",
        "runtime",
        "tx",
        "enttest/enttest",
        "hook/hook",
        "migrate/migrate",
        "migrate/schema",
        "predicate/predicate",
        "runtime/runtime",
    ]:
        files.append(f + ".go")

    for f in ctx.attr.extra_outputs:
        files.append(f)

    # TODO: get entity names from schema.
    for entity in ctx.attr.entities:
        for suffix in ["", "_create", "_delete", "_query", "_update"]:
            files.append(entity + suffix + ".go")
        files.append(entity + "/" + entity + ".go")
        files.append(entity + "/where.go")

    libraries = {}
    outputs = []
    for f in files:
        outfile = ctx.actions.declare_file(f)
        outputs.append(outfile)
        (dir, _, _) = f.rpartition("/")
        if dir:
            libraries.setdefault(dir, []).append(outfile)
        else:
            libraries.setdefault("ent", []).append(outfile)

    schema_srcs = []
    for pkg in ctx.attr.gopath[GoPath].packages:
        for src in pkg.srcs:
            schema_srcs.append(src)

    schema_path = "./" + ctx.attr.schema.label.package
    schema_package = ctx.attr.schema[GoSource].library.importpath
    target_path = outputs[0].dirname  # TODO: better/cleaner way?
    target_package = ctx.attr.importpath

    inputs_depset = depset([gomod_file, gosum_file] + ctx.files.data + schema_srcs)

    ctx.actions.run_shell(
        mnemonic = "EntGenerate",
        progress_message = "Generating Ent files in {dir}".format(dir = target_path),
        command = """
        set -eu

        cp "$5" go.mod
        cp "$6" go.sum
        chmod 777 go.mod go.sum

        export PATH="$(pwd)/{gobin}:$PATH"
        export GOCACHE="$(pwd)/.gocache"
        export GOPATH="$(pwd)/.gopath"

        exec {generate} "$1" "$2" "$3" "$4"
        """.format(
            gobin = go.go.dirname,
            generate = ctx.executable.generate_tool.path,
        ),
        arguments = [
            schema_path,
            schema_package,
            target_path,
            target_package,
            gomod_file.path,
            gosum_file.path,
        ],
        # TODO: check rules_go again what tools are really needed here.
        tools = [ctx.executable.generate_tool] + go.sdk_tools + go.sdk_files,
        inputs = inputs_depset,
        outputs = outputs,
        env = {"GOROOT_FINAL": "GOROOT"},
    )

    return [
        DefaultInfo(
            files = depset(outputs),
            runfiles = None,
        ),
        EntGenerateInfo(
            libraries = libraries,
            entities = ctx.attr.entities,
            schema = ctx.attr.schema,
            schema_path = schema_path,
            schema_packagename = schema_package,
            target_path = target_path,
            target_importpath = target_package,
        ),
    ]

_ent_generate = rule(
    implementation = _ent_generate_impl,
    attrs = {
        "schema": attr.label(
            mandatory = True,
        ),
        "generate_tool": attr.label(
            executable = True,
            default = Label("@com_github_cloneable_rules_ent//cmd/generate"),
            cfg = "exec",
        ),
        "_go_context_data": attr.label(
            default = Label("@io_bazel_rules_go//:go_context_data"),
        ),
        "gopath": attr.label(),
        "importpath": attr.string(mandatory = True),
        "data": attr.label_list(),
        "deps": attr.label_list(
            default = [
                "@io_entgo_ent//:go_default_library",
                "@io_entgo_ent//dialect:go_default_library",
                "@io_entgo_ent//dialect/sql:go_default_library",
                "@io_entgo_ent//dialect/sql/schema:go_default_library",
                "@io_entgo_ent//dialect/sql/sqlgraph:go_default_library",
                "@io_entgo_ent//schema/field:go_default_library",
            ],
        ),
        "gomod": attr.label(
            default = Label("@//:go.mod"),
            doc = "The go.mod file at the root of the repo",
            allow_single_file = [".mod"],
        ),
        "gosum": attr.label(
            default = Label("@//:go.sum"),
            doc = "The go.sum file at the root of the repo",
            allow_single_file = [".sum"],
        ),
        # TODO: remove this.
        "entities": attr.string_list(mandatory = True),
        "extra_outputs": attr.string_list(),
    },
    toolchains = ["@io_bazel_rules_go//go:toolchain"],
)

def _ent_library_impl(ctx):
    go = go_context(ctx)
    ent = ctx.attr.ent_generate[EntGenerateInfo]

    lib = "ent"
    if ctx.attr.entlib:
        lib = ctx.attr.entlib

    files = ent.libraries[lib]

    library = go.new_library(go, srcs = files, deps = ctx.attr.deps + ctx.attr._ent_deps + [ent.schema])
    source = go.library_to_source(go, ctx.attr, library, ctx.coverage_instrumented())
    archive = go.archive(go, source = source)

    return [library, source, archive, DefaultInfo(files = depset(files)), OutputGroupInfo(
        cgo_exports = archive.cgo_exports,
        compilation_outputs = [archive.data.file],
    )]

_ent_library = rule(
    implementation = _ent_library_impl,
    attrs = {
        "importpath": attr.string(mandatory = True),
        "entlib": attr.string(),
        "ent_generate": attr.label(mandatory = True, providers = [EntGenerateInfo]),
        "deps": attr.label_list(),
        "_ent_deps": attr.label_list(
            default = [
                "@io_entgo_ent//:go_default_library",
                "@io_entgo_ent//dialect:go_default_library",
                "@io_entgo_ent//dialect/sql:go_default_library",
                "@io_entgo_ent//dialect/sql/schema:go_default_library",
                "@io_entgo_ent//dialect/sql/sqlgraph:go_default_library",
                "@io_entgo_ent//schema/field:go_default_library",
            ],
        ),
        "_go_context_data": attr.label(
            default = Label("@io_bazel_rules_go//:go_context_data"),
        ),
    },
    toolchains = ["@io_bazel_rules_go//go:toolchain"],
)

def go_ent_library(
        name,
        entities,
        schema,
        visibility,
        importpath,
        extra_deps = [],
        **kwargs):
    # TODO: handle potential name conflicts.
    go_path(
        name = name + "_gopath",
        deps = [schema],
    )
    _ent_generate(
        name = name + "_generate",
        entities = entities,
        schema = schema,
        importpath = importpath,
        gopath = ":" + name + "_gopath",
        visibility = [":__subpackages__"],
        **kwargs
    )

    default_deps = [
        schema,
        "@io_entgo_ent//:go_default_library",
        "@io_entgo_ent//dialect:go_default_library",
        "@io_entgo_ent//dialect/sql:go_default_library",
        "@io_entgo_ent//dialect/sql/schema:go_default_library",
        "@io_entgo_ent//dialect/sql/sqlgraph:go_default_library",
        "@io_entgo_ent//schema/field:go_default_library",
    ]
    libdeps = {
        "enttest": [
            ":" + name,
            ":" + name + "_runtime",
        ] + default_deps,
        "hook": [
            ":" + name,
        ] + default_deps,
        "migrate": [
        ] + default_deps,
        "predicate": [
        ] + default_deps,
        "runtime": [
        ] + default_deps,
    }
    for entity in entities:
        libdeps[entity] = [
            ":" + name + "_predicate",
        ] + default_deps

    _ent_library(
        name = name,
        ent_generate = ":" + name + "_generate",
        importpath = importpath,
        visibility = visibility,
        deps = [
            ":" + name + "_predicate",
            ":" + name + "_migrate",
        ] + default_deps + extra_deps + [":" + name + "_" + entity for entity in entities],
    )
    for libname, deps in libdeps.items():
        _ent_library(
            name = name + "_" + libname,
            entlib = libname,
            ent_generate = ":" + name + "_generate",
            importpath = importpath + "/" + libname,
            visibility = visibility,
            deps = deps,
        )
