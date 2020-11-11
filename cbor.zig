const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;

pub const MajorType = enum(u8) {
    Int = 0x00,
    NegativeInt = 0x20,
    ByteString = 0x40,
    TextString = 0x60,
    Array = 0x80,
    Map = 0xa0,
    Tag = 0xc0,
    Simple = 0xe0,
};

const payload_size = struct {
    const b8 = 24;
    const b16 = 25;
    const b32 = 26;
    const b64 = 27;
    const indefinite = 31;
};

const simple = struct {
    const @"false" = 20;
    const @"true" = 21;
    const @"null" = 22;
    const @"undefined" = 23;
    const next_byte = 24;
    const @"break" = 31;
};

pub const Encoder = struct {
    context: ArrayList(u8),

    pub fn init(allocator: *std.mem.Allocator) Encoder {
        return .{
            .context = ArrayList(u8).init(allocator),
        };
    }

    pub fn toOwnedSlice(self: *Encoder) []u8 {
        return self.context.toOwnedSlice();
    }

    /// Writes major type + value for integer and tag types, and length for container types
    pub fn writeHeader(self: *Encoder, major_type: MajorType, val: u64) !void {
        const major = @enumToInt(major_type);
        if (val < 24) {
            try self.context.append(major | @intCast(u8, val));
        } else inline for ([_]type{ u8, u16, u32, u64 }) |T, i| {
            if (val <= std.math.maxInt(T)) {
                var buf: [@sizeOf(T)]u8 = undefined;
                std.mem.writeIntBig(T, buf[0..], @intCast(T, val));
                try self.context.append(major | @intCast(u8, 24 + i));
                try self.context.appendSlice(buf[0..]);
                break;
            }
        } else unreachable;
    }

    pub fn encodeInt(self: *Encoder, val: anytype) !void {
        const type_info = @typeInfo(@TypeOf(val));
        std.debug.assert(type_info == .Int or type_info == .ComptimeInt);
        if (val >= 0) {
            try self.writeHeader(.Int, val);
        } else {
            try self.writeHeader(.NegativeInt, -val - 1);
        }
    }

    pub fn encodeTag(self: *Encoder, val: u64) !void {
        try self.writeHeader(.Tag, val);
    }

    // Can comptime_float be coerced to a runtime float type deterministically?
    pub fn encodeFloat(self: *Encoder, val: anytype) !void {
        const T = @TypeOf(val);
        std.debug.assert(@typeInfo(T) == .Float);
        const size = switch (T) {
            f16 => payload_size.b16,
            f32 => payload_size.b32,
            f64 => payload_size.b64,
            else => unreachable,
        };
        var buf: [@sizeOf(T)]u8 = undefined;
        const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
        std.mem.writeIntBig(Int, buf[0..], @bitCast(Int, val));
        try self.context.append(@enumToInt(MajorType.Simple) | size);
        try self.context.appendSlice(buf[0..]);
    }

    pub fn encodeBool(self: *Encoder, val: bool) !void {
        try self.writeHeader(.Simple, if (val) simple.@"true" else simple.@"false");
    }

    pub fn encodeNull(self: *Encoder) !void {
        try self.writeHeader(.Simple, simple.@"null");
    }

    pub fn encodeUndefined(self: *Encoder) !void {
        try self.writeHeader(.Simple, simple.@"undefined");
    }

    pub fn encodeSimple(self: *Encoder, val: u8) !void {
        try self.context.append(@enumToInt(MajorType.Simple) | simple.next_byte);
        try self.context.append(val);
    }

    /// Also encodes slice length. Use `writeHeader(.ByteString, slice)`,
    /// followed by `appendSlice` to encode with indefinite length
    pub fn encodeByteString(self: *Encoder, slice: []const u8) !void {
        try self.writeHeader(.ByteString, slice.len);
        try self.appendSlice(slice);
    }

    /// Also encodes slice length. Use `writeHeader(.TextString, slice)`,
    /// followed by `appendSlice` to encode with indefinite length
    pub fn encodeTextString(self: *Encoder, slice: []const u8) !void {
        try self.writeHeader(.TextString, slice.len);
        try self.appendSlice(slice);
    }

    /// Encode a struct as an array of values
    /// See also `encodeStructAsMap`
    pub fn encodeStruct(self: *Encoder, arg: anytype) !void {
        const fields = std.meta.fields(@TypeOf(arg));
        try self.beginArray(fields.len);
        inline for (fields) |field| {
            try self.encodeGeneric(@field(arg, field.name));
        }
    }

    /// Given a struct field name, should encode a key in `encoder`
    pub const Mapper = fn (encoder: *Encoder, name: []const u8) anyerror!void;

    /// Encode a key-value map based on a struct
    /// If `mapper` is null, keys are field names
    /// See also `encodeStruct`
    pub fn encodeStructAsMap(self: *Encoder, arg: anytype, mapperFn: ?Mapper) !void {
        const map = mapperFn orelse encodeTextString;
        const fields = std.meta.fields(@TypeOf(arg));
        try self.beginMap(fields.len);
        inline for (fields) |field, i| {
            try map(self, field.name);
            try self.encodeGeneric(@field(arg, field.name));
        }
    }

    pub fn encodeGeneric(self: *Encoder, val: anytype) !void {
        try switch (@typeInfo(@TypeOf(val))) {
            .Int => self.encodeInt(val),
            .Float => self.encodeFloat(val),
            .Bool => self.encodeBool(val),
            .Optional => self.encodeOptional(val),
            .Struct => self.encodeStruct(val),
            .EnumLiteral => self.encodeInt(@enumToInt(val)),
            .Void => return,
            else => @panic("Unacceptable field for encodeStruct: " ++ @typeName(@TypeOf(val))),
        };
    }

    pub fn encodeOptional(self: *Encoder, opt: anytype) !void {
        std.debug.assert(@typeInfo(@TypeOf(array)) == .Optional);
        if (opt) |val| self.encodeGeneric(val) else self.encodeNull();
    }

    pub fn encodeArray(self: *Encoder, array: anytype) !void {
        std.debug.assert(@typeInfo(@TypeOf(array)) == .Array);
        try self.beginArray(array.len);
        for (array) |x| try self.encodeGeneric(x);
    }

    /// Copy a slice of bytes verbatim
    pub fn appendSlice(self: *Encoder, slice: []const u8) !void {
        try self.context.appendSlice(slice);
    }

    /// Arrays with indefinite length should be closed with `closeContainer`
    pub fn beginArray(self: *Encoder, length: ?u64) !void {
        if (length) |l| {
            try self.writeHeader(.Array, l);
        } else {
            try self.context.append(@enumToInt(MajorType.Array) | payload_size.indefinite);
        }
    }

    /// Maps with indefinite length should be closed with `closeContainer`
    pub fn beginMap(self: *Encoder, length: ?u64) !void {
        if (length) |l| {
            try self.writeHeader(.Map, l);
        } else {
            try self.context.append(@enumToInt(MajorType.Map) | payload_size.indefinite);
        }
    }

    /// Closes last begun array with indefinite length
    pub fn closeArray(self: *Encoder) !void {
        try self.context.append(@enumToInt(MajorType.Simple) | simple.@"break");
    }
};

