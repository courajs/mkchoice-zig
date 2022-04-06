const std = @import("std");
const args_parser = @import("args"); // https://github.com/MasterQ32/zig-args
const mibu = @import("mibu"); // https://github.com/xyaman/mibu
const input = @import("./input.zig");

// All the information to start running the app
const Parameters = struct {
    opts: CliConfig,
    choices: []const []const u8,
};

// Config passed via command line switches
const CliConfig = struct {
    const Self = @This();

    prompt: []const u8 = "Choose one:",
    vanish: bool = false,
    selection: ?[]const u8 = null,
    index: ?usize = null,
    help: bool = false,

    pub const shorthands = .{
        .h = "help",
        .n = "index",
        .p = "prompt",
        .s = "selection",
        .v = "vanish",
    };
};

// Load app parameters from argv and maybe stdin
pub fn load_parameters(alloc: std.mem.Allocator) !Parameters {
    var args = try args_parser.parseForCurrentProcess(CliConfig, alloc, .print);
    var choices: []const []const u8 = args.positionals;
    // Check all non-raw arguments for `-`, which indicates we
    // should splice in lines from stdin.
    var end = args.raw_start_index orelse args.positionals.len;
    for (args.positionals[0..end]) |arg, idx| {
        if (std.mem.eql(u8, arg, "-")) {
            var _choices = std.ArrayList([]const u8).init(alloc);
            try _choices.appendSlice(choices[0..idx]);
            try _choices.appendSlice(try get_stdin_lines_alloc(alloc));
            try _choices.appendSlice(choices[idx + 1 ..]);
            choices = _choices.toOwnedSlice();
            break;
        }
    }
    // If no positional arguments, default read from stdin for options
    if (args.positionals.len == 0 and !args.options.help) {
        choices = try get_stdin_lines_alloc(alloc);
    }
    return Parameters{
        .opts = args.options,
        .choices = choices,
    };
}

fn get_stdin_lines_alloc(alloc: std.mem.Allocator) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).init(alloc);
    var stdin = std.io.getStdIn();
    var reader = stdin.reader();
    const pretty_big = 1 << 16;
    while (try reader.readUntilDelimiterOrEofAlloc(alloc, '\n', pretty_big)) |line| {
        try lines.append(line);
    }
    return lines.toOwnedSlice();
}

