const std = @import("std");
const contract = @import("update_service_contract");

pub const max_packages: usize = 64;
pub const max_components: usize = 192;

pub const SessionState = enum(u8) {
    available,
    downloading,
    downloaded,
    verifying,
    installing,
    installed,
    staged,
    pending_restart,
    failed,
};

pub const Package = struct {
    offer: contract.Offer = .{},
    state: SessionState = .available,
    result: i32 = contract.result_ok,
    progress_current: u64 = 0,
    progress_total: u64 = 0,
    component_start: u16 = 0,
    component_count: u16 = 0,
};

pub const Component = struct {
    package_index: u16 = 0,
    value: contract.OfferComponent = .{},
};

pub const Model = struct {
    search_job_id: u32 = 0,
    current_release: [contract.offer_release_capacity]u8 = .{0} ** contract.offer_release_capacity,
    current_release_len: u8 = 0,
    target_release: [contract.offer_release_capacity]u8 = .{0} ** contract.offer_release_capacity,
    target_release_len: u8 = 0,
    packages: [max_packages]Package = .{Package{}} ** max_packages,
    package_count: usize = 0,
    components: [max_components]Component = .{Component{}} ** max_components,
    component_count: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,

    pub fn clearForSearch(self: *Model, job_id: u32) void {
        self.* = .{ .search_job_id = job_id };
    }

    pub fn clearForPendingSearch(self: *Model) void {
        self.* = .{};
    }

    pub fn acceptResultPage(self: *Model, page: *const contract.ResultsPage) bool {
        if (!page.valid() or page.job_id == 0 or page.job_id != self.search_job_id or
            page.total > self.packages.len or page.index != self.package_count) return false;
        if (self.package_count == 0) {
            self.current_release_len = page.current_release_len;
            @memcpy(self.current_release[0..page.current_release_len], page.currentReleaseText());
        }
        if (page.index >= page.total) return page.has_offer == 0;
        if (page.has_offer == 0 or !page.offer.valid()) return false;
        const state = offerState(page.offer.state) orelse return false;
        if (self.package_count != 0 and !std.mem.eql(u8, self.targetReleaseText(), page.offer.release[0..page.offer.release_len]))
            return false;
        if (self.package_count == 0) {
            self.target_release_len = @intCast(page.offer.release_len);
            @memcpy(self.target_release[0..page.offer.release_len], page.offer.release[0..page.offer.release_len]);
        }
        self.packages[self.package_count] = .{
            .offer = page.offer,
            .state = state,
            .result = page.offer.result,
            .progress_current = page.offer.progress_current,
            .progress_total = page.offer.progress_total,
            .component_start = @intCast(self.component_count),
        };
        self.package_count += 1;
        return true;
    }

    pub fn acceptComponentPage(self: *Model, page: *const contract.ComponentPage) bool {
        if (!page.valid() or page.job_id != self.search_job_id or page.result_index >= self.package_count or
            page.component_index >= page.total or page.has_component == 0 or self.component_count >= self.components.len)
            return false;
        const package = &self.packages[page.result_index];
        if (page.component_index != package.component_count or
            page.total != package.offer.component_count or
            package.component_start + package.component_count != self.component_count) return false;
        self.components[self.component_count] = .{
            .package_index = @intCast(page.result_index),
            .value = page.component,
        };
        self.component_count += 1;
        package.component_count += 1;
        return true;
    }

    pub fn updatePackage(self: *Model, package_index: usize, status: contract.Status) bool {
        if (package_index >= self.package_count or !status.valid()) return false;
        const package = &self.packages[package_index];
        package.result = status.result;
        package.progress_current = status.progress_current;
        package.progress_total = status.progress_total;
        package.state = switch (contract.stateFromWire(status.state) orelse return false) {
            .queued, .authenticating, .searching => package.state,
            .downloading => .downloading,
            .downloaded => .downloaded,
            .verifying => .verifying,
            .installing => .installing,
            .installed => .installed,
            .staged => .staged,
            .pending_restart => .pending_restart,
            .failed, .interrupted, .cancelled => .failed,
            .available => .available,
            else => package.state,
        };
        return true;
    }

    pub fn actionEnabled(self: *const Model, package_index: usize, service_busy: bool) bool {
        if (service_busy or package_index >= self.package_count) return false;
        return switch (self.packages[package_index].state) {
            .available, .downloaded, .failed => true,
            else => false,
        };
    }

    pub fn actionLabel(self: *const Model, package_index: usize) []const u8 {
        if (package_index >= self.package_count) return "Update";
        return switch (self.packages[package_index].state) {
            .downloaded => "Install",
            .failed => "Retry",
            else => "Update",
        };
    }

    pub fn updateAllEnabled(self: *const Model, service_busy: bool) bool {
        if (service_busy or self.search_job_id == 0 or self.package_count == 0) return false;
        for (self.packages[0..self.package_count]) |package| switch (package.state) {
            .available, .downloaded, .failed => return true,
            else => {},
        };
        return false;
    }

    pub fn restartReadyFromStatus(status: contract.Status, service_busy: bool) bool {
        if (service_busy or !status.valid() or status.result != contract.result_ok) return false;
        if (status.operation != contract.op_install and status.operation != contract.op_update_all) return false;
        return contract.stateFromWire(status.state) == .pending_restart and
            (status.flags & contract.flag_restart_required) != 0;
    }

    pub fn select(self: *Model, package_index: usize, visible_rows: usize) bool {
        if (package_index >= self.package_count) return false;
        self.selected = package_index;
        if (package_index < self.scroll) self.scroll = package_index;
        if (visible_rows != 0 and package_index >= self.scroll + visible_rows)
            self.scroll = package_index + 1 - visible_rows;
        return true;
    }

    pub fn scrollBy(self: *Model, delta: i32, visible_rows: usize) void {
        if (visible_rows == 0 or self.package_count <= visible_rows) {
            self.scroll = 0;
            return;
        }
        const maximum = self.package_count - visible_rows;
        if (delta < 0) {
            const magnitude: usize = @intCast(-delta);
            self.scroll -|= magnitude;
        } else {
            self.scroll = @min(maximum, self.scroll + @as(usize, @intCast(delta)));
        }
    }

    pub fn packageComponents(self: *const Model, package_index: usize) []const Component {
        if (package_index >= self.package_count) return self.components[0..0];
        const package = &self.packages[package_index];
        const start: usize = package.component_start;
        return self.components[start .. start + package.component_count];
    }

    pub fn currentReleaseText(self: *const Model) []const u8 {
        return self.current_release[0..self.current_release_len];
    }

    pub fn targetReleaseText(self: *const Model) []const u8 {
        return self.target_release[0..self.target_release_len];
    }
};

