const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{
        .zig_module_roots = &.{sdk_dep.namedLazyPath("update_service_contract")},
    });
}