// A running app
pub const App = struct {
    const Self = @This();
    const State = usize;

    params: Parameters,
    state: State,
    tty: std.fs.File,

    fn initial_state(params: Parameters) usize {
        if (params.opts.index) |i| return i;
        if (params.opts.selection) |initial_selection| {
            for (params.choices) |choice, i| {
                if (std.mem.eql(u8, choice, initial_selection)) {
                    return i;
                }
            }
        }
        return 0;
    }

    fn vanish(self: Self) !void {
        if (self.params.opts.vanish) {
            var size = try mibu.term.getSizeFd(self.tty.handle);
            var rendered_heght = self.full_height(size);
            try self.tty.writer().print("\r{s}{s}", .{ mibu.cursor.goUp(rendered_heght), mibu.clear.screen_from_cursor });
        }
    }

    pub const help_text =
        \\Usage: mkchoice [-h|--help] [-v|--vanish]
        \\            [-p|--prompt <prompt>] [-s|--selection <selection>]
        \\            [-n|--index <selected index>]
        \\            [args] [-- <args>]
        \\
        \\  mkchoice prompts the user's tty to choose one of the given choices,
        \\  and outputs the chosen one. Pass - as one of the args to also read
        \\  line-separated options from stdin. Arguments after -- are taken as
        \\  literal choices, not interpreted as flags. If you pass no arguments,
        \\  mkchoice will read from stdin by default.
        \\
        \\  You can pass the initially selected value with --selection, which
        \\  accepts the text of an option that will appear in the list. It
        \\  defaults to the first item if the specified one can't be found. Or,
        \\  you can pass a zero-based index with --index.
        \\
        \\  Change the selected option with up/down or j/k, and confirm your
        \\  selection with space or enter.
        \\
        \\  If the --vanish flag is given, the prompt will be erased from the
        \\  terminal before the output is shown. Otherwise, the final state of
        \\  the prompt will still be visible on the screen.
        \\
        \\  Example:
        \\
        \\  $ seq 3 | mkchoice -s main a - b -p "Which one?" -- -p -h - -- main z >some-file
        \\  Which one?
        \\    a
        \\    1
        \\    2
        \\    3
        \\    b
        \\    -p
        \\    -h
        \\    -
        \\    --
        \\  > main
        \\    z
        \\  $ cat some-file
        \\  main
        \\
    ;

    pub fn run(params: Parameters) !u8 {
        if (params.opts.help) {
            try std.io.getStdErr().writeAll(help_text);
            return 0;
        }
        var app = App{
            .params = params,
            .state = initial_state(params),
            .tty = try std.fs.openFileAbsolute("/dev/tty", .{ .read = true, .write = true }),
        };
        var user_events = try input.RawInputReader.init(app.tty);
        defer user_events.deinit() catch {};

        try app.first_render();

        while (true) {
            switch (app.handle_user_input(try user_events.next())) {
                .next => {},
                .cancel => {
                    try app.vanish();
                    return 1;
                },
                .choice => |c| {
                    try app.vanish();
                    try std.io.getStdOut().writeAll(c);
                    try std.io.getStdOut().writeAll("\n");
                    return 0;
                },
                .update => |s| {
                    app.state = s;
                    try app.re_render();
                },
            }
        }
    }

    // cancel: user aborted via escape or something
    // choice: user made a choice
    // update: re-render with new state
    // next: nothing to do, just wait for next input event
    const EventResult = union(enum) {
        cancel,
        choice: []const u8,
        update: State,
        next,
    };
    fn handle_user_input(self: Self, ev: mibu.events.Event) EventResult {
        return switch (ev.key) {
            .ctrlC, .escape => .cancel,
            .up => self.up(),
            .down => self.down(),
            .ctrlM, .ctrlJ => self.get_choice(),
            .char => |c| switch (c) {
                'q' => .cancel,
                ' ' => self.get_choice(),
                'j' => self.down(),
                'k' => self.up(),
                else => .next,
            },
            else => .next,
        };
    }

    fn up(self: Self) EventResult {
        if (self.state > 0) {
            return EventResult{ .update = self.state - 1 };
        } else {
            return .next;
        }
    }
    fn down(self: Self) EventResult {
        if (self.state < (self.params.choices.len - 1)) {
            return EventResult{ .update = self.state + 1 };
        } else {
            return .next;
        }
    }
    fn get_choice(self: Self) EventResult {
        return EventResult{
            .choice = self.params.choices[self.state],
        };
    }

    fn first_render(self: Self) !void {
        var writer = self.tty.writer();
        try writer.print("{s}\r\n", .{self.params.opts.prompt});
        try self.write_choices(writer);
    }

    fn re_render(self: Self) !void {
        var term_size = try mibu.term.getSizeFd(self.tty.handle);
        var rendered_choice_height = self.choice_height(term_size);
        var writer = self.tty.writer();
        try writer.print("\r{s}{s}", .{ mibu.cursor.goUp(rendered_choice_height), mibu.clear.screen_from_cursor });
        try self.write_choices(writer);
    }

    fn write_choices(self: Self, writer: anytype) !void {
        for (self.params.choices) |choice, i| {
            if (i == self.state) {
                try writer.print("{s}>  {s}{s}\r\n", .{ mibu.color.fg(.green), choice, mibu.color.reset });
            } else {
                try writer.print("  {s}\r\n", .{choice});
            }
        }
    }

    fn full_height(self: Self, term_size: mibu.term.TermSize) usize {
        return str_height(self.params.opts.prompt, term_size.height) + self.choice_height(term_size);
    }
    fn choice_height(self: Self, term_size: mibu.term.TermSize) usize {
        var height: usize = 0;
        for (self.params.choices) |choice, i| {
            if (i == self.state) {
                height += str_height_prefixed(3, choice, term_size.width);
            } else {
                height += str_height_prefixed(2, choice, term_size.width);
            }
        }
        return height;
    }
};

fn str_height_prefixed(prefix_length: usize, s: []const u8, terminal_width: u16) usize {
    var height: usize = 0;
    var lines = std.mem.split(u8, s, "\r\n");
    if (lines.next()) |line| {
        height += 1;
        height += (prefix_length + str_width(line)) / terminal_width;
    }
    while (lines.next()) |line| {
        height += 1;
        height += str_width(line) / terminal_width;
    }
    return height;
}
fn str_height(s: []const u8, terminal_width: u16) usize {
    return str_height_prefixed(0, s, terminal_width);
}
fn str_width(s: []const u8) usize {
    // Todo: unicode & wide character support
    return s.len;
}
