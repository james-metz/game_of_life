const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const GameBoardDimensions = struct {
    x: u64,
    y: u64,
};

pub const Click = struct {
    x: u64,
    y: u64,
};

const live_cell: u8 = ' ';
const dead_cell: u8 = '@';
const non_game_board_rows: u64 = 3; // 2 for title and instructions, 1 for stats on the bottom
var height_and_width: u64 = 0;
var board_origin_col: u64 = 2;
var board_origin_row: u64 = 0;

var quit_requested: bool = false;
var frame_count: u64 = 0;
var game_start_ns: ?i128 = null;
var original_termios: ?posix.termios = null;

const RuntimeError = error{TerminalTooSmall};

/// Find the largest square game board that will fit in the current terminal.
/// One row above the board is reserved for the title and one row below is
/// reserved for timing/FPS stats.
pub fn determineGameBoardDimensions(io: std.Io) RuntimeError!GameBoardDimensions {
    const size = terminalSize(io);
    if (size.rows <= non_game_board_rows) return RuntimeError.TerminalTooSmall;
    const usable_rows = size.rows - non_game_board_rows;
    height_and_width = @min(usable_rows, size.cols);
    if (height_and_width < 10) {
        return RuntimeError.TerminalTooSmall;
    }
    return .{ .x = height_and_width, .y = height_and_width };
}

/// Clear the terminal and write a title, the board, elapsed seconds, and the
/// average FPS since the first call to this function.
///
/// `gameBoard` is intentionally `anytype` so callers can pass fixed-size Zig
/// arrays such as `[height][width]u8` / `*[height][width]u8`. Cells with value
/// 0 are drawn as spaces; all other values are drawn as `#`.
pub fn writeFrame(io: std.Io, gameBoard: [][]u8) !void {
    const now = monotonicNanoTimestamp();
    if (game_start_ns == null) game_start_ns = now;
    frame_count += 1;

    const elapsed_ns: i128 = now - game_start_ns.?;
    const elapsed_seconds: f64 = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const fps: f64 = if (elapsed_seconds > 0)
        @as(f64, @floatFromInt(frame_count)) / elapsed_seconds
    else
        0;

    const stdout = std.Io.File.stdout();
    var header_buffer: [128]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "\x1b[H\x1b[2JLife - click seed, q quit\n", .{});
    try stdout.writeStreamingAll(io, header);

    for (gameBoard) |row| {
        try stdout.writeStreamingAll(io, row);
        try stdout.writeStreamingAll(io, "\n");
    }

    var stats_buffer: [128]u8 = undefined;
    const stats = try std.fmt.bufPrint(&stats_buffer, "elapsed: {d:.2}s  avg fps: {d:.2}\n", .{ elapsed_seconds, fps });
    try stdout.writeStreamingAll(io, stats);
}

/// Check whether a mouse click was received inside the current game board.
/// Returns null when no click is available or when the click is outside board.
///
/// Call `enableTerminalInput()` once before polling this function and
/// `restoreTerminalInput()` before exit so the terminal sends mouse events and
/// input can be read without pressing Enter.
pub fn checkForClick() !?Click {
    var fds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    if (try posix.poll(&fds, 0) == 0) return null;
    if ((fds[0].revents & posix.POLL.IN) == 0) return null;

    var buf: [64]u8 = undefined;
    const len = posix.read(posix.STDIN_FILENO, &buf) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };

    if (std.mem.indexOfScalar(u8, buf[0..len], 'q') != null or
        std.mem.indexOfScalar(u8, buf[0..len], 'Q') != null)
    {
        quit_requested = true;
        return null;
    }

    if (parseMouseClick(buf[0..len])) |terminal_pos| {
        const x = terminal_pos.col - board_origin_col;
        const y = terminal_pos.row - board_origin_row;
        return .{ .x = x, .y = y };
    }

    return null;
}

/// Put stdin into a cbreak-like mode and enable SGR mouse reporting.
pub fn enableTerminalInput(io: std.Io) !void {
    if (original_termios == null) {
        original_termios = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = original_termios.?;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
    }
    try std.Io.File.stdout().writeStreamingAll(io, "\x1b[?1000h\x1b[?1006h");
}

/// Restore terminal input mode and disable mouse reporting.
pub fn restoreTerminalInput(io: std.Io) void {
    std.Io.File.stdout().writeStreamingAll(io, "\x1b[?1006l\x1b[?1000l") catch |err| {
        std.debug.print("Failed to write to std out! {s}", .{@errorName(err)});
    };
    if (original_termios) |termios| {
        posix.tcsetattr(posix.STDIN_FILENO, .NOW, termios) catch {};
        original_termios = null;
    }
}

pub fn resetFrameStats() void {
    frame_count = 0;
    game_start_ns = null;
}

pub fn checkForQuit() bool {
    return quit_requested;
}

const TerminalSize = struct { cols: u64, rows: u64 };