pub fn stateText(state: SessionState) []const u8 {
    return switch (state) {
        .available => "Available",
        .downloading => "Downloading",
        .downloaded => "Downloaded",
        .verifying => "Verifying",
        .installing => "Installing",
        .installed => "Installed",
        .staged => "Staged",
        .pending_restart => "Pending restart",
        .failed => "Failed",
    };
}

fn offerState(raw: u16) ?SessionState {
    return switch (contract.stateFromWire(raw) orelse return null) {
        .available => .available,
        .downloading => .downloading,
        .downloaded => .downloaded,
        .failed => .failed,
        else => null,
    };
}

fn offer(id: []const u8, release: []const u8, components: u16) contract.Offer {
    var result = contract.Offer{
        .state = @intFromEnum(contract.State.available),
        .progress_total = 100,
        .size_bytes = 100,
        .component_count = components,
    };
    result.package_id_len = @intCast(id.len);
    @memcpy(result.package_id[0..id.len], id);
    result.release_len = @intCast(release.len);
    @memcpy(result.release[0..release.len], release);
    return result;
}

fn resultPage(job: u32, index: u32, total: u32, value: ?contract.Offer) contract.ResultsPage {
    var page = contract.ResultsPage{ .job_id = job, .index = index, .total = total };
    page.current_release_len = 7;
    @memcpy(page.current_release[0..7], "0.63.18");
    if (value) |item| {
        page.has_offer = 1;
        page.offer = item;
    }
    return page;
}

