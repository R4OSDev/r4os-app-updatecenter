const std = @import("std");
const r4os = @import("r4os");
const contract = @import("update_service_contract");
const model = @import("model.zig");

const inbox_prefix = "C:\\R4OS\\UPDATE\\INBOX\\";
const call_timeout_ns: u64 = 2_000_000_000;
const poll_loops: u16 = 12;
const minimum_width: i32 = 760;
const minimum_height: i32 = 480;
const maximum_width: i32 = 1600;
const maximum_height: i32 = 1000;
const margin: i32 = 12;
const header_h: i32 = 54;
const status_h: i32 = 24;
const details_h: i32 = 224;
const package_row_h: i32 = 44;
const component_row_h: i32 = 20;
const package_button_w: i32 = 78;
const scroll_button_w: i32 = 22;

const color_bg: u32 = 0xD8D0C8;
const color_panel: u32 = 0xFFFFFF;
const color_shadow: u32 = 0x808080;
const color_title: u32 = 0x0A246A;
const color_title_text: u32 = 0xFFFFFF;
const color_text: u32 = 0x000000;
const color_muted: u32 = 0x606060;
const color_selected: u32 = 0xDCE8FF;
const color_selected_edge: u32 = 0x0A246A;
const color_ok: u32 = 0x007020;
const color_warning: u32 = 0x8A4E00;
const color_error: u32 = 0xA00000;

const palette = r4os.gui.Palette{
    .text = color_text,
    .disabled_text = color_muted,
    .face = color_bg,
    .face_light = color_panel,
    .face_shadow = color_shadow,
    .client_bg = color_panel,
    .select_bg = color_selected_edge,
    .select_text = color_title_text,
    .title_bg = color_title,
    .title_text = color_title_text,
};

const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    services: r4os.Services,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
            .services = r4_app.services() orelse return null,
        };
    }
};

const Action = enum(u8) {
    none,
    search,
    update_all,
    restart,
    update,
    list_up,
    list_down,
    component_up,
    component_down,
};