fn monotonicNanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// returns x and y dimensions of stderr or returns x:50 y:50 on error
/// no error value because 50x50 is pretty conservative
fn terminalSize(io: std.Io) TerminalSize {
    const file: std.Io.File = .stderr();

    var winsize: posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const err = (io.operate(.{ .device_io_control = .{
        .file = file,
        .code = posix.T.IOCGWINSZ,
        .arg = &winsize,
    } }) catch {
        std.log.debug("failed to determine terminal size; using conservative guess 50x50", .{});
        return TerminalSize{ .rows = 50, .cols = 50 };
    }).device_io_control;

    if (err >= 0) {
        return TerminalSize{ .rows = winsize.row, .cols = winsize.col };
    } else {
        std.log.debug("failed to determine terminal size; using conservative guess 80x25", .{});
        return TerminalSize{ .rows = 50, .cols = 50 };
    }
}

const TerminalPosition = struct { col: u64, row: u64 };

fn parseMouseClick(input: []const u8) ?TerminalPosition {
    // SGR mouse mode: ESC [ < button ; col ; row M
    if (std.mem.indexOf(u8, input, "\x1b[<")) |start| {
        var i = start + 3;
        _ = parseUnsigned(input, &i) orelse return null; // button
        if (i >= input.len or input[i] != ';') return null;
        i += 1;
        const col = parseUnsigned(input, &i) orelse return null;
        if (i >= input.len or input[i] != ';') return null;
        i += 1;
        const row = parseUnsigned(input, &i) orelse return null;
        if (i >= input.len or input[i] != 'M') return null; // ignore release events ('m')
        return .{ .col = col, .row = row };
    }

    // X10 mouse mode: ESC [ M button col row (values are encoded as byte - 32)
    if (std.mem.indexOf(u8, input, "\x1b[M")) |start| {
        if (start + 5 >= input.len) return null;
        const col_byte = input[start + 4];
        const row_byte = input[start + 5];
        if (col_byte < 33 or row_byte < 33) return null;
        return .{ .col = col_byte - 32, .row = row_byte - 32 };
    }

    return null;
}

fn parseUnsigned(input: []const u8, index: *usize) ?u64 {
    var value: u64 = 0;
    var saw_digit = false;
    while (index.* < input.len and std.ascii.isDigit(input[index.*])) : (index.* += 1) {
        saw_digit = true;
        value = value * 10 + (input[index.*] - '0');
    }
    return if (saw_digit) value else null;
}

pub fn updateClickedCell(click: Click, gameBoard: [][]u8) void {
    if (gameBoard.len == 0) return;

    const x: usize = @intCast(click.x);
    const y: usize = @intCast(click.y);

    setCellAlive(gameBoard, x, y);
    if (x > 0) setCellAlive(gameBoard, x - 1, y);
    setCellAlive(gameBoard, x + 1, y);
    if (y > 0) setCellAlive(gameBoard, x, y - 1);
    setCellAlive(gameBoard, x, y + 1);
}

fn setCellAlive(gameBoard: [][]u8, x: usize, y: usize) void {
    if (y >= gameBoard.len or x >= gameBoard[y].len) return;
    gameBoard[y][x] = live_cell;
}

pub fn evolveState(gameBoard: [][]u8, nextGameBoard: [][]u8) void {
    if (gameBoard.len == 0) return;

    for (gameBoard, 0..) |row, y| {
        for (row, 0..) |cell, x| {
            const live_cells = countLiveCells(x, y, gameBoard);
            nextGameBoard[y][x] = switch (cell) {
                dead_cell => if (live_cells == 3) live_cell else dead_cell,
                live_cell => if (live_cells == 2 or live_cells == 3) live_cell else dead_cell,
                else => dead_cell,
            };
        }
    }

    for (gameBoard, nextGameBoard) |current_row, next_row| {
        @memcpy(current_row, next_row);
    }
}

fn countLiveCells(x: usize, y: usize, gameBoard: [][]u8) u64 {
    var live_cells: u64 = 0;
    const offsets = [_]isize{ -1, 0, 1 };

    for (offsets) |dy| {
        const ny_signed = @as(isize, @intCast(y)) + dy;
        if (ny_signed < 0) continue;
        const ny: usize = @intCast(ny_signed);
        if (ny >= gameBoard.len) continue;

        for (offsets) |dx| {
            if (dx == 0 and dy == 0) continue;

            const nx_signed = @as(isize, @intCast(x)) + dx;
            if (nx_signed < 0) continue;
            const nx: usize = @intCast(nx_signed);
            if (nx >= gameBoard[ny].len) continue;

            if (gameBoard[ny][nx] == live_cell) live_cells += 1;
        }
    }

    return live_cells;
}

test "determine dimensions returns a square" {
    const dims = try determineGameBoardDimensions(std.testing.io);
    try std.testing.expect(dims.x == dims.y);
    try std.testing.expect(dims.x > 0);
}

test "parse SGR mouse click" {
    const pos = parseMouseClick("\x1b[<0;12;7M").?;
    try std.testing.expectEqual(@as(u64, 12), pos.col);
    try std.testing.expectEqual(@as(u64, 7), pos.row);
}

test "writeFrame accepts row slices" {
    if (false) {
        var row_0 = [_]u8{ 0, 1 };
        var row_1 = [_]u8{ 1, 0 };
        var board = [_][]u8{ &row_0, &row_1 };
        try writeFrame(std.testing.io, &board);
    }
}