test "empty short and maximum package lists remain bounded and scrollable" {
    var model = Model{};
    model.clearForSearch(5);
    try std.testing.expect(model.acceptResultPage(&resultPage(5, 0, 0, null)));
    try std.testing.expectEqual(@as(usize, 0), model.package_count);

    model.clearForSearch(6);
    var one = resultPage(6, 0, 1, offer("ONE", "0.63.19", 1));
    try std.testing.expect(model.acceptResultPage(&one));
    try std.testing.expectEqualStrings("0.63.18", model.currentReleaseText());
    try std.testing.expectEqualStrings("0.63.19", model.targetReleaseText());

    model.clearForSearch(7);
    var index: u32 = 0;
    while (index < max_packages) : (index += 1) {
        var page = resultPage(7, index, max_packages, offer("PACKAGE", "0.63.19", 1));
        try std.testing.expect(model.acceptResultPage(&page));
    }
    model.scrollBy(1000, 6);
    try std.testing.expectEqual(max_packages - 6, model.scroll);
    model.scrollBy(-1000, 6);
    try std.testing.expectEqual(@as(usize, 0), model.scroll);
}

test "component rows retain package grouping and separate kernel versions" {
    var model = Model{};
    model.clearForSearch(9);
    var package_page = resultPage(9, 0, 1, offer("FOUNDATION", "0.63.19", 2));
    try std.testing.expect(model.acceptResultPage(&package_page));
    var first = contract.ComponentPage{ .job_id = 9, .result_index = 0, .component_index = 0, .total = 2, .has_component = 1 };
    first.component.flags = contract.component_flag_kernel | contract.component_flag_active_differs;
    first.component.installed_version_len = 5;
    @memcpy(first.component.installed_version[0..5], "0.1.1");
    first.component.offered_version_len = 5;
    @memcpy(first.component.offered_version[0..5], "0.1.2");
    first.component.active_version_len = 5;
    @memcpy(first.component.active_version[0..5], "0.1.0");
    try std.testing.expect(model.acceptComponentPage(&first));
    var second = contract.ComponentPage{ .job_id = 9, .result_index = 0, .component_index = 1, .total = 2, .has_component = 1 };
    try std.testing.expect(model.acceptComponentPage(&second));
    try std.testing.expectEqual(@as(usize, 2), model.packageComponents(0).len);
}

test "all package states drive progress and button policy without losing installed results" {
    var model = Model{};
    model.clearForSearch(11);
    var page = resultPage(11, 0, 1, offer("LIVE", "0.63.19", 1));
    try std.testing.expect(model.acceptResultPage(&page));
    try std.testing.expect(model.actionEnabled(0, false));

    var status = contract.Status{
        .operation = contract.op_download,
        .state = @intFromEnum(contract.State.downloading),
        .progress_current = 40,
        .progress_total = 100,
    };
    try std.testing.expect(model.updatePackage(0, status));
    try std.testing.expect(!model.actionEnabled(0, false));
    try std.testing.expectEqual(@as(u64, 40), model.packages[0].progress_current);

    status.operation = contract.op_install;
    status.state = @intFromEnum(contract.State.installed);
    status.progress_current = 0;
    status.progress_total = 0;
    try std.testing.expect(model.updatePackage(0, status));
    try std.testing.expectEqualStrings("Installed", stateText(model.packages[0].state));
    try std.testing.expect(!model.actionEnabled(0, false));
    try std.testing.expectEqual(@as(usize, 1), model.package_count);

    model.clearForSearch(12);
    try std.testing.expectEqual(@as(usize, 0), model.package_count);
}