const App = struct {
    ctx: AppApi = undefined,
    connection: ?r4os.ServiceConnection = null,
    data: model.Model = .{},
    w: i32 = 900,
    h: i32 = 600,
    should_exit: bool = false,
    service_busy: bool = false,
    active_job: u32 = 0,
    active_package: usize = 0,
    poll_counter: u16 = 0,
    component_scroll: usize = 0,
    pressed: Action = .none,
    pressed_package: usize = 0,
    install_attempted_for_job: u32 = 0,
    status: [192]u8 = .{0} ** 192,
    status_len: usize = 0,
    status_is_error: bool = false,
    restart_ready: bool = false,

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() < 0) {
            self.ctx.sys.println("UPDATE.R4X requires the desktop.");
            return 1;
        }
        _ = self.ctx.desk.guiSetTitle("R4OS Update");
        _ = self.ctx.desk.guiSetMinSize(minimum_width, minimum_height);
        self.updateMetrics();
        self.setStatus("Connecting to Update Service...", false);
        self.recoverServiceState();
        self.render();
        defer self.closeConnection();

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                switch (kind) {
                    .close => return 0,
                    .resize => {
                        self.updateMetrics();
                        self.clampSelection();
                        self.render();
                    },
                    .mouse_down => self.handleMouseDown(event.x, event.y),
                    .mouse_up => self.handleMouseUp(event.x, event.y),
                    .key_down => self.handleKey(@intCast(event.key & 0xFF)),
                    else => {},
                }
            }
            self.poll_counter +%= 1;
            if (self.poll_counter >= poll_loops) {
                self.poll_counter = 0;
                if (self.active_job != 0 or self.service_busy) {
                    self.refreshStatus();
                    self.render();
                }
            }
            self.ctx.sys.sleepTicks(3);
        }
        return 0;
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = clampI32(canvas.w, minimum_width, maximum_width);
        self.h = clampI32(canvas.h, minimum_height, maximum_height);
    }

    fn closeConnection(self: *App) void {
        // Deliberately no UPDSVC cancel: closing this view never owns the job.
        if (self.connection) |*connection| {
            if (connection.valid()) _ = connection.close();
        }
        self.connection = null;
    }

    fn connectionPtr(self: *App) ?*r4os.ServiceConnection {
        if (self.connection) |*connection| {
            if (connection.valid()) return connection;
        }
        self.connection = null;
        switch (self.ctx.services.open(contract.service_name)) {
            .connection => |value| self.connection = value,
            .failure => |raw| {
                self.setCodeStatus("Update Service unavailable", raw);
                return null;
            },
        }
        return if (self.connection) |*connection| connection else null;
    }

    fn recoverServiceState(self: *App) void {
        const status = self.requestStatus(0) orelse return;
        self.applyServiceStatus(status, true);
    }

    fn requestStatus(self: *App, job_id: u32) ?contract.Status {
        const connection = self.connectionPtr() orelse return null;
        const request = contract.StatusRequest{ .job_id = job_id };
        return switch (connection.callTyped(
            contract.StatusRequest,
            contract.Status,
            contract.op_status,
            &request,
            callTimeout(),
        )) {
            .value => |value| if (value.valid()) value else invalid: {
                self.setStatus("Update Service returned an invalid status.", true);
                break :invalid null;
            },
            .timed_out => timed: {
                self.setStatus("Update Service status timed out.", true);
                break :timed null;
            },
            .remote_failure => |raw| remote: {
                self.setCodeStatus("Update Service rejected status", raw);
                break :remote null;
            },
            .failure => |raw| failed: {
                self.setCodeStatus("Update Service connection failed", raw);
                break :failed null;
            },
        };
    }

    fn refreshStatus(self: *App) void {
        const status = self.requestStatus(0) orelse return;
        self.applyServiceStatus(status, false);
    }

    fn applyServiceStatus(self: *App, status: contract.Status, recovering: bool) void {
        const state = contract.stateFromWire(status.state) orelse {
            self.setStatus("Update Service returned an unknown state.", true);
            return;
        };
        self.service_busy = (status.flags & contract.flag_busy) != 0;
        if (status.operation == contract.op_search) {
            self.active_job = if (self.service_busy) status.job_id else 0;
            if (self.data.search_job_id == 0 and status.job_id != 0 and
                (status.flags & contract.flag_results_ready) != 0)
                self.loadResults(status.job_id);
            switch (state) {
                .available => {
                    if (self.data.search_job_id != status.job_id) self.loadResults(status.job_id);
                    self.setStatus("Updates are available.", false);
                },
                .up_to_date => {
                    if (self.data.search_job_id != status.job_id) self.loadResults(status.job_id);
                    self.setStatus("R4OS is up to date.", false);
                },
                .pending_restart => {
                    if (self.data.search_job_id != status.job_id) self.loadResults(status.job_id);
                    self.setStatus("A restart is pending.", false);
                },
                .failed, .interrupted, .cancelled => self.setContractStatus(status, true),
                else => self.setContractStatus(status, false),
            }
            return;
        }

        if (status.operation == contract.op_download or status.operation == contract.op_install) {
            if (status.source_job_id != 0 and self.data.search_job_id != status.source_job_id)
                self.loadResults(status.source_job_id);
            const package_index: usize = status.result_index;
            if (package_index < self.data.package_count) {
                _ = self.data.updatePackage(package_index, status);
                self.active_package = package_index;
            }
            self.active_job = if (self.service_busy) status.job_id else 0;
            if (status.operation == contract.op_install)
                self.restart_ready = model.Model.restartReadyFromStatus(status, self.service_busy);
            self.setContractStatus(status, state == .failed or state == .interrupted or state == .cancelled);
            if (status.operation == contract.op_download and state == .downloaded and
                package_index < self.data.package_count and self.install_attempted_for_job != status.job_id)
            {
                self.install_attempted_for_job = status.job_id;
                self.beginInstall(package_index);
                return;
            }
            if (!self.service_busy) self.active_job = 0;
            return;
        }

        if (status.operation == contract.op_update_all) {
            if (status.source_job_id != 0 and self.data.search_job_id != status.source_job_id)
                self.loadResults(status.source_job_id);
            if (status.result_index < self.data.package_count)
                _ = self.data.updatePackage(status.result_index, status);
            self.active_job = if (self.service_busy) status.job_id else 0;
            self.restart_ready = model.Model.restartReadyFromStatus(status, self.service_busy);
            if (!self.service_busy and status.source_job_id != 0) self.loadResults(status.source_job_id);
            self.setContractStatus(status, state == .failed or state == .interrupted or state == .cancelled);
            return;
        }

        if (status.operation == contract.op_restart) {
            self.active_job = if (self.service_busy) status.job_id else 0;
            self.setContractStatus(status, state == .failed or state == .interrupted or state == .cancelled);
            return;
        }

        self.active_job = 0;
        if (recovering) self.setStatus("Ready. Search for updates.", false);
    }

    fn beginSearch(self: *App) void {
        if (self.service_busy) return;
        const connection = self.connectionPtr() orelse return;
        const request = contract.CommandRequest{};
        switch (connection.callTyped(
            contract.CommandRequest,
            contract.Ack,
            contract.op_search,
            &request,
            callTimeout(),
        )) {
            .value => |ack| {
                if (!ack.valid() or ack.result != contract.result_ok or ack.job_id == 0) {
                    self.setCodeStatus("Search was rejected", ack.result);
                    return;
                }
                // The accepted job is active, but its result pages do not
                // exist yet. Binding the empty model here would make the
                // completion path mistake it for an already loaded snapshot.
                self.data.clearForPendingSearch();
                self.component_scroll = 0;
                self.active_job = ack.job_id;
                self.service_busy = true;
                self.install_attempted_for_job = 0;
                self.setStatus("Searching for updates...", false);
            },
            .timed_out => {
                self.service_busy = true;
                self.setStatus("Search request timed out; checking service state.", true);
            },
            .remote_failure => |raw| self.setCodeStatus("Search was rejected", raw),
            .failure => |raw| self.setCodeStatus("Search connection failed", raw),
        }
    }

    fn beginSnapshotOperation(self: *App, operation: u16) void {
        if (self.service_busy or self.data.search_job_id == 0) return;
        if (operation == contract.op_update_all and !self.data.updateAllEnabled(false)) return;
        if (operation == contract.op_restart and !self.restart_ready) return;
        const connection = self.connectionPtr() orelse return;
        const request = contract.SnapshotRequest{ .search_job_id = self.data.search_job_id };
        switch (connection.callTyped(
            contract.SnapshotRequest,
            contract.Ack,
            operation,
            &request,
            callTimeout(),
        )) {
            .value => |ack| {
                if (!ack.valid() or ack.result != contract.result_ok or ack.job_id == 0) {
                    self.setCodeStatus(if (operation == contract.op_restart) "Restart was rejected" else "Update All was rejected", ack.result);
                    return;
                }
                self.active_job = ack.job_id;
                self.service_busy = true;
                if (operation == contract.op_update_all) self.restart_ready = false;
                self.setStatus(if (operation == contract.op_restart) "Committing restart batch..." else "Updating all packages...", false);
            },
            .timed_out => {
                self.service_busy = true;
                self.setStatus("Request timed out; checking service state.", true);
            },
            .remote_failure => |raw| self.setCodeStatus("Update Service rejected request", raw),
            .failure => |raw| self.setCodeStatus("Update Service connection failed", raw),
        }
    }

    fn beginUpdate(self: *App, package_index: usize) void {
        if (!self.data.actionEnabled(package_index, self.service_busy)) return;
        if (self.data.packages[package_index].state == .downloaded) {
            self.beginInstall(package_index);
            return;
        }
        const connection = self.connectionPtr() orelse return;
        const request = contract.DownloadRequest{
            .search_job_id = self.data.search_job_id,
            .result_index = @intCast(package_index),
        };
        switch (connection.callTyped(
            contract.DownloadRequest,
            contract.Ack,
            contract.op_download,
            &request,
            callTimeout(),
        )) {
            .value => |ack| {
                if (!ack.valid() or ack.result != contract.result_ok or ack.job_id == 0) {
                    self.setCodeStatus("Download was rejected", ack.result);
                    return;
                }
                self.data.packages[package_index].state = .downloading;
                self.data.packages[package_index].progress_current = 0;
                self.data.packages[package_index].progress_total = self.data.packages[package_index].offer.size_bytes;
                self.active_job = ack.job_id;
                self.active_package = package_index;
                self.service_busy = true;
                self.install_attempted_for_job = 0;
                self.setStatus("Downloading selected update...", false);
            },
            .timed_out => {
                self.service_busy = true;
                self.setStatus("Download request timed out; checking service state.", true);
            },
            .remote_failure => |raw| self.setCodeStatus("Download was rejected", raw),
            .failure => |raw| self.setCodeStatus("Download connection failed", raw),
        }
    }

    fn beginInstall(self: *App, package_index: usize) void {
        if (package_index >= self.data.package_count) return;
        const offer = &self.data.packages[package_index].offer;
        const filename_len: usize = offer.filename_len;
        if (filename_len == 0 or filename_len > offer.filename.len or
            inbox_prefix.len + filename_len > contract.selection_capacity)
        {
            self.setStatus("Downloaded package has an invalid filename.", true);
            return;
        }
        var request = contract.CommandRequest{};
        @memcpy(request.selection[0..inbox_prefix.len], inbox_prefix);
        @memcpy(request.selection[inbox_prefix.len .. inbox_prefix.len + filename_len], offer.filename[0..filename_len]);
        request.selection_len = @intCast(inbox_prefix.len + filename_len);
        const connection = self.connectionPtr() orelse return;
        switch (connection.callTyped(
            contract.CommandRequest,
            contract.Ack,
            contract.op_install,
            &request,
            callTimeout(),
        )) {
            .value => |ack| {
                if (!ack.valid() or ack.result != contract.result_ok or ack.job_id == 0) {
                    self.setCodeStatus("Install was rejected", ack.result);
                    return;
                }
                self.data.packages[package_index].state = .installing;
                self.data.packages[package_index].progress_current = 0;
                self.data.packages[package_index].progress_total = 0;
                self.active_job = ack.job_id;
                self.active_package = package_index;
                self.service_busy = true;
                self.setStatus("Installing selected update...", false);
            },
            .timed_out => {
                self.service_busy = true;
                self.setStatus("Install request timed out; checking service state.", true);
            },
            .remote_failure => |raw| self.setCodeStatus("Install was rejected", raw),
            .failure => |raw| self.setCodeStatus("Install connection failed", raw),
        }
    }

    fn loadResults(self: *App, search_job_id: u32) void {
        if (search_job_id == 0) return;
        const connection = self.connectionPtr() orelse return;
        var next = model.Model{};
        next.clearForSearch(search_job_id);
        var result_index: u32 = 0;
        while (result_index < model.max_packages) : (result_index += 1) {
            const request = contract.ResultsRequest{ .job_id = search_job_id, .index = result_index };
            const page = switch (connection.callTyped(
                contract.ResultsRequest,
                contract.ResultsPage,
                contract.op_results,
                &request,
                callTimeout(),
            )) {
                .value => |value| value,
                .timed_out => {
                    self.setStatus("Loading update results timed out.", true);
                    return;
                },
                .remote_failure => |raw| {
                    self.setCodeStatus("Update results unavailable", raw);
                    return;
                },
                .failure => |raw| {
                    self.setCodeStatus("Update result connection failed", raw);
                    return;
                },
            };
            if (!next.acceptResultPage(&page)) {
                self.setStatus("Update Service returned invalid result data.", true);
                return;
            }
            if (page.total == 0) break;
            if (!self.loadComponents(connection, &next, search_job_id, result_index, page.offer.component_count)) return;
            if (result_index + 1 >= page.total) break;
        }
        self.data = next;
        self.component_scroll = 0;
        self.clampSelection();
    }

    fn loadComponents(
        self: *App,
        connection: *r4os.ServiceConnection,
        next: *model.Model,
        search_job_id: u32,
        result_index: u32,
        count: u16,
    ) bool {
        var component_index: u32 = 0;
        while (component_index < count) : (component_index += 1) {
            const request = contract.ComponentRequest{
                .job_id = search_job_id,
                .result_index = result_index,
                .component_index = component_index,
            };
            const page = switch (connection.callTyped(
                contract.ComponentRequest,
                contract.ComponentPage,
                contract.op_components,
                &request,
                callTimeout(),
            )) {
                .value => |value| value,
                .timed_out => {
                    self.setStatus("Loading package components timed out.", true);
                    return false;
                },
                .remote_failure => |raw| {
                    self.setCodeStatus("Package components unavailable", raw);
                    return false;
                },
                .failure => |raw| {
                    self.setCodeStatus("Component connection failed", raw);
                    return false;
                },
            };
            if (!next.acceptComponentPage(&page)) {
                self.setStatus("Update Service returned invalid component data.", true);
                return false;
            }
        }
        return true;
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [320]u8 = .{0} ** 320;
        _ = canvas.clear(color_bg);
        self.drawHeader(canvas, scratch[0..]);
        self.drawPackages(canvas, scratch[0..]);
        self.drawDetails(canvas, scratch[0..]);
        self.drawStatus(canvas, scratch[0..]);
        _ = paint.present();
    }

    fn drawHeader(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.w, .h = header_h }, color_title);
        _ = canvas.text(14, 9, "R4OS Update", color_title_text, color_title);
        const releases = format(scratch, "Release {s}  ->  {s}", .{
            displayOr(self.data.currentReleaseText(), "unknown"),
            displayOr(self.data.targetReleaseText(), "not searched"),
        });
        _ = canvas.textClipped(14, 29, self.w - 190, scratch, releases, color_title_text, color_title);
        _ = canvas.button(.{
            .rect = self.searchRect(),
            .text = "Search for Updates",
            .state = if (self.service_busy) .disabled else if (self.pressed == .search) .pressed else .normal,
            .palette = palette,
        }, scratch);
        _ = canvas.button(.{
            .rect = self.updateAllRect(),
            .text = "Update All",
            .state = if (!self.data.updateAllEnabled(self.service_busy)) .disabled else if (self.pressed == .update_all) .pressed else .normal,
            .palette = palette,
        }, scratch);
    }

    fn drawPackages(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.packageListRect();
        _ = canvas.rect(rect, color_shadow);
        _ = canvas.rect(rect.inset(1, 1), color_panel);
        if (self.data.package_count == 0) {
            const empty_text = if (self.service_busy) "Searching..." else "No update results. Select 'Search for Updates'.";
            _ = canvas.label(.{
                .rect = rect.inset(12, 12),
                .text = empty_text,
                .alignment = .center,
                .fg = color_muted,
                .bg = color_panel,
                .palette = palette,
            }, scratch);
            return;
        }

        var visible_index: usize = 0;
        while (visible_index < self.visiblePackageRows()) : (visible_index += 1) {
            const package_index = self.data.scroll + visible_index;
            if (package_index >= self.data.package_count) break;
            self.drawPackageRow(canvas, scratch, package_index, visible_index);
        }
        self.drawScrollButton(canvas, scratch, .list_up, "^", self.listUpRect(), self.data.scroll == 0);
        self.drawScrollButton(canvas, scratch, .list_down, "v", self.listDownRect(), self.data.scroll + self.visiblePackageRows() >= self.data.package_count);
    }

    fn drawPackageRow(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, package_index: usize, visible_index: usize) void {
        const package = &self.data.packages[package_index];
        const rect = self.packageRowRect(visible_index);
        const selected = package_index == self.data.selected;
        const background = if (selected) color_selected else color_panel;
        _ = canvas.rect(rect, background);
        if (selected) _ = canvas.rect(.{ .x = rect.x, .y = rect.y, .w = 3, .h = rect.h }, color_selected_edge);

        const title = displayOr(package.offer.titleText(), package.offer.packageIdText());
        _ = canvas.textClipped(rect.x + 9, rect.y + 5, @max(80, rect.w - 330), scratch, title, color_text, background);
        const group = format(scratch, "Package {s}  |  version {s}  |  {d} component(s)", .{
            package.offer.packageIdText(),
            fixedText(package.offer.package_version[0..], package.offer.package_version_len),
            package.offer.component_count,
        });
        _ = canvas.textClipped(rect.x + 9, rect.y + 24, @max(80, rect.w - 330), scratch, group, color_muted, background);

        const state = model.stateText(package.state);
        const state_color = stateColor(package.state);
        _ = canvas.textClipped(rect.right() - 298, rect.y + 5, 120, scratch, state, state_color, background);
        const progress = progressText(scratch, package.progress_current, package.progress_total);
        _ = canvas.textClipped(rect.right() - 298, rect.y + 24, 120, scratch, progress, color_muted, background);
        _ = canvas.button(.{
            .rect = self.packageUpdateRect(visible_index),
            .text = self.data.actionLabel(package_index),
            .state = if (!self.data.actionEnabled(package_index, self.service_busy)) .disabled else if (self.pressed == .update and self.pressed_package == package_index) .pressed else .normal,
            .palette = palette,
        }, scratch);
    }

    fn drawDetails(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.detailsRect();
        _ = canvas.groupBox(.{ .rect = rect, .title = "Selected update", .palette = palette }, scratch);
        if (self.data.package_count == 0 or self.data.selected >= self.data.package_count) return;
        const package = &self.data.packages[self.data.selected];
        const activation = if ((package.offer.flags & contract.offer_flag_restart_required) != 0) "Restart" else "Live";
        const priority = if ((package.offer.flags & contract.offer_flag_foundation) != 0) "Foundation (first)" else "Normal";
        const summary = format(scratch, "Activation: {s}   Priority: {s}   Status: {s}", .{
            activation,
            priority,
            model.stateText(package.state),
        });
        _ = canvas.textClipped(rect.x + 12, rect.y + 22, rect.w - 24, scratch, summary, color_text, color_bg);
        const description = displayOr(package.offer.descriptionText(), "No package description.");
        drawWrapped(canvas, scratch, rect.x + 12, rect.y + 43, rect.w - 24, 2, description, color_muted, color_bg);

        const components = self.data.packageComponents(self.data.selected);
        const first = @min(self.component_scroll, components.len);
        const visible = self.visibleComponentRows();
        const last = @min(components.len, first + visible);
        const component_title = format(scratch, "Components {d}-{d} of {d}   Name / Type   Installed -> Offered", .{
            if (components.len == 0) @as(usize, 0) else first + 1,
            last,
            components.len,
        });
        _ = canvas.textClipped(rect.x + 12, rect.y + 84, rect.w - 90, scratch, component_title, color_title, color_bg);
        self.drawScrollButton(canvas, scratch, .component_up, "^", self.componentUpRect(), first == 0);
        self.drawScrollButton(canvas, scratch, .component_down, "v", self.componentDownRect(), last >= components.len);

        var row: usize = 0;
        while (first + row < last) : (row += 1) {
            const component = &components[first + row].value;
            const y = rect.y + 106 + @as(i32, @intCast(row)) * component_row_h;
            const missing = (component.flags & contract.component_flag_missing) != 0;
            const kind = fixedText(component.kind[0..], component.kind_len);
            const name = fixedText(component.name[0..], component.name_len);
            const installed = if (missing) "not installed" else displayOr(fixedText(component.installed_version[0..], component.installed_version_len), "unknown");
            const offered = displayOr(fixedText(component.offered_version[0..], component.offered_version_len), "unknown");
            const line = format(scratch, "{s} / {s}   {s} -> {s}", .{ name, kind, installed, offered });
            _ = canvas.textClipped(rect.x + 18, y, rect.w - 36, scratch, line, color_text, color_bg);
            if ((component.flags & contract.component_flag_kernel) != 0) {
                const active = displayOr(fixedText(component.active_version[0..], component.active_version_len), "unknown");
                const active_line = format(scratch, "Kernel running: {s}   installed on disk: {s}", .{ active, installed });
                _ = canvas.textClipped(rect.x + @divTrunc(rect.w, 2), y, @divTrunc(rect.w, 2) - 24, scratch, active_line, color_warning, color_bg);
            }
        }
    }

    fn drawStatus(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.statusRect();
        _ = canvas.rect(rect, color_shadow);
        _ = canvas.rect(rect.inset(1, 1), color_bg);
        const restart_visible = self.restart_ready;
        const reserved_width: i32 = if (restart_visible) 142 else 12;
        _ = canvas.textClipped(rect.x + 6, rect.y + 5, rect.w - reserved_width, scratch, self.status[0..self.status_len], if (self.status_is_error) color_error else color_text, color_bg);
        if (restart_visible) _ = canvas.button(.{
            .rect = self.restartRect(),
            .text = "Restart R4OS",
            .state = if (self.service_busy) .disabled else if (self.pressed == .restart) .pressed else .normal,
            .palette = palette,
        }, scratch);
    }

    fn drawScrollButton(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, action: Action, label: []const u8, rect: r4os.gui.Rect, disabled: bool) void {
        _ = canvas.button(.{
            .rect = rect,
            .text = label,
            .state = if (disabled) .disabled else if (self.pressed == action) .pressed else .normal,
            .palette = palette,
        }, scratch);
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        self.pressed = .none;
        if (self.searchRect().contains(x, y) and !self.service_busy) self.pressed = .search;
        if (self.updateAllRect().contains(x, y) and self.data.updateAllEnabled(self.service_busy)) self.pressed = .update_all;
        if (self.restart_ready and self.restartRect().contains(x, y) and !self.service_busy) self.pressed = .restart;
        if (self.listUpRect().contains(x, y) and self.data.scroll > 0) self.pressed = .list_up;
        if (self.listDownRect().contains(x, y) and
            self.data.scroll + self.visiblePackageRows() < self.data.package_count) self.pressed = .list_down;
        const components = if (self.data.package_count == 0) self.data.components[0..0] else self.data.packageComponents(self.data.selected);
        if (self.componentUpRect().contains(x, y) and self.component_scroll > 0) self.pressed = .component_up;
        if (self.componentDownRect().contains(x, y) and
            self.component_scroll + self.visibleComponentRows() < components.len) self.pressed = .component_down;

        if (self.packageAt(x, y)) |hit| {
            self.data.selected = hit.package_index;
            self.component_scroll = 0;
            if (hit.update and self.data.actionEnabled(hit.package_index, self.service_busy)) {
                self.pressed = .update;
                self.pressed_package = hit.package_index;
            }
        }
        self.render();
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        const action = self.pressed;
        const package_index = self.pressed_package;
        self.pressed = .none;
        switch (action) {
            .search => if (self.searchRect().contains(x, y)) self.beginSearch(),
            .update_all => if (self.updateAllRect().contains(x, y)) self.beginSnapshotOperation(contract.op_update_all),
            .restart => if (self.restartRect().contains(x, y)) self.beginSnapshotOperation(contract.op_restart),
            .update => if (self.updateRectForPackage(package_index).contains(x, y)) self.beginUpdate(package_index),
            .list_up => if (self.listUpRect().contains(x, y)) self.data.scrollBy(-1, self.visiblePackageRows()),
            .list_down => if (self.listDownRect().contains(x, y)) self.data.scrollBy(1, self.visiblePackageRows()),
            .component_up => {
                if (self.componentUpRect().contains(x, y)) self.component_scroll -|= 1;
            },
            .component_down => {
                if (self.componentDownRect().contains(x, y)) self.component_scroll += 1;
            },
            .none => {},
        }
        self.render();
    }

    fn handleKey(self: *App, key: u8) void {
        switch (key) {
            r4os.gui.Key.escape => self.should_exit = true,
            r4os.gui.Key.up => {
                if (self.data.selected > 0) {
                    _ = self.data.select(self.data.selected - 1, self.visiblePackageRows());
                    self.component_scroll = 0;
                }
            },
            r4os.gui.Key.down => {
                if (self.data.selected + 1 < self.data.package_count) {
                    _ = self.data.select(self.data.selected + 1, self.visiblePackageRows());
                    self.component_scroll = 0;
                }
            },
            r4os.gui.Key.home => {
                if (self.data.package_count != 0) _ = self.data.select(0, self.visiblePackageRows());
                self.component_scroll = 0;
            },
            r4os.gui.Key.end => {
                if (self.data.package_count != 0) _ = self.data.select(self.data.package_count - 1, self.visiblePackageRows());
                self.component_scroll = 0;
            },
            r4os.gui.Key.enter => if (self.data.package_count != 0) self.beginUpdate(self.data.selected),
            'a', 'A' => self.beginSnapshotOperation(contract.op_update_all),
            'r', 'R', 's', 'S' => self.beginSearch(),
            else => {},
        }
        self.render();
    }

    fn packageAt(self: *const App, x: i32, y: i32) ?struct { package_index: usize, update: bool } {
        if (!self.packageListRect().contains(x, y)) return null;
        var visible_index: usize = 0;
        while (visible_index < self.visiblePackageRows()) : (visible_index += 1) {
            const package_index = self.data.scroll + visible_index;
            if (package_index >= self.data.package_count) break;
            if (self.packageRowRect(visible_index).contains(x, y)) return .{
                .package_index = package_index,
                .update = self.packageUpdateRect(visible_index).contains(x, y),
            };
        }
        return null;
    }

    fn updateRectForPackage(self: *const App, package_index: usize) r4os.gui.Rect {
        if (package_index < self.data.scroll) return .{};
        const visible = package_index - self.data.scroll;
        if (visible >= self.visiblePackageRows()) return .{};
        return self.packageUpdateRect(visible);
    }

    fn clampSelection(self: *App) void {
        if (self.data.package_count == 0) {
            self.data.selected = 0;
            self.data.scroll = 0;
            self.component_scroll = 0;
            return;
        }
        if (self.data.selected >= self.data.package_count) self.data.selected = self.data.package_count - 1;
        _ = self.data.select(self.data.selected, self.visiblePackageRows());
        const count = self.data.packageComponents(self.data.selected).len;
        if (self.component_scroll >= count) self.component_scroll = if (count == 0) 0 else count - 1;
    }

    fn setContractStatus(self: *App, value: contract.Status, failed: bool) void {
        const reason = displayOr(value.reasonText(), contract.stateName(value.state));
        const text = std.fmt.bufPrint(self.status[0..], "{s}: {s}", .{
            contract.operationName(value.operation), reason,
        }) catch "Update Service status is too long.";
        self.status_len = text.len;
        self.status_is_error = failed;
    }

    fn setStatus(self: *App, value: []const u8, failed: bool) void {
        @memset(self.status[0..], 0);
        self.status_len = @min(value.len, self.status.len);
        if (self.status_len != 0) @memcpy(self.status[0..self.status_len], value[0..self.status_len]);
        self.status_is_error = failed;
    }

    fn setCodeStatus(self: *App, prefix: []const u8, raw: i32) void {
        const text = std.fmt.bufPrint(self.status[0..], "{s} (error {d}).", .{ prefix, raw }) catch "Update Service error.";
        self.status_len = text.len;
        self.status_is_error = true;
    }

    fn searchRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 170, .y = 14, .w = 156, .h = 28 };
    }

    fn updateAllRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.w - 272, .y = 14, .w = 94, .h = 28 };
    }

    fn packageListRect(self: *const App) r4os.gui.Rect {
        return .{ .x = margin, .y = header_h + 10, .w = self.w - margin * 2, .h = self.packageListHeight() };
    }

    fn packageListHeight(self: *const App) i32 {
        return @max(package_row_h + 2, self.h - header_h - details_h - status_h - 32);
    }

    fn packageRowRect(self: *const App, visible_index: usize) r4os.gui.Rect {
        const list = self.packageListRect();
        return .{
            .x = list.x + 2,
            .y = list.y + 2 + @as(i32, @intCast(visible_index)) * package_row_h,
            .w = list.w - scroll_button_w - 6,
            .h = package_row_h,
        };
    }

    fn packageUpdateRect(self: *const App, visible_index: usize) r4os.gui.Rect {
        const row = self.packageRowRect(visible_index);
        return .{ .x = row.right() - package_button_w - 8, .y = row.y + 9, .w = package_button_w, .h = 26 };
    }

    fn visiblePackageRows(self: *const App) usize {
        return @max(1, @as(usize, @intCast(@divTrunc(self.packageListRect().h - 4, package_row_h))));
    }

    fn listUpRect(self: *const App) r4os.gui.Rect {
        const list = self.packageListRect();
        return .{ .x = list.right() - scroll_button_w - 2, .y = list.y + 2, .w = scroll_button_w, .h = 24 };
    }

    fn listDownRect(self: *const App) r4os.gui.Rect {
        const list = self.packageListRect();
        return .{ .x = list.right() - scroll_button_w - 2, .y = list.bottom() - 26, .w = scroll_button_w, .h = 24 };
    }

    fn detailsRect(self: *const App) r4os.gui.Rect {
        const list = self.packageListRect();
        return .{ .x = margin, .y = list.bottom() + 8, .w = self.w - margin * 2, .h = details_h };
    }

    fn componentUpRect(self: *const App) r4os.gui.Rect {
        const rect = self.detailsRect();
        return .{ .x = rect.right() - 58, .y = rect.y + 78, .w = 22, .h = 22 };
    }

    fn componentDownRect(self: *const App) r4os.gui.Rect {
        const rect = self.detailsRect();
        return .{ .x = rect.right() - 32, .y = rect.y + 78, .w = 22, .h = 22 };
    }

    fn visibleComponentRows(self: *const App) usize {
        _ = self;
        return @max(1, @as(usize, @intCast(@divTrunc(details_h - 112, component_row_h))));
    }

    fn statusRect(self: *const App) r4os.gui.Rect {
        return .{ .x = margin, .y = self.h - status_h - 6, .w = self.w - margin * 2, .h = status_h };
    }

    fn restartRect(self: *const App) r4os.gui.Rect {
        const rect = self.statusRect();
        return .{ .x = rect.right() - 134, .y = rect.y + 1, .w = 132, .h = rect.h - 2 };
    }
};