test "encode" {
    var buffer: [100]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);
    var encoder = Encoder.init(&fba.allocator);

    try encoder.beginArray(null);
    try encoder.encodeInt(123);
    try encoder.encodeInt(-12);
    try encoder.encodeFloat(@as(f64, 3.1415));
    try encoder.closeArray();

    testEncode(
        "\x9f\x18\x7b\x2b\xfb\x40\x09\x21\xca\xc0\x83\x12\x6f\xff",
        encoder.toOwnedSlice(),
    );

    try encoder.beginArray(null);
    try encoder.encodeBool(false);
    try encoder.encodeNull();
    try encoder.encodeTextString("hello world");
    try encoder.closeArray();

    testEncode(
        "\x9f\xf4\xf6\x6bhello world\xff",
        encoder.toOwnedSlice(),
    );

    const s: struct {
        x: u16,
        y: f32,
        z: bool,
    } = .{ .x = 1, .y = 2.0, .z = false };

    try encoder.encodeStruct(s);

    testEncode(
        "\x83\x01\xfa\x40\x00\x00\x00\xf4",
        encoder.toOwnedSlice(),
    );

    try encoder.encodeArray([_]u8{ 1, 2, 3, 4, 255 });

    testEncode(
        "\x85\x01\x02\x03\x04\x18\xff",
        encoder.toOwnedSlice(),
    );

    const t: struct {
        serial_nr: u16,
        value1: f32,
        value2: bool,
    } = .{ .serial_nr = 0x1231, .value1 = 14.0, .value2 = false };

    try encoder.encodeStructAsMap(t, null);

    testEncode(
        "\xa3\x69serial_nr\x19\x12\x31\x66value1\xfa\x41\x60\x00\x00\x66value2\xf4",
        encoder.toOwnedSlice(),
    );
}

fn testEncode(expected: []const u8, actual: []const u8) void {
    if (!std.mem.eql(u8, expected, actual)) {
        print("Expected: \n\t", .{});
        for (expected) |c| print("{x:0>2} ", .{c});
        print("\nActual: \n\t", .{});
        for (actual) |c| print("{x:0>2} ", .{c});
        print("\n", .{});
        std.testing.expect(false);
    }
}

fn testMapper(encoder: *Encoder, name: []const u8) !void {
    const Mapping = struct {
        name: []const u8,
        tag: u8,
    };
    const mappings = [_]Mapping{
        .{ .name = "serial_nr", .tag = 10 },
        .{ .name = "value1", .tag = 20 },
        .{ .name = "value2", .tag = 30 },
    };
    for (mappings) |mapping| {
        if (std.mem.eql(u8, name, mapping.name)) {
            return encoder.encodeInt(mapping.tag);
        }
    }
}
