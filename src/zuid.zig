const std = @import("std");

const rand = std.crypto.random;

/// Pre-defined UUID Namespaces from RFC-4122.
pub const UuidNamespace = struct {
    pub const DNS = deserialize("6ba7b810-9dad-11d1-80b4-00c04fd430c8") catch unreachable;
    pub const URL = deserialize("6ba7b811-9dad-11d1-80b4-00c04fd430c8") catch unreachable;
    pub const OID = deserialize("6ba7b812-9dad-11d1-80b4-00c04fd430c8") catch unreachable;
    pub const X500 = deserialize("6ba7b814-9dad-11d1-80b4-00c04fd430c8") catch unreachable;
};

/// Convert a hexadecimal character to a numberic digit.
fn hexCharToInt(c: u8) u8 {
    switch (c) {
        '0'...'9' => return c - '0',
        'a'...'f' => return c - 'a' + 10,
        'A'...'F' => return c - 'A' + 10,
        else => return 0,
    }
}

pub const UUID = struct {
    time_low: u32,
    time_mid: u16,
    time_hi_and_version: u16,
    clock_seq_hi_and_reserved: u8,
    clock_seq_low: u8,
    node: u48,

    pub fn toString(self: *const UUID) ![36]u8 {
        var buffer: [36]u8 = undefined;
        _ = try std.fmt.bufPrint(&buffer, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>12}", .{
            self.time_low,
            self.time_mid,
            self.time_hi_and_version,
            self.clock_seq_hi_and_reserved,
            self.clock_seq_low,
            self.node,
        });

        return buffer;
    }

    pub fn toInt(self: *const UUID) u128 {
        const time_low = @as(u128, @intCast(self.time_low)) << 96;
        const time_mid = @as(u128, @intCast(self.time_mid)) << 80;
        const time_hi_and_version = @as(u128, @intCast(self.time_hi_and_version)) << 64;
        const clock_seq_hi_and_reserved = @as(u128, @intCast(self.clock_seq_hi_and_reserved)) << 56;
        const clock_seq_low = @as(u128, @intCast(self.clock_seq_low)) << 48;
        const node = @as(u128, @intCast(self.node));

        return time_low | time_mid | time_hi_and_version | clock_seq_hi_and_reserved | clock_seq_low | node;
    }

    pub fn toArray(self: *const UUID) ![16]u8 {
        var byte_array: [16]u8 = undefined;

        const str = try self.toString();

        var byte: u8 = 0;
        var high_nibble: bool = true;
        var byte_indexx: usize = 0;

        for (str) |char| {
            if (char == '-') {
                continue;
            }

            byte |= hexCharToInt(char);

            if (high_nibble) {
                byte <<= 4;
                high_nibble = false;
            } else {
                byte_array[byte_indexx] = byte;
                byte_indexx += 1;
                byte = 0;
                high_nibble = true;
            }
        }

        return byte_array;
    }
};

/// Create a UUID object from a string
pub fn deserialize(urn: []const u8) !UUID {
    @setEvalBranchQuota(4096);

    if (urn.len != 36 or std.mem.count(u8, urn, "-") != 4 or urn[8] != '-' or urn[13] != '-' or urn[18] != '-' or urn[23] != '-') {
        return error.InvalidUuid;
    }

    const time_low = try std.fmt.parseInt(u32, urn[0..8], 16);
    const time_mid = try std.fmt.parseInt(u16, urn[9..13], 16);
    const time_hi_and_version = try std.fmt.parseInt(u16, urn[14..18], 16);
    const clock_seq_hi_and_reserved = try std.fmt.parseInt(u8, urn[19..21], 16);
    const clock_seq_low = try std.fmt.parseInt(u8, urn[21..23], 16);
    const node = try std.fmt.parseInt(u48, urn[24..36], 16);

    return UUID{
        .time_low = time_low,
        .time_mid = time_mid,
        .time_hi_and_version = time_hi_and_version,
        .clock_seq_hi_and_reserved = clock_seq_hi_and_reserved,
        .clock_seq_low = clock_seq_low,
        .node = node,
    };
}

/// Get the time since the Gregorian epoch as 100-nanosecond units.
fn getTime() u60 {
    const current_time = std.time.nanoTimestamp();
    const since_epoch_nano_seconds: i128 = current_time + 12_220_761_600_000_000_000;
    const intervals_since_gregorian_epoch = @divFloor(since_epoch_nano_seconds, 100);
    const i_60_value = intervals_since_gregorian_epoch & 0x0FFFFFFFFFFFFFFF;

    return @as(u60, @intCast(i_60_value));
}

