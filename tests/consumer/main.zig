//! Uses the exported interfaces as a probe or engine implementation would.

const std = @import("std");
const proto = @import("proto");
const engine_contract = @import("engine_contract");

test "a consumer can encode a hello frame" {
    var hello = proto.Hello{};
    const bytes = std.mem.asBytes(&hello);
    try std.testing.expectEqual(@as(usize, 128), bytes.len);
    try std.testing.expectEqual(proto.hello_magic, std.mem.readInt(u32, bytes[0..4], .little));
}

test "a consumer can read the engine contract version" {
    try std.testing.expectEqual(1, engine_contract.version);
}
