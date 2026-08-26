const std = @import("std");
const game_of_life = @import("game_of_life");

pub fn main(init: std.process.Init) !void {
    const dims = game_of_life.determineGameBoardDimensions(init.io) catch {
        std.debug.print("Terminal is too small to run game!", .{});
        return;
    };
    std.debug.print("Game board dimensions: {d}x{d}\n", .{ dims.x, dims.y });
    std.debug.print("Utility functions are available from the game_of_life module.\n", .{});

    const allocator = init.arena.allocator();

    for (0..3) |i| {
        std.debug.print("Starting game in {d} seconds...\n", .{3 - i});
        try init.io.sleep(std.Io.Duration.fromSeconds(1), std.Io.Clock.awake);
    }

    game_of_life.enableTerminalInput(init.io) catch |err| {
        std.log.err("Failed to begin terminal input: {s}", .{@errorName(err)});
        return;
    };
    defer game_of_life.restoreTerminalInput(init.io);

    const width: usize = @intCast(dims.x);
    const height: usize = @intCast(dims.y);
    const current_cells = try allocator.alloc(u8, width * height);
    @memset(current_cells, 0);
    const next_cells = try allocator.alloc(u8, width * height);
    @memset(next_cells, 0);

    const current_game_board = try allocator.alloc([]u8, height);
    const next_game_board = try allocator.alloc([]u8, height);
    for (current_game_board, next_game_board, 0..) |*current_row, *next_row, y| {
        current_row.* = current_cells[(y * width)..][0..width];
        next_row.* = next_cells[(y * width)..][0..width];
    }

    while (true) {
        if (game_of_life.checkForQuit()) return;

        const maybe_click = game_of_life.checkForClick() catch |err| {
            std.log.err("Failed to checkForClick, ending game. Err: {s}", .{@errorName(err)});
            return;
        };

        if (maybe_click) |click| {
            game_of_life.updateClickedCell(click, current_game_board);
        }

        game_of_life.evolveState(current_game_board, next_game_board);

        try game_of_life.writeFrame(init.io, current_game_board);
        try init.io.sleep(std.Io.Duration.fromMilliseconds(100), std.Io.Clock.awake);
    }
}