/// Create a new UUID
pub const new = struct {
    pub fn v1() UUID {
        const timestamp = getTime();

        // This library uses random values for the node and clock sequence because
        // it is not easy to get the MAC address of the machine in Zig.
        // This may be implemented in the future, but for now, it is not a priority.
        var node = rand.int(u48);
        node |= 1 << 40; // Set multicast bit to distinguish from IEEE 802 MAC addresses.

        const clock_seq = @as(u16, @intCast(rand.int(u14)));

        const time_low = @as(u32, @intCast(timestamp & 0xFFFFFFFF));
        const time_mid = @as(u16, @intCast((timestamp >> 32) & 0xFFFF));

        var time_hi_and_version = @as(u16, @intCast(timestamp >> 48));
        time_hi_and_version &= 0x0FFF;
        time_hi_and_version |= 0x1000;

        const clock_seq_low = @as(u8, @intCast(clock_seq & 0xFF));

        var clock_seq_hi_and_reserved = @as(u8, @intCast(clock_seq >> 8));
        clock_seq_hi_and_reserved &= 0x3F;
        clock_seq_hi_and_reserved |= 0x80;

        return UUID{
            .time_low = time_low,
            .time_mid = time_mid,
            .time_hi_and_version = time_hi_and_version,
            .clock_seq_hi_and_reserved = clock_seq_hi_and_reserved,
            .clock_seq_low = clock_seq_low,
            .node = node,
        };
    }

    pub fn v3(uuid_namespace: UUID, name: []const u8) !UUID {
        var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        const namespace_str = try uuid_namespace.toArray();

        var hasher = std.crypto.hash.Md5.init(.{});

        hasher.update(&namespace_str);
        hasher.update(name);

        hasher.final(&digest);

        const time_low = std.mem.nativeToBig(u32, std.mem.bytesToValue(u32, digest[0..4]));
        const time_mid = std.mem.nativeToBig(u16, std.mem.bytesToValue(u16, digest[4..6]));

        var time_hi_and_version = std.mem.nativeToBig(u16, std.mem.bytesToValue(u16, digest[6..8]));
        time_hi_and_version &= 0x0FFF;
        time_hi_and_version |= 0x3000;

        var clock_seq_hi_and_reserved = std.mem.nativeToBig(u8, digest[8]);
        clock_seq_hi_and_reserved &= 0x3F;
        clock_seq_hi_and_reserved |= 0x80;

        const clock_seq_low = std.mem.nativeToBig(u8, digest[9]);
        const node = std.mem.nativeToBig(u48, std.mem.bytesToValue(u48, digest[10..16]));

        return UUID{
            .time_low = time_low,
            .time_mid = time_mid,
            .time_hi_and_version = time_hi_and_version,
            .clock_seq_hi_and_reserved = clock_seq_hi_and_reserved,
            .clock_seq_low = clock_seq_low,
            .node = node,
        };
    }

    pub fn v4() UUID {
        const time_low = rand.int(u32);
        const time_mid = rand.int(u16);

        var time_hi_and_version = rand.int(u16);
        time_hi_and_version &= 0x0FFF;
        time_hi_and_version |= 0x4000;

        var clock_seq_hi_and_reserved = rand.int(u8);
        clock_seq_hi_and_reserved &= 0x3F;
        clock_seq_hi_and_reserved |= 0x80;

        const clock_seq_low = rand.int(u8);
        const node = rand.int(u48);

        return UUID{
            .time_low = time_low,
            .time_mid = time_mid,
            .time_hi_and_version = time_hi_and_version,
            .clock_seq_hi_and_reserved = clock_seq_hi_and_reserved,
            .clock_seq_low = clock_seq_low,
            .node = node,
        };
    }

    pub fn v5(uuid_namespace: UUID, name: []const u8) !UUID {
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        const namespace_str = try uuid_namespace.toArray();

        var hasher = std.crypto.hash.Sha1.init(.{});

        hasher.update(&namespace_str);
        hasher.update(name);

        hasher.final(&digest);

        const time_low = std.mem.nativeToBig(u32, std.mem.bytesToValue(u32, digest[0..4]));
        const time_mid = std.mem.nativeToBig(u16, std.mem.bytesToValue(u16, digest[4..6]));

        var time_hi_and_version = std.mem.nativeToBig(u16, std.mem.bytesToValue(u16, digest[6..8]));
        time_hi_and_version &= 0x0FFF;
        time_hi_and_version |= 0x5000;

        var clock_seq_hi_and_reserved = std.mem.nativeToBig(u8, digest[8]);
        clock_seq_hi_and_reserved &= 0x3F;
        clock_seq_hi_and_reserved |= 0x80;

        const clock_seq_low = std.mem.nativeToBig(u8, digest[9]);
        const node = std.mem.nativeToBig(u48, std.mem.bytesToValue(u48, digest[10..16]));

        return UUID{
            .time_low = time_low,
            .time_mid = time_mid,
            .time_hi_and_version = time_hi_and_version,
            .clock_seq_hi_and_reserved = clock_seq_hi_and_reserved,
            .clock_seq_low = clock_seq_low,
            .node = node,
        };
    }
};
