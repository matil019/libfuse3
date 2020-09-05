# libfuse3: A Haskell binding to libfuse-3.x

![GitHub Actions](https://github.com/matil019/haskell-libfuse3/workflows/Haskell%20CI/badge.svg?branch=master)

## Important notes

- Executables using `libfuse3` should be compiled with the threaded runtime (`-threaded`).
- Developed and tested on Linux only. Not tested on other UNIXes such as BSD and MacOS because I don't own them / machines to run them on.

## System dependencies

This package depends on the C library [libfuse][libfuse] and `pkg-config`. Please install them with your system package manager before building this package. For example, on Ubuntu:

```sh
sudo apt-get update && sudo apt-get install libfuse3-dev pkg-config
```

**NOTE:** `libfuse3-dev` is not available until Ubuntu-20.04 (a.k.a. "focal").

**NOTE2:** Not to be confused with `libfuse-dev` (whose version is 2.x). It can coexist with `libfuse3-dev`, but it is incompatible with this package.

## Building from HEAD

This packages uses the `./configure` script, but it is not checked into the git repository. To build the source checked out from git, you must generate it from `configure.ac` before invoking any of the `cabal` commands:

```
autoreconf -fiv
# cabal v2-build, etc.
```

You may have to install `autotools` or something like that with your system package manager.

## Examples

There are two examples, `null` and `passthrough` in the `example` directory. These are the ports of the examples in the official libfuse. They should be good start points for writing your filesystems.

Enable the cabal flag to build them:

```
cabal v2-configure --flags=examples
```

## Known issues and limitations

- A signal needs to be sent twice to stop the process and unmount the filesystem.
  - This means you have to run `kill -2 <pid>` twice or hit `Ctrl-C` twice (if running in foreground).
  - On the other hand, `fusermount3 -u` can unmount the filesystem on the first attempt.
- Not all Haskell-friendly bindings to the FUSE operations are implemented yet, including but not limited to:
  - `struct fuse_conn_info`. The availability of filesystem capabilities such as `FUSE_CAP_HANDLE_KILLPRIV` can't be checked.
  - Setting the fields of `struct fuse_file_info` from the certain fuse operations.
- Look for the `TODO` comments in the source tree for more specific topics.

If you are able to fix/implement any of these, that would be very appreciated! Please open a PR to contribute.

## Related works

- [libfuse][libfuse]: The reference implementation, to which this package binds
- [HFuse][HFuse]: The bindings to libfuse-2.x
  - `libfuse3` is based on `HFuse` (with massive rewrites).
  - `libfuse3` has more complete API and exposes internal (and unstable) API to allow workarounds.
- [fuse-rs][fuse-rs]: The Rust implementation of FUSE. Unlike this package, `fuse-rs` implements the FUSE protocol itself (i.e. replaces `libfuse`). See [its README](https://github.com/zargony/fuse-rs) for overview.

[libfuse]: https://github.com/libfuse/libfuse
[HFuse]: https://github.com/m15k/hfuse
[fuse-rs]: https://github.com/zargony/fuse-rs
