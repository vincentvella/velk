pub const types = @import("openai/types.zig");
pub const client = @import("openai/client.zig");
pub const provider = @import("openai/provider.zig");

pub const Client = client.Client;
pub const Adapter = provider.Adapter;
pub const Error = client.Error;

test {
    _ = types;
    _ = client;
    _ = provider;
}