var runtime: App = .{};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    const api = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    runtime = .{ .ctx = api };
    return runtime.run();
}

fn callTimeout() r4os.time_contract.Timeout {
    return r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(call_timeout_ns));
}

fn fixedText(buffer: []const u8, raw_len: anytype) []const u8 {
    const len: usize = @min(@as(usize, @intCast(raw_len)), buffer.len);
    return buffer[0..len];
}

fn displayOr(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len == 0) fallback else value;
}

fn format(buffer: []u8, comptime template: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, template, args) catch "...";
}

fn progressText(buffer: []u8, current: u64, total: u64) []const u8 {
    if (total == 0) return "";
    const percent = @min(@as(u64, 100), current *| 100 / total);
    return format(buffer, "{d}%  ({d}/{d} bytes)", .{ percent, current, total });
}

fn stateColor(state: model.SessionState) u32 {
    return switch (state) {
        .installed => color_ok,
        .staged, .pending_restart => color_warning,
        .failed => color_error,
        else => color_title,
    };
}

fn drawWrapped(
    canvas: r4os.gui.Canvas,
    scratch: []u8,
    x: i32,
    y: i32,
    width: i32,
    maximum_lines: usize,
    text: []const u8,
    fg: u32,
    bg: u32,
) void {
    var remaining = text;
    var line_index: usize = 0;
    const chars = @max(@as(usize, 1), canvas.charsForWidth(width));
    while (remaining.len != 0 and line_index < maximum_lines) : (line_index += 1) {
        var take = @min(chars, remaining.len);
        if (take < remaining.len) {
            if (std.mem.lastIndexOfScalar(u8, remaining[0..take], ' ')) |space| {
                if (space != 0) take = space;
            }
        }
        _ = canvas.textClipped(x, y + @as(i32, @intCast(line_index)) * 18, width, scratch, remaining[0..take], fg, bg);
        remaining = std.mem.trimStart(u8, remaining[take..], " \t\r\n");
    }
}

fn clampI32(value: i32, low: i32, high: i32) i32 {
    return @max(low, @min(high, value));
}
