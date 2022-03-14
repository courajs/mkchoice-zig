const std = @import("std");
const mibu = @import("mibu");

pub const RawInputReader = struct {
    pub const Self = @This();
    pub const Buffer = std.fifo.LinearFifo(u8, .{ .Static = 512 });

    tty: std.fs.File,
    buf: Buffer,
    raw: mibu.term.RawTerm,

    pub fn init(tty: std.fs.File) !Self {
        var raw = try mibu.term.RawTerm.enableRawMode(tty.handle, .blocking);
        try tty.writeAll(mibu.cursor.hide());
        return Self{
            .tty = tty,
            .raw = raw,
            .buf = Buffer.init(),
        };
    }

    pub fn deinit(self: *Self) !void {
        try self.tty.writeAll(mibu.cursor.show());
        try self.raw.disableRawMode();
    }

    // Non-blocking check for already buffered data
    pub fn try_next(self: *Self) !?mibu.events.Event {
        switch (try mibu.events.next(self.buf.readableSlice(0))) {
            .none => return null,
            .not_supported => {
                self.buf.discard(self.buf.count);
                return null;
            },
            .incomplete => return null,
            .event => |event_result| {
                self.buf.discard(event_result.bytes_read);
                return event_result.event;
            },
        }
    }

    // Blocking wait for next event
    pub fn next(self: *Self) !mibu.events.Event {
        while (true) {
            switch (try mibu.events.next(self.buf.readableSlice(0))) {
                .none => {
                    try self.do_read();
                },
                .not_supported => {
                    self.buf.discard(self.buf.count);
                },
                .incomplete => {
                    try self.do_read();
                },
                .event => |event_result| {
                    self.buf.discard(event_result.bytes_read);
                    return event_result.event;
                },
            }
        }
    }

    // Blocking read for more user input
    pub fn do_read(self: *Self) !void {
        self.buf.realign();
        var count = try self.tty.read(self.buf.writableSlice(0));
        self.buf.update(count);
    }
};