test "locally submitted search remains unbound until result pages arrive" {
    var model = Model{};
    model.clearForSearch(22);
    var old_page = resultPage(22, 0, 1, offer("OLD", "0.63.19", 1));
    try std.testing.expect(model.acceptResultPage(&old_page));

    model.clearForPendingSearch();
    try std.testing.expectEqual(@as(u32, 0), model.search_job_id);
    try std.testing.expectEqual(@as(usize, 0), model.package_count);

    model.clearForSearch(23);
    var new_page = resultPage(23, 0, 1, offer("NEW", "0.63.22", 1));
    try std.testing.expect(model.acceptResultPage(&new_page));
    try std.testing.expectEqual(@as(usize, 1), model.package_count);
}

test "every visible status has a stable label and update button policy" {
    var model = Model{};
    model.clearForSearch(21);
    var page = resultPage(21, 0, 1, offer("STATUS", "0.63.19", 1));
    try std.testing.expect(model.acceptResultPage(&page));
    const cases = [_]struct { state: SessionState, label: []const u8, enabled: bool }{
        .{ .state = .available, .label = "Available", .enabled = true },
        .{ .state = .downloading, .label = "Downloading", .enabled = false },
        .{ .state = .downloaded, .label = "Downloaded", .enabled = true },
        .{ .state = .verifying, .label = "Verifying", .enabled = false },
        .{ .state = .installing, .label = "Installing", .enabled = false },
        .{ .state = .installed, .label = "Installed", .enabled = false },
        .{ .state = .staged, .label = "Staged", .enabled = false },
        .{ .state = .pending_restart, .label = "Pending restart", .enabled = false },
        .{ .state = .failed, .label = "Failed", .enabled = true },
    };
    for (cases) |case| {
        model.packages[0].state = case.state;
        try std.testing.expectEqualStrings(case.label, stateText(case.state));
        try std.testing.expectEqual(case.enabled, model.actionEnabled(0, false));
    }
    try std.testing.expect(!model.actionEnabled(0, true));
    model.packages[0].state = .downloaded;
    try std.testing.expectEqualStrings("Install", model.actionLabel(0));
    model.packages[0].state = .failed;
    try std.testing.expectEqualStrings("Retry", model.actionLabel(0));
    try std.testing.expect(model.updateAllEnabled(false));
    try std.testing.expect(!model.updateAllEnabled(true));
    model.packages[0].state = .staged;
    try std.testing.expect(!model.updateAllEnabled(false));
}

test "reopened client can bind an active service job to its search package" {
    const status = contract.Status{
        .job_id = 31,
        .operation = contract.op_download,
        .state = @intFromEnum(contract.State.downloading),
        .progress_current = 4093,
        .progress_total = 8192,
        .source_job_id = 29,
        .result_index = 4,
    };
    try std.testing.expect(status.valid());
    try std.testing.expectEqual(@as(u32, 29), status.source_job_id);
    try std.testing.expectEqual(@as(u32, 4), status.result_index);
}

test "individual and update all completion expose only a prepared restart" {
    const ready = contract.Status{
        .operation = contract.op_install,
        .state = @intFromEnum(contract.State.pending_restart),
        .flags = contract.flag_restart_required,
    };
    try std.testing.expect(Model.restartReadyFromStatus(ready, false));
    var update_all = ready;
    update_all.operation = contract.op_update_all;
    try std.testing.expect(Model.restartReadyFromStatus(update_all, false));
    var merely_staged = ready;
    merely_staged.state = @intFromEnum(contract.State.staged);
    try std.testing.expect(!Model.restartReadyFromStatus(merely_staged, false));
    var failed = ready;
    failed.result = contract.result_invalid;
    try std.testing.expect(!Model.restartReadyFromStatus(failed, false));
    try std.testing.expect(!Model.restartReadyFromStatus(ready, true));
}
